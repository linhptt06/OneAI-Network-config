#ifndef ROUTER_AGENT_NETWORK_PLAN_H
#define ROUTER_AGENT_NETWORK_PLAN_H

#include "rollback.h"

#include <stddef.h>
#include <stdint.h>

#define RB_NETWORK_PLAN_TTL_SECONDS 300

/* Validate a plan token's hex format */
int rb_network_plan_token_valid(const char *token);

typedef struct {
    char interface[64];
    char proto[32];
    char ipaddr[64];
    char netmask[64];
    char gateway[64];
} rb_network_request_t;

typedef enum {
    RB_NETWORK_PLAN_STATE_UNUSED = 0,
    RB_NETWORK_PLAN_STATE_CONSUMED,
    RB_NETWORK_PLAN_STATE_EXPIRED
} rb_network_plan_state_t;

typedef struct {
    char token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
    /* Delivered to the app at preview time; activated only by apply. */
    char health_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U];
    rb_scope_t scope;
    int64_t created_at;
    int64_t deadline;
    rb_network_plan_state_t state;
    rb_network_request_t baseline;
    rb_network_request_t request;
} rb_network_plan_t;

int rb_network_plan_create(rb_context_t *context, const rb_network_request_t *request,
                           rb_network_plan_t *plan);
int rb_network_plan_create_with_baseline(rb_context_t *context,
                           const rb_network_request_t *baseline,
                           const rb_network_request_t *request,
                           rb_network_plan_t *plan);
int rb_network_plan_create_with_baseline_ttl(rb_context_t *context,
                           const rb_network_request_t *baseline,
                           const rb_network_request_t *request,
                           int64_t ttl_seconds, rb_network_plan_t *plan);
int rb_network_plan_load(rb_context_t *context, const char *token,
                        rb_network_plan_t *plan);
int rb_network_plan_verify_request(const rb_network_plan_t *plan,
                                  const rb_network_request_t *request);
int rb_network_plan_consume(rb_context_t *context, const char *token,
                           const rb_network_request_t *request,
                           rb_network_plan_t *plan);
const char *rb_network_plan_state_name(rb_network_plan_state_t state);

#endif
