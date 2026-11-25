#ifndef KARUTO_STITCHER_H
#define KARUTO_STITCHER_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SXStitcher SXStitcher;
typedef struct SXStitchProgress {
    uint32_t width;
    uint32_t height;
    /* 0 accepted, 1 unchanged, 2 reconnect required, 3 limit reached, 4 checking content, 5 reconnected. */
    int32_t disposition;
} SXStitchProgress;

/* All input pointers are borrowed only for the duration of the call.
   BGRA8 frames are top-to-bottom. Caller must supply readable length bytes.
   Error buffers are always NUL terminated when capacity is nonzero.
   Return 0 for success, -1 for failure. No Rust panic unwinds into C.
   Caller must serialize destroy against all other calls and destroy once. */
SXStitcher *sx_stitcher_create(const char *directory, char *error, size_t capacity);
/* Calibrated mode retains at most four input frames while verifying moving content. */
SXStitcher *sx_stitcher_create_calibrated(const char *directory, char *error, size_t capacity);
typedef struct SXContentRect { uint32_t x, y, width, height; } SXContentRect;
/* Top-left input pixel coordinates. Returns 1 verified, 0 pending, -1 invalid. */
int32_t sx_stitcher_content_rect(SXStitcher *, SXContentRect *);
/* Returns 1 when the verified capture excludes a floating bottom overlay. */
int32_t sx_stitcher_excluded_bottom_overlay(SXStitcher *);
/* Optional input-pixel pane bounds. Set before appending the first frame. */
int32_t sx_stitcher_set_content_hint(SXStitcher *, SXContentRect);

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
