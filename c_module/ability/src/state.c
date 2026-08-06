/*
 * Global framework state and small shared helpers.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

OHAbility_State g_oh_state;

void oh_state_lock(void) { pthread_mutex_lock(&g_oh_state.lock); }

void oh_state_unlock(void) { pthread_mutex_unlock(&g_oh_state.lock); }

char *oh_strdup(const char *src) {
    if (src == NULL) {
        src = "";
    }
    size_t len = strlen(src);
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, src, len + 1);
    return copy;
}

int oh_validate_identifier(const char *label, const char *value) {
    if (label == NULL || value == NULL || value[0] == '\0') {
        return 0;
    }
    for (const char *p = value; *p != '\0'; ++p) {
        unsigned char c = (unsigned char)*p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-')) {
            return 0;
        }
    }
    return 1;
}

char *oh_napi_get_string(napi_env env, napi_value value) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) {
        return oh_strdup("");
    }
    char *buffer = (char *)malloc(len + 1);
    if (buffer == NULL) {
        return oh_strdup("");
    }
    if (napi_get_value_string_utf8(env, value, buffer, len + 1, &len) != napi_ok) {
        free(buffer);
        return oh_strdup("");
    }
    return buffer;
}
