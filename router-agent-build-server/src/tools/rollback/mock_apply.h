#ifndef ROUTER_AGENT_MOCK_APPLY_H
#define ROUTER_AGENT_MOCK_APPLY_H

#include "rollback.h"

typedef struct {
    unsigned int calls;
    rb_scope_t last_scope;
    int result;
} rb_mock_apply_t;

int rb_mock_apply(rb_scope_t scope, void *private_data);

#endif
