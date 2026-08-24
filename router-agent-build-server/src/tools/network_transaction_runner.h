#ifndef ROUTER_AGENT_NETWORK_TRANSACTION_RUNNER_H
#define ROUTER_AGENT_NETWORK_TRANSACTION_RUNNER_H

#include "rollback/network_uci.h"
#include <stdio.h>

typedef int (*router_guard_running_fn)(void *private_data);

int router_network_transaction_run(rb_context_t *context,
        const rb_network_uci_ops_t *uci_ops, void *uci_private,
        router_guard_running_fn guard_running, void *guard_private,
        FILE *output);

#endif
