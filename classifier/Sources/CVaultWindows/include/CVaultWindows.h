#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t vault_windows_random(uint8_t *output, size_t length);
uint32_t vault_windows_protect(const uint8_t *input, size_t length, uint8_t **output, size_t *outputLength, int decrypt);
void vault_windows_free(void *memory);
uint32_t vault_windows_restrict_path(const char *path);
uint32_t vault_windows_image_jpeg(const uint8_t *input, size_t length, uint8_t **output, size_t *outputLength);
void vault_windows_prune_package(const char *parentPath, const char *name);
#ifdef __cplusplus
}
#endif
