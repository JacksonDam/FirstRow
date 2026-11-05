#include "CPortable.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Box sizes whose three passes approximate a gaussian of `sigma` (Kovesi's method). */
static void box_sizes(float sigma, int sizes[3])
{
    float ideal = sqrtf(12.0f * sigma * sigma / 3.0f + 1.0f);
    int lower = (int)floorf(ideal);
    if(lower % 2 == 0)
        lower--;
    int upper = lower + 2;
    float m_ideal = (12.0f * sigma * sigma - 3.0f * lower * lower - 12.0f * lower - 9.0f) / (-4.0f * lower - 4.0f);
    int m = (int)roundf(m_ideal);
    for(int i = 0; i < 3; i++)
        sizes[i] = i < m ? lower : upper;
}

static void box_pass(const uint8_t* src, uint8_t* dst, int count, int step, int radius)
{
    if(radius <= 0) {
        for(int i = 0; i < count; i++)
            memcpy(dst + i * step, src + i * step, 4);
        return;
    }
    int window = radius * 2 + 1;
    int sum[4] = { 0, 0, 0, 0 };
    /* Pixels past the edges count as transparent, as a shadow or blur sees them. */
    for(int i = 0; i <= radius && i < count; i++)
        for(int c = 0; c < 4; c++)
            sum[c] += src[i * step + c];
    for(int i = 0; i < count; i++) {
        for(int c = 0; c < 4; c++)
            dst[i * step + c] = (uint8_t)((sum[c] + window / 2) / window);
        int add = i + radius + 1;
        int remove = i - radius;
        if(add < count)
            for(int c = 0; c < 4; c++)
                sum[c] += src[add * step + c];
        if(remove >= 0)
            for(int c = 0; c < 4; c++)
                sum[c] -= src[remove * step + c];
    }
}

void fr_blur_bgra(uint8_t* pixels, int width, int height, int stride, float sigma)
{
    if(sigma < 0.2f || width <= 0 || height <= 0)
        return;
    int sizes[3];
    box_sizes(sigma, sizes);
    int longest = width > height ? width : height;
    uint8_t* line = malloc((size_t)longest * 4);
    uint8_t* out = malloc((size_t)longest * 4);
    if(!line || !out) {
        free(line);
        free(out);
        return;
    }
    for(int pass = 0; pass < 3; pass++) {
        int radius = (sizes[pass] - 1) / 2;
        for(int y = 0; y < height; y++) {
            uint8_t* row = pixels + (size_t)y * stride;
            memcpy(line, row, (size_t)width * 4);
            box_pass(line, out, width, 4, radius);
            memcpy(row, out, (size_t)width * 4);
        }
        for(int x = 0; x < width; x++) {
            for(int y = 0; y < height; y++)
                memcpy(line + y * 4, pixels + (size_t)y * stride + x * 4, 4);
            box_pass(line, out, height, 4, radius);
            for(int y = 0; y < height; y++)
                memcpy(pixels + (size_t)y * stride + x * 4, out + y * 4, 4);
        }
    }
    free(line);
    free(out);
}

