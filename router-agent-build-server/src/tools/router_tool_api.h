#ifndef ROUTER_AGENT_TOOL_API_H
#define ROUTER_AGENT_TOOL_API_H

#include <stddef.h>

typedef int (*router_tool_handler_t)(const char *argument,
                                     char *output,
                                     size_t output_size);

int router_tool_traffic_stats(const char *argument, char *output, size_t output_size);
int router_tool_network_get(const char *argument, char *output, size_t output_size);
int router_tool_network_list(const char *argument, char *output, size_t output_size);
int router_tool_wifi_get(const char *argument, char *output, size_t output_size);
int router_tool_route_info(const char *argument, char *output, size_t output_size);
int router_tool_network_set_preview(const char *argument, char *output, size_t output_size);
int router_tool_network_set_apply(const char *argument, char *output, size_t output_size);
int router_tool_network_set_health_confirm(const char *argument, char *output, size_t output_size);

#ifdef ROUTER_AGENT_TEST_BACKEND
#include "rollback/network_plan.h"
typedef struct {
    int uci_result;
    int reload_result;
    unsigned int uci_calls;
    unsigned int reload_calls;
    unsigned int rollback_calls;
    char events[128];
    rb_network_request_t current;
    rb_network_request_t applied_request;
} router_test_backend_t;
void router_test_backend_reset(void);
void router_test_backend_fail_uci(int result);
void router_test_backend_fail_reload(int result);
void router_test_backend_set_current(const rb_network_request_t *current);
const router_test_backend_t *router_test_backend_state(void);
#endif

#endif
