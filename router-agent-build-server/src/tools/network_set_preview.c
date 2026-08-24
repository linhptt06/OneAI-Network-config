#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"
#include "router_tool_api.h"

#include "rollback/rollback.h"
#include "rollback/network_plan.h"
#include "rollback/network_uci.h"
#ifndef ROUTER_AGENT_TEST_BACKEND
#include "rollback/native_apply.h"
#endif

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

#ifdef ROUTER_AGENT_TEST_BACKEND
#ifndef ROUTER_AGENT_TEST_STATE_ROOT
#error "ROUTER_AGENT_TEST_STATE_ROOT must be defined when ROUTER_AGENT_TEST_BACKEND is set"
#endif
#ifndef ROUTER_AGENT_TEST_CONFIG_ROOT
#error "ROUTER_AGENT_TEST_CONFIG_ROOT must be defined when ROUTER_AGENT_TEST_BACKEND is set"
#endif
static router_test_backend_t test_backend;
static int test_rolling_back;
static rb_network_request_t test_precommit;

static void test_event(const char *event)
{
    size_t used = strlen(test_backend.events);
    if (used != 0U) test_backend.events[used++] = ',';
    (void)snprintf(test_backend.events + used, sizeof(test_backend.events) - used, "%s", event);
}

void router_test_backend_reset(void)
{
    (void)memset(&test_backend, 0, sizeof(test_backend));
    (void)snprintf(test_backend.current.interface, sizeof(test_backend.current.interface), "lan");
    (void)snprintf(test_backend.current.proto, sizeof(test_backend.current.proto), "static");
    (void)snprintf(test_backend.current.ipaddr, sizeof(test_backend.current.ipaddr), "192.168.1.1");
    (void)snprintf(test_backend.current.netmask, sizeof(test_backend.current.netmask), "255.255.255.0");
    test_rolling_back = 0;
    test_precommit = test_backend.current;
}

void router_test_backend_fail_uci(int result) { test_backend.uci_result = result; }
void router_test_backend_fail_reload(int result) { test_backend.reload_result = result; }
const router_test_backend_t *router_test_backend_state(void) { return &test_backend; }
void router_test_backend_set_current(const rb_network_request_t *current) { if (current != NULL) test_backend.current = *current; }

static int test_uci_read(void *private_data, rb_network_request_t *current)
{
    (void)private_data;
    if (test_backend.current.interface[0] == '\0') router_test_backend_reset();
    *current = test_backend.current;
    return 0;
}

static int test_uci_commit(void *private_data, const rb_network_request_t *request)
{
    (void)private_data;
    test_backend.uci_calls += 1U;
    test_backend.applied_request = *request;
    test_precommit = test_backend.current;
    test_event("commit");
    if (test_backend.uci_result == 0) test_backend.current = *request;
    return test_backend.uci_result;
}

static const rb_network_uci_ops_t test_uci_ops = { test_uci_read, test_uci_commit };

static int rb_test_apply(rb_scope_t scope, void *private_data)
{
    (void)scope;
    (void)private_data;
    if (test_rolling_back != 0) {
        test_backend.rollback_calls += 1U;
        test_backend.current = test_precommit;
        test_event("rollback");
        return 0;
    }
    test_backend.reload_calls += 1U;
    test_event("apply");
    return test_backend.reload_result;
}
#endif

/* Simple strict JSON parser for the expected flat object with string values. */
static int extract_string(const char **p, char *out, size_t out_size)
{
    const char *s = *p;
    if (*s != '"') return -1;
    s++;
    size_t o = 0;
    while (*s && *s != '"') {
        if ((*s == '\\') && s[1]) {
            /* accept simple escapes */
            s++;
            if (o + 1 < out_size) out[o++] = *s;
            s++;
            continue;
        }
        if (o + 1 < out_size) out[o++] = *s;
        s++;
    }
    if (*s != '"') return -1;
    s++;
    out[o] = '\0';
    *p = s;
    return 0;
}

static const char *skip_ws(const char *s)
{
    while (*s && ((*s == ' ') || (*s == '\n') || (*s == '\r') || (*s == '\t'))) s++;
    return s;
}

