#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <json-c/json.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tools/router_tool_api.h"

#define REQUEST_LIMIT (128U * 1024U)
#define TOOL_OUTPUT_LIMIT (128U * 1024U)

typedef struct {
    const char *name;
    const char *description;
    const char *argument_name;
    router_tool_handler_t handler;
    enum {
        TOOL_INPUT_NONE,
        TOOL_INPUT_STRING,
        TOOL_INPUT_NETWORK_PREVIEW,
        TOOL_INPUT_NETWORK_APPLY,
        TOOL_INPUT_NETWORK_HEALTH_CONFIRM
    } input_kind;
} tool_definition_t;

typedef struct json_object *(*method_handler_t)(struct json_object *id,
                                                struct json_object *params);

typedef struct {
    const char *name;
    method_handler_t handler;
} method_definition_t;

static const tool_definition_t tools[] = {
    {"traffic_stats", "Read counters for a router network interface.", "interface", router_tool_traffic_stats, TOOL_INPUT_STRING},
    {"network_get", "Read a named UCI network interface.", "interface", router_tool_network_get, TOOL_INPUT_STRING},
    {"route_info", "Read route and interface state from ubus.", NULL, router_tool_route_info, TOOL_INPUT_NONE},
    {"wifi_get", "Read non-secret fields from a named UCI wireless section.", "section", router_tool_wifi_get, TOOL_INPUT_STRING},
    {"network_list", "List UCI network interface sections (read-only).", NULL, router_tool_network_list, TOOL_INPUT_NONE},
    {"network_set_preview", "Preview a validated network.lan change and return a short-lived plan token; does not apply the change.", NULL, router_tool_network_set_preview, TOOL_INPUT_NETWORK_PREVIEW},
    {"network_set_apply", "Apply a previously previewed network plan after explicit confirmation; may interrupt connectivity and is protected by rollback.", NULL, router_tool_network_set_apply, TOOL_INPUT_NETWORK_APPLY},
    {"network_set_health_confirm", "Finalize a pending network change after the app reconnects and verifies router health.", NULL, router_tool_network_set_health_confirm, TOOL_INPUT_NETWORK_HEALTH_CONFIRM},
};

#define TOOL_COUNT (sizeof(tools) / sizeof(tools[0]))

static void print_json(struct json_object *value)
{
    (void)fputs(json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN), stdout);
    (void)fputc('\n', stdout);
    (void)fflush(stdout);
}

static struct json_object *new_error_response(struct json_object *id,
                                               int code,
                                               const char *message)
{
    struct json_object *response = json_object_new_object();
    struct json_object *error = json_object_new_object();

    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", id != NULL ? json_object_get(id) : json_object_new_null());
    json_object_object_add(error, "code", json_object_new_int(code));
    json_object_object_add(error, "message", json_object_new_string(message));
    json_object_object_add(response, "error", error);
    return response;
}

static struct json_object *new_text_result(struct json_object *id, const char *text)
{
    struct json_object *response = json_object_new_object();
    struct json_object *result = json_object_new_object();
    struct json_object *content = json_object_new_array();
    struct json_object *item = json_object_new_object();

    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", id != NULL ? json_object_get(id) : json_object_new_null());
    json_object_object_add(item, "type", json_object_new_string("text"));
    json_object_object_add(item, "text", json_object_new_string(text));
    json_object_array_add(content, item);
    json_object_object_add(result, "content", content);
    json_object_object_add(result, "isError", json_object_new_boolean(false));
    json_object_object_add(response, "result", result);
    return response;
}

static struct json_object *tool_error_text(const char *code, const char *message)
{
    struct json_object *root = json_object_new_object();
    struct json_object *error = json_object_new_object();
    json_object_object_add(root, "status", json_object_new_string("error"));
    json_object_object_add(error, "code", json_object_new_string(code));
    json_object_object_add(error, "message", json_object_new_string(message));
    json_object_object_add(root, "error", error);
    return root;
}

