#define _POSIX_C_SOURCE 200809L
#include "common/tool_common.h"
#include "common/validator.h"

#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>
#ifndef ROUTER_AGENT_TEST_BACKEND
#include <libubox/blobmsg_json.h>
#include <libubus.h>
#endif

#ifndef PROBE_ROOT
#define PROBE_ROOT ""
#endif

#define PROBE_JSON_SIZE 131072U
#define PROBE_FILE_SIZE 1048576U
#define PROBE_PATH_SIZE 256U

typedef struct {
    int argument_count;
} tool_request_t;

typedef struct {
    char data_json[PROBE_JSON_SIZE];
    size_t data_length;
    char error_code[TOOL_ERROR_CODE_SIZE];
    char error_message[TOOL_ERROR_MESSAGE_SIZE];
} tool_response_t;

typedef struct {
    const char *name;
    const char *const *paths;
    size_t path_count;
} library_spec_t;

static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response);
static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response);
static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response);
static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result);
static void set_response_error(tool_response_t *response, const char *code, const char *message);
static bool append_text(tool_response_t *response, const char *text);
static bool append_json_string(tool_response_t *response, const char *text);
static bool append_boolean(tool_response_t *response, bool value);
static bool fixed_path(char *destination, size_t size, const char *suffix);
static bool read_fixed_file(const char *suffix, char *destination, size_t size);
static bool fixed_exists(const char *suffix);
static bool fixed_executable(const char *suffix);
static bool append_system_info(tool_response_t *response);
static bool append_libraries(tool_response_t *response);
static bool append_library(tool_response_t *response, const library_spec_t *specification);
static bool append_elf_metadata(tool_response_t *response, const char *path);
static bool append_uci_files(tool_response_t *response);
static bool append_ubus_objects(tool_response_t *response);
static bool append_services(tool_response_t *response);
static bool process_named(const char *expected_name);
#ifndef ROUTER_AGENT_TEST_BACKEND
static void receive_ubus_object(struct ubus_context *context, struct ubus_object_data *object, void *private_data);
#endif

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

static tool_result_t parse_arguments(int argc, char **argv, tool_request_t *request, tool_response_t *response)
{
    (void)argv;
    request->argument_count = argc;
    if (argc != 1) {
        set_response_error(response, "invalid_arguments", "Usage: runtime_probe");
        return TOOL_RESULT_ERROR;
    }
    return TOOL_RESULT_OK;
}

static tool_result_t validate_request(const tool_request_t *request, tool_response_t *response)
{
    if (!validator_argument_count(request->argument_count, 1)) {
        set_response_error(response, "invalid_arguments", "runtime_probe accepts no arguments");
        return TOOL_RESULT_ERROR;
    }
    return TOOL_RESULT_OK;
}

static tool_result_t execute_backend_operation(const tool_request_t *request, tool_response_t *response)
{
    (void)request;
    if (!append_text(response, "{") ||
        !append_system_info(response) ||
        !append_text(response, ",\"libraries\":") || !append_libraries(response) ||
        !append_text(response, ",\"uci_configuration\":") || !append_uci_files(response) ||
        !append_text(response, ",\"ubus\":") || !append_ubus_objects(response) ||
        !append_text(response, ",\"service_backends\":") || !append_services(response) ||
        !append_text(response, "}")) {
        set_response_error(response, "probe_output_too_large", "Capability report exceeds the output limit");
        return TOOL_RESULT_ERROR;
    }
    return TOOL_RESULT_OK;
}

static int print_json_response(const tool_request_t *request, const tool_response_t *response, tool_result_t result)
{
    (void)request;
    if (result != TOOL_RESULT_OK) return tool_print_error(response->error_code, response->error_message);
    return tool_print_success_json(response->data_json);
}

static void set_response_error(tool_response_t *response, const char *code, const char *message)
{
    tool_set_error(response->error_code, sizeof(response->error_code), response->error_message, sizeof(response->error_message), code, message);
}

static bool append_text(tool_response_t *response, const char *text)
{
    size_t length = strlen(text);
    if ((response->data_length + length + 1U) > sizeof(response->data_json)) return false;
    (void)memcpy(response->data_json + response->data_length, text, length + 1U);
    response->data_length += length;
    return true;
}

static bool append_json_string(tool_response_t *response, const char *text)
{
    char *escaped;
    size_t escaped_size;
    bool result;
    if (strlen(text) > PROBE_FILE_SIZE) return false;
    escaped_size = (strlen(text) * 6U) + 1U;
    escaped = malloc(escaped_size);
    if (escaped == NULL) return false;
    if (tool_json_escape(text, escaped, escaped_size) != TOOL_RESULT_OK) { free(escaped); return false; }
    result = append_text(response, "\"") && append_text(response, escaped) && append_text(response, "\"");
    free(escaped);
    return result;
}

