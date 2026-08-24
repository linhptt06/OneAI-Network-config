#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"
#include "router_tool_api.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

#ifndef PROC_NET_DEV_PATH
#define PROC_NET_DEV_PATH "/proc/net/dev"
#endif

typedef struct {
    const char *interface_name;
} tool_request_t;

typedef struct {
    unsigned long long rx_bytes;
    unsigned long long rx_packets;
    unsigned long long rx_errors;
    unsigned long long rx_dropped;
    unsigned long long tx_bytes;
    unsigned long long tx_packets;
    unsigned long long tx_errors;
    unsigned long long tx_dropped;
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
} tool_response_t;

static tool_result_t parse_arguments(int argc,
                                     char **argv,
                                     tool_request_t *request,
                                     tool_response_t *response);
static tool_result_t validate_request(const tool_request_t *request,
                                      tool_response_t *response);
static tool_result_t execute_backend_operation(const tool_request_t *request,
                                               tool_response_t *response);
#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request,
                               const tool_response_t *response,
                               tool_result_t result);
#endif
static void set_response_error(tool_response_t *response,
                               const char *code,
                               const char *message);

 #ifndef ROUTER_AGENT_EMBEDDED
int main(int argc, char **argv)
{
    tool_request_t request = {0};
    tool_response_t response = {0};
    tool_result_t result;

    result = parse_arguments(argc, argv, &request, &response);
    if (result == TOOL_RESULT_OK) {
        result = validate_request(&request, &response);
    }
    if (result == TOOL_RESULT_OK) {
        result = execute_backend_operation(&request, &response);
    }
    return print_json_response(&request, &response, result);
}
#endif

static int print_json_response_to_buffer(const tool_request_t *request,
                               const tool_response_t *response,
                               tool_result_t result,
                               char *output,
                               size_t output_size)
{
    char escaped_interface[(VALIDATOR_INTERFACE_SIZE * 6U) + 1U];
    char data_json[512];
    int written;

    if (result != TOOL_RESULT_OK) {
        return tool_print_error_to_buffer(response->error_code, response->error_message, output, output_size);
    }
    if (tool_json_escape(request->interface_name,
                         escaped_interface,
                         sizeof(escaped_interface)) != TOOL_RESULT_OK) {
        return tool_print_error_to_buffer("internal_error", "Unable to encode interface name", output, output_size);
    }
    written = snprintf(data_json,
                       sizeof(data_json),
                       "{\"interface\":\"%s\",\"rx_bytes\":%llu,\"rx_packets\":%llu,\"rx_errors\":%llu,\"rx_dropped\":%llu,\"tx_bytes\":%llu,\"tx_packets\":%llu,\"tx_errors\":%llu,\"tx_dropped\":%llu}",
                       escaped_interface,
                       response->rx_bytes,
                       response->rx_packets,
                       response->rx_errors,
                       response->rx_dropped,
                       response->tx_bytes,
                       response->tx_packets,
                       response->tx_errors,
                       response->tx_dropped);
    if ((written < 0) || ((size_t)written >= sizeof(data_json))) {
        return tool_print_error_to_buffer("internal_error", "Unable to encode response", output, output_size);
    }
    return tool_print_success_json_to_buffer(data_json, output, output_size);
}

