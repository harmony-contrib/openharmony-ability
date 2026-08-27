/*
 * Event ring queue + application thread (SDL-style AppInit/AppEvent/AppIterate/AppQuit).
 *
 * The application thread starts automatically when the first XComponent surface is created and
 * lives until the module environment is torn down. Events are posted from any thread; string
 * fields are deep-copied on post and freed after `AppEvent` returns.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Deep-copy the string fields of an event into a destination. */
static void event_copy_strings(const OHAbility_Event *src, OHAbility_Event *dst) {
    *dst = *src;
    switch (src->kind) {
    case OH_ABILITY_EVENT_RESUME:
        dst->data.resume.saved_state = oh_strdup(src->data.resume.saved_state);
        break;
    case OH_ABILITY_EVENT_CONFIG_CHANGED:
        dst->data.config_changed.configuration.language =
            oh_strdup(src->data.config_changed.configuration.language);
        dst->data.config_changed.configuration.mcc =
            oh_strdup(src->data.config_changed.configuration.mcc);
        dst->data.config_changed.configuration.mnc =
            oh_strdup(src->data.config_changed.configuration.mnc);
        break;
    case OH_ABILITY_EVENT_IME_TEXT_INPUT:
        dst->data.ime_text_input.text_input.text =
            oh_strdup(src->data.ime_text_input.text_input.text);
        break;
    default:
        break;
    }
}

void oh_event_free_strings(OHAbility_Event *event) {
    switch (event->kind) {
    case OH_ABILITY_EVENT_RESUME:
        free((char *)event->data.resume.saved_state);
        event->data.resume.saved_state = NULL;
        break;
    case OH_ABILITY_EVENT_CONFIG_CHANGED:
        free((char *)event->data.config_changed.configuration.language);
        free((char *)event->data.config_changed.configuration.mcc);
        free((char *)event->data.config_changed.configuration.mnc);
        event->data.config_changed.configuration.language = NULL;
        event->data.config_changed.configuration.mcc = NULL;
        event->data.config_changed.configuration.mnc = NULL;
        break;
    case OH_ABILITY_EVENT_IME_TEXT_INPUT:
        free((char *)event->data.ime_text_input.text_input.text);
        event->data.ime_text_input.text_input.text = NULL;
        break;
    default:
        break;
    }
}

void oh_event_post(const OHAbility_Event *event) {
    if (event == NULL) {
        return;
    }
    oh_state_lock();
    if (g_oh_state.queue_count >= OHABILITY_QUEUE_CAPACITY) {
        /* Backpressure: drop the new event instead of the oldest so the newest state wins. */
        OHABILITY_LOG(LOG_WARN, "event queue full; dropping event kind=%d", (int)event->kind);
        oh_state_unlock();
        return;
    }
    OHAbility_Event *slot = &g_oh_state.queue[g_oh_state.queue_tail];
    event_copy_strings(event, slot);
    g_oh_state.queue_tail = (g_oh_state.queue_tail + 1) % OHABILITY_QUEUE_CAPACITY;
    g_oh_state.queue_count++;
    pthread_cond_signal(&g_oh_state.event_cond);
    oh_state_unlock();
}

int oh_event_try_pop_batch(OHAbility_Event *out, size_t capacity) {
    size_t n = 0;
    oh_state_lock();
    while (n < capacity && g_oh_state.queue_count > 0) {
        out[n] = g_oh_state.queue[g_oh_state.queue_head];
        g_oh_state.queue_head = (g_oh_state.queue_head + 1) % OHABILITY_QUEUE_CAPACITY;
        g_oh_state.queue_count--;
        n++;
    }
    oh_state_unlock();
    return (int)n;
}

