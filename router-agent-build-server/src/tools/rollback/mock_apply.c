#include "mock_apply.h"

#include <errno.h>
#include <stddef.h>

int rb_mock_apply(rb_scope_t scope, void *private_data)
{
    rb_mock_apply_t *mock = (rb_mock_apply_t *)private_data;
    if (mock == NULL) {
        errno = EINVAL;
        return -1;
    }
    mock->calls += 1U;
    mock->last_scope = scope;
    if (mock->result != 0) errno = EIO;
    return mock->result;
}
