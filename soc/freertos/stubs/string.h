/* Header toi thieu: cac ham nay nam trong rtos_libc.c */
#include <stddef.h>
void *memset(void *d, int c, size_t n);
void *memcpy(void *d, const void *s, size_t n);
int memcmp(const void *a, const void *b, size_t n);
char *strncpy(char *d, const char *s, size_t n);
