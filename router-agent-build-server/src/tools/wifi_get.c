#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"
#include <stdio.h>
#include <string.h>
#include "router_tool_api.h"
#ifndef ROUTER_AGENT_TEST_BACKEND
#include <uci.h>
#endif

typedef struct { const char *section_name; } tool_request_t;
typedef struct {
    char type[32], device[64], mode[32], network[64], ssid[VALIDATOR_SSID_SIZE];
    char encryption[32], disabled[16], channel[32], hwmode[32], country[16];
    char error_code[TOOL_ERROR_CODE_SIZE], error_message[TOOL_ERROR_MESSAGE_SIZE];
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
    tool_request_t request = {0}; tool_response_t response = {0}; tool_result_t result;
    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) result = validate_request(&request, &response);
    if (result == TOOL_RESULT_OK) result = execute_backend_operation(&request, &response);
    return print_json_response(&request, &response, result);
}
#endif

static int print_json_response_to_buffer(const tool_request_t *request, const tool_response_t *response, tool_result_t result, char *output, size_t output_size)
{
    char section[384], type[192], device[384], mode[192], network[384], ssid[256], encryption[192], disabled[96], channel[192], hwmode[192], country[96], data[3072]; int written;
    if (result != TOOL_RESULT_OK) return tool_print_error_to_buffer(response->error_code, response->error_message, output, output_size);
#define ESCAPE(field, output_buf) if (tool_json_escape(response->field, output_buf, sizeof(output_buf)) != TOOL_RESULT_OK) return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size)
    if (tool_json_escape(request->section_name, section, sizeof(section)) != TOOL_RESULT_OK) return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    ESCAPE(type, type); ESCAPE(device, device); ESCAPE(mode, mode); ESCAPE(network, network); ESCAPE(ssid, ssid); ESCAPE(encryption, encryption); ESCAPE(disabled, disabled); ESCAPE(channel, channel); ESCAPE(hwmode, hwmode); ESCAPE(country, country);
#undef ESCAPE
    written = snprintf(data, sizeof(data), "{\"section\":\"%s\",\"type\":\"%s\",\"device\":\"%s\",\"mode\":\"%s\",\"network\":\"%s\",\"ssid\":\"%s\",\"encryption\":\"%s\",\"disabled\":\"%s\",\"channel\":\"%s\",\"hwmode\":\"%s\",\"country\":\"%s\"}", section, type, device, mode, network, ssid, encryption, disabled, channel, hwmode, country);
    if ((written < 0) || ((size_t)written >= sizeof(data))) return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    return tool_print_success_json_to_buffer(data, output, output_size);
}

int router_tool_wifi_get(const char *argument, char *output, size_t output_size)
{
    tool_request_t request = {0}; tool_response_t response = {0}; tool_result_t result;
    char *argv[3]; int argc;
    argv[0] = "wifi_get";
    if ((argument != NULL) && (argument[0] != '\0')) { argc = 2; argv[1] = (char *)argument; argv[2] = NULL; } else { argc = 1; argv[1] = NULL; }
    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) result = validate_request(&request, &response);
    if (result == TOOL_RESULT_OK) result = execute_backend_operation(&request, &response);
    return print_json_response_to_buffer(&request, &response, result, output, output_size);
}

static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response)
{
    if (argc != 2) { set_response_error(response, "invalid_arguments", "Usage: wifi_get <section>"); return TOOL_RESULT_ERROR; }
    request->section_name = argv[1]; return TOOL_RESULT_OK;
}

static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response)
{
    if (!validator_uci_section(request->section_name)) { set_response_error(response, "invalid_section", "UCI wireless section name is invalid"); return TOOL_RESULT_ERROR; }
    return TOOL_RESULT_OK;
}

