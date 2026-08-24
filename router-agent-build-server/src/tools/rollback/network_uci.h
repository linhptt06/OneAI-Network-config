#ifndef ROUTER_AGENT_NETWORK_UCI_H
#define ROUTER_AGENT_NETWORK_UCI_H

#include "network_plan.h"

typedef struct {
    int (*read_lan)(void *private_data, rb_network_request_t *current);
    int (*commit_lan)(void *private_data, const rb_network_request_t *request);
} rb_network_uci_ops_t;

#ifndef ROUTER_AGENT_TEST_BACKEND
extern const rb_network_uci_ops_t rb_network_uci_native_ops;
#endif

#endif
