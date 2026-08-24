#ifndef ROUTER_AGENT_NATIVE_APPLY_H
#define ROUTER_AGENT_NATIVE_APPLY_H

#include "rollback.h"
#include <stdint.h>

#define RB_NATIVE_APPLY_TIMEOUT_MS 5000

typedef struct {
    void *(*connect)(void *private_data);
    int (*lookup)(void *context, const char *object, uint32_t *object_id);
    int (*invoke)(void *context, uint32_t object_id, const char *method,
                  int timeout_ms);
    void (*disconnect)(void *context);
} rb_native_apply_ops_t;

int rb_native_apply(rb_scope_t scope, void *private_data);
#ifdef ROUTER_AGENT_NATIVE_APPLY_TEST
int rb_native_apply_with_ops(rb_scope_t scope, const rb_native_apply_ops_t *ops,
                             void *private_data);
#endif

#endif