static bool append_boolean(tool_response_t *response, bool value)
{
    return append_text(response, value ? "true" : "false");
}

static bool fixed_path(char *destination, size_t size, const char *suffix)
{
    int written;
    if ((suffix == NULL) || (suffix[0] != '/')) return false;
    written = snprintf(destination, size, "%s%s", PROBE_ROOT, suffix);
    return (written >= 0) && ((size_t)written < size);
}

static bool read_fixed_file(const char *suffix, char *destination, size_t size)
{
    char path[PROBE_PATH_SIZE];
    int descriptor;
    ssize_t count;
    size_t used = 0U;
    if (!fixed_path(path, sizeof(path), suffix) || (size < 2U)) return false;
    descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return false;
    while ((used + 1U) < size) {
        count = read(descriptor, destination + used, size - used - 1U);
        if (count < 0) { (void)close(descriptor); return false; }
        if (count == 0) break;
        used += (size_t)count;
    }
    (void)close(descriptor);
    destination[used] = '\0';
    return true;
}

static bool fixed_exists(const char *suffix)
{
    char path[PROBE_PATH_SIZE];
    struct stat status;
    return fixed_path(path, sizeof(path), suffix) && (lstat(path, &status) == 0);
}

static bool fixed_executable(const char *suffix)
{
    char path[PROBE_PATH_SIZE];
    return fixed_path(path, sizeof(path), suffix) && (access(path, X_OK) == 0);
}

static bool append_system_info(tool_response_t *response)
{
    char release[8192] = "";
    char loader_path[PROBE_PATH_SIZE];
    struct utsname system_name;
    bool release_present = read_fixed_file("/etc/openwrt_release", release, sizeof(release));
    bool loader_present = fixed_exists("/lib/ld-musl-aarch64.so.1");
    (void)fixed_path(loader_path, sizeof(loader_path), "/lib/ld-musl-aarch64.so.1");
    if (uname(&system_name) != 0) (void)memset(&system_name, 0, sizeof(system_name));
    return append_text(response, "\"system\":{\"openwrt_release_present\":") && append_boolean(response, release_present) &&
        append_text(response, ",\"openwrt_release\":") && append_json_string(response, release) &&
        append_text(response, ",\"kernel_release\":") && append_json_string(response, system_name.release) &&
        append_text(response, ",\"machine\":") && append_json_string(response, system_name.machine) &&
        append_text(response, ",\"musl_loader\":{\"path\":") && append_json_string(response, loader_path) &&
        append_text(response, ",\"present\":") && append_boolean(response, loader_present) && append_text(response, "}}");
}

static bool append_libraries(tool_response_t *response)
{
    static const char *const uci_paths[] = {"/lib/libuci.so", "/usr/lib/libuci.so"};
    static const char *const ubus_paths[] = {"/lib/libubus.so.20210630", "/lib/libubus.so", "/usr/lib/libubus.so"};
    static const char *const ubox_paths[] = {"/lib/libubox.so.20210516", "/lib/libubox.so", "/usr/lib/libubox.so"};
    static const char *const blob_paths[] = {"/lib/libblobmsg_json.so.20210516", "/lib/libblobmsg_json.so", "/usr/lib/libblobmsg_json.so"};
    static const library_spec_t libraries[] = {
        {"libuci", uci_paths, sizeof(uci_paths) / sizeof(uci_paths[0])},
        {"libubus", ubus_paths, sizeof(ubus_paths) / sizeof(ubus_paths[0])},
        {"libubox", ubox_paths, sizeof(ubox_paths) / sizeof(ubox_paths[0])},
        {"libblobmsg_json", blob_paths, sizeof(blob_paths) / sizeof(blob_paths[0])}
    };
    size_t index;
    if (!append_text(response, "[")) return false;
    for (index = 0U; index < (sizeof(libraries) / sizeof(libraries[0])); index++) {
        if ((index > 0U) && !append_text(response, ",")) return false;
        if (!append_library(response, &libraries[index])) return false;
    }
    return append_text(response, "]");
}

static bool append_library(tool_response_t *response, const library_spec_t *specification)
{
    size_t index;
    char selected[PROBE_PATH_SIZE] = "";
    for (index = 0U; index < specification->path_count; index++) {
        if (fixed_exists(specification->paths[index])) {
            if (!fixed_path(selected, sizeof(selected), specification->paths[index])) return false;
            break;
        }
    }
    if (!append_text(response, "{\"name\":") || !append_json_string(response, specification->name) ||
        !append_text(response, ",\"present\":") || !append_boolean(response, selected[0] != '\0') ||
        !append_text(response, ",\"path\":") || !append_json_string(response, selected) ||
        !append_text(response, ",\"elf\":")) return false;
    if (selected[0] == '\0') {
        if (!append_text(response, "null")) return false;
    } else if (!append_elf_metadata(response, selected)) return false;
    return append_text(response, "}");
}

