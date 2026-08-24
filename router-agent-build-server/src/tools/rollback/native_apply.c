#include "native_apply.h"
#include <errno.h>
#include <stddef.h>

#ifndef ROUTER_AGENT_NATIVE_APPLY_TEST
#include <libubox/blob.h>
#include <libubus.h>
#endif

static int scope_mapping(rb_scope_t scope, const char **object, const char **method)
{
    if ((object == NULL) || (method == NULL)) { errno = EINVAL; return -1; }
    if (scope == RB_SCOPE_NETWORK) { *object = "network"; *method = "reload"; return 0; }
    if (scope == RB_SCOPE_WIRELESS) { *object = "network.wireless"; *method = "reconf"; return 0; }
    errno = EINVAL;
    return -1;
}

static int apply_with_ops(rb_scope_t scope, const rb_native_apply_ops_t *ops, void *private_data)
{
    const char *object = NULL;
    const char *method = NULL;
    void *context;
    uint32_t object_id = 0U;
    int status;
    if ((ops == NULL) || (ops->connect == NULL) || (ops->lookup == NULL) ||
        (ops->invoke == NULL) || (ops->disconnect == NULL) ||
        (scope_mapping(scope, &object, &method) != 0)) { errno = EINVAL; return -1; }
    context = ops->connect(private_data);
    if (context == NULL) { errno = ECONNREFUSED; return -1; }
    status = ops->lookup(context, object, &object_id);
    if (status != 0) { ops->disconnect(context); errno = ENOENT; return -1; }
    status = ops->invoke(context, object_id, method, RB_NATIVE_APPLY_TIMEOUT_MS);
    ops->disconnect(context);
    if (status != 0) { errno = EIO; return -1; }
    return 0;
}

#ifdef ROUTER_AGENT_NATIVE_APPLY_TEST
int rb_native_apply_with_ops(rb_scope_t scope, const rb_native_apply_ops_t *ops, void *private_data)
{
    return apply_with_ops(scope, ops, private_data);
}

int rb_native_apply(rb_scope_t scope, void *private_data)
{
    (void)scope; (void)private_data; errno = ENOTSUP; return -1;
}
#else
static void *native_connect(void *private_data) { (void)private_data; return ubus_connect(NULL); }
static int native_lookup(void *context, const char *object, uint32_t *object_id)
{
    return ubus_lookup_id((struct ubus_context *)context, object, object_id);
}
static int native_invoke(void *context, uint32_t object_id, const char *method, int timeout_ms)
{
    struct blob_buf payload = {0};
    int status;
    blob_buf_init(&payload, 0);
    status = ubus_invoke((struct ubus_context *)context, object_id, method,
                         payload.head, NULL, NULL, timeout_ms);
    blob_buf_free(&payload);
    return status;
}
static void native_disconnect(void *context) { ubus_free((struct ubus_context *)context); }

int rb_native_apply(rb_scope_t scope, void *private_data)
{
    static const rb_native_apply_ops_t ops = { native_connect, native_lookup, native_invoke, native_disconnect };
    return apply_with_ops(scope, &ops, private_data);
}
#endif