static const tool_definition_t *find_tool(const char *name)
{
    size_t index;

    if (name == NULL) return NULL;
    for (index = 0U; index < TOOL_COUNT; index++) {
        if (strcmp(name, tools[index].name) == 0) return &tools[index];
    }
    return NULL;
}

static bool object_has_only_argument(struct json_object *arguments, const char *argument_name)
{
    if (json_object_get_type(arguments) != json_type_object) return false;
    json_object_object_foreach(arguments, key, value) {
        (void)value;
        if ((argument_name == NULL) || (strcmp(key, argument_name) != 0)) return false;
    }
    return true;
}

static bool read_tool_argument(const tool_definition_t *tool,
                               struct json_object *arguments,
                               const char **argument,
                               const char **message)
{
    struct json_object *value = NULL;

    if ((tool->input_kind == TOOL_INPUT_NETWORK_PREVIEW) ||
        (tool->input_kind == TOOL_INPUT_NETWORK_APPLY) ||
        (tool->input_kind == TOOL_INPUT_NETWORK_HEALTH_CONFIRM)) {
        if (json_object_get_type(arguments) != json_type_object) {
            *message = "Tool arguments must be an object.";
            return false;
        }
        *argument = json_object_to_json_string_ext(arguments, JSON_C_TO_STRING_PLAIN);
        return *argument != NULL;
    }
    if (!object_has_only_argument(arguments, tool->argument_name)) {
        *message = "Tool arguments contain an unsupported field.";
        return false;
    }
    if (tool->argument_name == NULL) {
        *argument = NULL;
        return true;
    }
    if (!json_object_object_get_ex(arguments, tool->argument_name, &value) ||
        (json_object_get_type(value) != json_type_string)) {
        *message = "Tool requires one string argument.";
        return false;
    }
    *argument = json_object_get_string(value);
    if ((*argument == NULL) || (**argument == '\0') || (strlen(*argument) > 63U)) {
        *message = "Tool argument has an invalid length.";
        return false;
    }
    return true;
}

static bool run_tool(const tool_definition_t *tool,
                     const char *argument,
                     char *output,
                     size_t output_size,
                     const char **message)
{
    int result;

    if ((tool == NULL) || (tool->handler == NULL)) {
        *message = "Tool handler is unavailable.";
        return false;
    }
    output[0] = '\0';
    result = tool->handler(argument, output, output_size);
    if (result != 0) {
        *message = "Router tool reported an error.";
        return false;
    }
    if (output[0] == '\0') {
        *message = "Router tool returned an empty response.";
        return false;
    }
    return true;
}

static struct json_object *tool_response_from_error(struct json_object *id,
                                                     const char *code,
                                                     const char *message)
{
    struct json_object *error = tool_error_text(code, message);
    const char *text = json_object_to_json_string_ext(error, JSON_C_TO_STRING_PLAIN);
    struct json_object *response = new_text_result(id, text);
    json_object_put(error);
    return response;
}

static struct json_object *handle_tool_call(struct json_object *id, struct json_object *params)
{
    struct json_object *name_value = NULL;
    struct json_object *arguments = NULL;
    const tool_definition_t *tool;
    const char *argument = NULL;
    const char *message = NULL;
    char output[TOOL_OUTPUT_LIMIT];
    struct json_object *tool_response;
    struct json_tokener *tokenizer;

    if ((params == NULL) || (json_object_get_type(params) != json_type_object) ||
        !json_object_object_get_ex(params, "name", &name_value) ||
        (json_object_get_type(name_value) != json_type_string)) {
        return tool_response_from_error(id, "invalid_request", "tools/call requires a tool name.");
    }
    tool = find_tool(json_object_get_string(name_value));
    if (tool == NULL) return tool_response_from_error(id, "unknown_tool", "Tool is not allow-listed.");
    if (!json_object_object_get_ex(params, "arguments", &arguments)) arguments = json_object_new_object();
    else json_object_get(arguments);
    if (!read_tool_argument(tool, arguments, &argument, &message)) {
        json_object_put(arguments);
        return tool_response_from_error(id, "invalid_request", message);
    }
    if (!run_tool(tool, argument, output, sizeof(output), &message)) {
        json_object_put(arguments);
        return tool_response_from_error(id, "tool_failed", message);
    }
    json_object_put(arguments);
    tokenizer = json_tokener_new();
    tool_response = json_tokener_parse_ex(tokenizer, output, (int)strlen(output));
    if ((json_tokener_get_error(tokenizer) != json_tokener_success) ||
        (tool_response == NULL) || (json_object_get_type(tool_response) != json_type_object)) {
        json_tokener_free(tokenizer);
        if (tool_response != NULL) json_object_put(tool_response);
        return tool_response_from_error(id, "invalid_tool_response", "Router tool returned invalid JSON.");
    }
    json_tokener_free(tokenizer);
    message = json_object_to_json_string_ext(tool_response, JSON_C_TO_STRING_PLAIN);
    { struct json_object *response = new_text_result(id, message); json_object_put(tool_response); return response; }
}

