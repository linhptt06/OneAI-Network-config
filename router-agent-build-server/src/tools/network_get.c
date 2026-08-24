#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"
#include "router_tool_api.h"

#include <stdio.h>
#include <string.h>
#ifndef ROUTER_AGENT_TEST_BACKEND
#include <uci.h>
#endif

typedef struct {
    const char *interface_name;
} tool_request_t;

typedef struct {
    char proto[32];
    char ipaddr[64];
    char netmask[64];
    char gateway[64];
    char device[64];
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
} tool_response_t;

static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response);
static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response);
static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response);
#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result);
#endif
static void set_response_error(tool_response_t *response, const char *code, const char *message);
static tool_result_t copy_value(char *destination, size_t size, const char *value);

 #ifndef ROUTER_AGENT_EMBEDDED
int main(int argc, char **argv)
{
    tool_request_t request = {0};
    tool_response_t response = {0};
    tool_result_t result;

    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) result = validate_request(&request, &response);
    if (result == TOOL_RESULT_OK) result = execute_backend_operation(&request, &response);
    return print_json_response(&request, &response, result);
}
#endif

static int print_json_response_to_buffer(const tool_request_t *request, const tool_response_t *response, tool_result_t result, char *output, size_t output_size)
{
    char name[384], proto[192], ipaddr[384], netmask[384], gateway[384], device[384], data[2048];
    int written;
    if (result != TOOL_RESULT_OK) return tool_print_error_to_buffer(response->error_code, response->error_message, output, output_size);
    if ((tool_json_escape(request->interface_name, name, sizeof(name)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->proto, proto, sizeof(proto)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->ipaddr, ipaddr, sizeof(ipaddr)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->netmask, netmask, sizeof(netmask)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->gateway, gateway, sizeof(gateway)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->device, device, sizeof(device)) != TOOL_RESULT_OK))
        return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    written = snprintf(data, sizeof(data),
        "{\"interface\":\"%s\",\"proto\":\"%s\",\"ipaddr\":\"%s\",\"netmask\":\"%s\",\"gateway\":\"%s\",\"device\":\"%s\"}",
        name, proto, ipaddr, netmask, gateway, device);
    if ((written < 0) || ((size_t)written >= sizeof(data))) return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    return tool_print_success_json_to_buffer(data, output, output_size);
}

int router_tool_network_get(const char *argument, char *output, size_t output_size)
{
    tool_request_t request = {0};
    tool_response_t response = {0};
    tool_result_t result;
    char *argv[3];
    int argc;

    argv[0] = "network_get";
    if ((argument != NULL) && (argument[0] != '\0')) {
        argc = 2;
        argv[1] = (char *)argument;
        argv[2] = NULL;
    } else {
        argc = 1;
        argv[1] = NULL;
    }
    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) result = validate_request(&request, &response);
    if (result == TOOL_RESULT_OK) result = execute_backend_operation(&request, &response);
    return print_json_response_to_buffer(&request, &response, result, output, output_size);
}

static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response)
{
    if (argc != 2) {
        set_response_error(response, "invalid_arguments", "Usage: network_get <interface>");
        return TOOL_RESULT_ERROR;
    }
    request->interface_name = argv[1];
    return TOOL_RESULT_OK;
}

static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response)
{
    if (!validator_uci_section(request->interface_name)) {
        set_response_error(response, "invalid_interface", "UCI interface section name is invalid");
        return TOOL_RESULT_ERROR;
    }
    return TOOL_RESULT_OK;
}

static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response)
{
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (strcmp(request->interface_name, "lan") != 0) {
        set_response_error(response, "section_not_found", "Network interface section was not found");
        return TOOL_RESULT_ERROR;
    }
    (void)copy_value(response->proto, sizeof(response->proto), "static");
    (void)copy_value(response->ipaddr, sizeof(response->ipaddr), "192.168.1.1");
    (void)copy_value(response->netmask, sizeof(response->netmask), "255.255.255.0");
    (void)copy_value(response->gateway, sizeof(response->gateway), "192.168.1.254");
    (void)copy_value(response->device, sizeof(response->device), "br-lan");
    return TOOL_RESULT_OK;
#else
    struct uci_context *context = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_section *section;
    const char *value;
    if (context == NULL) {
        set_response_error(response, "backend_unavailable", "Unable to allocate UCI context");
        return TOOL_RESULT_ERROR;
    }
    if (uci_load(context, "network", &package) != UCI_OK) {
        tool_log_error("network_get", "Unable to load UCI network package");
        uci_free_context(context);
        set_response_error(response, "backend_unavailable", "Unable to load network configuration");
        return TOOL_RESULT_ERROR;
    }
    section = uci_lookup_section(context, package, request->interface_name);
    if ((section == NULL) || (strcmp(section->type, "interface") != 0)) {
        uci_unload(context, package);
        uci_free_context(context);
        set_response_error(response, "section_not_found", "Network interface section was not found");
        return TOOL_RESULT_ERROR;
    }
#define COPY_UCI_OPTION(field, option) do { \
    value = uci_lookup_option_string(context, section, option); \
    if ((value != NULL) && (copy_value(response->field, sizeof(response->field), value) != TOOL_RESULT_OK)) { \
        uci_unload(context, package); uci_free_context(context); \
        set_response_error(response, "backend_value_too_long", "UCI option exceeds the supported response size"); \
        return TOOL_RESULT_ERROR; \
    } \
} while (0)
    COPY_UCI_OPTION(proto, "proto");
    COPY_UCI_OPTION(ipaddr, "ipaddr");
    COPY_UCI_OPTION(netmask, "netmask");
    COPY_UCI_OPTION(gateway, "gateway");
    COPY_UCI_OPTION(device, "device");
    if (response->device[0] == '\0') COPY_UCI_OPTION(device, "ifname");
#undef COPY_UCI_OPTION
    uci_unload(context, package);
    uci_free_context(context);
    return TOOL_RESULT_OK;
#endif
}

#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result)
{
    char name[384], proto[192], ipaddr[384], netmask[384], gateway[384], device[384], data[2048];
    int written;
    if (result != TOOL_RESULT_OK) return tool_print_error(response->error_code, response->error_message);
    if ((tool_json_escape(request->interface_name, name, sizeof(name)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->proto, proto, sizeof(proto)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->ipaddr, ipaddr, sizeof(ipaddr)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->netmask, netmask, sizeof(netmask)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->gateway, gateway, sizeof(gateway)) != TOOL_RESULT_OK) ||
        (tool_json_escape(response->device, device, sizeof(device)) != TOOL_RESULT_OK))
        return tool_print_error("internal_error", "Unable to encode response");
    written = snprintf(data, sizeof(data),
        "{\"interface\":\"%s\",\"proto\":\"%s\",\"ipaddr\":\"%s\",\"netmask\":\"%s\",\"gateway\":\"%s\",\"device\":\"%s\"}",
        name, proto, ipaddr, netmask, gateway, device);
    if ((written < 0) || ((size_t)written >= sizeof(data))) return tool_print_error("internal_error", "Unable to encode response");
    return tool_print_success_json(data);
}
#endif

static void set_response_error(tool_response_t *response, const char *code, const char *message)
{
    tool_set_error(response->error_code, sizeof(response->error_code), response->error_message, sizeof(response->error_message), code, message);
}

static tool_result_t copy_value(char *destination, size_t size, const char *value)
{
    int written = snprintf(destination, size, "%s", value);
    return ((written >= 0) && ((size_t)written < size)) ? TOOL_RESULT_OK : TOOL_RESULT_ERROR;
}
