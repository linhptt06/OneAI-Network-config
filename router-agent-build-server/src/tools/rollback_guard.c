#define _POSIX_C_SOURCE 200809L
#include "rollback/native_apply.h"
#include "rollback/rollback.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef RB_STATE_ROOT
#define RB_STATE_ROOT "/etc/router-agent"
#endif
#ifndef RB_CONFIG_ROOT
#define RB_CONFIG_ROOT "/etc/config"
#endif
static volatile sig_atomic_t running = 1;


static void stop_guard(int signal_number)
{
    (void)signal_number;
    running = 0;
}

int main(int argc, char **argv)
{
    rb_context_t context;
    bool recovering = true;
    (void)argv;
    if (argc != 1) {
        (void)fputs("rollback_guard accepts no arguments\n", stderr);
        return 2;
    }
    if (rb_context_init(&context, RB_STATE_ROOT, RB_CONFIG_ROOT,
                        rb_native_apply, NULL) != 0) {
        (void)fprintf(stderr, "rollback_guard: initialization failed: %s\n", strerror(errno));
        return 1;
    }
    (void)signal(SIGTERM, stop_guard);
    (void)signal(SIGINT, stop_guard);
    while (running != 0) {
        time_t now = time(NULL);
        if (rb_lock(&context) == 0) {
            int result = rb_guard_check(&context, (int64_t)now, recovering);
            recovering = false;
            if (result < 0) {
                (void)fprintf(stderr, "rollback_guard: guard check failed: %s\n", strerror(errno));
            }
            rb_unlock(&context);
        } else if ((errno != EWOULDBLOCK) && (errno != EAGAIN)) {
            (void)fprintf(stderr, "rollback_guard: lock failed: %s\n", strerror(errno));
        }
        if (running != 0) (void)sleep(1U);
    }
    rb_context_close(&context);
    return 0;
}
