#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_ohos_ability.h>
#include <hilog/log.h>
#include <napi/native_api.h>

#define SDL_DEMO_TAG "ohosSDLDemo"
#define SDL_DEMO_LOG(level, fmt, ...)                                                              \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, SDL_DEMO_TAG, fmt, ##__VA_ARGS__)

typedef struct SDLAbilityDemo {
    SDL_Window *window;
    SDL_Renderer *renderer;
    bool surface_ready;
    bool paused;
    float pointer_x;
    float pointer_y;
    Uint64 started_at;
    uint32_t touch_count;
    uint32_t key_count;
    uint32_t wheel_count;
    uint32_t tap_count;
    uint32_t pan_count;
    uint32_t swipe_count;
    char last_input[96];
} SDLAbilityDemo;

static void sdl_demo_set_last_input(SDLAbilityDemo *demo, const char *text) {
    SDL_strlcpy(demo->last_input, text != NULL ? text : "", sizeof(demo->last_input));
}

static int sdl_demo_init(void **appstate, int argc, char **argv) {
    (void)argc;
    (void)argv;

    SDLAbilityDemo *demo = (SDLAbilityDemo *)SDL_calloc(1, sizeof(*demo));
    if (demo == NULL) {
        return 1;
    }
    *appstate = demo;

    if (!SDL_OHOS_AbilityPrepareVideo() || !SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        SDL_DEMO_LOG(LOG_ERROR, "SDL init failed: %{public}s", SDL_GetError());
        return 2;
    }

    OHAbility_Rect rect;
    if (OHAbility_GetContentRect(&rect) != OH_ABILITY_ERROR_OK) {
        SDL_DEMO_LOG(LOG_ERROR, "surface rectangle is unavailable");
        return 3;
    }
    demo->window = SDL_CreateWindow("oh_ability SDL3 demo", rect.width, rect.height,
                                    SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (demo->window == NULL || !SDL_OHOS_AbilityAttachWindow(demo->window)) {
        SDL_DEMO_LOG(LOG_ERROR, "SDL window attach failed: %{public}s", SDL_GetError());
        return 4;
    }
    demo->renderer = SDL_CreateRenderer(demo->window, NULL);
    if (demo->renderer == NULL) {
        SDL_DEMO_LOG(LOG_ERROR, "SDL renderer creation failed: %{public}s", SDL_GetError());
        return 5;
    }

    demo->surface_ready = true;
    demo->started_at = SDL_GetTicks();
    demo->pointer_x = (float)rect.width * 0.5f;
    demo->pointer_y = (float)rect.height * 0.5f;
    sdl_demo_set_last_input(demo, "touch, drag, scroll, or press a key");
    SDL_DEMO_LOG(LOG_INFO, "SDL3 demo ready: %{public}dx%{public}d", rect.width, rect.height);
    return 0;
}

static void sdl_demo_handle_sdl_events(SDLAbilityDemo *demo) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_EVENT_QUIT:
        case SDL_EVENT_TERMINATING:
            OHAbility_RequestQuit(0);
            break;
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION: {
            int width = 0;
            int height = 0;
            if (SDL_GetWindowSizeInPixels(demo->window, &width, &height)) {
                demo->pointer_x = event.tfinger.x * (float)width;
                demo->pointer_y = event.tfinger.y * (float)height;
            }
        } break;
        case SDL_EVENT_MOUSE_MOTION:
            demo->pointer_x = event.motion.x;
            demo->pointer_y = event.motion.y;
            break;
        case SDL_EVENT_TEXT_INPUT:
            sdl_demo_set_last_input(demo, event.text.text);
            break;
        default:
            break;
        }
    }
}

static void sdl_demo_iterate(void *appstate) {
    SDLAbilityDemo *demo = (SDLAbilityDemo *)appstate;
    if (demo == NULL) {
        return;
    }
    sdl_demo_handle_sdl_events(demo);
    if (!demo->surface_ready || demo->paused || demo->renderer == NULL) {
        return;
    }

    int width = 0;
    int height = 0;
    if (!SDL_GetWindowSizeInPixels(demo->window, &width, &height) || width <= 0 || height <= 0) {
        return;
    }
    const float seconds = (float)(SDL_GetTicks() - demo->started_at) / 1000.0f;
    const Uint8 pulse = (Uint8)(48.0f + 32.0f * (1.0f + SDL_sinf(seconds * 1.8f)));

    SDL_SetRenderDrawColor(demo->renderer, 10, 18, pulse, 255);
    SDL_RenderClear(demo->renderer);

    const SDL_FRect band = {20.0f, 58.0f, (float)width - 40.0f, 62.0f};
    SDL_SetRenderDrawColor(demo->renderer, 32, 154, 214, 255);
    SDL_RenderFillRect(demo->renderer, &band);

    const float orbit_x = (float)width * 0.5f + SDL_cosf(seconds) * (float)width * 0.25f;
    const float orbit_y = (float)height * 0.62f + SDL_sinf(seconds * 1.4f) * 36.0f;
    const SDL_FRect orbit = {orbit_x - 22.0f, orbit_y - 22.0f, 44.0f, 44.0f};
    SDL_SetRenderDrawColor(demo->renderer, 255, 190, 56, 255);
    SDL_RenderFillRect(demo->renderer, &orbit);

    const SDL_FRect pointer = {demo->pointer_x - 10.0f, demo->pointer_y - 10.0f, 20.0f, 20.0f};
    SDL_SetRenderDrawColor(demo->renderer, 255, 91, 120, 255);
    SDL_RenderFillRect(demo->renderer, &pointer);

    char status[160];
    SDL_snprintf(status, sizeof(status), "touch %u  key %u  wheel %u  tap %u  pan %u  swipe %u",
                 demo->touch_count, demo->key_count, demo->wheel_count, demo->tap_count,
                 demo->pan_count, demo->swipe_count);
    SDL_SetRenderDrawColor(demo->renderer, 242, 248, 255, 255);
    SDL_RenderDebugText(demo->renderer, 28.0f, 24.0f, "SDL3 + oh_ability / shared XComponent");
    SDL_RenderDebugText(demo->renderer, 28.0f, 82.0f, status);
    SDL_RenderDebugText(demo->renderer, 28.0f, (float)height - 32.0f, demo->last_input);
    SDL_RenderPresent(demo->renderer);
}