static int parse_object(const char *json,
                        char *interface, size_t interface_size,
                        char *proto, size_t proto_size,
                        char *ipaddr, size_t ipaddr_size,
                        char *netmask, size_t netmask_size,
                        char *gateway, size_t gateway_size,
                        char *error_code, size_t error_code_size,
                        char *error_message, size_t error_message_size)
{
    const char *s = skip_ws(json);
    int seen_interface = 0, seen_proto = 0, seen_ipaddr = 0, seen_netmask = 0, seen_gateway = 0;
    if (*s != '{') goto bad_json;
    s++;
    while (1) {
        s = skip_ws(s);
        if (*s == '}') { s++; break; }
        if (*s != '"') goto bad_json;
        char key[64];
        const char *kp = s;
        if (extract_string(&kp, key, sizeof(key)) != 0) goto bad_json;
        s = skip_ws(kp);
        if (*s != ':') goto bad_json;
        s++;
        s = skip_ws(s);
        if (strcmp(key, "interface") == 0) {
            if (extract_string(&s, interface, interface_size) != 0) goto bad_json;
            seen_interface = 1;
        } else if (strcmp(key, "proto") == 0) {
            if (extract_string(&s, proto, proto_size) != 0) goto bad_json;
            seen_proto = 1;
        } else if (strcmp(key, "ipaddr") == 0) {
            if (extract_string(&s, ipaddr, ipaddr_size) != 0) goto bad_json;
            seen_ipaddr = 1;
        } else if (strcmp(key, "netmask") == 0) {
            if (extract_string(&s, netmask, netmask_size) != 0) goto bad_json;
            seen_netmask = 1;
        } else if (strcmp(key, "gateway") == 0) {
            if (extract_string(&s, gateway, gateway_size) != 0) goto bad_json;
            seen_gateway = 1;
        } else {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_field", "Unexpected field in request");
            return -1;
        }
        s = skip_ws(s);
        if (*s == ',') { s++; continue; }
        if (*s == '}') { s++; break; }
        goto bad_json;
    }
    if (!seen_interface || !seen_proto || !seen_ipaddr || !seen_netmask || !seen_gateway) {
        tool_set_error(error_code, error_code_size, error_message, error_message_size,
                       "invalid_arguments", "Missing required fields");
        return -1;
    }
    return 0;
bad_json:
    tool_set_error(error_code, error_code_size, error_message, error_message_size,
                   "invalid_json", "Unable to parse JSON request");
    return -1;
}

static tool_result_t validate_request_fields(const char *interface, const char *proto,
                                            const char *ipaddr, const char *netmask, const char *gateway,
                                            char *error_code, size_t error_code_size,
                                            char *error_message, size_t error_message_size)
{
    if (strcmp(interface, "lan") != 0) {
        tool_set_error(error_code, error_code_size, error_message, error_message_size,
                       "invalid_interface", "Interface name is invalid");
        return TOOL_RESULT_ERROR;
    }
    if (!((strcmp(proto, "static") == 0) || (strcmp(proto, "dhcp") == 0))) {
        tool_set_error(error_code, error_code_size, error_message, error_message_size,
                       "invalid_proto", "Proto must be 'static' or 'dhcp'");
        return TOOL_RESULT_ERROR;
    }
    if (strcmp(proto, "static") == 0) {
        if (!validator_ipv4(ipaddr)) {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_ipaddr", "IP address is invalid");
            return TOOL_RESULT_ERROR;
        }
        if (!validator_netmask(netmask)) {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_netmask", "Netmask is invalid");
            return TOOL_RESULT_ERROR;
        }
        if ((gateway[0] != '\0') && !validator_optional_gateway(gateway)) {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_gateway", "Gateway is invalid");
            return TOOL_RESULT_ERROR;
        }
    } else {
        if ((ipaddr[0] != '\0') || (netmask[0] != '\0') || (gateway[0] != '\0')) {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_dhcp_fields", "DHCP requires empty IP, netmask and gateway fields");
            return TOOL_RESULT_ERROR;
        }
    }
    return TOOL_RESULT_OK;
}

