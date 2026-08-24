#define _POSIX_C_SOURCE 200809L

#include "rollback.h"

#include "network_plan.h"

#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#define RB_RECORD_SIZE 512U
#define RB_COPY_BUFFER_SIZE 4096U

static const char *scope_name(rb_scope_t scope);
static const char *config_name(rb_scope_t scope);
static bool valid_id(const char *id);
static int ensure_directory(int parent, const char *name, mode_t mode);
static int open_root(const char *path);
static int open_transactions(rb_context_t *context);
static int open_pending(rb_context_t *context);
static int injected_fsync(rb_context_t *context, int descriptor, bool directory);
static ssize_t injected_write(rb_context_t *context, int descriptor,
                              const void *buffer, size_t size);
static int write_all(rb_context_t *context, int descriptor,
                     const void *buffer, size_t size);
static int atomic_write(rb_context_t *context, int directory,
                        const char *temporary, const char *destination,
                        const void *buffer, size_t size, mode_t mode);
static int copy_regular_atomic(rb_context_t *context, int source_directory,
                               const char *source_name, int destination_directory,
                               const char *temporary, const char *destination,
                               mode_t destination_mode, bool restoring);
static int write_record(rb_context_t *context, const rb_record_t *record,
                        const char *name);
static int parse_record(const char *text, rb_record_t *record);
static bool transition_allowed(rb_state_t from, rb_state_t to);
static int rollback_current(rb_context_t *context, rb_record_t *record);

static int generate_token(char *out, size_t out_size)
{
    unsigned char bytes[RB_NETWORK_PLAN_TOKEN_HEX_LEN / 2U];
    static const char hex[] = "0123456789abcdef";
    int descriptor;
    ssize_t count;
    size_t index;

    if ((out == NULL) || (out_size < (RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U))) {
        errno = EINVAL;
        return -1;
    }
    descriptor = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return -1;
    count = read(descriptor, bytes, sizeof(bytes));
    (void)close(descriptor);
    if (count != (ssize_t)sizeof(bytes)) {
        errno = EIO;
        return -1;
    }
    for (index = 0U; index < sizeof(bytes); index++) {
        out[index * 2U] = hex[(bytes[index] >> 4U) & 0x0fU];
        out[(index * 2U) + 1U] = hex[bytes[index] & 0x0fU];
    }
    out[RB_NETWORK_PLAN_TOKEN_HEX_LEN] = '\0';
    return 0;
}

static int generate_id(char *out, size_t out_size)
{
    unsigned char buf[16];
    const char *hex = "0123456789abcdef";
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t r = read(fd, buf, sizeof(buf));
    (void)close(fd);
    if (r != (ssize_t)sizeof(buf)) return -1;
    if (out == NULL) { errno = EINVAL; return -1; }
    if (out_size < 33) { errno = EINVAL; return -1; }
    for (size_t i = 0; i < sizeof(buf); i++) {
        out[i * 2] = hex[(buf[i] >> 4) & 0x0f];
        out[(i * 2) + 1] = hex[buf[i] & 0x0f];
    }
    out[32] = '\0';
    return 0;
}

