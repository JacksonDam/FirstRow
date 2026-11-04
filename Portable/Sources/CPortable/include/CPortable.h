#ifndef CPORTABLE_H
#define CPORTABLE_H

#include <stddef.h>
#include <stdint.h>
#include "plutovg.h"
#include "fr_gl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Font lookups added to plutovg-font.c. */
int plutovg_font_face_glyph_index(plutovg_font_face_t* face, plutovg_codepoint_t codepoint);
float plutovg_font_face_kerning(plutovg_font_face_t* face, float size, plutovg_codepoint_t left, plutovg_codepoint_t right);
int plutovg_font_face_units_per_em(plutovg_font_face_t* face);
int plutovg_font_face_name(plutovg_font_face_t* face, int name_id, char* out, int capacity);
int plutovg_font_data_face_count(const void* data);

/* Pixel work that is too slow in unoptimised Swift. Buffers are premultiplied BGRA unless noted. */

/* Gaussian blur of every channel, in place, approximated with three box passes. */
void fr_blur_bgra(uint8_t* pixels, int width, int height, int stride, float sigma);

/* Box-filtered resize from one BGRA buffer to another. */
void fr_resize_bgra(const uint8_t* src, int src_width, int src_height, int src_stride,
                    uint8_t* dst, int dst_width, int dst_height, int dst_stride);

/* Converts straight RGBA (as image decoders return it) to premultiplied BGRA. */
void fr_rgba_to_premultiplied_bgra(const uint8_t* src, uint8_t* dst, int width, int height, int src_stride, int dst_stride);

/* Fills every pixel's colour with `color` (premultiplied BGRA) scaled by the pixel's alpha. */
void fr_tint_bgra(uint8_t* pixels, int width, int height, int stride, const float color[4]);

/* Multiplies every channel by an 8-bit mask. */
void fr_apply_mask(uint8_t* pixels, int width, int height, int stride, const uint8_t* mask, int mask_stride);

/* Reads a mask from alpha, or from brightness for opaque grey images; optionally multiplies into it. */
void fr_extract_mask(const uint8_t* pixels, int width, int height, int stride, int use_luminance, uint8_t* mask, int mask_stride, int multiply);

/* Decodes PNG, JPEG, BMP, GIF and other common formats to straight RGBA. Free with fr_image_free. */
uint8_t* fr_image_decode(const uint8_t* data, int length, int* width, int* height);
int fr_image_info(const uint8_t* data, int length, int* width, int* height);
void fr_image_free(uint8_t* pixels);

/* Writes straight RGBA as PNG. */
int fr_png_write(const char* path, const uint8_t* rgba, int width, int height, int stride);

#ifdef __cplusplus
}
#endif

#endif
