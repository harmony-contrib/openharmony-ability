/*
 * IME support: attaches a text editor proxy on surface creation and translates the four
 * callbacks the Rust framework exposes (insert text / keyboard status / delete backward /
 * enter key) into app events. The OHOS headers use char16_t without including <uchar.h>, so it
 * is included here first (SDL does the same).
 */
#include <uchar.h>

#include "oh_state.h"

#include <stdlib.h>

#include <inputmethod/inputmethod_attach_options_capi.h>
#include <inputmethod/inputmethod_controller_capi.h>
#include <inputmethod/inputmethod_inputmethod_proxy_capi.h>
#include <inputmethod/inputmethod_text_editor_proxy_capi.h>
#include <inputmethod/inputmethod_types_capi.h>

static InputMethod_TextEditorProxy *g_text_editor_proxy;
static InputMethod_InputMethodProxy *g_ime_proxy;

/* UTF-16 (with surrogate pairs) -> UTF-8. Returns the number of bytes written (excluding the
 * terminator), or 0 when the buffer is too small. */
static size_t utf16_to_utf8(const char16_t *text, size_t length, char *out, size_t out_capacity) {
    size_t written = 0;
    for (size_t i = 0; i < length; i++) {
        uint32_t codepoint = text[i];
        if (codepoint >= 0xD800 && codepoint <= 0xDBFF && i + 1 < length && text[i + 1] >= 0xDC00 &&
            text[i + 1] <= 0xDFFF) {
            codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (text[++i] - 0xDC00);
        }
        size_t needed;
        if (codepoint <= 0x7F) {
            needed = 1;
        } else if (codepoint <= 0x7FF) {
            needed = 2;
        } else if (codepoint <= 0xFFFF) {
            needed = 3;
        } else {
            needed = 4;
        }
        if (written + needed + 1 > out_capacity) {
            return 0;
        }
        if (needed == 1) {
            out[written++] = (char)codepoint;
        } else if (needed == 2) {
            out[written++] = (char)(0xC0 | (codepoint >> 6));
            out[written++] = (char)(0x80 | (codepoint & 0x3F));
        } else if (needed == 3) {
            out[written++] = (char)(0xE0 | (codepoint >> 12));
            out[written++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
            out[written++] = (char)(0x80 | (codepoint & 0x3F));
        } else {
            out[written++] = (char)(0xF0 | (codepoint >> 18));
            out[written++] = (char)(0x80 | ((codepoint >> 12) & 0x3F));
            out[written++] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
            out[written++] = (char)(0x80 | (codepoint & 0x3F));
        }
    }
    out[written] = '\0';
    return written;
}

static void on_insert_text(InputMethod_TextEditorProxy *proxy, const char16_t *text,
                           size_t length) {
    (void)proxy;
    if (text == NULL) {
        return;
    }
    char buffer[512];
    if (utf16_to_utf8(text, length, buffer, sizeof(buffer)) == 0) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_IME_TEXT_INPUT;
    event.data.ime_text_input.text_input.text = buffer;
    oh_event_post(&event);
}

static void on_send_keyboard_status(InputMethod_TextEditorProxy *proxy,
                                    InputMethod_KeyboardStatus status) {
    (void)proxy;
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_IME_STATUS;
    event.data.ime_status.status.status = (OHAbility_ImeStatus)status;
    oh_event_post(&event);
}

static void on_delete_backward(InputMethod_TextEditorProxy *proxy, int32_t length) {
    (void)proxy;
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_IME_BACKSPACE;
    event.data.ime_backspace.backspace.length = length;
    oh_event_post(&event);
}

static void on_send_enter_key(InputMethod_TextEditorProxy *proxy, InputMethod_EnterKeyType key) {
    (void)proxy;
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_IME_ENTER;
    event.data.ime_enter.enter.key = (int32_t)key;
    oh_event_post(&event);
}

void oh_ime_attach(void) {
    if (g_ime_proxy != NULL) {
        return;
    }
    if (g_text_editor_proxy == NULL) {
        g_text_editor_proxy = OH_TextEditorProxy_Create();
        if (g_text_editor_proxy == NULL) {
            OHABILITY_LOG(LOG_ERROR, "IME: failed to create text editor proxy");
            return;
        }
        OH_TextEditorProxy_SetInsertTextFunc(g_text_editor_proxy, on_insert_text);
        OH_TextEditorProxy_SetSendKeyboardStatusFunc(g_text_editor_proxy, on_send_keyboard_status);
        OH_TextEditorProxy_SetDeleteBackwardFunc(g_text_editor_proxy, on_delete_backward);
        OH_TextEditorProxy_SetSendEnterKeyFunc(g_text_editor_proxy, on_send_enter_key);
    }

    InputMethod_AttachOptions *options = OH_AttachOptions_Create(false);
    if (options == NULL) {
        OHABILITY_LOG(LOG_ERROR, "IME: failed to create attach options");
        return;
    }
    InputMethod_ErrorCode code =
        OH_InputMethodController_Attach(g_text_editor_proxy, options, &g_ime_proxy);
    OH_AttachOptions_Destroy(options);
    if (code != IME_ERR_OK) {
        OHABILITY_LOG(LOG_ERROR, "IME: attach failed with %d", (int)code);
        g_ime_proxy = NULL;
    } else {
        OHABILITY_LOG(LOG_INFO, "IME: attached");
    }
}

void oh_ime_detach(void) {
    if (g_ime_proxy != NULL) {
        OH_InputMethodController_Detach(g_ime_proxy);
        g_ime_proxy = NULL;
    }
    if (g_text_editor_proxy != NULL) {
        OH_TextEditorProxy_Destroy(g_text_editor_proxy);
        g_text_editor_proxy = NULL;
    }
    OHABILITY_LOG(LOG_INFO, "IME: detached");
}

void oh_ime_show_keyboard(void) {
    if (g_ime_proxy != NULL) {
        OH_InputMethodProxy_ShowKeyboard(g_ime_proxy);
    }
}

void oh_ime_hide_keyboard(void) {
    if (g_ime_proxy != NULL) {
        OH_InputMethodProxy_HideKeyboard(g_ime_proxy);
    }
}
