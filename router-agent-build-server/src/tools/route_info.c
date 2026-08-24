#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"
#include <stdio.h>
#include <string.h>
#include "router_tool_api.h"
#ifndef ROUTER_AGENT_TEST_BACKEND
#include <libubox/blobmsg_json.h>
#include <libubus.h>
#include <stdlib.h>
#endif

#define ROUTE_JSON_SIZE 65536U

typedef struct { int argument_count; } tool_request_t;
typedef struct {
    char route_json[ROUTE_JSON_SIZE];
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
} tool_response_t;

#ifndef ROUTER_AGENT_EMBEDDED
static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response);
#endif
static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response);
static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response);
#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result);
#endif
static void set_response_error(tool_response_t *response, const char *code, const char *message);
#ifndef ROUTER_AGENT_TEST_BACKEND
static void receive_ubus_response(struct ubus_request *request, int type, struct blob_attr *message);
#endif

 #ifndef ROUTER_AGENT_EMBEDDED
int main(int argc, char **argv)
{
    tool_request_t request = {0}; tool_response_t response = {0}; tool_result_t result;
    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) result = validate_request(&request, &response);
    if (result == TOOL_RESULT_OK) result = execute_backend_operation(&request, &response);
    return print_json_response(&request, &response, result);
}
#endif

int router_tool_route_info(const char *argument, char *output, size_t output_size)
{
    (void)argument;
    tool_request_t request = {0}; tool_response_t response = {0}; tool_result_t result;
    request.argument_count = 1;
    if (validate_request(&request, &response) != TOOL_RESULT_OK) return tool_print_error_to_buffer(response.error_code, response.error_message, output, output_size);
    result = execute_backend_operation(&request, &response);
    if (result != TOOL_RESULT_OK) return tool_print_error_to_buffer(response.error_code, response.error_message, output, output_size);
    return tool_print_success_json_to_buffer(response.route_json, output, output_size);
}

#ifndef ROUTER_AGENT_EMBEDDED
static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response)
{
    (void)argv; request->argument_count = argc;
    if (argc != 1) { set_response_error(response, "invalid_arguments", "Usage: route_info"); return TOOL_RESULT_ERROR; }
    return TOOL_RESULT_OK;
}
#endif

static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response)
{
    if (!validator_argument_count(request->argument_count, 1)) { set_response_error(response, "invalid_arguments", "route_info accepts no arguments"); return TOOL_RESULT_ERROR; }
    return TOOL_RESULT_OK;
}

static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response)
{
    (void)request;
#ifdef ROUTER_AGENT_TEST_BACKEND
    (void)snprintf(response->route_json, sizeof(response->route_json), "{\"interface\":[{\"interface\":\"lan\",\"route\":[{\"target\":\"0.0.0.0\",\"mask\":0}]}]}");
    return TOOL_RESULT_OK;
#else
    struct ubus_context *context; uint32_t object_id; int status;
    context = ubus_connect(NULL);
    if (context == NULL) { set_response_error(response, "backend_unavailable", "Unable to connect to ubus"); return TOOL_RESULT_ERROR; }
    status = ubus_lookup_id(context, "network.interface", &object_id);
    if (status == 0) status = ubus_invoke(context, object_id, "dump", NULL, receive_ubus_response, response, 5000);
    ubus_free(context);
    if ((status != 0) || (response->route_json[0] == '\0')) { tool_log_error("route_info", ubus_strerror(status)); set_response_error(response, "backend_failed", "Unable to obtain route information from ubus"); return TOOL_RESULT_ERROR; }
    return TOOL_RESULT_OK;
#endif
}

#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result)
{
    (void)request;
    if (result != TOOL_RESULT_OK) return tool_print_error(response->error_code, response->error_message);
    return tool_print_success_json(response->route_json);
}
#endif

static void set_response_error(tool_response_t *response, const char *code, const char *message)
{ tool_set_error(response->error_code, sizeof(response->error_code), response->error_message, sizeof(response->error_message), code, message); }

#ifndef ROUTER_AGENT_TEST_BACKEND
static void receive_ubus_response(struct ubus_request *request, int type, struct blob_attr *message)
{
    tool_response_t *response = (tool_response_t *)request->priv;
    char *json;
    int written;
    (void)type;
    if ((response == NULL) || (message == NULL)) return;
    json = blobmsg_format_json(message, true);
    if (json == NULL) return;
    written = snprintf(response->route_json, sizeof(response->route_json), "%s", json);
    free(json);
    if ((written < 0) || ((size_t)written >= sizeof(response->route_json))) response->route_json[0] = '\0';
}
#endif