static int request_equal(const rb_network_request_t *left, const rb_network_request_t *right)
{
    return (strcmp(left->interface, right->interface) == 0) &&
           (strcmp(left->proto, right->proto) == 0) &&
           (strcmp(left->ipaddr, right->ipaddr) == 0) &&
           (strcmp(left->netmask, right->netmask) == 0) &&
           (strcmp(left->gateway, right->gateway) == 0);
}

int router_tool_network_set_preview(const char *argument, char *output, size_t output_size)
{
    char interface[VALIDATOR_UCI_SECTION_SIZE];
    char proto[32];
    char ipaddr[64];
    char netmask[64];
    char gateway[64];
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
    if (argument == NULL) return tool_print_error_to_buffer("invalid_arguments", "Missing argument", output, output_size);

    if (parse_object(argument, interface, sizeof(interface), proto, sizeof(proto),
                     ipaddr, sizeof(ipaddr), netmask, sizeof(netmask), gateway, sizeof(gateway),
                     error_code, sizeof(error_code), error_message, sizeof(error_message)) != 0) {
        return tool_print_error_to_buffer(error_code, error_message, output, output_size);
    }

    if (validate_request_fields(interface, proto, ipaddr, netmask, gateway,
                                error_code, sizeof(error_code), error_message, sizeof(error_message)) != TOOL_RESULT_OK) {
        return tool_print_error_to_buffer(error_code, error_message, output, output_size);
    }

#ifndef RB_STATE_ROOT
#define RB_STATE_ROOT "/etc/router-agent"
#endif
#ifndef RB_CONFIG_ROOT
#define RB_CONFIG_ROOT "/etc/config"
#endif
    rb_context_t context;
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (rb_context_init(&context, ROUTER_AGENT_TEST_STATE_ROOT, ROUTER_AGENT_TEST_CONFIG_ROOT, rb_test_apply, NULL) != 0) {
        return tool_print_error_to_buffer("backend_unavailable", "Unable to initialize context", output, output_size);
    }
#else
    if (rb_context_init(&context, RB_STATE_ROOT, RB_CONFIG_ROOT, rb_native_apply, NULL) != 0) {
        return tool_print_error_to_buffer("backend_unavailable", "Unable to initialize context", output, output_size);
    }
#endif

    rb_network_request_t req;
    rb_network_request_t baseline;
    (void)memset(&req, 0, sizeof(req));
    (void)snprintf(req.interface, sizeof(req.interface), "%s", interface);
    (void)snprintf(req.proto, sizeof(req.proto), "%s", proto);
    (void)snprintf(req.ipaddr, sizeof(req.ipaddr), "%s", ipaddr);
    (void)snprintf(req.netmask, sizeof(req.netmask), "%s", netmask);
    (void)snprintf(req.gateway, sizeof(req.gateway), "%s", gateway);

#ifdef ROUTER_AGENT_TEST_BACKEND
    if (test_uci_ops.read_lan(NULL, &baseline) != 0) {
#else
    if (rb_network_uci_native_ops.read_lan(NULL, &baseline) != 0) {
#endif
        rb_context_close(&context);
        return tool_print_error_to_buffer("uci_read_failed", "Unable to read network.lan", output, output_size);
    }
    if (validate_request_fields(baseline.interface, baseline.proto,
                                baseline.ipaddr, baseline.netmask, baseline.gateway,
                                error_code, sizeof(error_code), error_message,
                                sizeof(error_message)) != TOOL_RESULT_OK) {
        rb_context_close(&context);
        return tool_print_error_to_buffer("invalid_baseline", "Current network.lan is invalid", output, output_size);
    }

    rb_network_plan_t plan;
    if (rb_network_plan_create_with_baseline(&context, &baseline, &req, &plan) != 0) {
        rb_context_close(&context);
        return tool_print_error_to_buffer("internal_error", "Unable to create plan", output, output_size);
    }
    rb_context_close(&context);

    char esc_interface[256], esc_proto[256], esc_ip[256], esc_netmask[256], esc_gateway[256];
    if (tool_json_escape(plan.request.interface, esc_interface, sizeof(esc_interface)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.request.proto, esc_proto, sizeof(esc_proto)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.request.ipaddr, esc_ip, sizeof(esc_ip)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.request.netmask, esc_netmask, sizeof(esc_netmask)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.request.gateway, esc_gateway, sizeof(esc_gateway)) != TOOL_RESULT_OK) {
        return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    }

    char old_proto[256], old_ip[256], old_netmask[256], old_gateway[256];
    if (tool_json_escape(plan.baseline.proto, old_proto, sizeof(old_proto)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.baseline.ipaddr, old_ip, sizeof(old_ip)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.baseline.netmask, old_netmask, sizeof(old_netmask)) != TOOL_RESULT_OK ||
        tool_json_escape(plan.baseline.gateway, old_gateway, sizeof(old_gateway)) != TOOL_RESULT_OK) {
        return tool_print_error_to_buffer("internal_error", "Unable to encode baseline", output, output_size);
    }
    char data[3072];
    int written = snprintf(data, sizeof(data),
        "{\"plan_token\":\"%s\",\"health_token\":\"%s\",\"deadline\":%lld,\"request\":{\"interface\":\"%s\",\"proto\":\"%s\",\"ipaddr\":\"%s\",\"netmask\":\"%s\",\"gateway\":\"%s\"},\"diff\":{\"proto\":{\"before\":\"%s\",\"after\":\"%s\"},\"ipaddr\":{\"before\":\"%s\",\"after\":\"%s\"},\"netmask\":{\"before\":\"%s\",\"after\":\"%s\"},\"gateway\":{\"before\":\"%s\",\"after\":\"%s\"}}}",
        plan.token, plan.health_token, (long long)plan.deadline, esc_interface, esc_proto, esc_ip, esc_netmask, esc_gateway,
        old_proto, esc_proto, old_ip, esc_ip, old_netmask, esc_netmask, old_gateway, esc_gateway);
    if ((written < 0) || ((size_t)written >= sizeof(data))) return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    return tool_print_success_json_to_buffer(data, output, output_size);
}

/* Strict parser for apply: only allow {"plan_token":"...","confirmed":true} */
static int parse_apply_object(const char *json, char *plan_token, size_t plan_token_size,
                              int *confirmed,
                              char *error_code, size_t error_code_size,
                              char *error_message, size_t error_message_size)
{
    const char *s = skip_ws(json);
    if (*s != '{') goto bad_json;
    s++;
    int seen_token = 0, seen_confirmed = 0;
    while (1) {
        s = skip_ws(s);
        if (*s == '}') { s++; break; }
        if (*s != '"') goto bad_json;
        char key[64];
        const char *kp = s;
        if (extract_string(&kp, key, sizeof(key)) != 0) goto bad_json;
        s = skip_ws(kp);
        if (*s != ':') goto bad_json;
        s++;
        s = skip_ws(s);
        if (strcmp(key, "plan_token") == 0) {
            if (extract_string(&s, plan_token, plan_token_size) != 0) goto bad_json;
            seen_token = 1;
        } else if (strcmp(key, "confirmed") == 0) {
            if (strncmp(s, "true", 4) == 0) {
                *confirmed = 1; s += 4; seen_confirmed = 1;
            } else if (strncmp(s, "false", 5) == 0) {
                *confirmed = 0; s += 5; seen_confirmed = 1;
            } else goto bad_json;
        } else {
            tool_set_error(error_code, error_code_size, error_message, error_message_size,
                           "invalid_field", "Unexpected field in request");
            return -1;
        }
        s = skip_ws(s);
        if (*s == ',') { s++; continue; }
        if (*s == '}') { s++; break; }
        goto bad_json;
    }
    if (!seen_token || !seen_confirmed) {
        tool_set_error(error_code, error_code_size, error_message, error_message_size,
                       "invalid_arguments", "Missing required fields");
        return -1;
    }
    return 0;
bad_json:
    tool_set_error(error_code, error_code_size, error_message, error_message_size,
                   "invalid_json", "Unable to parse JSON request");
    return -1;
}

/* Strict parser for health confirmation: only a distinct health token. */
static int parse_health_confirm_object(const char *json, char *health_token,
                                       size_t health_token_size,
                                       char *error_code, size_t error_code_size,
                                       char *error_message, size_t error_message_size)
{
    const char *s = skip_ws(json);
    const char *key_start;
    char key[64];

    if (*s != '{') goto bad_json;
    s++;
    s = skip_ws(s);
    if (*s != '"') goto bad_json;
    key_start = s;
    if (extract_string(&key_start, key, sizeof(key)) != 0) goto bad_json;
    if (strcmp(key, "health_token") != 0) {
        tool_set_error(error_code, error_code_size, error_message, error_message_size,
                       "invalid_field", "Unexpected field in request");
        return -1;
    }
    s = skip_ws(key_start);
    if (*s != ':') goto bad_json;
    s++;
    s = skip_ws(s);
    if (extract_string(&s, health_token, health_token_size) != 0) goto bad_json;
    s = skip_ws(s);
    if (*s != '}') goto bad_json;
    s++;
    if (*skip_ws(s) != '\0') goto bad_json;
    return 0;
bad_json:
    tool_set_error(error_code, error_code_size, error_message, error_message_size,
                   "invalid_json", "Unable to parse JSON request");
    return -1;
}

static void rollback_immediate(rb_context_t *context)
{
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_rolling_back = 1;
#endif
    (void)rb_guard_check(context, (int64_t)time(NULL), true);
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_rolling_back = 0;
#endif
}

int router_tool_network_set_apply(const char *argument, char *output, size_t output_size)
{
    char plan_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U] = "";
    int confirmed = 0;
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];

    if (argument == NULL) return tool_print_error_to_buffer("invalid_arguments", "Missing argument", output, output_size);
    if (parse_apply_object(argument, plan_token, sizeof(plan_token), &confirmed, error_code, sizeof(error_code), error_message, sizeof(error_message)) != 0) {
        return tool_print_error_to_buffer(error_code, error_message, output, output_size);
    }
    if (!rb_network_plan_token_valid(plan_token)) return tool_print_error_to_buffer("invalid_token", "Plan token invalid", output, output_size);
    if (!confirmed) return tool_print_error_to_buffer("not_confirmed", "Action not confirmed", output, output_size);