void fr_resize_bgra(const uint8_t* src, int src_width, int src_height, int src_stride,
                    uint8_t* dst, int dst_width, int dst_height, int dst_stride)
{
    if(dst_width <= 0 || dst_height <= 0 || src_width <= 0 || src_height <= 0)
        return;
    float sx = (float)src_width / dst_width;
    float sy = (float)src_height / dst_height;
    for(int y = 0; y < dst_height; y++) {
        float y0 = y * sy, y1 = (y + 1) * sy;
        if(sy < 1) {
            /* Upscaling: bilinear. */
            float fy = (y + 0.5f) * sy - 0.5f;
            if(fy < 0) fy = 0;
            int iy = (int)fy;
            int iy1 = iy + 1 < src_height ? iy + 1 : iy;
            float ty = fy - iy;
            for(int x = 0; x < dst_width; x++) {
                float fx = (x + 0.5f) * sx - 0.5f;
                if(fx < 0) fx = 0;
                int ix = (int)fx;
                int ix1 = ix + 1 < src_width ? ix + 1 : ix;
                float tx = fx - ix;
                if(sx >= 1) {
                    ix = (int)(x * sx);
                    ix1 = ix;
                    tx = 0;
                }
                for(int c = 0; c < 4; c++) {
                    float a = src[(size_t)iy * src_stride + ix * 4 + c] * (1 - tx) + src[(size_t)iy * src_stride + ix1 * 4 + c] * tx;
                    float b = src[(size_t)iy1 * src_stride + ix * 4 + c] * (1 - tx) + src[(size_t)iy1 * src_stride + ix1 * 4 + c] * tx;
                    float v = a * (1 - ty) + b * ty;
                    dst[(size_t)y * dst_stride + x * 4 + c] = (uint8_t)(v + 0.5f);
                }
            }
            continue;
        }
        for(int x = 0; x < dst_width; x++) {
            float x0 = x * sx, x1 = (x + 1) * sx;
            float acc[4] = { 0, 0, 0, 0 };
            float total = 0;
            for(int yy = (int)y0; yy < (int)ceilf(y1) && yy < src_height; yy++) {
                float wy = fminf(y1, yy + 1) - fmaxf(y0, yy);
                if(wy <= 0) continue;
                for(int xx = (int)x0; xx < (int)ceilf(x1) && xx < src_width; xx++) {
                    float wx = fminf(x1, xx + 1) - fmaxf(x0, xx);
                    if(wx <= 0) continue;
                    float w = wx * wy;
                    const uint8_t* p = src + (size_t)yy * src_stride + xx * 4;
                    for(int c = 0; c < 4; c++)
                        acc[c] += p[c] * w;
                    total += w;
                }
            }
            for(int c = 0; c < 4; c++)
                dst[(size_t)y * dst_stride + x * 4 + c] = (uint8_t)(total > 0 ? acc[c] / total + 0.5f : 0);
        }
    }
}

void fr_rgba_to_premultiplied_bgra(const uint8_t* src, uint8_t* dst, int width, int height, int src_stride, int dst_stride)
{
    for(int y = 0; y < height; y++) {
        const uint8_t* s = src + (size_t)y * src_stride;
        uint8_t* d = dst + (size_t)y * dst_stride;
        for(int x = 0; x < width; x++) {
            unsigned a = s[3];
            d[0] = (uint8_t)((s[2] * a + 127) / 255);
            d[1] = (uint8_t)((s[1] * a + 127) / 255);
            d[2] = (uint8_t)((s[0] * a + 127) / 255);
            d[3] = (uint8_t)a;
            s += 4;
            d += 4;
        }
    }
}

void fr_tint_bgra(uint8_t* pixels, int width, int height, int stride, const float color[4])
{
    /* Premultiplied: the colour's own alpha scales its channels too. */
    for(int y = 0; y < height; y++) {
        uint8_t* p = pixels + (size_t)y * stride;
        for(int x = 0; x < width; x++) {
            float a = p[3] / 255.0f * color[3];
            p[0] = (uint8_t)(color[0] * a * 255.0f + 0.5f);
            p[1] = (uint8_t)(color[1] * a * 255.0f + 0.5f);
            p[2] = (uint8_t)(color[2] * a * 255.0f + 0.5f);
            p[3] = (uint8_t)(a * 255.0f + 0.5f);
            p += 4;
        }
    }
}

void fr_apply_mask(uint8_t* pixels, int width, int height, int stride, const uint8_t* mask, int mask_stride)
{
    for(int y = 0; y < height; y++) {
        uint8_t* p = pixels + (size_t)y * stride;
        const uint8_t* m = mask + (size_t)y * mask_stride;
        for(int x = 0; x < width; x++) {
            unsigned v = m[x];
            if(v == 255) {
                p += 4;
                continue;
            }
            for(int c = 0; c < 4; c++)
                p[c] = (uint8_t)((p[c] * v + 127) / 255);
            p += 4;
        }
    }
}

void fr_extract_mask(const uint8_t* pixels, int width, int height, int stride, int use_luminance, uint8_t* mask, int mask_stride, int multiply)
{
    for(int y = 0; y < height; y++) {
        const uint8_t* p = pixels + (size_t)y * stride;
        uint8_t* m = mask + (size_t)y * mask_stride;
        for(int x = 0; x < width; x++) {
            unsigned v = use_luminance ? (unsigned)((p[2] * 54 + p[1] * 183 + p[0] * 19 + 128) >> 8) : p[3];
            if(use_luminance && p[3] < 255)
                v = (v * p[3] + 127) / 255;
            m[x] = multiply ? (uint8_t)((m[x] * v + 127) / 255) : (uint8_t)v;
            p += 4;
        }
    }
}
