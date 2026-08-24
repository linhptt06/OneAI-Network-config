#include "network_uci.h"

#ifndef ROUTER_AGENT_TEST_BACKEND
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <uci.h>

static int read_option(struct uci_context *context, const char *path,
                       char *output, size_t output_size)
{
    struct uci_ptr pointer;
    char lookup[64];
    if (snprintf(lookup, sizeof(lookup), "%s", path) < 0) return -1;
    (void)memset(&pointer, 0, sizeof(pointer));
    if ((uci_lookup_ptr(context, &pointer, lookup, false) != UCI_OK) ||
        (pointer.o == NULL) || (pointer.o->type != UCI_TYPE_STRING) ||
        (pointer.o->v.string == NULL)) {
        output[0] = '\0';
        return 0;
    }
    if (snprintf(output, output_size, "%s", pointer.o->v.string) < 0) return -1;
    return 0;
}

static int native_read_lan(void *private_data, rb_network_request_t *current)
{
    struct uci_context *context;
    struct uci_package *package = NULL;
    (void)private_data;
    if (current == NULL) { errno = EINVAL; return -1; }
    context = uci_alloc_context();
    if (context == NULL) return -1;
    if (uci_load(context, "network", &package) != UCI_OK) { uci_free_context(context); return -1; }
    (void)memset(current, 0, sizeof(*current));
    (void)snprintf(current->interface, sizeof(current->interface), "lan");
    if ((read_option(context, "network.lan.proto", current->proto, sizeof(current->proto)) != 0) ||
        (read_option(context, "network.lan.ipaddr", current->ipaddr, sizeof(current->ipaddr)) != 0) ||
        (read_option(context, "network.lan.netmask", current->netmask, sizeof(current->netmask)) != 0) ||
        (read_option(context, "network.lan.gateway", current->gateway, sizeof(current->gateway)) != 0)) {
        uci_unload(context, package); uci_free_context(context); return -1;
    }
    uci_unload(context, package);
    uci_free_context(context);
    return 0;
}

static int set_fixed(struct uci_context *context, const char *path, const char *value)
{
    struct uci_ptr pointer;
    char lookup[64];
    if (snprintf(lookup, sizeof(lookup), "%s", path) < 0) return -1;
    (void)memset(&pointer, 0, sizeof(pointer));
    if (uci_lookup_ptr(context, &pointer, lookup, false) != UCI_OK) return -1;
    pointer.value = value;
    return uci_set(context, &pointer) == UCI_OK ? 0 : -1;
}

static int delete_fixed(struct uci_context *context, const char *path)
{
    struct uci_ptr pointer;
    char lookup[64];
    if (snprintf(lookup, sizeof(lookup), "%s", path) < 0) return -1;
    (void)memset(&pointer, 0, sizeof(pointer));
    if (uci_lookup_ptr(context, &pointer, lookup, false) != UCI_OK) return 0;
    if (pointer.o == NULL) return 0;
    return uci_delete(context, &pointer) == UCI_OK ? 0 : -1;
}

static int native_commit_lan(void *private_data, const rb_network_request_t *request)
{
    struct uci_context *context;
    struct uci_package *package = NULL;
    int result = -1;
    (void)private_data;
    if ((request == NULL) || (strcmp(request->interface, "lan") != 0)) { errno = EINVAL; return -1; }
    context = uci_alloc_context();
    if (context == NULL) return -1;
    if (uci_load(context, "network", &package) != UCI_OK) goto done;
    if (set_fixed(context, "network.lan.proto", request->proto) != 0) goto revert;
    if (strcmp(request->proto, "dhcp") == 0) {
        if ((delete_fixed(context, "network.lan.ipaddr") != 0) ||
            (delete_fixed(context, "network.lan.netmask") != 0) ||
            (delete_fixed(context, "network.lan.gateway") != 0)) goto revert;
    } else {
        if ((set_fixed(context, "network.lan.ipaddr", request->ipaddr) != 0) ||
            (set_fixed(context, "network.lan.netmask", request->netmask) != 0)) goto revert;
        if (((request->gateway[0] == '\0') && (delete_fixed(context, "network.lan.gateway") != 0)) ||
            ((request->gateway[0] != '\0') && (set_fixed(context, "network.lan.gateway", request->gateway) != 0))) goto revert;
    }
    if ((uci_save(context, package) != UCI_OK) || (uci_commit(context, &package, false) != UCI_OK)) goto revert;
    result = 0;
    goto done;
revert:
    (void)uci_revert(context, &((struct uci_ptr){ .p = package }));
done:
    if (package != NULL) uci_unload(context, package);
    uci_free_context(context);
    return result;
}

const rb_network_uci_ops_t rb_network_uci_native_ops = { native_read_lan, native_commit_lan };
#endif