static bool append_elf_metadata(tool_response_t *response, const char *path)
{
    int descriptor;
    struct stat status;
    unsigned char *buffer = NULL;
    size_t used = 0U;
    ssize_t count;
    const Elf64_Ehdr *header;
    const Elf64_Phdr *programs;
    const Elf64_Dyn *dynamic = NULL;
    size_t dynamic_count = 0U;
    Elf64_Addr string_address = 0U;
    size_t string_size = 0U;
    size_t string_offset = 0U;
    size_t soname_offset = 0U;
    size_t index;
    bool first = true;
    descriptor = open(path, O_RDONLY | O_CLOEXEC);
    if ((descriptor < 0) || (fstat(descriptor, &status) != 0) || (status.st_size <= 0) || ((uintmax_t)status.st_size > PROBE_FILE_SIZE)) {
        if (descriptor >= 0) (void)close(descriptor);
        return append_text(response, "{\"valid\":false,\"soname\":\"\",\"needed\":[]}");
    }
    buffer = malloc((size_t)status.st_size);
    if (buffer == NULL) { (void)close(descriptor); return false; }
    while (used < (size_t)status.st_size) {
        count = read(descriptor, buffer + used, (size_t)status.st_size - used);
        if (count <= 0) break;
        used += (size_t)count;
    }
    (void)close(descriptor);
    if ((used < sizeof(Elf64_Ehdr)) || (memcmp(buffer, ELFMAG, SELFMAG) != 0) ||
        (buffer[EI_CLASS] != ELFCLASS64) || (buffer[EI_DATA] != ELFDATA2LSB)) goto invalid;
    header = (const Elf64_Ehdr *)buffer;
    if ((header->e_phentsize != sizeof(Elf64_Phdr)) ||
        (header->e_phoff > used) || ((size_t)header->e_phnum > ((used - (size_t)header->e_phoff) / sizeof(Elf64_Phdr)))) goto invalid;
    programs = (const Elf64_Phdr *)(buffer + header->e_phoff);
    for (index = 0U; index < header->e_phnum; index++) {
        if ((programs[index].p_type == PT_DYNAMIC) && (programs[index].p_offset <= used) &&
            (programs[index].p_filesz <= (used - (size_t)programs[index].p_offset))) {
            dynamic = (const Elf64_Dyn *)(buffer + programs[index].p_offset);
            dynamic_count = (size_t)programs[index].p_filesz / sizeof(Elf64_Dyn);
        }
    }
    if (dynamic == NULL) goto invalid;
    for (index = 0U; index < dynamic_count; index++) {
        if (dynamic[index].d_tag == DT_STRTAB) string_address = dynamic[index].d_un.d_ptr;
        else if (dynamic[index].d_tag == DT_STRSZ) string_size = (size_t)dynamic[index].d_un.d_val;
        else if (dynamic[index].d_tag == DT_SONAME) soname_offset = (size_t)dynamic[index].d_un.d_val;
    }
    for (index = 0U; index < header->e_phnum; index++) {
        if ((programs[index].p_type == PT_LOAD) && (string_address >= programs[index].p_vaddr) &&
            ((string_address - programs[index].p_vaddr) < programs[index].p_filesz)) {
            string_offset = (size_t)programs[index].p_offset + (size_t)(string_address - programs[index].p_vaddr);
            break;
        }
    }
    if ((string_offset >= used) || (string_size > (used - string_offset)) || (soname_offset >= string_size)) goto invalid;
    if (memchr(buffer + string_offset + soname_offset, '\0', string_size - soname_offset) == NULL) goto invalid;
    if (!append_text(response, "{\"valid\":true,\"soname\":") ||
        !append_json_string(response, (const char *)(buffer + string_offset + soname_offset)) ||
        !append_text(response, ",\"needed\":[")) { free(buffer); return false; }
    for (index = 0U; index < dynamic_count; index++) {
        size_t needed_offset;
        if (dynamic[index].d_tag != DT_NEEDED) continue;
        needed_offset = (size_t)dynamic[index].d_un.d_val;
        if (needed_offset >= string_size) goto invalid_after_output;
        if (memchr(buffer + string_offset + needed_offset, '\0', string_size - needed_offset) == NULL) goto invalid_after_output;
        if (!first && !append_text(response, ",")) { free(buffer); return false; }
        if (!append_json_string(response, (const char *)(buffer + string_offset + needed_offset))) { free(buffer); return false; }
        first = false;
    }
    free(buffer);
    return append_text(response, "]}");
invalid_after_output:
    free(buffer);
    return false;
invalid:
    free(buffer);
    return append_text(response, "{\"valid\":false,\"soname\":\"\",\"needed\":[]}");
}

