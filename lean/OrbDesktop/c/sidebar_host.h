/* The host owns the request, pixel buffer and hit-region consumer for one paint.
 * The Lean runtime and GTK stay on the same UI thread. No GTK types cross here. */
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef void (*OrbSidebarHits)(void *view, const char *regions);
typedef int (*OrbSidebarPaint)(void *renderer, const char *request, uint8_t *argb,
                               size_t capacity, OrbSidebarHits hits, void *view);
typedef int (*OrbSidebarHost)(OrbSidebarPaint paint, void *renderer);
