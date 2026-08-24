#define _POSIX_C_SOURCE 200809L

#include "network_plan.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include "../common/validator.h"

#define RB_NETWORK_PLAN_FILE_SIZE 4096U
#define RB_NETWORK_PLAN_TMP_PREFIX ".plan-"
#define RB_NETWORK_PLAN_TMP_SUFFIX ".tmp"

static const char *rb_network_plan_scope_name(void)
{
    return "network";
}

static bool valid_network_field_with_empty(const char *value, bool allow_empty)
{
    const unsigned char *cursor;
    if ((value == NULL) && allow_empty) return true;
    if ((value == NULL) || (*value == '\0')) return allow_empty;
    for (cursor = (const unsigned char *)value; *cursor != '\0'; cursor++) {
        if (((*cursor >= '0') && (*cursor <= '9')) ||
            ((*cursor >= 'A') && (*cursor <= 'Z')) ||
            ((*cursor >= 'a') && (*cursor <= 'z')) ||
            (*cursor == '.') || (*cursor == ':') ||
            (*cursor == '-') || (*cursor == '_')) {
            continue;
        }
        return false;
    }
    return true;
}

static bool proto_is_valid(const char *proto)
{
    if (proto == NULL) return false;
    return (strcmp(proto, "static") == 0) || (strcmp(proto, "dhcp") == 0);
}



static void normalize_optional_string(char *output, size_t size, const char *source)
{
    if (output == NULL) return;
    if ((source == NULL) || (*source == '\0')) {
        output[0] = '\0';
        return;
    }
    if (size == 0U) return;
    (void)memcpy(output, source, strlen(source) >= size ? size - 1U : strlen(source));
    output[strlen(source) >= size ? size - 1U : strlen(source)] = '\0';
}

static bool string_equal_optional(const char *left, const char *right)
{
    char left_value[128];
    char right_value[128];
    normalize_optional_string(left_value, sizeof(left_value), left);
    normalize_optional_string(right_value, sizeof(right_value), right);
    return strcmp(left_value, right_value) == 0;
}

int rb_network_plan_token_valid(const char *token)
{
    size_t index;
    if ((token == NULL) || (strlen(token) != RB_NETWORK_PLAN_TOKEN_HEX_LEN)) return 0;
    for (index = 0U; index < RB_NETWORK_PLAN_TOKEN_HEX_LEN; index++) {
        const char byte = token[index];
        if (((byte >= '0') && (byte <= '9')) ||
            ((byte >= 'a') && (byte <= 'f')) ||
            ((byte >= 'A') && (byte <= 'F'))) {
            continue;
        }
        return 0;
    }
    return 1;
}

static int ensure_directory(int parent, const char *name, mode_t mode)
{
    struct stat status;
    if ((mkdirat(parent, name, mode) != 0) && (errno != EEXIST)) return -1;
    if ((fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0) ||
        (!S_ISDIR(status.st_mode)) || (S_ISLNK(status.st_mode))) {
        errno = ELOOP;
        return -1;
    }
    return 0;
}

