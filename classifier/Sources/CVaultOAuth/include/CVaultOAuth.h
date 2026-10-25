#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
intptr_t vault_oauth_listen(uint16_t *port);
intptr_t vault_oauth_accept(intptr_t listener, int timeout_ms);
int vault_oauth_read(intptr_t client, char *buffer, size_t capacity);
void vault_oauth_reply(intptr_t client, int success);
void vault_oauth_close(intptr_t socket);
void vault_oauth_close_listener(intptr_t socket);
#ifdef __cplusplus
}
#endif