static void sdl_demo_event(void *appstate, const OHAbility_Event *event) {
    SDLAbilityDemo *demo = (SDLAbilityDemo *)appstate;
    if (demo == NULL || event == NULL) {
        return;
    }

    SDL_OHOS_AbilityHandleEvent(demo->window, event);
    switch (event->kind) {
    case OH_ABILITY_EVENT_SURFACE_CREATED:
    case OH_ABILITY_EVENT_SURFACE_CHANGED:
        demo->surface_ready = true;
        break;
    case OH_ABILITY_EVENT_SURFACE_DESTROYED:
        demo->surface_ready = false;
        break;
    case OH_ABILITY_EVENT_RESUME:
    case OH_ABILITY_EVENT_GAINED_FOCUS:
        demo->paused = false;
        break;
    case OH_ABILITY_EVENT_PAUSE:
    case OH_ABILITY_EVENT_LOST_FOCUS:
        demo->paused = true;
        break;
    case OH_ABILITY_EVENT_INPUT_TOUCH:
        demo->touch_count++;
        if (event->data.input_touch.touch.num_points > 0) {
            const OHAbility_TouchPoint *point = &event->data.input_touch.touch.points[0];
            demo->pointer_x = point->x;
            demo->pointer_y = point->y;
        }
        sdl_demo_set_last_input(demo, "raw XComponent touch -> SDL finger event");
        break;
    case OH_ABILITY_EVENT_INPUT_KEY:
        demo->key_count++;
        sdl_demo_set_last_input(demo, "XComponent key -> SDL keyboard event");
        break;
    case OH_ABILITY_EVENT_INPUT_AXIS:
        demo->wheel_count++;
        sdl_demo_set_last_input(demo, "ArkUI axis -> SDL mouse wheel event");
        break;
    case OH_ABILITY_EVENT_GESTURE_TAP:
        demo->tap_count++;
        sdl_demo_set_last_input(demo, "ArkUI tap recognizer");
#ifdef OH_ABILITY_ENABLE_IME
        if (demo->tap_count == 1) {
            (void)OHAbility_ShowKeyboard();
        }
#endif
        break;
    case OH_ABILITY_EVENT_GESTURE_PAN:
        demo->pan_count++;
        sdl_demo_set_last_input(demo, "ArkUI pan recognizer");
        break;
    case OH_ABILITY_EVENT_GESTURE_SWIPE:
        demo->swipe_count++;
        sdl_demo_set_last_input(demo, "ArkUI swipe recognizer");
        break;
    default:
        break;
    }
}

static void sdl_demo_quit(void *appstate, int result) {
    SDLAbilityDemo *demo = (SDLAbilityDemo *)appstate;
    SDL_DEMO_LOG(LOG_INFO, "SDL3 demo quit: %{public}d", result);
    if (demo != NULL) {
        SDL_DestroyRenderer(demo->renderer);
        SDL_DestroyWindow(demo->window);
        SDL_free(demo);
    }
    SDL_Quit();
}

static bool sdl_demo_back_press(void *userdata) {
    (void)userdata;
    return false;
}

static napi_value SDLAbilityModuleInit(napi_env env, napi_value exports) {
    static const OHAbility_AppCallbacks callbacks = {
        .init = sdl_demo_init,
        .iterate = sdl_demo_iterate,
        .event = sdl_demo_event,
        .quit = sdl_demo_quit,
    };

    int rc = SDL_OHOS_AbilityRegisterPlugins() ? OH_ABILITY_ERROR_OK : OH_ABILITY_ERROR_BRIDGE;
    if (rc == OH_ABILITY_ERROR_OK) {
        rc = OHAbility_RegisterModule(env, exports);
    }
    if (rc == OH_ABILITY_ERROR_OK) {
        rc = OHAbility_SetTouchInputDelivery(OH_ABILITY_TOUCH_INPUT_BOTH);
    }
    if (rc == OH_ABILITY_ERROR_OK) {
        rc = OHAbility_SetBackPressInterceptor(sdl_demo_back_press, NULL);
    }
    if (rc == OH_ABILITY_ERROR_OK) {
        rc = OHAbility_StartApp(&callbacks);
    }
    if (rc != OH_ABILITY_ERROR_OK) {
        SDL_DEMO_LOG(LOG_ERROR, "SDL ability module setup failed: %{public}d", rc);
    }
    return exports;
}

static napi_module sdl_demo_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = SDLAbilityModuleInit,
    .nm_modname = "sdl_demo_native",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) static void RegisterSDLAbilityModule(void) {
    napi_module_register(&sdl_demo_module);
}