int router_tool_traffic_stats(const char *argument, char *output, size_t output_size)
{
    tool_request_t request = {0};
    tool_response_t response = {0};
    tool_result_t result;
    char *argv[3];
    int argc;

    argv[0] = "traffic_stats";
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

static tool_result_t parse_arguments(int argc,
                                     char **argv,
                                     tool_request_t *request,
                                     tool_response_t *response)
{
    if ((request == NULL) || (response == NULL)) {
        return TOOL_RESULT_ERROR;
    }
    if (argc != 2) {
        set_response_error(response,
                           "invalid_arguments",
                           "Usage: traffic_stats <interface>");
        return TOOL_RESULT_ERROR;
    }
    request->interface_name = argv[1];
    return TOOL_RESULT_OK;
}

static tool_result_t validate_request(const tool_request_t *request,
                                      tool_response_t *response)
{
    if ((request == NULL) || !validator_interface(request->interface_name)) {
        set_response_error(response,
                           "invalid_interface",
                           "Interface name is invalid");
        return TOOL_RESULT_ERROR;
    }
    return TOOL_RESULT_OK;
}

static tool_result_t execute_backend_operation(const tool_request_t *request,
                                               tool_response_t *response)
{
    FILE *stream;
    char line[512];

    stream = fopen(PROC_NET_DEV_PATH, "r");
    if (stream == NULL) {
        tool_log_error("traffic_stats", strerror(errno));
        set_response_error(response,
                           "backend_unavailable",
                           "Unable to read network statistics");
        return TOOL_RESULT_ERROR;
    }

    while (fgets(line, sizeof(line), stream) != NULL) {
        char interface_name[VALIDATOR_INTERFACE_SIZE];
        unsigned long long ignored[8];
        int fields;

        fields = sscanf(line,
                        " %15[^:]: %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                        interface_name,
                        &response->rx_bytes,
                        &response->rx_packets,
                        &response->rx_errors,
                        &response->rx_dropped,
                        &ignored[0], &ignored[1], &ignored[2], &ignored[3],
                        &response->tx_bytes,
                        &response->tx_packets,
                        &response->tx_errors,
                        &response->tx_dropped,
                        &ignored[4], &ignored[5], &ignored[6], &ignored[7]);
        if ((fields == 17) && (strcmp(interface_name, request->interface_name) == 0)) {
            (void)fclose(stream);
            return TOOL_RESULT_OK;
        }
    }

    if (ferror(stream) != 0) {
        tool_log_error("traffic_stats", "Error while reading /proc/net/dev");
        (void)fclose(stream);
        set_response_error(response,
                           "backend_read_failed",
                           "Unable to read complete network statistics");
        return TOOL_RESULT_ERROR;
    }
    (void)fclose(stream);
    set_response_error(response,
                       "interface_not_found",
                       "Interface was not found");
    return TOOL_RESULT_ERROR;
}

#ifndef ROUTER_AGENT_EMBEDDED
static int print_json_response(const tool_request_t *request,
                               const tool_response_t *response,
                               tool_result_t result)
{
    char escaped_interface[(VALIDATOR_INTERFACE_SIZE * 6U) + 1U];
    char data_json[512];
    int written;

    if (result != TOOL_RESULT_OK) {
        return tool_print_error(response->error_code, response->error_message);
    }
    if (tool_json_escape(request->interface_name,
                         escaped_interface,
                         sizeof(escaped_interface)) != TOOL_RESULT_OK) {
        return tool_print_error("internal_error", "Unable to encode interface name");
    }
    written = snprintf(data_json,
                       sizeof(data_json),
                       "{\"interface\":\"%s\",\"rx_bytes\":%llu,\"rx_packets\":%llu,\"rx_errors\":%llu,\"rx_dropped\":%llu,\"tx_bytes\":%llu,\"tx_packets\":%llu,\"tx_errors\":%llu,\"tx_dropped\":%llu}",
                       escaped_interface,
                       response->rx_bytes,
                       response->rx_packets,
                       response->rx_errors,
                       response->rx_dropped,
                       response->tx_bytes,
                       response->tx_packets,
                       response->tx_errors,
                       response->tx_dropped);
    if ((written < 0) || ((size_t)written >= sizeof(data_json))) {
        return tool_print_error("internal_error", "Unable to encode response");
    }
    return tool_print_success_json(data_json);
}
#endif

static void set_response_error(tool_response_t *response,
                               const char *code,
                               const char *message)
{
    tool_set_error(response->error_code,
                   sizeof(response->error_code),
                   response->error_message,
                   sizeof(response->error_message),
                   code,
                   message);
}