static int open_root(const char *path)
{
    return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static int open_plans(rb_context_t *context)
{
    int root = -1;
    int plans = -1;
    if (context == NULL) { errno = EINVAL; return -1; }
    root = open_root(context->state_root);
    if (root < 0) return -1;
    if (ensure_directory(root, "plans", 0700) != 0) {
        (void)close(root);
        return -1;
    }
    plans = openat(root, "plans", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    (void)close(root);
    return plans;
}

static void hex_encode(const unsigned char *input, size_t input_size,
                       char *output, size_t output_size)
{
    static const char digits[] = "0123456789abcdef";
    size_t index;
    if ((input == NULL) || (output == NULL) || (output_size < (input_size * 2U) + 1U)) {
        errno = EINVAL;
        return;
    }
    for (index = 0U; index < input_size; index++) {
        output[index * 2U] = digits[input[index] >> 4U];
        output[(index * 2U) + 1U] = digits[input[index] & 0x0FU];
    }
    output[input_size * 2U] = '\0';
}

static int random_bytes(unsigned char *output, size_t size)
{
    int descriptor;
    size_t used = 0U;
    if ((output == NULL) || (size == 0U)) { errno = EINVAL; return -1; }
    descriptor = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return -1;
    while (used < size) {
        ssize_t count = read(descriptor, output + used, size - used);
        if (count <= 0) {
            int saved = errno;
            (void)close(descriptor);
            errno = saved;
            return -1;
        }
        used += (size_t)count;
    }
    (void)close(descriptor);
    return 0;
}

static int write_all(int descriptor, const void *buffer, size_t size)
{
    size_t used = 0U;
    const unsigned char *cursor = (const unsigned char *)buffer;
    while (used < size) {
        ssize_t count = write(descriptor, cursor + used, size - used);
        if (count <= 0) return -1;
        used += (size_t)count;
    }
    return 0;
}

static int atomic_write_file(int directory, const char *temporary,
                            const char *destination, const void *buffer,
                            size_t size)
{
    int descriptor;
    int saved;
    descriptor = openat(directory, temporary,
                       O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                       0600);
    if (descriptor < 0) return -1;
    if ((write_all(descriptor, buffer, size) != 0) || (fsync(descriptor) != 0)) {
        saved = errno;
        (void)close(descriptor);
        (void)unlinkat(directory, temporary, 0);
        errno = saved;
        return -1;
    }
    if (close(descriptor) != 0) {
        (void)unlinkat(directory, temporary, 0);
        return -1;
    }
    if (renameat(directory, temporary, directory, destination) != 0) {
        saved = errno;
        (void)unlinkat(directory, temporary, 0);
        errno = saved;
        return -1;
    }
    return fsync(directory);
}

static int read_file_all(int descriptor, char *buffer, size_t size)
{
    ssize_t count;
    size_t total = 0U;
    if ((buffer == NULL) || (size == 0U)) { errno = EINVAL; return -1; }
    while (total < (size - 1U)) {
        count = read(descriptor, buffer + total, size - total - 1U);
        if (count < 0) return -1;
        if (count == 0) break;
        total += (size_t)count;
    }
    buffer[total] = '\0';
    return 0;
}

static void normalize_field(char *output, size_t size, const char *source)
{
    size_t length;
    if ((output == NULL) || (source == NULL)) return;
    length = strlen(source);
    if (length >= size) length = size - 1U;
    (void)memcpy(output, source, length);
    output[length] = '\0';
}

static bool request_matches(const rb_network_request_t *left,
                           const rb_network_request_t *right)
{
    return string_equal_optional(left->interface, right->interface) &&
           string_equal_optional(left->proto, right->proto) &&
           string_equal_optional(left->ipaddr, right->ipaddr) &&
           string_equal_optional(left->netmask, right->netmask) &&
           string_equal_optional(left->gateway, right->gateway);
}

static int write_plan_file(rb_context_t *context, const rb_network_plan_t *plan)
{
    char text[RB_NETWORK_PLAN_FILE_SIZE];
    int plans;
    int length;
    char temporary[96];
    if ((context == NULL) || (plan == NULL)) { errno = EINVAL; return -1; }
    plans = open_plans(context);
    if (plans < 0) return -1;
    (void)snprintf(temporary, sizeof(temporary), "%s%s", RB_NETWORK_PLAN_TMP_PREFIX, plan->token);
    length = snprintf(text, sizeof(text),
                      "version=1\n"
                      "scope=%s\n"
                      "state=%s\n"
                      "created_at=%lld\n"
                      "deadline=%lld\n"
                      "health_token=%s\n"
                      "interface=%s\n"
                      "proto=%s\n"
                      "ipaddr=%s\n"
                      "netmask=%s\n"
                      "gateway=%s\n"
                      "baseline_proto=%s\n"
                      "baseline_ipaddr=%s\n"
                      "baseline_netmask=%s\n"
                      "baseline_gateway=%s\n",
                      rb_network_plan_scope_name(),
                      rb_network_plan_state_name(plan->state),
                      (long long)plan->created_at,
                      (long long)plan->deadline,
                      plan->health_token,
                      plan->request.interface,
                      plan->request.proto,
                      plan->request.ipaddr,
                      plan->request.netmask,
                      plan->request.gateway,
                      plan->baseline.proto,
                      plan->baseline.ipaddr,
                      plan->baseline.netmask,
                      plan->baseline.gateway);
    if ((length < 0) || ((size_t)length >= sizeof(text))) {
        (void)close(plans);
        errno = EOVERFLOW;
        return -1;
    }
    if (atomic_write_file(plans, temporary, plan->token, text, (size_t)length) != 0) {
        (void)close(plans);
        return -1;
    }
    (void)close(plans);
    return 0;
}

static int parse_plan_record(const char *text, rb_network_plan_t *plan)
{
    char raw[RB_NETWORK_PLAN_FILE_SIZE];
    char *cursor;
    char *line;
    char *equals;
    char scope[16] = "";
    char state[24] = "";
    long long created_at = 0;
    long long deadline = 0;
    char health_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U] = "";
    char interface[64] = "";
    char proto[32] = "";
    char ipaddr[64] = "";
    char netmask[64] = "";
    char gateway[64] = "";
    char baseline_proto[32] = "";
    char baseline_ipaddr[64] = "";
    char baseline_netmask[64] = "";
    char baseline_gateway[64] = "";
    if ((text == NULL) || (plan == NULL)) { errno = EINVAL; return -1; }
    if (strlen(text) >= sizeof(raw)) { errno = EOVERFLOW; return -1; }
    (void)snprintf(raw, sizeof(raw), "%s", text);
    cursor = raw;
    while (*cursor != '\0') {
        line = cursor;
        while ((*cursor != '\0') && (*cursor != '\n')) cursor++;
        if (*cursor == '\n') {
            *cursor = '\0';
            cursor++;
        }
        if (*line == '\0') continue;
        equals = strchr(line, '=');
        if (equals == NULL) { errno = EINVAL; return -1; }
        *equals = '\0';
        if (strcmp(line, "version") == 0) {
            if (strcmp(equals + 1, "1") != 0) { errno = EINVAL; return -1; }
        } else if (strcmp(line, "scope") == 0) {
            (void)snprintf(scope, sizeof(scope), "%s", equals + 1);
        } else if (strcmp(line, "state") == 0) {
            (void)snprintf(state, sizeof(state), "%s", equals + 1);
        } else if (strcmp(line, "created_at") == 0) {
            created_at = strtoll(equals + 1, NULL, 10);
        } else if (strcmp(line, "deadline") == 0) {
            deadline = strtoll(equals + 1, NULL, 10);
        } else if (strcmp(line, "health_token") == 0) {
            (void)snprintf(health_token, sizeof(health_token), "%s", equals + 1);
        } else if (strcmp(line, "interface") == 0) {
            (void)snprintf(interface, sizeof(interface), "%s", equals + 1);
        } else if (strcmp(line, "proto") == 0) {
            (void)snprintf(proto, sizeof(proto), "%s", equals + 1);
        } else if (strcmp(line, "ipaddr") == 0) {
            (void)snprintf(ipaddr, sizeof(ipaddr), "%s", equals + 1);
        } else if (strcmp(line, "netmask") == 0) {
            (void)snprintf(netmask, sizeof(netmask), "%s", equals + 1);
        } else if (strcmp(line, "gateway") == 0) {
            (void)snprintf(gateway, sizeof(gateway), "%s", equals + 1);
        } else if (strcmp(line, "baseline_proto") == 0) {
            (void)snprintf(baseline_proto, sizeof(baseline_proto), "%s", equals + 1);
        } else if (strcmp(line, "baseline_ipaddr") == 0) {
            (void)snprintf(baseline_ipaddr, sizeof(baseline_ipaddr), "%s", equals + 1);
        } else if (strcmp(line, "baseline_netmask") == 0) {
            (void)snprintf(baseline_netmask, sizeof(baseline_netmask), "%s", equals + 1);
        } else if (strcmp(line, "baseline_gateway") == 0) {
            (void)snprintf(baseline_gateway, sizeof(baseline_gateway), "%s", equals + 1);
        }
    }
    if ((strcmp(scope, rb_network_plan_scope_name()) != 0) ||
        (strcmp(state, "unused") != 0 && strcmp(state, "consumed") != 0 &&
         strcmp(state, "expired") != 0) ||
        (created_at <= 0) || (deadline <= 0) ||
        !rb_network_plan_token_valid(health_token)) {
        errno = EINVAL;
        return -1;
    }

    if ((strcmp(interface, "lan") != 0) || !proto_is_valid(proto) ||
        !proto_is_valid(baseline_proto)) {
        errno = EINVAL;
        return -1;
    }

    if (strcmp(proto, "static") == 0) {
        if (!validator_ipv4(ipaddr) || !validator_netmask(netmask) ||
            ((gateway[0] != '\0') && !validator_optional_gateway(gateway))) {
            errno = EINVAL;
            return -1;
        }
    } else {
        /* dhcp: allow empty fields after canonicalization, but ensure contents are valid when present */
        if (!valid_network_field_with_empty(ipaddr, true) || !valid_network_field_with_empty(netmask, true) ||
            !valid_network_field_with_empty(gateway, true)) {
            errno = EINVAL;
            return -1;
        }
    }
    if (strcmp(state, "unused") == 0) plan->state = RB_NETWORK_PLAN_STATE_UNUSED;
    else if (strcmp(state, "consumed") == 0) plan->state = RB_NETWORK_PLAN_STATE_CONSUMED;
    else plan->state = RB_NETWORK_PLAN_STATE_EXPIRED;
    normalize_field(plan->request.interface, sizeof(plan->request.interface), interface);
    normalize_field(plan->health_token, sizeof(plan->health_token), health_token);
    normalize_field(plan->request.proto, sizeof(plan->request.proto), proto);
    normalize_field(plan->request.ipaddr, sizeof(plan->request.ipaddr), ipaddr);
    normalize_field(plan->request.netmask, sizeof(plan->request.netmask), netmask);
    normalize_field(plan->request.gateway, sizeof(plan->request.gateway), gateway);
    normalize_field(plan->baseline.interface, sizeof(plan->baseline.interface), "lan");
    normalize_field(plan->baseline.proto, sizeof(plan->baseline.proto), baseline_proto);
    normalize_field(plan->baseline.ipaddr, sizeof(plan->baseline.ipaddr), baseline_ipaddr);
    normalize_field(plan->baseline.netmask, sizeof(plan->baseline.netmask), baseline_netmask);
    normalize_field(plan->baseline.gateway, sizeof(plan->baseline.gateway), baseline_gateway);
    plan->scope = RB_SCOPE_NETWORK;
    plan->created_at = created_at;
    plan->deadline = deadline;
    return 0;
}

static int load_plan_internal(rb_context_t *context, const char *token, rb_network_plan_t *plan)
{
    int plans;
    int descriptor;
    char buffer[RB_NETWORK_PLAN_FILE_SIZE];
    struct timespec now;
    if ((context == NULL) || (token == NULL) || (plan == NULL)) { errno = EINVAL; return -1; }
    if (!rb_network_plan_token_valid(token)) { errno = EINVAL; return -1; }
    {
        char token_copy[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
        (void)memcpy(token_copy, token, RB_NETWORK_PLAN_TOKEN_HEX_LEN);
        token_copy[RB_NETWORK_PLAN_TOKEN_HEX_LEN] = '\0';
        plans = open_plans(context);
        if (plans < 0) return -1;
        descriptor = openat(plans, token_copy, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        (void)close(plans);
        if (descriptor < 0) return -1;
        if (read_file_all(descriptor, buffer, sizeof(buffer)) != 0) {
            (void)close(descriptor);
            return -1;
        }
        (void)close(descriptor);
        (void)memset(plan, 0, sizeof(*plan));
        (void)snprintf(plan->token, sizeof(plan->token), "%s", token_copy);
        if (parse_plan_record(buffer, plan) != 0) return -1;
    }
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    if (plan->state == RB_NETWORK_PLAN_STATE_CONSUMED) { errno = EEXIST; return -1; }
    if ((plan->deadline <= (int64_t)now.tv_sec) ||
        (plan->state == RB_NETWORK_PLAN_STATE_EXPIRED)) {
        plan->state = RB_NETWORK_PLAN_STATE_EXPIRED;
        errno = ETIMEDOUT;
        return -1;
    }
    return 0;
}

int rb_network_plan_create_with_baseline_ttl(rb_context_t *context,
                           const rb_network_request_t *baseline,
                           const rb_network_request_t *request,
                           int64_t ttl_seconds, rb_network_plan_t *plan)
{
    unsigned char random_bytes_buffer[32];
    char token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
    int plans;
    struct timespec now;
    if ((context == NULL) || (baseline == NULL) || (request == NULL) ||
        (plan == NULL) || (ttl_seconds <= 0)) { errno = EINVAL; return -1; }

    if ((strcmp(request->interface, "lan") != 0) ||
        (strcmp(baseline->interface, "lan") != 0) ||
        !proto_is_valid(request->proto) || !proto_is_valid(baseline->proto)) {
        errno = EINVAL;
        return -1;
    }
    if ((strcmp(baseline->proto, "static") == 0) &&
        (!validator_ipv4(baseline->ipaddr) || !validator_netmask(baseline->netmask) ||
         ((baseline->gateway[0] != '\0') && !validator_optional_gateway(baseline->gateway)))) {
        errno = EINVAL;
        return -1;
    }
    if ((strcmp(baseline->proto, "dhcp") == 0) &&
        (!valid_network_field_with_empty(baseline->ipaddr, true) ||
         !valid_network_field_with_empty(baseline->netmask, true) ||
         !valid_network_field_with_empty(baseline->gateway, true))) {
        errno = EINVAL;
        return -1;
    }

    if (strcmp(request->proto, "static") == 0) {
        if (!validator_ipv4(request->ipaddr) || !validator_netmask(request->netmask) ||
            ((request->gateway[0] != '\0') && !validator_optional_gateway(request->gateway))) {
            errno = EINVAL;
            return -1;
        }
    } else {
        /* dhcp: allow optional/empty fields after canonicalization; ensure characters are valid when present */
        if (!valid_network_field_with_empty(request->ipaddr, true) || !valid_network_field_with_empty(request->netmask, true) ||
            !valid_network_field_with_empty(request->gateway, true)) {
            errno = EINVAL;
            return -1;
        }
    }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (random_bytes(random_bytes_buffer, sizeof(random_bytes_buffer)) != 0) return -1;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    hex_encode(random_bytes_buffer, sizeof(random_bytes_buffer), token, sizeof(token));
    if (random_bytes(random_bytes_buffer, sizeof(random_bytes_buffer)) != 0) return -1;
    (void)memset(plan, 0, sizeof(*plan));
    (void)snprintf(plan->token, sizeof(plan->token), "%s", token);
    hex_encode(random_bytes_buffer, sizeof(random_bytes_buffer), plan->health_token,
               sizeof(plan->health_token));
    plan->scope = RB_SCOPE_NETWORK;
    plan->created_at = (int64_t)now.tv_sec;
    plan->deadline = plan->created_at + ttl_seconds;
    plan->state = RB_NETWORK_PLAN_STATE_UNUSED;
    plan->baseline = *baseline;
    normalize_field(plan->request.interface, sizeof(plan->request.interface), request->interface);
    normalize_field(plan->request.proto, sizeof(plan->request.proto), request->proto);
    normalize_field(plan->request.ipaddr, sizeof(plan->request.ipaddr), request->ipaddr);
    normalize_field(plan->request.netmask, sizeof(plan->request.netmask), request->netmask);
    normalize_field(plan->request.gateway, sizeof(plan->request.gateway), request->gateway);
    plans = open_plans(context);
    if (plans < 0) return -1;
    if (openat(plans, token, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) >= 0) {
        (void)close(plans);
        errno = EEXIST;
        return -1;
    }
    (void)close(plans);
    return write_plan_file(context, plan);
}

int rb_network_plan_create_with_baseline(rb_context_t *context,
                           const rb_network_request_t *baseline,
                           const rb_network_request_t *request,
                           rb_network_plan_t *plan)
{
    return rb_network_plan_create_with_baseline_ttl(context, baseline, request,
                                                     RB_NETWORK_PLAN_TTL_SECONDS, plan);
}

int rb_network_plan_create(rb_context_t *context, const rb_network_request_t *request,
                           rb_network_plan_t *plan)
{
    return rb_network_plan_create_with_baseline(context, request, request, plan);
}

int rb_network_plan_load(rb_context_t *context, const char *token,
                        rb_network_plan_t *plan)
{
    return load_plan_internal(context, token, plan);
}

int rb_network_plan_verify_request(const rb_network_plan_t *plan,
                                  const rb_network_request_t *request)
{
    bool request_is_dhcp;
    if ((plan == NULL) || (request == NULL)) { errno = EINVAL; return -1; }
    request_is_dhcp = (strcmp(request->proto, "dhcp") == 0);
    if ((plan->scope != RB_SCOPE_NETWORK) || !rb_network_plan_token_valid(plan->token) ||
        !validator_interface(request->interface) || !proto_is_valid(request->proto)) {
        errno = EINVAL;
        return -1;
    }

    if (request_is_dhcp) {
        if (!valid_network_field_with_empty(request->ipaddr, true) ||
            !valid_network_field_with_empty(request->netmask, true) ||
            !valid_network_field_with_empty(request->gateway, true)) {
            errno = EINVAL;
            return -1;
        }
    } else {
        if (!validator_ipv4(request->ipaddr) || !validator_netmask(request->netmask) ||
            ((request->gateway[0] != '\0') && !validator_optional_gateway(request->gateway))) {
            errno = EINVAL;
            return -1;
        }
    }
    if (plan->state == RB_NETWORK_PLAN_STATE_CONSUMED) { errno = EEXIST; return -1; }
    if (plan->state == RB_NETWORK_PLAN_STATE_EXPIRED) { errno = ETIMEDOUT; return -1; }
    if (strcmp(plan->request.proto, "dhcp") == 0) {
        rb_network_request_t normalized_plan = plan->request;
        rb_network_request_t normalized_request = *request;
        if (normalized_plan.ipaddr[0] == '\0') normalized_plan.ipaddr[0] = '\0';
        if (normalized_plan.netmask[0] == '\0') normalized_plan.netmask[0] = '\0';
        if (normalized_plan.gateway[0] == '\0') normalized_plan.gateway[0] = '\0';
        normalize_optional_string(normalized_request.ipaddr, sizeof(normalized_request.ipaddr), normalized_request.ipaddr);
        normalize_optional_string(normalized_request.netmask, sizeof(normalized_request.netmask), normalized_request.netmask);
        normalize_optional_string(normalized_request.gateway, sizeof(normalized_request.gateway), normalized_request.gateway);
        if (strcmp(plan->request.interface, request->interface) != 0 ||
            strcmp(plan->request.proto, request->proto) != 0 ||
            !string_equal_optional(normalized_plan.ipaddr, normalized_request.ipaddr) ||
            !string_equal_optional(normalized_plan.netmask, normalized_request.netmask) ||
            !string_equal_optional(normalized_plan.gateway, normalized_request.gateway)) {
            errno = EINVAL;
            return -1;
        }
        return 0;
    }
    if (request_matches(&plan->request, request) == false) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

int rb_network_plan_consume(rb_context_t *context, const char *token,
                           const rb_network_request_t *request,
                           rb_network_plan_t *plan)
{
    rb_network_plan_t current;
    struct timespec now;
    if ((context == NULL) || (token == NULL) || (request == NULL) || (plan == NULL)) {
        errno = EINVAL;
        return -1;
    }
    if ((context->lock_fd < 0) && (rb_lock(context) != 0)) return -1;
    if (load_plan_internal(context, token, &current) != 0) return -1;
    if (rb_network_plan_verify_request(&current, request) != 0) return -1;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return -1;
    if (current.deadline <= (int64_t)now.tv_sec) {
        current.state = RB_NETWORK_PLAN_STATE_EXPIRED;
        errno = ETIMEDOUT;
        return -1;
    }
    current.state = RB_NETWORK_PLAN_STATE_CONSUMED;
    (void)memcpy(plan, &current, sizeof(*plan));
    return write_plan_file(context, plan);
}

const char *rb_network_plan_state_name(rb_network_plan_state_t state)
{
    static const char *const names[] = {
        "unused",
        "consumed",
        "expired"
    };
    if ((unsigned int)state >= (sizeof(names) / sizeof(names[0]))) return "invalid";
    return names[(unsigned int)state];
}