#ifndef RB_STATE_ROOT
#define RB_STATE_ROOT "/etc/router-agent"
#endif
#ifndef RB_CONFIG_ROOT
#define RB_CONFIG_ROOT "/etc/config"
#endif
    rb_context_t context;
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (rb_context_init(&context, ROUTER_AGENT_TEST_STATE_ROOT, ROUTER_AGENT_TEST_CONFIG_ROOT, rb_test_apply, NULL) != 0) {
        return tool_print_error_to_buffer("backend_unavailable", "Unable to initialize context", output, output_size);
    }
#else
    if (rb_context_init(&context, RB_STATE_ROOT, RB_CONFIG_ROOT, rb_native_apply, NULL) != 0) {
        return tool_print_error_to_buffer("backend_unavailable", "Unable to initialize context", output, output_size);
    }
#endif

    rb_network_plan_t plan;
    if (rb_network_plan_load(&context, plan_token, &plan) != 0) {
        rb_context_close(&context);
        return tool_print_error_to_buffer("not_found", "Plan not found or expired", output, output_size);
    }
    if (plan.scope != RB_SCOPE_NETWORK) { rb_context_close(&context); return tool_print_error_to_buffer("invalid_scope", "Plan scope not network", output, output_size); }

    if (rb_lock(&context) != 0) {
        rb_context_close(&context);
        return tool_print_error_to_buffer("transaction_busy", "Another transaction is active", output, output_size);
    }
    {
        rb_network_request_t current;
#ifdef ROUTER_AGENT_TEST_BACKEND
        int read_result = test_uci_ops.read_lan(NULL, &current);
#else
        int read_result = rb_network_uci_native_ops.read_lan(NULL, &current);
#endif
        if ((read_result != 0) || !request_equal(&current, &plan.baseline)) {
            rb_context_close(&context);
            return tool_print_error_to_buffer("baseline_mismatch", "network.lan changed since preview", output, output_size);
        }
    }

    if (rb_guard_arm(&context, plan_token, &plan.request) != 0) {
        rollback_immediate(&context);
        rb_context_close(&context);
        return tool_print_error_to_buffer("arm_failed", "Unable to arm guard", output, output_size);
    }
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_event("backup");
    test_event("staged");