static struct json_object *handle_initialize(struct json_object *id,
                                             struct json_object *params)
{
    struct json_object *response = json_object_new_object();
    struct json_object *result = json_object_new_object();
    struct json_object *server_info = json_object_new_object();
    struct json_object *capabilities = json_object_new_object();
    (void)params;
    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", id != NULL ? json_object_get(id) : json_object_new_null());
    json_object_object_add(result, "protocolVersion", json_object_new_string("2024-11-05"));
    json_object_object_add(server_info, "name", json_object_new_string("router-agent-c"));
    json_object_object_add(server_info, "version", json_object_new_string("0.1.0"));
    json_object_object_add(capabilities, "tools", json_object_new_object());
    json_object_object_add(result, "serverInfo", server_info);
    json_object_object_add(result, "capabilities", capabilities);
    json_object_object_add(response, "result", result);
    return response;
}

static struct json_object *new_input_schema(const tool_definition_t *tool)
{
    struct json_object *schema = json_object_new_object();
    struct json_object *properties = json_object_new_object();
    json_object_object_add(schema, "type", json_object_new_string("object"));
    if (tool->input_kind == TOOL_INPUT_NETWORK_PREVIEW) {
        static const char *const fields[] = {"interface", "proto", "ipaddr", "netmask", "gateway"};
        struct json_object *required = json_object_new_array();
        size_t index;
        for (index = 0U; index < (sizeof(fields) / sizeof(fields[0])); index++) {
            struct json_object *property = json_object_new_object();
            json_object_object_add(property, "type", json_object_new_string("string"));
            json_object_object_add(property, "maxLength", json_object_new_int(63));
            json_object_object_add(properties, fields[index], property);
            json_object_array_add(required, json_object_new_string(fields[index]));
        }
        json_object_object_add(schema, "required", required);
    } else if (tool->input_kind == TOOL_INPUT_NETWORK_APPLY) {
        struct json_object *token = json_object_new_object();
        struct json_object *confirmed = json_object_new_object();
        struct json_object *required = json_object_new_array();
        json_object_object_add(token, "type", json_object_new_string("string"));
        json_object_object_add(token, "minLength", json_object_new_int(64));
        json_object_object_add(token, "maxLength", json_object_new_int(64));
        json_object_object_add(confirmed, "type", json_object_new_string("boolean"));
        json_object_object_add(properties, "plan_token", token);
        json_object_object_add(properties, "confirmed", confirmed);
        json_object_array_add(required, json_object_new_string("plan_token"));
        json_object_array_add(required, json_object_new_string("confirmed"));
        json_object_object_add(schema, "required", required);
    } else if (tool->input_kind == TOOL_INPUT_NETWORK_HEALTH_CONFIRM) {
        struct json_object *token = json_object_new_object();
        struct json_object *required = json_object_new_array();
        json_object_object_add(token, "type", json_object_new_string("string"));
        json_object_object_add(token, "minLength", json_object_new_int(64));
        json_object_object_add(token, "maxLength", json_object_new_int(64));
        json_object_object_add(properties, "health_token", token);
        json_object_array_add(required, json_object_new_string("health_token"));
        json_object_object_add(schema, "required", required);
    } else if (tool->argument_name != NULL) {
        struct json_object *property = json_object_new_object();
        struct json_object *required = json_object_new_array();
        json_object_object_add(property, "type", json_object_new_string("string"));
        json_object_object_add(property, "maxLength", json_object_new_int(63));
        json_object_object_add(properties, tool->argument_name, property);
        json_object_array_add(required, json_object_new_string(tool->argument_name));
        json_object_object_add(schema, "required", required);
    }
    json_object_object_add(schema, "properties", properties);
    json_object_object_add(schema, "additionalProperties", json_object_new_boolean(false));
    return schema;
}

