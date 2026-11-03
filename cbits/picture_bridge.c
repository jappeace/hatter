/*
 * Platform-agnostic picture bridge dispatcher. Without a platform's
 * implementation, no picture is read.
 */

#include "PictureBridge.h"
#include <stddef.h>

static uint8_t *(*g_pixels_impl)(const char *, int32_t, int32_t *, int32_t *) = NULL;
static int32_t (*g_shrink_impl)(const char *, const char *, int32_t) = NULL;

void picture_register_impl(uint8_t *(*pixels_impl)(const char *, int32_t, int32_t *, int32_t *),
                           int32_t (*shrink_impl)(const char *, const char *, int32_t))
{
    g_pixels_impl = pixels_impl;
    g_shrink_impl = shrink_impl;
}

int32_t picture_shrink(const char *path, const char *out, int32_t longest)
{
    return g_shrink_impl ? g_shrink_impl(path, out, longest) : 0;
}

uint8_t *picture_pixels(const char *path, int32_t max_pixels, int32_t *width, int32_t *height)
{
    return g_pixels_impl ? g_pixels_impl(path, max_pixels, width, height) : NULL;
}