#endif

    /* Commit only fixed package network, section lan and allow-listed keys. */
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (test_uci_ops.commit_lan(NULL, &plan.request) != 0) {
#else
    if (rb_network_uci_native_ops.commit_lan(NULL, &plan.request) != 0) {
#endif
        rollback_immediate(&context);
        rb_context_close(&context);
        return tool_print_error_to_buffer("commit_failed", "Unable to commit network.lan", output, output_size);
    }
    if (rb_transition(&context, RB_STATE_COMMITTED) != 0) {
        rollback_immediate(&context); rb_context_close(&context);
        return tool_print_error_to_buffer("state_failed", "Unable to record committed state", output, output_size);
    }
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_event("committed");
#endif
    if (rb_transition(&context, RB_STATE_APPLYING) != 0) {
        rollback_immediate(&context); rb_context_close(&context);
        return tool_print_error_to_buffer("state_failed", "Unable to record applying state", output, output_size);
    }
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_event("applying");
#endif

    if (context.apply(RB_SCOPE_NETWORK, context.apply_private) != 0) {
        rollback_immediate(&context);
        rb_context_close(&context);
        return tool_print_error_to_buffer("reload_failed", "Unable to reload network", output, output_size);
    }
    if (rb_transition(&context, RB_STATE_PENDING_HEALTH_CONFIRMATION) != 0) {
        rollback_immediate(&context); rb_context_close(&context);
        return tool_print_error_to_buffer("state_failed", "Unable to record pending state", output, output_size);
    }
#ifdef ROUTER_AGENT_TEST_BACKEND
    test_event("pending");
#endif

    char data[128];
    int written = snprintf(data, sizeof(data), "{\"status\":\"pending_health_confirmation\",\"deadline\":%lld}", (long long)plan.deadline);
    if ((written < 0) || ((size_t)written >= sizeof(data))) { rb_context_close(&context); return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size); }
    rb_context_close(&context);
    return tool_print_success_json_to_buffer(data, output, output_size);
}

