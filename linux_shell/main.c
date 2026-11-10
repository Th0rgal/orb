/*
 * linux_shell/main.c — Hardened GTK3 + WebKitGTK 4.1 desktop shell for Orb (<= 220 LOC).
 * Validates ORB_LOCALD_PORT, spawns orb-locald with an allowlisted environment, injects a top-frame-only
 * WebKitUserScript with loopback allow_list + captured _fetch, and confines top-frame navigation.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#endif
static int parse_valid_port(const char *s, unsigned *out_port) {
    if (!s || !*s) return 0;
    unsigned v = 0;
    for (const char *p = s; *p; ++p)
        if (*p < '0' || *p > '9' || (v = v * 10u + (unsigned)(*p - '0')) > 65535u) return 0;
    return v >= 1024u ? (*out_port = v, 1) : 0;
}
static int gen_csprng_hex(char out_hex[65]) {
    unsigned char raw[32];
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    for (size_t got = 0; got < sizeof(raw); ) {
        ssize_t n = read(fd, raw + got, sizeof(raw) - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        got += (size_t)n;
    }
    close(fd);
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) { out_hex[i * 2] = hex[(raw[i] >> 4) & 0x0F]; out_hex[i * 2 + 1] = hex[raw[i] & 0x0F]; }
    return out_hex[64] = '\0', 0;
}
static char *json_escape_string(const char *s) {
    size_t len = strlen(s), j = 0;
    char *out = len <= 4096 ? malloc(len * 6 + 4) : NULL;
    if (!out) return NULL;
    out[j++] = '"';
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; }
        else if (c < 0x20 || c == 0x7F) j += (size_t)snprintf(out + j, 8, "\\u%04x", c);
        else out[j++] = (char)c;
    }
    return out[j++] = '"', out[j] = '\0', out;
}
static int is_confined_shell_uri(const char *u) {
    if (!u || !*u) return 0;
    if (strncmp(u, "file:///", 8) == 0 || strcmp(u, "about:blank") == 0) return 1;
    const char *rest = strncmp(u, "http://127.0.0.1", 16) == 0 ? u + 16 : (strncmp(u, "http://localhost", 16) == 0 ? u + 16 : NULL);
    if (!rest) return 0;
    if (*rest == ':') {
        if (*++rest < '1' || *rest > '9') return 0;
        for (unsigned p = 0; *rest >= '0' && *rest <= '9'; )
            if ((p = p * 10u + (unsigned)(*rest++ - '0')) > 65535u) return 0;
    }
    return *rest == '\0' || *rest == '/' || *rest == '?' || *rest == '#';
}
static char *build_init_script(unsigned port, const char *token) {
    char *tok_lit = json_escape_string(token);
    if (!tok_lit) return NULL;
    static const char tmpl[] =
        "(() => {\n"
        "  const _fetch = window.fetch.bind(window), _jsonStringify = JSON.stringify, _btoa = window.btoa.bind(window);\n"
        "  const ORB_LOCALD_URL = \"http://127.0.0.1:%u/__orb_rpc\", ORB_EVENTS_URL = \"http://127.0.0.1:%u/__orb_events\", ORB_TOKEN = %s;\n"
        "  class Channel { constructor() { this.onmessage = () => {}; } }\n"
        "  const listeners = new Map(), channels = new Map(); let streamCtrl = null, ps = 10000;\n"
        "  const emit = (name, payload) => { const s = listeners.get(name); if (s) for (const h of Array.from(s)) { try { h({ event: name, payload }); } catch {} } };\n"
        "  const dispatch = (ev) => { if (ev && typeof ev === 'object') { if (typeof ev.event === 'string') emit(ev.event, ev.payload); else if (typeof ev.token === 'number') channels.get(ev.token)?.onmessage(ev.payload); } };\n"
        "  const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return _btoa(s); };\n"
        "  window.__ORB_EMIT__ = emit;\n"
        "  window.__ORB_PINCH__ = (ph, x16, y16, s10k, dx16, dy16) => {\n"
        "    if (ph === 0) { ps = s10k > 0 ? s10k : 10000; return; } if (ph !== 1 || s10k <= 0 || ps <= 0) return;\n"
        "    const x = x16 / 16, y = y16 / 16, el = document.elementFromPoint(x, y) || document.documentElement;\n"
        "    if (s10k !== ps) { const dy = -Math.log(s10k / ps) * 100; ps = s10k; el.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, ctrlKey: true, clientX: x, clientY: y, deltaY: dy })); }\n"
        "    if ((dx16 || dy16) && el.closest('.mermaid-stage, .image-viewport')) el.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, clientX: x, clientY: y, deltaX: -dx16 / 16, deltaY: -dy16 / 16 }));\n"
        "  };\n"
        "  async function drain() {\n"
        "    if (!channels.size) return;\n"
        "    try { const r = await _fetch(ORB_LOCALD_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN }, body: _jsonStringify({ command: '__orb_poll_events', args: { tokens: Array.from(channels.keys()) } }) }); const b = await r.json(); if (Array.isArray(b.result)) for (const ev of b.result) dispatch(ev); } catch {}\n"
        "  }\n"
        "  const stopStream = () => { if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; } };\n"
        "  function ensureStream() {\n"
        "    if (streamCtrl || (!channels.size && !listeners.size)) return;\n"
        "    const ctrl = streamCtrl = new AbortController();\n"
        "    (async () => {\n"
        "      while (!ctrl.signal.aborted && (channels.size || listeners.size)) {\n"
        "        try {\n"
        "          const r = await _fetch(ORB_EVENTS_URL, { headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN }, signal: ctrl.signal }); if (!r.ok || !r.body) throw new Error('sse');\n"
        "          const rd = r.body.getReader(), dec = new TextDecoder(); let buf = '';\n"
        "          while (!ctrl.signal.aborted && (channels.size || listeners.size)) {\n"
        "            const { value, done } = await rd.read(); if (done) break; buf += dec.decode(value, { stream: true }); let idx;\n"
        "            while ((idx = buf.indexOf('\\n\\n')) >= 0) { const fr = buf.slice(0, idx); buf = buf.slice(idx + 2); for (const ln of fr.split('\\n')) if (ln.startsWith('data: ')) { const a = JSON.parse(ln.slice(6)); if (Array.isArray(a)) for (const ev of a) dispatch(ev); } }\n"
        "          }\n"
        "        } catch { if (ctrl.signal.aborted || (!channels.size && !listeners.size)) break; await new Promise(w => setTimeout(w, 1500)); if (!ctrl.signal.aborted && channels.size) await drain(); }\n"
        "      }\n"
        "      if (streamCtrl === ctrl) streamCtrl = null;\n"
        "    })();\n"
        "  }\n"
        "  async function invoke(command, args = {}, options = {}) {\n"
        "    const isBin = args instanceof Uint8Array || args instanceof ArrayBuffer, clean = isBin ? { __binaryBase64: b64(args instanceof Uint8Array ? args : new Uint8Array(args)), __headers: options?.headers || {} } : { ...(args || {}) };\n"
        "    let bound = null; if (!isBin && clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; } if (!isBin && options?.headers && typeof options.headers === 'object') clean.__headers = { ...options.headers };\n"
        "    if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') { channels.delete(clean.token); if (!channels.size && !listeners.size) stopStream(); }\n"
        "    let r; for (let i = 0; ; i++) { try { r = await _fetch(ORB_LOCALD_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN }, body: _jsonStringify({ command, args: clean }) }); break; } catch (e) { if (i >= 8) throw e; await new Promise(w => setTimeout(w, 75)); } }\n"
        "    const b = await r.json(); if (!r.ok || b.error) throw new Error(b.error || command); if (bound && typeof b.result === 'number') { channels.set(b.result, bound); void drain(); ensureStream(); } return b.result;\n"
        "  }\n"
        "  async function listen(n, h) { if (!listeners.has(n)) listeners.set(n, new Set()); listeners.get(n).add(h); ensureStream(); return () => { listeners.get(n)?.delete(h); if (!listeners.get(n)?.size) listeners.delete(n); if (!channels.size && !listeners.size) stopStream(); }; }\n"
        "  window.__TAURI_INTERNALS__ = { invoke }; window.__ORB_DESKTOP__ = window.__TAURI__ = { core: { invoke, Channel }, event: { listen },\n"
        "    window: { getCurrentWindow: () => ({ innerSize: async () => { const s = window.devicePixelRatio || 1; return { width: Math.round(window.innerWidth * s), height: Math.round(window.innerHeight * s) }; }, scaleFactor: async () => window.devicePixelRatio || 1 }) }, webview: { getCurrentWebview: () => ({ label: 'main' }) } };\n"
        "})();\n";
    size_t need = sizeof(tmpl) + strlen(tok_lit) + 64;
    char *buf = malloc(need);
    if (buf) snprintf(buf, need, tmpl, port, port, tok_lit);
    return free(tok_lit), buf;
}
#if defined(ORB_HAS_WEBKITGTK)
static gboolean on_wv_event(GtkWidget *wv, GdkEvent *ev, gpointer ud) {
    (void)ud;
    guint *st = (ev->type == GDK_KEY_PRESS || ev->type == GDK_KEY_RELEASE) ? &ev->key.state :
                (ev->type == GDK_BUTTON_PRESS || ev->type == GDK_BUTTON_RELEASE) ? &ev->button.state : (ev->type == GDK_SCROLL) ? &ev->scroll.state : NULL;
    if (st && (*st & (GDK_SUPER_MASK | GDK_MOD4_MASK)) && !(*st & GDK_CONTROL_MASK)) *st |= GDK_META_MASK;
    if (ev->type != GDK_TOUCHPAD_PINCH) return FALSE;
    const GdkEventTouchpadPinch *p = &ev->touchpad_pinch;
    if (p->phase == GDK_TOUCHPAD_GESTURE_PHASE_BEGIN || p->phase == GDK_TOUCHPAD_GESTURE_PHASE_UPDATE) {
        char js[160];
        snprintf(js, sizeof(js), "window.__ORB_PINCH__&&window.__ORB_PINCH__(%d,%ld,%ld,%ld,%ld,%ld)",
            (int)p->phase, (long)(p->x * 16.0), (long)(p->y * 16.0), (long)(p->scale * 10000.0), (long)(p->dx * 16.0), (long)(p->dy * 16.0));
        webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(wv), js, -1, NULL, NULL, NULL, NULL, NULL);
    }
    return TRUE;
}
static gboolean on_decide_policy(WebKitWebView *wv, WebKitPolicyDecision *dec, WebKitPolicyDecisionType dtype, gpointer ud) {
    (void)wv; (void)ud;
    if (dtype == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION || dtype == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        WebKitNavigationAction *act = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(dec));
        const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(act));
        if (dtype == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION || !is_confined_shell_uri(uri))
            return webkit_policy_decision_ignore(dec), TRUE;
    }
    return FALSE;
}
#endif
int main(int argc, char **argv) {
    unsigned port = 19479;
    const char *port_env = getenv("ORB_LOCALD_PORT");
    if (port_env && *port_env && !parse_valid_port(port_env, &port))
        return fprintf(stderr, "orb-linux-shell: invalid ORB_LOCALD_PORT\n"), 1;
    char eph_tok[65], *init_js = NULL;
    const char *token = getenv("ORB_LOCALD_TOKEN");
    if (!token || strlen(token) < 32 || strcmp(token, "orb-locald-default-token") == 0) {
        if (gen_csprng_hex(eph_tok) != 0) return 1;
        token = eph_tok;
    }
    if (!(init_js = build_init_script(port, token))) return 1;
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        int ok = strstr(init_js, "__ORB_DESKTOP__") != NULL && strstr(init_js, "__ORB_EMIT__") != NULL && strstr(init_js, "__ORB_PINCH__") != NULL &&
                 strstr(init_js, "/__orb_events") != NULL && strstr(init_js, "setInterval") == NULL &&
                 strstr(init_js, "const _fetch = window.fetch.bind(window)") != NULL && is_confined_shell_uri("http://127.0.0.1:1430") &&
                 is_confined_shell_uri("http://localhost/") && !is_confined_shell_uri("http://127.0.0.1:80@evil.com/") && !is_confined_shell_uri("https://evil.example");
        return free(init_js), ok ? (printf("orb-linux-shell self-test: ok\n"), 0) : 1;
    }
    pid_t parent_pid = getpid(), locald_pid = -1;
    const char *locald_bin = getenv("ORB_LOCALD_BIN");
    if (locald_bin && *locald_bin && (locald_pid = fork()) == 0) {
        static const char *const keep[] = { "HOME", "PATH", "TMPDIR", "USER", "LANG", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "HF_HUB_CACHE", "ORB_STATE_DIR", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR", "NIX_SSL_CERT_FILE", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "ORB_VOICE_FAKE", "ORB_VOICE_WORKER", "ORB_VOICE_PYTHON", "ORB_VOICE_MODEL_DIR", "ORB_VOICE_SOCKET", "VOICED_SOCKET", "VOICED_HOME", "VOICED_COHERE_LIB", "VK_ICD_FILENAMES", "VK_DRIVER_FILES" };
        enum { KEEP_N = sizeof(keep) / sizeof(keep[0]) }; static char kv[KEEP_N][32768];
        char pkv[40], ppkv[40], tkv[4200], *envp[KEEP_N + 4]; size_t n = 0;
        snprintf(pkv, sizeof(pkv), "ORB_LOCALD_PORT=%u", port); envp[n++] = pkv;
        snprintf(ppkv, sizeof(ppkv), "ORB_PARENT_PID=%ld", (long)parent_pid); envp[n++] = ppkv;
        snprintf(tkv, sizeof(tkv), "ORB_LOCALD_TOKEN=%s", token); envp[n++] = tkv;
        for (size_t i = 0; i < KEEP_N; ++i) { const char *v = getenv(keep[i]); if (v && (size_t)snprintf(kv[i], sizeof(kv[i]), "%s=%s", keep[i], v) < sizeof(kv[i])) envp[n++] = kv[i]; }
        envp[n] = NULL; execle(locald_bin, locald_bin, (char *)NULL, envp); _exit(127);
    }
#if defined(ORB_HAS_WEBKITGTK)
    g_set_prgname("orb-desktop"); g_setenv("GTK_USE_PORTAL", "1", FALSE); gtk_init(&argc, &argv);
    GtkSettings *gs = gtk_settings_get_default(); gint xft_dpi = -1;
    if (gs && (g_object_get(gs, "gtk-xft-dpi", &xft_dpi, NULL), xft_dpi <= 0)) g_object_set(gs, "gtk-xft-dpi", 96 * 1024, NULL);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL); GdkScreen *scr = gtk_widget_get_screen(win);
    gtk_window_set_default_icon_name("orb"); gtk_window_set_title(GTK_WINDOW(win), "Orb"); gtk_window_set_default_size(GTK_WINDOW(win), 1470, 923);
    if (scr && gdk_screen_get_resolution(scr) <= 0.0) gdk_screen_set_resolution(scr, 96.0);
    GdkVisual *rgba = (scr && gdk_screen_is_composited(scr)) ? gdk_screen_get_rgba_visual(scr) : NULL;
    if (rgba) {
        gtk_widget_set_visual(win, rgba); gtk_widget_set_app_paintable(win, TRUE); GtkCssProvider *css = gtk_css_provider_new();
        gtk_css_provider_load_from_data(css, "window, window.background { background-color: rgba(0,0,0,0); background-image: none; }", -1, NULL);
        gtk_style_context_add_provider_for_screen(scr, GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION); g_object_unref(css);
    }
    GdkGeometry geom = { .min_width = 720, .min_height = 480 }; gtk_window_set_geometry_hints(GTK_WINDOW(win), NULL, &geom, GDK_HINT_MIN_SIZE);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    WebKitMemoryPressureSettings *mp = webkit_memory_pressure_settings_new(); webkit_memory_pressure_settings_set_memory_limit(mp, 512);
    webkit_memory_pressure_settings_set_conservative_threshold(mp, 0.35); webkit_memory_pressure_settings_set_strict_threshold(mp, 0.60);
    webkit_memory_pressure_settings_set_kill_threshold(mp, 0.0); webkit_website_data_manager_set_memory_pressure_settings(mp);
    WebKitWebContext *ctx = g_object_new(WEBKIT_TYPE_WEB_CONTEXT, "memory-pressure-settings", mp, NULL); webkit_memory_pressure_settings_free(mp);
    webkit_web_context_set_cache_model(ctx, WEBKIT_CACHE_MODEL_DOCUMENT_BROWSER);
    static const gchar *const allow_list[] = { "http://127.0.0.1/*", "http://localhost/*", "file:///*", NULL };
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    WebKitUserScript *script = webkit_user_script_new(init_js, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, allow_list, NULL);
    webkit_user_content_manager_add_script(ucm, script); webkit_user_script_unref(script);
    GtkWidget *wv = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", ctx, "user-content-manager", ucm, NULL); g_object_unref(ctx); g_object_unref(ucm);
    WebKitSettings *wks = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(wv)); webkit_settings_set_hardware_acceleration_policy(wks, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS);
    g_object_set(wks, "enable-media-stream", TRUE, "enable-webaudio", TRUE, "media-playback-requires-user-gesture", FALSE, NULL);
    const GdkRGBA bg = rgba ? (GdkRGBA){ 0, 0, 0, 0 } : (GdkRGBA){ 0.078, 0.078, 0.078, 1 }; webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(wv), &bg);
    g_signal_connect(wv, "event", G_CALLBACK(on_wv_event), NULL); g_signal_connect(wv, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    gtk_container_add(GTK_CONTAINER(win), wv); const char *url = getenv("ORB_DEV_URL");
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), (url && is_confined_shell_uri(url)) ? url : "http://127.0.0.1:1430");
    gtk_widget_show_all(win); gtk_main();
#else
    (void)argc; (void)argv;
#endif
    free(init_js);
    if (locald_pid > 0) { kill(locald_pid, SIGTERM); waitpid(locald_pid, NULL, 0); }
    return 0;
}