int rb_guard_arm(rb_context_t *context, const char *plan_token, const void *request_payload)
{
    const rb_network_request_t *request = (const rb_network_request_t *)request_payload;
    rb_network_plan_t plan;
    rb_network_plan_t consumed;
    rb_record_t existing;
    int config_dir = -1;
    int transactions = -1;
    int pending = -1;
    char id[RB_ID_SIZE];

    if ((context == NULL) || (plan_token == NULL) || (request == NULL)) { errno = EINVAL; return -1; }
    if (!rb_network_plan_token_valid(plan_token)) { errno = EINVAL; return -1; }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (rb_load_current(context, &existing) == 0) { errno = EBUSY; return -1; }
    if (errno != ENOENT) return -1;

    if (rb_network_plan_load(context, plan_token, &plan) != 0) return -1;
    if (rb_network_plan_verify_request(&plan, request) != 0) return -1;

    config_dir = open_root(context->config_root);
    transactions = open_transactions(context);
    if ((config_dir < 0) || (transactions < 0) || (ensure_directory(transactions, "pending", 0700) != 0)) goto arm_err;
    pending = openat(transactions, "pending", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (pending < 0) goto arm_err;
    if (copy_regular_atomic(context, config_dir, config_name(plan.scope), pending,
                            "backup.tmp", "config.backup", 0600, false) != 0) goto arm_err;

    if (generate_id(id, sizeof(id)) != 0) goto arm_err;
    (void)memset(&existing, 0, sizeof(existing));
    (void)snprintf(existing.id, sizeof(existing.id), "%s", id);
    existing.scope = plan.scope;
    existing.state = RB_STATE_STAGED;
    existing.deadline = plan.deadline;
    (void)snprintf(existing.plan_token, sizeof(existing.plan_token), "%s", plan_token);
    (void)snprintf(existing.health_token, sizeof(existing.health_token), "%s",
                   plan.health_token);
    if (write_record(context, &existing, "pending.record") != 0) goto arm_err;

    /* Ensure the pending record is visible on disk before proceeding. */
    {
        int _pend_chk = open_pending(context);
        if (_pend_chk < 0) goto arm_err;
        int _chk = openat(_pend_chk, "pending.record", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        (void)close(_pend_chk);
        if (_chk < 0) goto arm_err;
        (void)close(_chk);
    }

    if (rb_network_plan_consume(context, plan_token, request, &consumed) != 0) goto arm_err;

    /* Some code paths may have removed the on-disk pending record; ensure it still exists. */
    {
        int _pend_chk = open_pending(context);
        int _chk = -1;
        if (_pend_chk >= 0) {
            _chk = openat(_pend_chk, "pending.record", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            (void)close(_pend_chk);
        }
        if (_chk < 0) {
            /* Attempt to re-write the record to restore canonical pending state */
            if (write_record(context, &existing, "pending.record") != 0) goto arm_err;
        } else {
            (void)close(_chk);
        }
    }

    if (pending >= 0) (void)close(pending);
    if (transactions >= 0) (void)close(transactions);
    if (config_dir >= 0) (void)close(config_dir);
    return 0;
arm_err:
    { int saved = errno; if (pending >= 0) (void)close(pending); if (transactions >= 0) (void)close(transactions); if (config_dir >= 0) (void)close(config_dir); errno = saved; }
    return -1;
}

int rb_guard_status(rb_context_t *context, const char *plan_token, rb_record_t *out_record)
{
    rb_record_t record;
    if ((context == NULL) || (plan_token == NULL) || (out_record == NULL)) { errno = EINVAL; return -1; }
    if (rb_load_current(context, &record) != 0) return -1;
    if (record.plan_token[0] == '\0') { errno = ENOENT; return -1; }
    if (strcmp(record.plan_token, plan_token) != 0) { errno = EINVAL; return -1; }
    (void)memcpy(out_record, &record, sizeof(record));
    return 0;
}

int rb_guard_finalize(rb_context_t *context, const char *plan_token)
{
    rb_record_t record;
    struct timespec now;
    if ((context == NULL) || (plan_token == NULL)) { errno = EINVAL; return -1; }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (rb_load_current(context, &record) != 0) return -1;
    if (record.plan_token[0] == '\0') { errno = ENOENT; return -1; }
    if (strcmp(record.plan_token, plan_token) != 0) { errno = EINVAL; return -1; }
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    if (record.deadline <= (int64_t)now.tv_sec) { errno = ETIMEDOUT; return -1; }
    return rb_confirm(context);
}

int rb_guard_set_health_token(rb_context_t *context, char *out_token,
                              size_t out_token_size)
{
    rb_record_t record;
    struct timespec now;

    if ((context == NULL) || (out_token == NULL) ||
        (out_token_size < (RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U)) ||
        (context->lock_fd < 0)) {
        errno = EPERM;
        return -1;
    }
    if (rb_load_current(context, &record) != 0) return -1;
    if (record.state != RB_STATE_PENDING_HEALTH_CONFIRMATION) {
        errno = EINVAL;
        return -1;
    }
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    if (record.deadline <= (int64_t)now.tv_sec) {
        errno = ETIMEDOUT;
        return -1;
    }
    if (generate_token(record.health_token, sizeof(record.health_token)) != 0) {
        return -1;
    }
    if (write_record(context, &record, "pending.record") != 0) return -1;
    (void)snprintf(out_token, out_token_size, "%s", record.health_token);
    return 0;
}

int rb_guard_finalize_health(rb_context_t *context, const char *health_token)
{
    rb_record_t record;
    struct timespec now;

    if ((context == NULL) || (health_token == NULL) ||
        !rb_network_plan_token_valid(health_token)) {
        errno = EINVAL;
        return -1;
    }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (rb_load_current(context, &record) != 0) return -1;
    if ((record.health_token[0] == '\0') ||
        (strcmp(record.health_token, health_token) != 0)) {
        errno = EACCES;
        return -1;
    }
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    if (record.deadline <= (int64_t)now.tv_sec) {
        errno = ETIMEDOUT;
        return -1;
    }
    return rb_confirm(context);
}

int rb_context_init(rb_context_t *context, const char *state_root,
                    const char *config_root, rb_apply_fn apply,
                    void *apply_private)
{
    int state_directory;
    if ((context == NULL) || (state_root == NULL) || (config_root == NULL) ||
        (apply == NULL) || (strlen(state_root) >= sizeof(context->state_root)) ||
        (strlen(config_root) >= sizeof(context->config_root))) {
        errno = EINVAL;
        return -1;
    }
    (void)memset(context, 0, sizeof(*context));
    (void)snprintf(context->state_root, sizeof(context->state_root), "%s", state_root);
    (void)snprintf(context->config_root, sizeof(context->config_root), "%s", config_root);
    context->lock_fd = -1;
    context->apply = apply;
    context->apply_private = apply_private;

    state_directory = open_root(state_root);
    if (state_directory < 0) return -1;
    if (ensure_directory(state_directory, "transactions", 0700) != 0) {
        (void)close(state_directory);
        return -1;
    }
    (void)close(state_directory);
    return 0;
}

void rb_context_close(rb_context_t *context)
{
    if (context == NULL) return;
    rb_unlock(context);
}

void rb_set_failpoint(rb_context_t *context, rb_failpoint_t failpoint)
{
    if (context == NULL) return;
    context->failpoint = failpoint;
    context->failpoint_used = false;
}

int rb_lock(rb_context_t *context)
{
    int root;
    if (context == NULL) { errno = EINVAL; return -1; }
    if (context->lock_fd >= 0) return 0;
    root = open_root(context->state_root);
    if (root < 0) return -1;
    context->lock_fd = openat(root, "transaction.lock",
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    (void)close(root);
    if (context->lock_fd < 0) return -1;
    if (flock(context->lock_fd, LOCK_EX | LOCK_NB) != 0) {
        (void)close(context->lock_fd);
        context->lock_fd = -1;
        return -1;
    }
    return 0;
}

void rb_unlock(rb_context_t *context)
{
    if ((context == NULL) || (context->lock_fd < 0)) return;
    (void)flock(context->lock_fd, LOCK_UN);
    (void)close(context->lock_fd);
    context->lock_fd = -1;
}

int rb_prepare(rb_context_t *context, const char *id, rb_scope_t scope,
               int64_t deadline)
{
    int config_directory = -1;
    int transactions = -1;
    int pending = -1;
    rb_record_t existing;
    rb_record_t record;
    const char *name = config_name(scope);
    int result = -1;

    if ((context == NULL) || !valid_id(id) || (name == NULL) || (deadline <= 0)) {
        errno = EINVAL;
        return -1;
    }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (rb_load_current(context, &existing) == 0) { errno = EBUSY; return -1; }
    if (errno != ENOENT) return -1;

    config_directory = open_root(context->config_root);
    transactions = open_transactions(context);
    if ((config_directory < 0) || (transactions < 0) ||
        (ensure_directory(transactions, "pending", 0700) != 0)) goto done;
    pending = openat(transactions, "pending", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (pending < 0) goto done;
    if (copy_regular_atomic(context, config_directory, name, pending,
                            "backup.tmp", "config.backup", 0600, false) != 0) goto done;
    (void)memset(&record, 0, sizeof(record));
    (void)snprintf(record.id, sizeof(record.id), "%s", id);
    record.scope = scope;
    record.state = RB_STATE_STAGED;
    record.deadline = deadline;
    if (write_record(context, &record, "pending.record") != 0) goto done;
    result = 0;
done:
    if (pending >= 0) (void)close(pending);
    if (transactions >= 0) (void)close(transactions);
    if (config_directory >= 0) (void)close(config_directory);
    return result;
}

int rb_transition(rb_context_t *context, rb_state_t next_state)
{
    rb_record_t record;
    if ((context == NULL) || (context->lock_fd < 0)) { errno = EPERM; return -1; }
    if (rb_load_current(context, &record) != 0) return -1;
    if (!transition_allowed(record.state, next_state)) { errno = EINVAL; return -1; }
    record.state = next_state;
    return write_record(context, &record, "pending.record");
}

int rb_confirm(rb_context_t *context)
{
    rb_record_t record;
    int pending;
    if ((context == NULL) || (context->lock_fd < 0)) { errno = EPERM; return -1; }
    if (rb_load_current(context, &record) != 0) return -1;
    if (record.state != RB_STATE_PENDING_HEALTH_CONFIRMATION) { errno = EINVAL; return -1; }
    record.state = RB_STATE_CONFIRMED;
    if (write_record(context, &record, "finalized.record") != 0) return -1;
    pending = open_pending(context);
    if (pending < 0) return -1;
    if ((unlinkat(pending, "config.backup", 0) != 0) ||
        (unlinkat(pending, "pending.record", 0) != 0) ||
        (injected_fsync(context, pending, true) != 0)) {
        (void)close(pending);
        return -1;
    }
    (void)close(pending);
    return 0;
}

int rb_guard_check(rb_context_t *context, int64_t now, bool recovering)
{
    rb_record_t record;
    if ((context == NULL) || (context->lock_fd < 0)) { errno = EPERM; return -1; }
    if (rb_load_current(context, &record) != 0) return (errno == ENOENT) ? 0 : -1;
    if ((record.state == RB_STATE_CONFIRMED) || (record.state == RB_STATE_ROLLED_BACK) ||
        (record.state == RB_STATE_ROLLBACK_FAILED)) return 0;
    if (!recovering && (now < record.deadline)) return 0;
    return rollback_current(context, &record);
}

int rb_load_current(rb_context_t *context, rb_record_t *record)
{
    int pending;
    int descriptor;
    char buffer[RB_RECORD_SIZE];
    ssize_t count;
    if ((context == NULL) || (record == NULL)) { errno = EINVAL; return -1; }
    pending = open_pending(context);
    if (pending < 0) return -1;
    descriptor = openat(pending, "pending.record", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    (void)close(pending);
    if (descriptor < 0) return -1;
    count = read(descriptor, buffer, sizeof(buffer) - 1U);
    (void)close(descriptor);
    if (count <= 0) { errno = EINVAL; return -1; }
    buffer[(size_t)count] = '\0';
    return parse_record(buffer, record);
}

const char *rb_state_name(rb_state_t state)
{
    static const char *const names[] = {
        "not_started", "staged", "committed", "applying",
        "pending_health_confirmation", "confirmed", "rolling_back",
        "rolled_back", "rollback_failed"
    };
    if ((unsigned int)state >= (sizeof(names) / sizeof(names[0]))) return "invalid";
    return names[(unsigned int)state];
}

static const char *scope_name(rb_scope_t scope)
{
    if (scope == RB_SCOPE_NETWORK) return "network";
    if (scope == RB_SCOPE_WIRELESS) return "wireless";
    return NULL;
}

static const char *config_name(rb_scope_t scope)
{
    return scope_name(scope);
}

static bool valid_id(const char *id)
{
    size_t index;
    if ((id == NULL) || (strlen(id) != (RB_ID_SIZE - 1U))) return false;
    for (index = 0U; index < (RB_ID_SIZE - 1U); index++) {
        if (!(((id[index] >= '0') && (id[index] <= '9')) ||
              ((id[index] >= 'a') && (id[index] <= 'f')))) return false;
    }
    return true;
}

static int ensure_directory(int parent, const char *name, mode_t mode)
{
    struct stat status;
    if ((mkdirat(parent, name, mode) != 0) && (errno != EEXIST)) return -1;
    if ((fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0) ||
        !S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) { errno = ELOOP; return -1; }
    return 0;
}

static int open_root(const char *path)
{
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int open_transactions(rb_context_t *context)
{
    int root = open_root(context->state_root);
    int result;
    if (root < 0) return -1;
    result = openat(root, "transactions", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    (void)close(root);
    return result;
}

static int open_pending(rb_context_t *context)
{
    int transactions = open_transactions(context);
    int result;
    if (transactions < 0) return -1;
    result = openat(transactions, "pending", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    (void)close(transactions);
    return result;
}

static int injected_fsync(rb_context_t *context, int descriptor, bool directory)
{
    rb_failpoint_t wanted = directory ? RB_FAIL_DIRECTORY_FSYNC : RB_FAIL_FILE_FSYNC;
    if (!context->failpoint_used && (context->failpoint == wanted)) {
        context->failpoint_used = true;
        errno = EIO;
        return -1;
    }
    return fsync(descriptor);
}

static ssize_t injected_write(rb_context_t *context, int descriptor,
                              const void *buffer, size_t size)
{
    if (!context->failpoint_used && (context->failpoint == RB_FAIL_WRITE_ENOSPC)) {
        context->failpoint_used = true;
        errno = ENOSPC;
        return -1;
    }
    if (!context->failpoint_used && (context->failpoint == RB_FAIL_SHORT_WRITE) && (size > 1U)) {
        context->failpoint_used = true;
        return write(descriptor, buffer, size / 2U);
    }
    return write(descriptor, buffer, size);
}

static int write_all(rb_context_t *context, int descriptor,
                     const void *buffer, size_t size)
{
    size_t used = 0U;
    while (used < size) {
        ssize_t count = injected_write(context, descriptor,
                                       (const unsigned char *)buffer + used, size - used);
        if (count <= 0) return -1;
        used += (size_t)count;
    }
    return 0;
}

static int atomic_write(rb_context_t *context, int directory,
                        const char *temporary, const char *destination,
                        const void *buffer, size_t size, mode_t mode)
{
    int descriptor = openat(directory, temporary,
                            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode);
    int saved;
    if (descriptor < 0) return -1;
    if ((write_all(context, descriptor, buffer, size) != 0) ||
        (injected_fsync(context, descriptor, false) != 0)) {
        saved = errno;
        (void)close(descriptor);
        (void)unlinkat(directory, temporary, 0);
        errno = saved;
        return -1;
    }
    if (close(descriptor) != 0) { (void)unlinkat(directory, temporary, 0); return -1; }
    if (renameat(directory, temporary, directory, destination) != 0) {
        saved = errno;
        (void)unlinkat(directory, temporary, 0);
        errno = saved;
        return -1;
    }
    return injected_fsync(context, directory, true);
}

static int copy_regular_atomic(rb_context_t *context, int source_directory,
                               const char *source_name, int destination_directory,
                               const char *temporary, const char *destination,
                               mode_t destination_mode, bool restoring)
{
    int source = -1;
    int target = -1;
    struct stat status;
    struct stat destination_status;
    unsigned char buffer[RB_COPY_BUFFER_SIZE];
    ssize_t count;
    int saved;
    source = openat(source_directory, source_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if ((source < 0) || (fstat(source, &status) != 0) || !S_ISREG(status.st_mode)) {
        if (source >= 0) (void)close(source);
        errno = EINVAL;
        return -1;
    }
    target = openat(destination_directory, temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    destination_mode);
    if (target < 0) { (void)close(source); return -1; }
    if (restoring) {
        if ((fstatat(destination_directory, destination, &destination_status,
                     AT_SYMLINK_NOFOLLOW) != 0) ||
            !S_ISREG(destination_status.st_mode) ||
            (fchmod(target, destination_status.st_mode & 07777) != 0) ||
            (fchown(target, destination_status.st_uid, destination_status.st_gid) != 0)) goto failed;
    }
    while ((count = read(source, buffer, sizeof(buffer))) > 0) {
        if (write_all(context, target, buffer, (size_t)count) != 0) goto failed;
    }
    if ((count < 0) || (injected_fsync(context, target, false) != 0)) goto failed;
    if ((close(source) != 0) || (close(target) != 0)) {
        source = -1;
        target = -1;
        goto failed;
    }
    source = -1;
    target = -1;
    if (restoring && !context->failpoint_used &&
        (context->failpoint == RB_FAIL_RESTORE_RENAME)) {
        context->failpoint_used = true;
        errno = EIO;
        goto failed;
    }
    if (renameat(destination_directory, temporary,
                 destination_directory, destination) != 0) goto failed;
    return injected_fsync(context, destination_directory, true);
failed:
    saved = errno;
    if (source >= 0) (void)close(source);
    if (target >= 0) (void)close(target);
    (void)unlinkat(destination_directory, temporary, 0);
    errno = saved;
    return -1;
}

static int write_record(rb_context_t *context, const rb_record_t *record,
                        const char *name)
{
    int pending = open_pending(context);
    char text[RB_RECORD_SIZE];
    int length;
    if (pending < 0) return -1;
    /* Write base fields */
    length = snprintf(text, sizeof(text),
                      "version=2\nid=%s\nscope=%s\nstate=%s\ndeadline=%lld\n",
                      record->id, scope_name(record->scope), rb_state_name(record->state),
                      (long long)record->deadline);
    if ((length < 0) || ((size_t)length >= sizeof(text))) {
        (void)close(pending);
        errno = EOVERFLOW;
        return -1;
    }
    /* Optionally include plan token for guard reference */
    if (record->plan_token[0] != '\0') {
        int extra = snprintf(text + length, sizeof(text) - (size_t)length,
                             "plan_token=%s\n", record->plan_token);
        if ((extra < 0) || ((size_t)extra >= (sizeof(text) - (size_t)length))) {
            (void)close(pending);
            errno = EOVERFLOW;
            return -1;
        }
        length += extra;
    }
    if (record->health_token[0] != '\0') {
        int extra = snprintf(text + length, sizeof(text) - (size_t)length,
                             "health_token=%s\n", record->health_token);
        if ((extra < 0) || ((size_t)extra >= (sizeof(text) - (size_t)length))) {
            (void)close(pending);
            errno = EOVERFLOW;
            return -1;
        }
        length += extra;
    }
    if (atomic_write(context, pending, "record.tmp", name,
                     text, (size_t)length, 0600) != 0) {
        (void)close(pending);
        return -1;
    }
    (void)close(pending);
    return 0;
}

static int parse_record(const char *text, rb_record_t *record)
{
    char raw[RB_RECORD_SIZE];
    char *cursor;
    char *line;
    char *equals;
    char id[RB_ID_SIZE] = "";
    char scope[16] = "";
    char state[40] = "";
    long long deadline = 0;
    char plan_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U] = "";
    char health_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U] = "";
    int version = 0;
    if ((text == NULL) || (record == NULL)) { errno = EINVAL; return -1; }
    if (strlen(text) >= sizeof(raw)) { errno = EOVERFLOW; return -1; }
    (void)snprintf(raw, sizeof(raw), "%s", text);
    cursor = raw;
    while (*cursor != '\0') {
        line = cursor;
        while ((*cursor != '\0') && (*cursor != '\n')) cursor++;
        if (*cursor == '\n') { *cursor = '\0'; cursor++; }
        if (*line == '\0') continue;
        equals = strchr(line, '=');
        if (equals == NULL) { errno = EINVAL; return -1; }
        *equals = '\0';
        if (strcmp(line, "version") == 0) {
            version = atoi(equals + 1);
            if ((version != 1) && (version != 2)) { errno = EINVAL; return -1; }
        } else if (strcmp(line, "id") == 0) {
            (void)snprintf(id, sizeof(id), "%s", equals + 1);
        } else if (strcmp(line, "scope") == 0) {
            (void)snprintf(scope, sizeof(scope), "%s", equals + 1);
        } else if (strcmp(line, "state") == 0) {
            (void)snprintf(state, sizeof(state), "%s", equals + 1);
        } else if (strcmp(line, "deadline") == 0) {
            deadline = strtoll(equals + 1, NULL, 10);
        } else if (strcmp(line, "plan_token") == 0) {
            (void)snprintf(plan_token, sizeof(plan_token), "%s", equals + 1);
        } else if (strcmp(line, "health_token") == 0) {
            (void)snprintf(health_token, sizeof(health_token), "%s", equals + 1);
        }
    }
    if (!valid_id(id) || (deadline <= 0) || (strcmp(scope, "") == 0) || (strcmp(state, "") == 0)) { errno = EINVAL; return -1; }
    (void)memset(record, 0, sizeof(*record));
    (void)snprintf(record->id, sizeof(record->id), "%s", id);
    if (strcmp(scope, "network") == 0) record->scope = RB_SCOPE_NETWORK;
    else if (strcmp(scope, "wireless") == 0) record->scope = RB_SCOPE_WIRELESS;
    else { errno = EINVAL; return -1; }
    for (unsigned int index = 0U; index <= (unsigned int)RB_STATE_ROLLBACK_FAILED; index++) {
        if (strcmp(state, rb_state_name((rb_state_t)index)) == 0) {
            record->state = (rb_state_t)index;
            record->deadline = (int64_t)deadline;
            /* preserve parsed plan_token (if any) into the record and validate it */
            if (plan_token[0] != '\0') {
                if (!rb_network_plan_token_valid(plan_token)) { errno = EINVAL; return -1; }
                (void)snprintf(record->plan_token, sizeof(record->plan_token), "%s", plan_token);
            } else {
                record->plan_token[0] = '\0';
            }
            if (health_token[0] != '\0') {
                if (!rb_network_plan_token_valid(health_token)) { errno = EINVAL; return -1; }
                (void)snprintf(record->health_token, sizeof(record->health_token), "%s", health_token);
            }
            return 0;
        }
    }
    errno = EINVAL;
    return -1;
}

static bool transition_allowed(rb_state_t from, rb_state_t to)
{
    return ((from == RB_STATE_STAGED) && (to == RB_STATE_COMMITTED)) ||
           ((from == RB_STATE_COMMITTED) && (to == RB_STATE_APPLYING)) ||
           ((from == RB_STATE_APPLYING) && (to == RB_STATE_PENDING_HEALTH_CONFIRMATION));
}

static int rollback_current(rb_context_t *context, rb_record_t *record)
{
    int pending = -1;
    int config = -1;
    const char *name = config_name(record->scope);
    int result = -1;
    record->state = RB_STATE_ROLLING_BACK;
    if (write_record(context, record, "pending.record") != 0) return -1;
    pending = open_pending(context);
    config = open_root(context->config_root);
    if ((pending < 0) || (config < 0) ||
        (copy_regular_atomic(context, pending, "config.backup", config,
                             ".router-agent-restore.tmp", name, 0600, true) != 0) ||
        (context->apply(record->scope, context->apply_private) != 0)) {
        record->state = RB_STATE_ROLLBACK_FAILED;
        (void)write_record(context, record, "pending.record");
        goto done;
    }
    record->state = RB_STATE_ROLLED_BACK;
    if (write_record(context, record, "finalized.record") != 0) goto done;
    if ((unlinkat(pending, "config.backup", 0) != 0) ||
        (unlinkat(pending, "pending.record", 0) != 0) ||
        (injected_fsync(context, pending, true) != 0)) goto done;
    result = 1;
done:
    if (pending >= 0) (void)close(pending);
    if (config >= 0) (void)close(config);
    return result;
}
