#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "router_tool_api.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#ifndef ROUTER_AGENT_TEST_BACKEND
#include <uci.h>
#endif

#define RESPONSE_SIZE 8192U
#define ESCAPED_VALUE_SIZE 384U

#ifndef ROUTER_AGENT_TEST_BACKEND
static bool append_text(char *buffer, size_t size, size_t *position,
                        const char *text)
{
    const size_t length = strlen(text);

    if ((length >= size) || (*position > (size - length - 1U))) return false;
    (void)memcpy(buffer + *position, text, length);
    *position += length;
    buffer[*position] = '\0';
    return true;
}

static bool append_field(char *buffer, size_t size, size_t *position,
                         bool *first, const char *name, const char *value)
{
    char escaped[ESCAPED_VALUE_SIZE];

    if (value == NULL) return true;
    if (tool_json_escape(value, escaped, sizeof(escaped)) != TOOL_RESULT_OK) {
        return false;
    }
    if (!*first && !append_text(buffer, size, position, ",")) return false;
    if (!append_text(buffer, size, position, "\"") ||
        !append_text(buffer, size, position, name) ||
        !append_text(buffer, size, position, "\":\"") ||
        !append_text(buffer, size, position, escaped) ||
        !append_text(buffer, size, position, "\"")) {
        return false;
    }
    *first = false;
    return true;
}
#endif

#ifdef ROUTER_AGENT_TEST_BACKEND
static int run_test_backend(void)
{
    return tool_print_success_json(
        "[{\"interface\":\"lan\",\"proto\":\"static\","
        "\"device\":\"br-lan\",\"ipaddr\":\"192.168.1.1\","
        "\"gateway\":\"192.168.1.254\"},"
        "{\"interface\":\"wan\",\"proto\":\"dhcp\","
        "\"device\":\"eth0\"}]");
}
#else
#ifndef ROUTER_AGENT_EMBEDDED
static int run_uci_backend(void)
{
    struct uci_context *context = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_element *element;
    char data[RESPONSE_SIZE] = "";
    size_t position = 0U;
    bool first_section = true;

    if (context == NULL) {
        return tool_print_error("backend_unavailable", "Unable to allocate UCI context");
    }
    if (uci_load(context, "network", &package) != UCI_OK) {
        tool_log_error("network_list", "Unable to load UCI network package");
        uci_free_context(context);
        return tool_print_error("backend_unavailable", "Unable to load network configuration");
    }

    if (!append_text(data, sizeof(data), &position, "[")) goto too_large;
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        const char *device;
        bool first_field = true;

        if (strcmp(section->type, "interface") != 0) continue;
        if ((!first_section && !append_text(data, sizeof(data), &position, ",")) ||
            !append_text(data, sizeof(data), &position, "{") ||
            !append_field(data, sizeof(data), &position, &first_field,
                          "interface", section->e.name) ||
            !append_field(data, sizeof(data), &position, &first_field,
                          "proto", uci_lookup_option_string(context, section, "proto"))) {
            goto too_large;
        }
        device = uci_lookup_option_string(context, section, "device");
        if (device == NULL) device = uci_lookup_option_string(context, section, "ifname");
        if (!append_field(data, sizeof(data), &position, &first_field, "device", device) ||
            !append_field(data, sizeof(data), &position, &first_field,
                          "ipaddr", uci_lookup_option_string(context, section, "ipaddr")) ||
            !append_field(data, sizeof(data), &position, &first_field,
                          "gateway", uci_lookup_option_string(context, section, "gateway")) ||
            !append_text(data, sizeof(data), &position, "}")) {
            goto too_large;
        }
        first_section = false;
    }
    if (!append_text(data, sizeof(data), &position, "]")) goto too_large;

    uci_unload(context, package);
    uci_free_context(context);
    return tool_print_success_json(data);

too_large:
    uci_unload(context, package);
    uci_free_context(context);
    return tool_print_error("response_too_large", "Network configuration exceeds the response limit");
}
#endif
#endif

#ifndef ROUTER_AGENT_EMBEDDED
int main(int argc, char **argv)
{
    (void)argv;
    if (argc != 1) return tool_print_error("invalid_arguments", "Usage: network_list");
#ifdef ROUTER_AGENT_TEST_BACKEND
    return run_test_backend();
#else
    return run_uci_backend();
#endif
}
#endif

int router_tool_network_list(const char *argument, char *output, size_t output_size)
{
    (void)argument;
#ifdef ROUTER_AGENT_TEST_BACKEND
    return run_test_backend() ? tool_print_error_to_buffer("internal_error", "backend failed", output, output_size) : tool_print_success_json_to_buffer("[]", output, output_size);
#else
    {
#ifndef ROUTER_AGENT_TEST_BACKEND
        struct uci_context *context = uci_alloc_context();
        struct uci_package *package = NULL;
        struct uci_element *element;
        char data[RESPONSE_SIZE] = "";
        size_t position = 0U;
        bool first_section = true;

        if (context == NULL) {
            return tool_print_error_to_buffer("backend_unavailable", "Unable to allocate UCI context", output, output_size);
        }
        if (uci_load(context, "network", &package) != UCI_OK) {
            tool_log_error("network_list", "Unable to load UCI network package");
            uci_free_context(context);
            return tool_print_error_to_buffer("backend_unavailable", "Unable to load network configuration", output, output_size);
        }

        if (!append_text(data, sizeof(data), &position, "[")) goto too_large;
        uci_foreach_element(&package->sections, element) {
            struct uci_section *section = uci_to_section(element);
            const char *device;
            bool first_field = true;

            if (strcmp(section->type, "interface") != 0) continue;
            if ((!first_section && !append_text(data, sizeof(data), &position, ",")) ||
                !append_text(data, sizeof(data), &position, "{") ||
                !append_field(data, sizeof(data), &position, &first_field,
                              "interface", section->e.name) ||
                !append_field(data, sizeof(data), &position, &first_field,
                              "proto", uci_lookup_option_string(context, section, "proto"))) {
                goto too_large;
            }
            device = uci_lookup_option_string(context, section, "device");
            if (device == NULL) device = uci_lookup_option_string(context, section, "ifname");
            if (!append_field(data, sizeof(data), &position, &first_field, "device", device) ||
                !append_field(data, sizeof(data), &position, &first_field,
                              "ipaddr", uci_lookup_option_string(context, section, "ipaddr")) ||
                !append_field(data, sizeof(data), &position, &first_field,
                              "gateway", uci_lookup_option_string(context, section, "gateway")) ||
                !append_text(data, sizeof(data), &position, "}")) {
                goto too_large;
            }
            first_section = false;
        }
        if (!append_text(data, sizeof(data), &position, "]")) goto too_large;

        uci_unload(context, package);
        uci_free_context(context);
        return tool_print_success_json_to_buffer(data, output, output_size);

    too_large:
        uci_unload(context, package);
        uci_free_context(context);
        return tool_print_error_to_buffer("response_too_large", "Network configuration exceeds the response limit", output, output_size);
#endif
    }
#endif
}
