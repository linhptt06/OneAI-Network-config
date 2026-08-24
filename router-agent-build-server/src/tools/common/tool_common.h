#ifndef ROUTER_AGENT_TOOL_COMMON_H
#define ROUTER_AGENT_TOOL_COMMON_H

#include <stddef.h>

#define TOOL_ERROR_CODE_SIZE 48U
#define TOOL_ERROR_MESSAGE_SIZE 256U

typedef enum {
    TOOL_RESULT_OK = 0,
    TOOL_RESULT_ERROR = 1
} tool_result_t;

void tool_set_error(char *code_destination,
                    size_t code_size,
                    char *message_destination,
                    size_t message_size,
                    const char *code,
                    const char *message);

int tool_print_error(const char *code, const char *message);
int tool_print_success_json(const char *data_json);

int tool_print_error_to_buffer(const char *code, const char *message, char *output, size_t output_size);
int tool_print_success_json_to_buffer(const char *data_json, char *output, size_t output_size);

tool_result_t tool_json_escape(const char *source,
                               char *destination,
                               size_t destination_size);

void tool_log_error(const char *tool_name, const char *message);

#endif