int router_tool_network_set_health_confirm(const char *argument, char *output,
                                           size_t output_size)
{
    char health_token[RB_NETWORK_PLAN_TOKEN_HEX_LEN + 1U] = "";
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
    rb_context_t context;

    if (argument == NULL) {
        return tool_print_error_to_buffer("invalid_arguments", "Missing argument", output, output_size);
    }
    if (parse_health_confirm_object(argument, health_token, sizeof(health_token),
                                    error_code, sizeof(error_code), error_message,
                                    sizeof(error_message)) != 0) {
        return tool_print_error_to_buffer(error_code, error_message, output, output_size);
    }
    if (!rb_network_plan_token_valid(health_token)) {
        return tool_print_error_to_buffer("invalid_health_token", "Health token invalid", output, output_size);
    }
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (rb_context_init(&context, ROUTER_AGENT_TEST_STATE_ROOT, ROUTER_AGENT_TEST_CONFIG_ROOT,
                        rb_test_apply, NULL) != 0) {
#else
    if (rb_context_init(&context, RB_STATE_ROOT, RB_CONFIG_ROOT, rb_native_apply, NULL) != 0) {
#endif
        return tool_print_error_to_buffer("backend_unavailable", "Unable to initialize context", output, output_size);
    }
    if (rb_guard_finalize_health(&context, health_token) != 0) {
        const int saved = errno;
        if (saved == ETIMEDOUT) {
            rollback_immediate(&context);
        }
        rb_context_close(&context);
        return tool_print_error_to_buffer(saved == ETIMEDOUT ? "health_confirmation_expired" : "health_confirmation_failed",
                                          saved == ETIMEDOUT ? "Health confirmation deadline expired" : "Health confirmation rejected",
                                          output, output_size);
    }
    rb_context_close(&context);
    return tool_print_success_json_to_buffer("{\"status\":\"confirmed\"}", output, output_size);
}