static struct json_object *handle_list_tools(struct json_object *id,
                                             struct json_object *params)
{
    struct json_object *response = json_object_new_object();
    struct json_object *result = json_object_new_object();
    struct json_object *list = json_object_new_array();
    size_t index;
    (void)params;
    for (index = 0U; index < TOOL_COUNT; index++) {
        struct json_object *item = json_object_new_object();
        json_object_object_add(item, "name", json_object_new_string(tools[index].name));
        json_object_object_add(item, "description", json_object_new_string(tools[index].description));
        json_object_object_add(item, "inputSchema", new_input_schema(&tools[index]));
        json_object_array_add(list, item);
    }
    json_object_object_add(response, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(response, "id", id != NULL ? json_object_get(id) : json_object_new_null());
    json_object_object_add(result, "tools", list);
    json_object_object_add(response, "result", result);
    return response;
}

static const method_definition_t methods[] = {
    {"initialize", handle_initialize},
    {"tools/list", handle_list_tools},
    {"tools/call", handle_tool_call},
    {"notifications/initialized", NULL},
};

static const method_definition_t *find_method(const char *name)
{
    size_t index;

    for (index = 0U; index < (sizeof(methods) / sizeof(methods[0])); index++) {
        if (strcmp(name, methods[index].name) == 0) return &methods[index];
    }
    return NULL;
}

static void handle_request(struct json_object *request)
{
    struct json_object *method_value = NULL;
    struct json_object *id = NULL;
    struct json_object *params = NULL;
    const char *method_name;
    const method_definition_t *method;
    struct json_object *response;

    if ((json_object_get_type(request) != json_type_object) ||
        !json_object_object_get_ex(request, "jsonrpc", &method_value) ||
        (json_object_get_type(method_value) != json_type_string) ||
        (strcmp(json_object_get_string(method_value), "2.0") != 0) ||
        !json_object_object_get_ex(request, "method", &method_value) ||
        (json_object_get_type(method_value) != json_type_string)) {
        response = new_error_response(NULL, -32600, "Invalid JSON-RPC request.");
        print_json(response); json_object_put(response); return;
    }
    (void)json_object_object_get_ex(request, "id", &id);
    (void)json_object_object_get_ex(request, "params", &params);
    method_name = json_object_get_string(method_value);
    method = find_method(method_name);
    if (method == NULL) response = new_error_response(id, -32601, "Method not found.");
    else if (method->handler == NULL) return;
    else response = method->handler(id, params);
    print_json(response);
    json_object_put(response);
}

int main(void)
{
    char *line = malloc(REQUEST_LIMIT + 2U);
    if (line == NULL) return 1;
    while (fgets(line, (int)(REQUEST_LIMIT + 2U), stdin) != NULL) {
        size_t length = strlen(line);
        struct json_object *request;
        struct json_tokener *tokenizer;
        if ((length == 0U) || (line[length - 1U] != '\n')) {
            struct json_object *response = new_error_response(NULL, -32600, "MCP request line is too large.");
            print_json(response); json_object_put(response); continue;
        }
        tokenizer = json_tokener_new();
        request = json_tokener_parse_ex(tokenizer, line, (int)length);
        if ((json_tokener_get_error(tokenizer) != json_tokener_success) || (request == NULL)) {
            struct json_object *response = new_error_response(NULL, -32700, "JSON parse error.");
            print_json(response); json_object_put(response);
        } else {
            handle_request(request);
            json_object_put(request);
        }
        json_tokener_free(tokenizer);
    }
    free(line);
    return 0;
}
