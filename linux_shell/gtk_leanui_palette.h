/* linux_shell/gtk_leanui_palette.h — Pure palette paint protocol helpers & self-test. */
#ifndef ORB_GTK_LEANUI_PALETTE_H
#define ORB_GTK_LEANUI_PALETTE_H

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define ORB_PALETTE_MAX_ITEMS 24
#define ORB_PALETTE_CARD_HIT_ID 900000u

typedef struct {
    unsigned id;
    int x, y, w, h;
} OrbPaletteHit;

static inline void orb_palette_sanitize(const char *src, char *dst, size_t cap) {
    if (!dst || cap == 0) return;
    if (!src) { dst[0] = '\0'; return; }
    size_t i = 0;
    for (; src[i] && i + 1 < cap; ++i) {
        char ch = src[i];
        dst[i] = (ch == '\t' || ch == '\r' || ch == '\n') ? ' ' : ch;
    }
    if (i > 0 && ((unsigned char)dst[i - 1] & 0x80u) != 0) {
        size_t k = i - 1;
        while (k > 0 && ((unsigned char)dst[k] & 0xC0u) == 0x80u) --k;
        unsigned char lead = (unsigned char)dst[k];
        if ((lead & 0x80u) == 0) {
            i = k + 1;
        } else {
            size_t need = (lead & 0xE0u) == 0xC0u ? 2
                        : (lead & 0xF0u) == 0xE0u ? 3
                        : (lead & 0xF8u) == 0xF0u ? 4 : 0;
            if (need == 0 || i - k < need) i = k;
        }
    }
    dst[i] = '\0';
}

static inline int orb_palette_format_header(char *out, size_t cap, int w, int h, int scale,
                                            int light, int selected, const char *query) {
    char q[320];
    orb_palette_sanitize(query, q, sizeof(q));
    int n = snprintf(out, cap, "P\t%d\t%d\t%d\t%d\t%d\t%s\n", w, h, scale, light ? 1 : 0, selected, q);
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

static inline int orb_palette_format_item(char *out, size_t cap, unsigned idx, const char *id,
                                          const char *kind, const char *title, const char *subtitle,
                                          const char *status, const char *shortcut, const char *color) {
    char sid[160], skind[48], stitle[256], ssub[256], sstat[64], ssc[48], scol[48];
    orb_palette_sanitize(id, sid, sizeof(sid));
    orb_palette_sanitize(kind, skind, sizeof(skind));
    orb_palette_sanitize(title, stitle, sizeof(stitle));
    orb_palette_sanitize(subtitle, ssub, sizeof(ssub));
    orb_palette_sanitize(status, sstat, sizeof(sstat));
    orb_palette_sanitize(shortcut, ssc, sizeof(ssc));
    orb_palette_sanitize(color, scol, sizeof(scol));
    int n = snprintf(out, cap, "%u\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                     idx, sid, skind, stitle, ssub, sstat, ssc, scol);
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

static inline int orb_palette_rect_contains(const OrbPaletteHit *r, int x, int y) {
    return r && r->w > 0 && r->h > 0 && x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

static inline void orb_palette_parse_hits(const char *regions, OrbPaletteHit *items, size_t max_items,
                                          size_t *out_count, OrbPaletteHit *out_card, int *has_card) {
    size_t count = 0;
    if (has_card) *has_card = 0;
    if (out_count) *out_count = 0;
    if (!regions) return;
    const char *p = regions;
    while (*p) {
        const char *nl = strchr(p, '\n');
        char line[128];
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len > 0 && len < sizeof(line)) {
            memcpy(line, p, len);
            line[len] = '\0';
            OrbPaletteHit h;
            if (sscanf(line, "%u %d %d %d %d", &h.id, &h.x, &h.y, &h.w, &h.h) == 5 && h.w > 0 && h.h > 0) {
                if (h.id == ORB_PALETTE_CARD_HIT_ID) {
                    if (out_card) *out_card = h;
                    if (has_card) *has_card = 1;
                } else if (items && count < max_items) {
                    items[count++] = h;
                }
            }
        }
        p = nl ? nl + 1 : p + len;
    }
    if (out_count) *out_count = count;
}

static inline int orb_palette_hit_item(const OrbPaletteHit *items, size_t count, int x, int y) {
    for (size_t i = 0; i < count; ++i) {
        if (orb_palette_rect_contains(&items[i], x, y)) return (int)items[i].id;
    }
    return -1;
}

static inline int orb_palette_self_test(void) {
    char hdr[512], row[512], san[32];
    orb_palette_sanitize("a\tb\rc\nd", san, sizeof(san));
    if (strcmp(san, "a b c d") != 0) return 0;
    /* UTF-8 multi-byte truncation boundaries: 3-byte CJK ("漢" = E6 BC A2) & 4-byte emoji ("🚀" = F0 9F 9A 80). */
    const char *cjk = "a\xE6\xBC\xA2" "b";
    orb_palette_sanitize(cjk, san, 2); if (strcmp(san, "a") != 0) return 0;
    orb_palette_sanitize(cjk, san, 3); if (strcmp(san, "a") != 0) return 0;
    orb_palette_sanitize(cjk, san, 4); if (strcmp(san, "a") != 0) return 0;
    orb_palette_sanitize(cjk, san, 5); if (strcmp(san, "a\xE6\xBC\xA2") != 0) return 0;
    const char *emoji = "x\xF0\x9F\x9A\x80" "y";
    orb_palette_sanitize(emoji, san, 2); if (strcmp(san, "x") != 0) return 0;
    orb_palette_sanitize(emoji, san, 3); if (strcmp(san, "x") != 0) return 0;
    orb_palette_sanitize(emoji, san, 4); if (strcmp(san, "x") != 0) return 0;
    orb_palette_sanitize(emoji, san, 5); if (strcmp(san, "x") != 0) return 0;
    orb_palette_sanitize(emoji, san, 6); if (strcmp(san, "x\xF0\x9F\x9A\x80") != 0) return 0;
    orb_palette_sanitize("\xC3\xA9", san, 2); if (strcmp(san, "") != 0) return 0;
    orb_palette_sanitize("\xC3\xA9", san, 3); if (strcmp(san, "\xC3\xA9") != 0) return 0;
    if (orb_palette_format_header(hdr, sizeof(hdr), 900, 620, 2, 1, 3, "foo\tbar\nbaz") < 0) return 0;
    if (strcmp(hdr, "P\t900\t620\t2\t1\t3\tfoo bar baz\n") != 0) return 0;
    if (orb_palette_format_item(row, sizeof(row), 2, "m:1\t2", "mission", "Fix\nbug", "proj\r1", "running", "⌘K", "blue") < 0) return 0;
    if (strcmp(row, "2\tm:1 2\tmission\tFix bug\tproj 1\trunning\t⌘K\tblue\n") != 0) return 0;
    OrbPaletteHit hits[8], card = {0};
    size_t n = 0;
    int has_card = 0;
    orb_palette_parse_hits("900000 170 84 560 220\n0 186 138 528 42\n1 186 182 528 42\nbad line\n2 0 0 0 10",
                           hits, 8, &n, &card, &has_card);
    if (!has_card || n != 2 || card.x != 170 || card.w != 560) return 0;
    if (orb_palette_hit_item(hits, n, 200, 150) != 0) return 0;
    if (orb_palette_hit_item(hits, n, 200, 200) != 1) return 0;
    if (orb_palette_hit_item(hits, n, 200, 100) != -1) return 0;
    if (!orb_palette_rect_contains(&card, 200, 100) || orb_palette_rect_contains(&card, 20, 20)) return 0;
    return 1;
}

#endif
