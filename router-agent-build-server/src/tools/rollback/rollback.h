#ifndef ROUTER_AGENT_ROLLBACK_H
#define ROUTER_AGENT_ROLLBACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef RB_NETWORK_PLAN_TOKEN_HEX_LEN
#define RB_NETWORK_PLAN_TOKEN_HEX_LEN 64U
#endif

#define RB_ID_SIZE 33U
#define RB_PATH_SIZE 256U

typedef enum {
    RB_SCOPE_NETWORK = 0,
    RB_SCOPE_WIRELESS = 1
} rb_scope_t;

typedef enum {
    RB_STATE_NOT_STARTED = 0,
    RB_STATE_STAGED,
    RB_STATE_COMMITTED,
    RB_STATE_APPLYING,
    RB_STATE_PENDING_HEALTH_CONFIRMATION,
    RB_STATE_CONFIRMED,
    RB_STATE_ROLLING_BACK,
    RB_STATE_ROLLED_BACK,
    RB_STATE_ROLLBACK_FAILED
} rb_state_t;

typedef enum {
    RB_FAIL_NONE = 0,
    RB_FAIL_WRITE_ENOSPC,
    RB_FAIL_SHORT_WRITE,
    RB_FAIL_FILE_FSYNC,
    RB_FAIL_DIRECTORY_FSYNC,
    RB_FAIL_RESTORE_RENAME
} rb_failpoint_t;

typedef int (*rb_apply_fn)(rb_scope_t scope, void *private_data);

typedef struct {
    char state_root[RB_PATH_SIZE];
    char config_root[RB_PATH_SIZE];
    int lock_fd;
    rb_failpoint_t failpoint;
    bool failpoint_used;
    rb_apply_fn apply;
    void *apply_private;
} rb_context_t;

typedef struct {
    char id[RB_ID_SIZE];
    rb_scope_t scope;
    rb_state_t state;
    int64_t deadline;
    char plan_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
    /* Distinct capability presented only to the app after a successful apply. */
    char health_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
} rb_record_t;

int rb_context_init(rb_context_t *context, const char *state_root,
                    const char *config_root, rb_apply_fn apply,
                    void *apply_private);
void rb_context_close(rb_context_t *context);
void rb_set_failpoint(rb_context_t *context, rb_failpoint_t failpoint);

int rb_lock(rb_context_t *context);
void rb_unlock(rb_context_t *context);

/* Guard control APIs: arm a plan for guarding, query status, and finalize to cancel rollback. */
int rb_guard_arm(rb_context_t *context, const char *plan_token, const void *request_payload);
int rb_guard_status(rb_context_t *context, const char *plan_token, rb_record_t *out_record);
int rb_guard_finalize(rb_context_t *context, const char *plan_token);
int rb_guard_set_health_token(rb_context_t *context, char *out_token,
                              size_t out_token_size);
int rb_guard_finalize_health(rb_context_t *context, const char *health_token);

int rb_prepare(rb_context_t *context, const char *id, rb_scope_t scope,
               int64_t deadline);
int rb_transition(rb_context_t *context, rb_state_t next_state);
int rb_confirm(rb_context_t *context);
int rb_guard_check(rb_context_t *context, int64_t now, bool recovering);
int rb_load_current(rb_context_t *context, rb_record_t *record);

const char *rb_state_name(rb_state_t state);

#endif
