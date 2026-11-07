#ifndef SCREENSHOTX_STITCHER_H
#define SCREENSHOTX_STITCHER_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SXStitcher SXStitcher;
typedef struct SXStitchProgress {
    uint32_t width;
    uint32_t height;
    /* 0 accepted, 1 unchanged, 2 reconnect required, 3 limit reached. */
    int32_t disposition;
} SXStitchProgress;

/* All input pointers are borrowed only for the duration of the call.
   BGRA8 frames are top-to-bottom. Caller must supply readable length bytes.
   Error buffers are always NUL terminated when capacity is nonzero.
   Return 0 for success, -1 for failure. No Rust panic unwinds into C.
   Caller must serialize destroy against all other calls and destroy once. */
SXStitcher *sx_stitcher_create(const char *directory, char *error, size_t capacity);
int32_t sx_stitcher_append(SXStitcher *, const uint8_t *bytes, size_t length,
                          uint32_t width, uint32_t height, size_t stride,
                          SXStitchProgress *, char *error, size_t capacity);
int32_t sx_stitcher_finish(SXStitcher *, const char *png_path,
                          SXStitchProgress *, char *error, size_t capacity);
void sx_stitcher_destroy(SXStitcher *);

#ifdef __cplusplus
}
#endif
#endif