static bool append_uci_files(tool_response_t *response)
{
    static const char *const names[] = {"network", "wireless", "dhcp"};
    static const char *const paths[] = {"/etc/config/network", "/etc/config/wireless", "/etc/config/dhcp"};
    size_t index;
    if (!append_text(response, "[")) return false;
    for (index = 0U; index < (sizeof(names) / sizeof(names[0])); index++) {
        if (((index > 0U) && !append_text(response, ",")) || !append_text(response, "{\"name\":") ||
            !append_json_string(response, names[index]) || !append_text(response, ",\"path\":") ||
            !append_json_string(response, paths[index]) || !append_text(response, ",\"present\":") ||
            !append_boolean(response, fixed_exists(paths[index])) || !append_text(response, "}")) return false;
    }
    return append_text(response, "]");
}

static bool append_ubus_objects(tool_response_t *response)
{
#ifdef ROUTER_AGENT_TEST_BACKEND
    return append_text(response, "{\"connected\":true,\"objects\":[{\"name\":\"network\",\"methods\":{\"reload\":{}}},{\"name\":\"network.wireless\",\"methods\":{\"status\":{}}}]}");
#else
    struct ubus_context *context = ubus_connect(NULL);
    int status;
    if (!append_text(response, "{\"connected\":")) return false;
    if (context == NULL) return append_text(response, "false,\"objects\":[]}");
    if (!append_text(response, "true,\"objects\":[")) { ubus_free(context); return false; }
    status = ubus_lookup(context, NULL, receive_ubus_object, response);
    ubus_free(context);
    if (status != 0) return false;
    return append_text(response, "]}");
#endif
}

#ifndef ROUTER_AGENT_TEST_BACKEND
static void receive_ubus_object(struct ubus_context *context, struct ubus_object_data *object, void *private_data)
{
    tool_response_t *response = (tool_response_t *)private_data;
    char *methods;
    bool relevant;
    (void)context;
    if ((response == NULL) || (object == NULL) || (object->path == NULL)) return;
    relevant = (strncmp(object->path, "network", 7U) == 0) || (strstr(object->path, "wireless") != NULL);
    if (!relevant) return;
    methods = object->signature != NULL ? blobmsg_format_json(object->signature, true) : NULL;
    if ((response->data_length > 0U) && (response->data_json[response->data_length - 1U] != '[')) (void)append_text(response, ",");
    (void)append_text(response, "{\"name\":");
    (void)append_json_string(response, object->path);
    (void)append_text(response, ",\"methods\":");
    (void)append_text(response, methods != NULL ? methods : "{}");
    (void)append_text(response, "}");
    free(methods);
}
#endif

static bool append_services(tool_response_t *response)
{
    static const char *const names[] = {"network_init", "wifi_command", "dnsmasq_init", "odhcpd_init", "ubus_cli"};
    static const char *const paths[] = {"/etc/init.d/network", "/sbin/wifi", "/etc/init.d/dnsmasq", "/etc/init.d/odhcpd", "/bin/ubus"};
    static const char *const candidate_actions[] = {"reload", "reload", "reload", "reload", "list-only inspection"};
    size_t index;
    bool procd = process_named("procd");
    if (!append_text(response, "{\"inspection_only\":true,\"commands_invoked\":false,\"backends\":[")) return false;
    for (index = 0U; index < (sizeof(names) / sizeof(names[0])); index++) {
        if (((index > 0U) && !append_text(response, ",")) || !append_text(response, "{\"name\":") ||
            !append_json_string(response, names[index]) || !append_text(response, ",\"path\":") ||
            !append_json_string(response, paths[index]) || !append_text(response, ",\"present\":") ||
            !append_boolean(response, fixed_exists(paths[index])) || !append_text(response, ",\"executable\":") ||
            !append_boolean(response, fixed_executable(paths[index])) || !append_text(response, ",\"candidate_action\":") ||
            !append_json_string(response, candidate_actions[index]) ||
            !append_text(response, ",\"behavior_verified\":false,\"invoked\":false}")) return false;
    }
    return append_text(response, "],\"procd_running\":") && append_boolean(response, procd) &&
        append_text(response, ",\"service_management\":") && append_json_string(response, procd ? "procd/ubus" : "not_detected") && append_text(response, "}");
}

static bool process_named(const char *expected_name)
{
    char name[64];
    if (!read_fixed_file("/proc/1/comm", name, sizeof(name))) return false;
    name[strcspn(name, "\r\n")] = '\0';
    return strcmp(name, expected_name) == 0;
}