static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response)
{
#ifdef ROUTER_AGENT_TEST_BACKEND
    if (strcmp(request->section_name, "default_radio0") != 0) { set_response_error(response, "section_not_found", "Wireless section was not found"); return TOOL_RESULT_ERROR; }
    (void)copy_value(response->type, sizeof(response->type), "wifi-iface");
    (void)copy_value(response->device, sizeof(response->device), "radio0");
    (void)copy_value(response->mode, sizeof(response->mode), "ap");
    (void)copy_value(response->network, sizeof(response->network), "lan");
    (void)copy_value(response->ssid, sizeof(response->ssid), "Example WiFi");
    (void)copy_value(response->encryption, sizeof(response->encryption), "psk2");
    (void)copy_value(response->disabled, sizeof(response->disabled), "0");
    return TOOL_RESULT_OK;
#else
    struct uci_context *context = uci_alloc_context(); struct uci_package *package = NULL; struct uci_section *section; const char *value;
    if (context == NULL) { set_response_error(response, "backend_unavailable", "Unable to allocate UCI context"); return TOOL_RESULT_ERROR; }
    if (uci_load(context, "wireless", &package) != UCI_OK) { tool_log_error("wifi_get", "Unable to load UCI wireless package"); uci_free_context(context); set_response_error(response, "backend_unavailable", "Unable to load wireless configuration"); return TOOL_RESULT_ERROR; }
    section = uci_lookup_section(context, package, request->section_name);
    if ((section == NULL) || ((strcmp(section->type, "wifi-iface") != 0) && (strcmp(section->type, "wifi-device") != 0))) { uci_unload(context, package); uci_free_context(context); set_response_error(response, "section_not_found", "Wireless section was not found"); return TOOL_RESULT_ERROR; }
    if (copy_value(response->type, sizeof(response->type), section->type) != TOOL_RESULT_OK) { uci_unload(context, package); uci_free_context(context); set_response_error(response, "backend_value_too_long", "UCI section type is too long"); return TOOL_RESULT_ERROR; }
#define COPY_WIFI(field, option) do { value = uci_lookup_option_string(context, section, option); if ((value != NULL) && (copy_value(response->field, sizeof(response->field), value) != TOOL_RESULT_OK)) { uci_unload(context, package); uci_free_context(context); set_response_error(response, "backend_value_too_long", "UCI option exceeds the supported response size"); return TOOL_RESULT_ERROR; } } while (0)
    COPY_WIFI(device, "device"); COPY_WIFI(mode, "mode"); COPY_WIFI(network, "network");
    COPY_WIFI(ssid, "ssid"); COPY_WIFI(encryption, "encryption"); COPY_WIFI(disabled, "disabled");
    COPY_WIFI(channel, "channel"); COPY_WIFI(hwmode, "hwmode"); COPY_WIFI(country, "country");
#undef COPY_WIFI
    uci_unload(context, package); uci_free_context(context); return TOOL_RESULT_OK;
#endif
}

#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result)
{
    char section[384], type[192], device[384], mode[192], network[384], ssid[256], encryption[192], disabled[96], channel[192], hwmode[192], country[96], data[3072]; int written;
    if (result != TOOL_RESULT_OK) return tool_print_error(response->error_code, response->error_message);
#define ESCAPE(field, output) if (tool_json_escape(response->field, output, sizeof(output)) != TOOL_RESULT_OK) return tool_print_error("internal_error", "Unable to encode response")
    if (tool_json_escape(request->section_name, section, sizeof(section)) != TOOL_RESULT_OK) return tool_print_error("internal_error", "Unable to encode response");
    ESCAPE(type, type); ESCAPE(device, device); ESCAPE(mode, mode); ESCAPE(network, network); ESCAPE(ssid, ssid); ESCAPE(encryption, encryption); ESCAPE(disabled, disabled); ESCAPE(channel, channel); ESCAPE(hwmode, hwmode); ESCAPE(country, country);
#undef ESCAPE
    written = snprintf(data, sizeof(data), "{\"section\":\"%s\",\"type\":\"%s\",\"device\":\"%s\",\"mode\":\"%s\",\"network\":\"%s\",\"ssid\":\"%s\",\"encryption\":\"%s\",\"disabled\":\"%s\",\"channel\":\"%s\",\"hwmode\":\"%s\",\"country\":\"%s\"}", section, type, device, mode, network, ssid, encryption, disabled, channel, hwmode, country);
    if ((written < 0) || ((size_t)written >= sizeof(data))) return tool_print_error("internal_error", "Unable to encode response");
    return tool_print_success_json(data);
}
#endif

static void set_response_error(tool_response_t *response, const char *code, const char *message)
{ tool_set_error(response->error_code, sizeof(response->error_code), response->error_message, sizeof(response->error_message), code, message); }
static tool_result_t copy_value(char *destination, size_t size, const char *value)
{ int written = snprintf(destination, size, "%s", value); return ((written >= 0) && ((size_t)written < size)) ? TOOL_RESULT_OK : TOOL_RESULT_ERROR; }