int OHAbility_PostEvent(const OHAbility_Event *event) {
    if (event == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_event_post(event);
    return OH_ABILITY_ERROR_OK;
}

int OHAbility_RequestQuit(int result) {
    oh_app_request_quit(result);
    return OH_ABILITY_ERROR_OK;
}

void oh_app_request_quit(int result) {
    oh_state_lock();
    if (!g_oh_state.quit_requested) {
        g_oh_state.quit_requested = 1;
        g_oh_state.quit_result = result;
    }
    pthread_cond_signal(&g_oh_state.event_cond);
    oh_state_unlock();
}

static void app_loop_idle_tick(void) {
    /* Bounded idle wait (16 ms) so AppIterate is polled while no events are pending. */
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 16 * 1000 * 1000;
    if (deadline.tv_nsec >= 1000 * 1000 * 1000) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000 * 1000 * 1000;
    }
    pthread_cond_timedwait(&g_oh_state.event_cond, &g_oh_state.lock, &deadline);
}

static void *app_thread_main(void *arg) {
    (void)arg;
    void *appstate = NULL;
    OHAbility_AppCallbacks callbacks;

    oh_state_lock();
    callbacks = g_oh_state.app_callbacks;
    oh_state_unlock();

    if (callbacks.init != NULL) {
        int rc = callbacks.init(&appstate, 0, NULL);
        if (rc != 0) {
            OHABILITY_LOG(LOG_WARN, "app init returned %d; application loop will not run", rc);
            oh_state_lock();
            g_oh_state.app_thread_started = 0;
            oh_state_unlock();
            if (callbacks.quit != NULL) {
                callbacks.quit(appstate, rc);
            }
            return NULL;
        }
    }

    for (;;) {
        OHAbility_Event batch[32];
        int n = oh_event_try_pop_batch(batch, 32);

        if (n == 0) {
            oh_state_lock();
            if (g_oh_state.quit_requested) {
                oh_state_unlock();
                break;
            }
            if (g_oh_state.queue_count == 0) {
                app_loop_idle_tick();
            }
            int quit = g_oh_state.quit_requested;
            oh_state_unlock();
            if (quit) {
                break;
            }
            if (callbacks.iterate != NULL) {
                callbacks.iterate(appstate);
            }
            continue;
        }

        for (int i = 0; i < n; i++) {
            if (callbacks.event != NULL) {
                callbacks.event(appstate, &batch[i]);
            }
            oh_event_free_strings(&batch[i]);
        }
    }

    oh_state_lock();
    int result = g_oh_state.quit_result;
    g_oh_state.app_thread_started = 0;
    oh_state_unlock();

    if (callbacks.quit != NULL) {
        callbacks.quit(appstate, result);
    }
    return NULL;
}

void oh_app_maybe_start(void) {
    oh_state_lock();
    if (!g_oh_state.app_callbacks_valid || g_oh_state.app_thread_started) {
        oh_state_unlock();
        return;
    }
    if (pthread_create(&g_oh_state.app_thread, NULL, app_thread_main, NULL) != 0) {
        OHABILITY_LOG(LOG_ERROR, "failed to create application thread");
        oh_state_unlock();
        return;
    }
    g_oh_state.app_thread_started = 1;
    oh_state_unlock();
}

void oh_app_join(void) {
    oh_app_request_quit(0);
    oh_state_lock();
    int started = g_oh_state.app_thread_started;
    pthread_t thread = g_oh_state.app_thread;
    oh_state_unlock();
    if (started) {
        pthread_join(thread, NULL);
    }
}

int OHAbility_StartApp(const OHAbility_AppCallbacks *callbacks) {
    if (callbacks == NULL || callbacks->init == NULL || callbacks->event == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    g_oh_state.app_callbacks = *callbacks;
    g_oh_state.app_callbacks_valid = 1;
    int surface_exists = g_oh_state.native_window != NULL;
    oh_state_unlock();

    if (surface_exists) {
        /* Surface already created: start immediately. */
        oh_app_maybe_start();
    }
    return OH_ABILITY_ERROR_OK;
}
