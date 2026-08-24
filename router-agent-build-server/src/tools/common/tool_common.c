#include "tool_common.h"

#include <stdio.h>
#include <string.h>

static int append_character(char *destination,
                            size_t destination_size,
                            size_t *position,
                            char value)
{
    if ((*position + 1U) >= destination_size) {
        return 0;
    }
    destination[*position] = value;
    *position += 1U;
    return 1;
}

void tool_set_error(char *code_destination,
                    size_t code_size,
                    char *message_destination,
                    size_t message_size,
                    const char *code,
                    const char *message)
{
    if ((code_destination != NULL) && (code_size > 0U)) {
        (void)snprintf(code_destination, code_size, "%s", code != NULL ? code : "internal_error");
    }
    if ((message_destination != NULL) && (message_size > 0U)) {
        (void)snprintf(message_destination,
                       message_size,
                       "%s",
                       message != NULL ? message : "Internal error");
    }
}

int tool_print_error(const char *code, const char *message)
{
    char escaped_code[(TOOL_ERROR_CODE_SIZE * 6U) + 1U];
    char escaped_message[(TOOL_ERROR_MESSAGE_SIZE * 6U) + 1U];

    if ((tool_json_escape(code != NULL ? code : "internal_error",
                          escaped_code,
                          sizeof(escaped_code)) != TOOL_RESULT_OK) ||
        (tool_json_escape(message != NULL ? message : "Internal error",
                          escaped_message,
                          sizeof(escaped_message)) != TOOL_RESULT_OK)) {
        (void)fputs("{\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"Unable to encode error\"}}\n",
                    stdout);
        return 1;
    }

    (void)printf("{\"status\":\"error\",\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}\n",
                 escaped_code,
                 escaped_message);
    return 1;
}

int tool_print_success_json(const char *data_json)
{
    if (data_json == NULL) {
        return tool_print_error("internal_error", "Success data is missing");
    }
    (void)printf("{\"status\":\"ok\",\"data\":%s}\n", data_json);
    return 0;
}

int tool_print_error_to_buffer(const char *code, const char *message, char *output, size_t output_size)
{
    char escaped_code[(TOOL_ERROR_CODE_SIZE * 6U) + 1U];
    char escaped_message[(TOOL_ERROR_MESSAGE_SIZE * 6U) + 1U];

    if ((tool_json_escape(code != NULL ? code : "internal_error",
                          escaped_code,
                          sizeof(escaped_code)) != TOOL_RESULT_OK) ||
        (tool_json_escape(message != NULL ? message : "Internal error",
                          escaped_message,
                          sizeof(escaped_message)) != TOOL_RESULT_OK)) {
        if ((output != NULL) && (output_size > 0U)) {
            (void)snprintf(output, output_size, "{\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"Unable to encode error\"}}\n");
        }
        return 1;
    }
    if ((output != NULL) && (output_size > 0U)) {
        (void)snprintf(output,
                       output_size,
                       "{\"status\":\"error\",\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}\n",
                       escaped_code,
                       escaped_message);
    }
    return 1;
}

int tool_print_success_json_to_buffer(const char *data_json, char *output, size_t output_size)
{
    if (data_json == NULL) {
        return tool_print_error_to_buffer("internal_error", "Success data is missing", output, output_size);
    }
    if ((output != NULL) && (output_size > 0U)) {
        (void)snprintf(output, output_size, "{\"status\":\"ok\",\"data\":%s}\n", data_json);
    }
    return 0;
}

tool_result_t tool_json_escape(const char *source,
                               char *destination,
                               size_t destination_size)
{
    size_t source_position = 0U;
    size_t destination_position = 0U;

    if ((source == NULL) || (destination == NULL) || (destination_size == 0U)) {
        return TOOL_RESULT_ERROR;
    }

    while (source[source_position] != '\0') {
        const unsigned char value = (unsigned char)source[source_position];
        if ((value == (unsigned char)'"') || (value == (unsigned char)'\\')) {
            if (!append_character(destination, destination_size, &destination_position, '\\') ||
                !append_character(destination,
                                  destination_size,
                                  &destination_position,
                                  (char)value)) {
                return TOOL_RESULT_ERROR;
            }
        } else if (value < 0x20U) {
            static const char hexadecimal[] = "0123456789abcdef";
            const char sequence[6] = {'\\', 'u', '0', '0',
                                      hexadecimal[(value >> 4U) & 0x0fU],
                                      hexadecimal[value & 0x0fU]};
            size_t index;
            for (index = 0U; index < sizeof(sequence); index++) {
                if (!append_character(destination,
                                      destination_size,
                                      &destination_position,
                                      sequence[index])) {
                    return TOOL_RESULT_ERROR;
                }
            }
        } else if (!append_character(destination,
                                     destination_size,
                                     &destination_position,
                                     (char)value)) {
            return TOOL_RESULT_ERROR;
        }
        source_position += 1U;
    }

    destination[destination_position] = '\0';
    return TOOL_RESULT_OK;
}

void tool_log_error(const char *tool_name, const char *message)
{
    (void)fprintf(stderr,
                  "%s: %s\n",
                  tool_name != NULL ? tool_name : "router-agent-tool",
                  message != NULL ? message : "unknown diagnostic");
}
