#define _POSIX_C_SOURCE 200809L

#include "network_transaction_runner.h"
#include "rollback/native_apply.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RUNNER_OLD_IP "192.168.88.1"
#define RUNNER_NEW_IP "192.168.10.1"
#define RUNNER_TIMEOUT_SECONDS 60

static int request_equal(const rb_network_request_t *left,
                         const rb_network_request_t *right)
{
    return strcmp(left->interface, right->interface) == 0 &&
           strcmp(left->proto, right->proto) == 0 &&
           strcmp(left->ipaddr, right->ipaddr) == 0 &&
           strcmp(left->netmask, right->netmask) == 0 &&
           strcmp(left->gateway, right->gateway) == 0;
}

static void rollback_immediate(rb_context_t *context)
{
    (void)rb_guard_check(context, (int64_t)time(NULL), true);
}

int router_network_transaction_run(rb_context_t *context,
        const rb_network_uci_ops_t *uci_ops, void *uci_private,
        router_guard_running_fn guard_running, void *guard_private,
        FILE *output)
{
    rb_network_request_t baseline;
    rb_network_request_t request;
    rb_network_request_t current;
    rb_network_plan_t plan;

    if ((context == NULL) || (uci_ops == NULL) || (uci_ops->read_lan == NULL) ||
        (uci_ops->commit_lan == NULL) || (guard_running == NULL) || (output == NULL)) {
        errno = EINVAL;
        return -1;
    }
    if (guard_running(guard_private) != 1) { errno = ESRCH; return -1; }
    if (uci_ops->read_lan(uci_private, &baseline) != 0) return -1;
    if ((strcmp(baseline.interface, "lan") != 0) ||
        (strcmp(baseline.ipaddr, RUNNER_OLD_IP) != 0)) { errno = ESTALE; return -1; }

    request = baseline;
    (void)snprintf(request.ipaddr, sizeof(request.ipaddr), "%s", RUNNER_NEW_IP);
    if (rb_network_plan_create_with_baseline_ttl(context, &baseline, &request,
            RUNNER_TIMEOUT_SECONDS, &plan) != 0) return -1;
    if (rb_lock(context) != 0) return -1;
    if ((uci_ops->read_lan(uci_private, &current) != 0) ||
        !request_equal(&current, &baseline)) { errno = ESTALE; return -1; }
    if (guard_running(guard_private) != 1) { errno = ESRCH; return -1; }
    if (rb_guard_arm(context, plan.token, &plan.request) != 0) return -1;

    if (fprintf(output,
            "{\"plan_token\":\"%s\",\"deadline\":%lld,\"expected_new_ip\":\"%s\"}\n",
            plan.token, (long long)plan.deadline, RUNNER_NEW_IP) < 0 ||
        fflush(output) != 0) {
        rollback_immediate(context);
        return -1;
    }
    if (uci_ops->commit_lan(uci_private, &plan.request) != 0) goto rollback;
    if (rb_transition(context, RB_STATE_COMMITTED) != 0) goto rollback;
    if (rb_transition(context, RB_STATE_APPLYING) != 0) goto rollback;
    if (context->apply(RB_SCOPE_NETWORK, context->apply_private) != 0) goto rollback;
    if (rb_transition(context, RB_STATE_PENDING_HEALTH_CONFIRMATION) != 0) goto rollback;
    return 0;

rollback:
    rollback_immediate(context);
    return -1;
}

#ifndef ROUTER_AGENT_RUNNER_NO_MAIN
static int native_guard_running(void *private_data)
{
    DIR *directory;
    struct dirent *entry;
    (void)private_data;
    directory = opendir("/proc");
    if (directory == NULL) return -1;
    while ((entry = readdir(directory)) != NULL) {
        char path[64];
        char comm[64];
        FILE *file;
        char *end = NULL;
        (void)strtol(entry->d_name, &end, 10);
        if ((entry->d_name[0] == '\0') || (end == NULL) || (*end != '\0')) continue;
        if (snprintf(path, sizeof(path), "/proc/%s/comm", entry->d_name) < 0) continue;
        file = fopen(path, "r");
        if (file == NULL) continue;
        if ((fgets(comm, sizeof(comm), file) != NULL) &&
            ((strcmp(comm, "rollback_guard\n") == 0) ||
             (strcmp(comm, "rollback_guard") == 0))) {
            (void)fclose(file);
            (void)closedir(directory);
            return 1;
        }
        (void)fclose(file);
    }
    (void)closedir(directory);
    return 0;
}

int main(void)
{
    rb_context_t context;
    int result;
    if (rb_context_init(&context, "/etc/router-agent", "/etc/config",
                        rb_native_apply, NULL) != 0) {
        perror("context");
        return 1;
    }
    result = router_network_transaction_run(&context, &rb_network_uci_native_ops,
            NULL, native_guard_running, NULL, stdout);
    if (result != 0) perror("network transaction");
    rb_context_close(&context);
    return result == 0 ? 0 : 1;
}
#endif
