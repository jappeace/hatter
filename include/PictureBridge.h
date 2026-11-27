#ifndef PICTURE_BRIDGE_H
#define PICTURE_BRIDGE_H

#include <stdint.h>

/*
 * Platform-agnostic bridge for the pixels of picture files, from any
 * thread.
 *
 * Without a platform's implementation, no picture is read.
 */

/* The pixels of a picture file, turned the way its camera says, as RGBA
 * without premultiplied alpha, halved until there are at most max_pixels.
 * A buffer of width * height * 4 bytes for the caller to free, or NULL if
 * the file is no picture. */
uint8_t *picture_pixels(const char *path, int32_t max_pixels, int32_t *width, int32_t *height);

/* A picture file written again to out, turned the way its camera says,
 * no longer than longest on either side and without its metadata: 1 as
 * JPEG, 2 as PNG for one with transparency, 0 if the file is no picture. */
int32_t picture_shrink(const char *path, const char *out, int32_t longest);

/* Register a platform-specific implementation. */
void picture_register_impl(uint8_t *(*pixels_impl)(const char *, int32_t, int32_t *, int32_t *),
                           int32_t (*shrink_impl)(const char *, const char *, int32_t));

#endif /* PICTURE_BRIDGE_H */
