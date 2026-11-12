/*
 * linux_shell/main.c — Hardened GTK4 + WebKitGTK 6.0 desktop shell for Orb (<= 220 LOC).
 * Serves ORB_UI_ROOT over `tauri://localhost/`, spawns orb-locald with PDEATHSIG, pauses animations unfocused, and confines navigation.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(ORB_HAS_WEBKITGTK)
#include <glib-unix.h>
#include <gtk/gtk.h>
#include <webkit/webkit.h>
#endif
static int parse_valid_port(const char *s, unsigned *out_port) {
    if (!s || !*s) return 0;
    unsigned v = 0; for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9' || (v = v * 10u + (unsigned)(*p - '0')) > 65535u) return 0;
    return v >= 1024u ? (*out_port = v, 1) : 0;
}
static unsigned pick_ephemeral_port(unsigned fb) {
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); if (s < 0) return fb;
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = 0, .sin_addr = { .s_addr = htonl(INADDR_LOOPBACK) } }; socklen_t sl = sizeof(sa);
    unsigned p = (bind(s, (struct sockaddr *)&sa, sizeof(sa)) == 0 && getsockname(s, (struct sockaddr *)&sa, &sl) == 0) ? ntohs(sa.sin_port) : fb;
    return close(s), p >= 1024u ? p : fb;
}
static int gen_csprng_hex(char out_hex[65]) {
    unsigned char raw[32]; int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC); if (fd < 0) return -1;
    for (size_t got = 0; got < sizeof(raw); ) { ssize_t n = read(fd, raw + got, sizeof(raw) - got); if (n < 0 && errno == EINTR) continue; if (n <= 0) return close(fd), -1; got += (size_t)n; }
    close(fd); static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) { out_hex[i * 2] = hex[(raw[i] >> 4) & 0x0F]; out_hex[i * 2 + 1] = hex[raw[i] & 0x0F]; }
    return out_hex[64] = '\0', 0;
}
static char *json_escape_string(const char *s) {
    size_t len = strlen(s), j = 0; char *out = len <= 4096 ? malloc(len * 6 + 4) : NULL; if (!out) return NULL;
    out[j++] = '"';
    for (size_t i = 0; i < len; ++i) { unsigned char c = (unsigned char)s[i]; if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; } else if (c < 0x20 || c == 0x7F) j += (size_t)snprintf(out + j, 8, "\\u%04x", c); else out[j++] = (char)c; }
    return out[j++] = '"', out[j] = '\0', out;
}
static int is_confined_shell_uri(const char *u) {
    if (!u || !*u) return 0;
    if (strncmp(u, "file:///", 8) == 0 || strcmp(u, "about:blank") == 0) return 1;
    if (strncmp(u, "tauri://localhost", 17) == 0) { char c = u[17]; return c == '\0' || c == '/' || c == '?' || c == '#'; }
    const char *rest = strncmp(u, "http://127.0.0.1", 16) == 0 ? u + 16 : (strncmp(u, "http://localhost", 16) == 0 ? u + 16 : NULL);
    if (!rest) return 0;
    if (*rest == ':') {
        if (*++rest < '1' || *rest > '9') return 0;
        for (unsigned p = 0; *rest >= '0' && *rest <= '9'; ) if ((p = p * 10u + (unsigned)(*rest++ - '0')) > 65535u) return 0;
    }
    return *rest == '\0' || *rest == '/' || *rest == '?' || *rest == '#';
}
static void focus_hypr_class(const char *cls) {
    const char *rt = getenv("XDG_RUNTIME_DIR"), *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE"); struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (!rt || !*rt || !sig || !*sig || (size_t)snprintf(a.sun_path, sizeof(a.sun_path), "%s/hypr/%s/.socket.sock", rt, sig) >= sizeof(a.sun_path)) return;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) { char cmd[128]; int n = snprintf(cmd, sizeof(cmd), "dispatch focuswindow class:^%s$", cls); if (n > 0) (void)send(fd, cmd, (size_t)n, MSG_NOSIGNAL); }
    if (fd >= 0) close(fd);
}
static char *build_init_script(unsigned port, const char *token) {
    char *tok_lit = json_escape_string(token); if (!tok_lit) return NULL;
    static const char tmpl[] =
        "(() => { if (document.documentElement) document.documentElement.dataset.platform = 'linux'; let sup = false; const isSup = (e) => e.key === 'Meta' || e.key === 'Super' || e.code === 'MetaLeft' || e.code === 'MetaRight' || e.code === 'OSLeft' || e.code === 'OSRight';\n"
        "  window.addEventListener('keydown', (e) => { if (isSup(e)) sup = true; }, true); window.addEventListener('keyup', (e) => { if (isSup(e)) sup = false; }, true); window.addEventListener('blur', () => { sup = false; }, true);\n"
        "  for (const P of [KeyboardEvent.prototype, MouseEvent.prototype]) { const d = Object.getOwnPropertyDescriptor(P, 'metaKey'); if (d?.get) Object.defineProperty(P, 'metaKey', { configurable: true, enumerable: true, get() { return d.get.call(this) || ((sup || !!this.getModifierState?.('Super')) && !this.ctrlKey); } }); }\n"
        "  const _fetch = window.fetch.bind(window), _jsonStringify = JSON.stringify, _btoa = window.btoa.bind(window);\n"
        "  const ORB_LOCALD_URL = \"http://127.0.0.1:%u/__orb_rpc\", ORB_EVENTS_URL = \"http://127.0.0.1:%u/__orb_events\", ORB_TOKEN = %s;\n"
        "  class Channel { constructor() { this.onmessage = () => {}; } } const listeners = new Map(), channels = new Map(); let streamCtrl = null, ps = 10000;\n"
        "  const emit = (name, payload) => { const s = listeners.get(name); if (s) for (const h of Array.from(s)) { try { h({ event: name, payload }); } catch {} } };\n"
        "  const dispatch = (ev) => { if (ev && typeof ev === 'object') { if (typeof ev.event === 'string') emit(ev.event, ev.payload); else if (typeof ev.token === 'number') channels.get(ev.token)?.onmessage(ev.payload); } };\n"
        "  const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return _btoa(s); }; window.__ORB_EMIT__ = emit;\n"
        "  window.__ORB_PINCH__ = (ph, x16, y16, s10k, dx16, dy16) => { if (ph === 0) { ps = s10k > 0 ? s10k : 10000; return; } if (ph !== 1 || s10k <= 0 || ps <= 0) return;\n"
        "    const x = x16 / 16, y = y16 / 16, el = document.elementFromPoint(x, y) || document.documentElement;\n"
        "    if (s10k !== ps) { const dy = -Math.log(s10k / ps) * 100; ps = s10k; el.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, ctrlKey: true, clientX: x, clientY: y, deltaY: dy })); }\n"
        "    if ((dx16 || dy16) && el.closest('.mermaid-stage, .image-viewport')) el.dispatchEvent(new WheelEvent('wheel', { bubbles: true, cancelable: true, clientX: x, clientY: y, deltaX: -dx16 / 16, deltaY: -dy16 / 16 })); };\n"
        "  async function drain() { if (!channels.size) return; try { const r = await _fetch(ORB_LOCALD_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN }, body: _jsonStringify({ command: '__orb_poll_events', args: { tokens: Array.from(channels.keys()) } }) }); const b = await r.json(); if (Array.isArray(b.result)) for (const ev of b.result) dispatch(ev); } catch {} }\n"
        "  const stopStream = () => { if (streamCtrl) { streamCtrl.abort(); streamCtrl = null; } };\n"
        "  function ensureStream() { if (streamCtrl || (!channels.size && !listeners.size)) return; const ctrl = streamCtrl = new AbortController(); (async () => {\n"
        "    while (!ctrl.signal.aborted && (channels.size || listeners.size)) { try {\n"
        "      const r = await _fetch(ORB_EVENTS_URL, { headers: { 'Accept': 'text/event-stream', 'X-Orb-Token': ORB_TOKEN }, signal: ctrl.signal }); if (!r.ok || !r.body) throw new Error('sse');\n"
        "      const rd = r.body.getReader(), dec = new TextDecoder(); let buf = '';\n"
        "      while (!ctrl.signal.aborted && (channels.size || listeners.size)) { const { value, done } = await rd.read(); if (done) break; buf += dec.decode(value, { stream: true }); let idx;\n"
        "        while ((idx = buf.indexOf('\\n\\n')) >= 0) { const fr = buf.slice(0, idx); buf = buf.slice(idx + 2); for (const ln of fr.split('\\n')) if (ln.startsWith('data: ')) { const a = JSON.parse(ln.slice(6)); if (Array.isArray(a)) for (const ev of a) dispatch(ev); } } }\n"
        "    } catch { if (ctrl.signal.aborted || (!channels.size && !listeners.size)) break; await new Promise(w => setTimeout(w, 1500)); if (!ctrl.signal.aborted && channels.size) await drain(); } }\n"
        "    if (streamCtrl === ctrl) streamCtrl = null; })(); }\n"
        "  async function invoke(command, args = {}, options = {}) {\n"
        "    const isBin = args instanceof Uint8Array || args instanceof ArrayBuffer, clean = isBin ? { __binaryBase64: b64(args instanceof Uint8Array ? args : new Uint8Array(args)), __headers: options?.headers || {} } : { ...(args || {}) };\n"
        "    let bound = null; if (!isBin && clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; } if (!isBin && options?.headers && typeof options.headers === 'object') clean.__headers = { ...options.headers };\n"
        "    if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') { channels.delete(clean.token); if (!channels.size && !listeners.size) stopStream(); }\n"
        "    let r; for (let i = 0; ; i++) { try { r = await _fetch(ORB_LOCALD_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN }, body: _jsonStringify({ command, args: clean }) }); break; } catch (e) { if (i >= 8) throw e; await new Promise(w => setTimeout(w, 75)); } }\n"
        "    const b = await r.json(); if (!r.ok || b.error) throw new Error(b.error || command); if (bound && typeof b.result === 'number') { channels.set(b.result, bound); void drain(); ensureStream(); } return b.result; }\n"
        "  async function listen(n, h) { if (!listeners.has(n)) listeners.set(n, new Set()); listeners.get(n).add(h); ensureStream(); return () => { listeners.get(n)?.delete(h); if (!listeners.get(n)?.size) listeners.delete(n); if (!channels.size && !listeners.size) stopStream(); }; }\n"
        "  window.__TAURI_INTERNALS__ = { invoke }; window.__ORB_DESKTOP__ = window.__TAURI__ = { core: { invoke, Channel }, event: { listen }, window: { getCurrentWindow: () => ({ innerSize: async () => { const s = window.devicePixelRatio || 1; return { width: Math.round(window.innerWidth * s), height: Math.round(window.innerHeight * s) }; }, scaleFactor: async () => window.devicePixelRatio || 1 }) }, webview: { getCurrentWebview: () => ({ label: 'main' }) } }; })();\n";
    size_t need = sizeof(tmpl) + strlen(tok_lit) + 64; char *buf = malloc(need);
    if (buf) snprintf(buf, need, tmpl, port, port, tok_lit);
    return free(tok_lit), buf;
}
#if defined(ORB_HAS_WEBKITGTK)
static const char *mime_for_path(const char *p) {
    const char *e = strrchr(p, '.'); if (!e) return "application/octet-stream";
    static const struct { const char *x, *m; } t[] = { {".html","text/html; charset=utf-8"}, {".js","text/javascript; charset=utf-8"}, {".mjs","text/javascript; charset=utf-8"}, {".css","text/css; charset=utf-8"}, {".wasm","application/wasm"}, {".json","application/json; charset=utf-8"}, {".svg","image/svg+xml"}, {".png","image/png"}, {".jpg","image/jpeg"}, {".jpeg","image/jpeg"}, {".webp","image/webp"}, {".ico","image/x-icon"}, {".woff2","font/woff2"}, {".woff","font/woff"}, {".ttf","font/ttf"}, {".map","application/json; charset=utf-8"} };
    for (size_t i = 0; i < sizeof(t) / sizeof(t[0]); ++i) if (g_ascii_strcasecmp(e, t[i].x) == 0) return t[i].m;
    return "application/octet-stream";
}
static void finish_scheme_bytes(WebKitURISchemeRequest *req, guint code, const char *mime, GBytes *bytes, gboolean immut) {
    GInputStream *st = g_memory_input_stream_new_from_bytes(bytes); WebKitURISchemeResponse *resp = webkit_uri_scheme_response_new(st, (gint64)g_bytes_get_size(bytes));
    SoupMessageHeaders *hdr = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE); soup_message_headers_append(hdr, "Access-Control-Allow-Origin", "tauri://localhost");
    soup_message_headers_append(hdr, "Cache-Control", immut ? "public, max-age=31536000, immutable" : "no-cache");
    webkit_uri_scheme_response_set_status(resp, code, code == 200 ? "OK" : "Not Found"); webkit_uri_scheme_response_set_content_type(resp, mime);
    webkit_uri_scheme_response_set_http_headers(resp, hdr); webkit_uri_scheme_request_finish_with_response(req, resp); g_object_unref(resp); g_object_unref(st);
}
static void on_tauri_scheme(WebKitURISchemeRequest *req, gpointer ud) {
    const char *root = (const char *)ud, *uri = webkit_uri_scheme_request_get_uri(req), *path = webkit_uri_scheme_request_get_path(req);
    if (!root || !is_confined_shell_uri(uri)) { GBytes *b = g_bytes_new_static("forbidden", 9); finish_scheme_bytes(req, 403, "text/plain; charset=utf-8", b, FALSE); g_bytes_unref(b); return; }
    while (path && *path == '/') path++;
    const char *rel = (path && *path) ? path : "index.html";
    char rreal[PATH_MAX], creal[PATH_MAX], *joined = g_build_filename(root, rel, NULL); struct stat st;
    gboolean ok = realpath(root, rreal) != NULL && realpath(joined, creal) != NULL && (strcmp(creal, rreal) == 0 || (strncmp(creal, rreal, strlen(rreal)) == 0 && creal[strlen(rreal)] == '/')) && stat(creal, &st) == 0 && S_ISREG(st.st_mode);
    g_free(joined);
    if (!ok && strchr(rel, '.') == NULL) { char *idx = g_build_filename(root, "index.html", NULL); ok = realpath(root, rreal) != NULL && realpath(idx, creal) != NULL && stat(creal, &st) == 0 && S_ISREG(st.st_mode); g_free(idx); }
    gchar *data = NULL; gsize len = 0;
    if (!ok || !g_file_get_contents(creal, &data, &len, NULL)) { GBytes *b = g_bytes_new_static("not found", 9); finish_scheme_bytes(req, 404, "text/plain; charset=utf-8", b, FALSE); g_bytes_unref(b); return; }
    GBytes *b = g_bytes_new_take(data, len);
    finish_scheme_bytes(req, 200, mime_for_path(creal), b, g_str_has_prefix(rel, "assets/") || g_str_has_prefix(rel, "provider-icons/") || g_str_has_suffix(rel, ".woff2") || g_str_has_suffix(rel, ".wasm")); g_bytes_unref(b);
}
static void emit_zoom(GtkGesture *g, int ph, double scale, WebKitWebView *wv) {
    double cx = 0, cy = 0; gtk_gesture_get_bounding_box_center(g, &cx, &cy); char js[160];
    snprintf(js, sizeof(js), "window.__ORB_PINCH__&&window.__ORB_PINCH__(%d,%ld,%ld,%ld,0,0)", ph, (long)(cx * 16.0), (long)(cy * 16.0), (long)(scale * 10000.0));
    webkit_web_view_evaluate_javascript(wv, js, -1, NULL, NULL, NULL, NULL, NULL);
}
static void on_zoom_begin(GtkGesture *g, GdkEventSequence *s, gpointer ud) { (void)s; emit_zoom(g, 0, 1.0, WEBKIT_WEB_VIEW(ud)); }
static void on_zoom_scale(GtkGestureZoom *z, double sc, gpointer ud) { emit_zoom(GTK_GESTURE(z), 1, sc, WEBKIT_WEB_VIEW(ud)); }
static void on_win_active(GObject *w, GParamSpec *p, gpointer ud) { (void)p; webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(ud), gtk_window_is_active(GTK_WINDOW(w)) ? "document.documentElement&&(document.documentElement.dataset.windowFocused='true')" : "document.documentElement&&(document.documentElement.dataset.windowFocused='false')", -1, NULL, NULL, NULL, NULL, NULL); }
static gboolean on_perm_req(WebKitWebView *wv, WebKitPermissionRequest *req, gpointer ud) {
    (void)ud; if (!is_confined_shell_uri(webkit_web_view_get_uri(wv)) || !WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST(req)) return FALSE;
    WebKitUserMediaPermissionRequest *um = WEBKIT_USER_MEDIA_PERMISSION_REQUEST(req);
    return (webkit_user_media_permission_is_for_audio_device(um) && !webkit_user_media_permission_is_for_video_device(um) && !webkit_user_media_permission_is_for_display_device(um)) ? (webkit_permission_request_allow(req), TRUE) : FALSE;
}
static gboolean on_decide_policy(WebKitWebView *wv, WebKitPolicyDecision *dec, WebKitPolicyDecisionType dtype, gpointer ud) {
    (void)wv; (void)ud; if (dtype != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && dtype != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) return FALSE;
    WebKitNavigationAction *act = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(dec));
    return (dtype == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION || !is_confined_shell_uri(webkit_uri_request_get_uri(webkit_navigation_action_get_request(act)))) ? (webkit_policy_decision_ignore(dec), TRUE) : FALSE;
}
static gboolean on_close_req(GtkWindow *w, gpointer ud) { (void)w; g_main_loop_quit((GMainLoop *)ud); return FALSE; }
static gboolean on_quit_sig(gpointer ud) { g_main_loop_quit((GMainLoop *)ud); return G_SOURCE_REMOVE; }
#endif
int main(int argc, char **argv) {
    const char *port_env = getenv("ORB_LOCALD_PORT"); unsigned port = (port_env && *port_env) ? 0 : pick_ephemeral_port(19479);
    if (port_env && *port_env && !parse_valid_port(port_env, &port)) return fprintf(stderr, "orb-linux-shell: invalid ORB_LOCALD_PORT\n"), 1;
    char eph_tok[65], *init_js = NULL; const char *token = getenv("ORB_LOCALD_TOKEN");
    if (!token || strlen(token) < 32 || strcmp(token, "orb-locald-default-token") == 0) { if (gen_csprng_hex(eph_tok) != 0) return 1; token = eph_tok; }
    if (!(init_js = build_init_script(port, token))) return 1;
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        int ok = strstr(init_js, "__ORB_DESKTOP__") && strstr(init_js, "dataset.platform = 'linux'") && strstr(init_js, "__ORB_EMIT__") && strstr(init_js, "__ORB_PINCH__") && strstr(init_js, "/__orb_events") && strstr(init_js, "setInterval") == NULL && strstr(init_js, "const _fetch = window.fetch.bind(window)") && is_confined_shell_uri("tauri://localhost/") && is_confined_shell_uri("http://127.0.0.1:1430") && !is_confined_shell_uri("tauri://evil.example/") && !is_confined_shell_uri("http://127.0.0.1:80@evil.com/") && !is_confined_shell_uri("https://evil.example");
        return free(init_js), ok ? (printf("orb-linux-shell self-test: ok\n"), 0) : 1;
    }
    const char *dev_url = getenv("ORB_DEV_URL"), *rt_dir = getenv("XDG_RUNTIME_DIR"); int lock_fd = -1;
    if ((!dev_url || !*dev_url) && !getenv("ORB_MULTI_INSTANCE") && rt_dir && *rt_dir) {
        char lp[256]; snprintf(lp, sizeof(lp), "%s/orb-desktop.lock", rt_dir);
        if ((lock_fd = open(lp, O_CREAT | O_RDWR | O_CLOEXEC, 0600)) >= 0 && flock(lock_fd, LOCK_EX | LOCK_NB) != 0) return focus_hypr_class("orb-desktop"), close(lock_fd), free(init_js), 0;
    }
    pid_t parent_pid = getpid(), locald_pid = -1; const char *locald_bin = getenv("ORB_LOCALD_BIN");
    if (locald_bin && *locald_bin && (locald_pid = fork()) == 0) {
        prctl(PR_SET_PDEATHSIG, SIGTERM); if (getppid() != parent_pid) _exit(0);
        static const char *const keep[] = { "HOME", "PATH", "TMPDIR", "USER", "LANG", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "XDG_SESSION_TYPE", "BROWSER", "HF_HUB_CACHE", "ORB_STATE_DIR", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH", "SSL_CERT_FILE", "SSL_CERT_DIR", "NIX_SSL_CERT_FILE", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "ORB_VOICE_FAKE", "ORB_VOICE_WORKER", "ORB_VOICE_PYTHON", "ORB_VOICE_MODEL_DIR", "ORB_VOICE_SOCKET", "VOICED_SOCKET", "VOICED_HOME", "VOICED_COHERE_LIB", "VK_ICD_FILENAMES", "VK_DRIVER_FILES" };
        enum { KEEP_N = sizeof(keep) / sizeof(keep[0]) }; static char kv[KEEP_N][32768]; char pkv[40], ppkv[40], tkv[4200], *envp[KEEP_N + 4]; size_t n = 0;
        snprintf(pkv, sizeof(pkv), "ORB_LOCALD_PORT=%u", port); envp[n++] = pkv; snprintf(ppkv, sizeof(ppkv), "ORB_PARENT_PID=%ld", (long)parent_pid); envp[n++] = ppkv; snprintf(tkv, sizeof(tkv), "ORB_LOCALD_TOKEN=%s", token); envp[n++] = tkv;
        for (size_t i = 0; i < KEEP_N; ++i) { const char *v = getenv(keep[i]); if (v && (size_t)snprintf(kv[i], sizeof(kv[i]), "%s=%s", keep[i], v) < sizeof(kv[i])) envp[n++] = kv[i]; }
        envp[n] = NULL; execle(locald_bin, locald_bin, (char *)NULL, envp); _exit(127);
    }
#if defined(ORB_HAS_WEBKITGTK)
    g_set_prgname("orb-desktop"); g_setenv("GTK_USE_PORTAL", "1", FALSE); gtk_init();
    GMainLoop *loop = g_main_loop_new(NULL, FALSE); g_unix_signal_add(SIGTERM, on_quit_sig, loop); g_unix_signal_add(SIGINT, on_quit_sig, loop); g_unix_signal_add(SIGHUP, on_quit_sig, loop);
    GtkCssProvider *css = gtk_css_provider_new(); gtk_css_provider_load_from_string(css, "window, window.background { background-color: rgba(0,0,0,0); background-image: none; }");
    if (gdk_display_get_default()) gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css); GtkWidget *win = gtk_window_new();
    gtk_window_set_default_icon_name("orb"); gtk_window_set_title(GTK_WINDOW(win), "Orb"); gtk_window_set_default_size(GTK_WINDOW(win), 1470, 923); gtk_widget_set_size_request(win, 720, 480); g_signal_connect(win, "close-request", G_CALLBACK(on_close_req), loop);
    WebKitMemoryPressureSettings *mp = webkit_memory_pressure_settings_new(); webkit_memory_pressure_settings_set_memory_limit(mp, 512); webkit_memory_pressure_settings_set_conservative_threshold(mp, 0.35); webkit_memory_pressure_settings_set_strict_threshold(mp, 0.60); webkit_memory_pressure_settings_set_kill_threshold(mp, 0.0); webkit_network_session_set_memory_pressure_settings(mp); webkit_memory_pressure_settings_free(mp);
    WebKitWebContext *ctx = webkit_web_context_new(); webkit_web_context_set_cache_model(ctx, WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
    WebKitSecurityManager *sm = webkit_web_context_get_security_manager(ctx); webkit_security_manager_register_uri_scheme_as_secure(sm, "tauri"); webkit_security_manager_register_uri_scheme_as_cors_enabled(sm, "tauri");
    const char *ui_root = getenv("ORB_UI_ROOT"); if (!ui_root || !*ui_root) ui_root = getenv("ORB_DIST_DIR"); if (ui_root && *ui_root) webkit_web_context_register_uri_scheme(ctx, "tauri", on_tauri_scheme, (gpointer)ui_root, NULL);
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    WebKitUserScript *script = webkit_user_script_new(init_js, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
    WebKitUserStyleSheet *idle_css = webkit_user_style_sheet_new("html[data-window-focused=\"false\"] *,html[data-window-focused=\"false\"] *::before,html[data-window-focused=\"false\"] *::after{animation-play-state:paused !important;transition:none !important;caret-color:transparent !important;}", WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES, WEBKIT_USER_STYLE_LEVEL_USER, NULL, NULL);
    webkit_user_content_manager_add_script(ucm, script); webkit_user_content_manager_add_style_sheet(ucm, idle_css); webkit_user_script_unref(script); webkit_user_style_sheet_unref(idle_css);
    WebKitSettings *wks = webkit_settings_new(); webkit_settings_set_hardware_acceleration_policy(wks, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS); g_object_set(wks, "enable-media-stream", TRUE, "enable-webaudio", TRUE, "media-playback-requires-user-gesture", FALSE, NULL);
    GtkWidget *wv = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", ctx, "network-session", webkit_network_session_get_default(), "settings", wks, "user-content-manager", ucm, NULL);
    g_object_unref(ctx); g_object_unref(wks); g_object_unref(ucm); webkit_web_view_set_background_color(WEBKIT_WEB_VIEW(wv), &(GdkRGBA){ 0, 0, 0, 0 });
    GtkGesture *zoom = gtk_gesture_zoom_new(); gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(zoom), GTK_PHASE_CAPTURE); g_signal_connect(zoom, "begin", G_CALLBACK(on_zoom_begin), wv); g_signal_connect(zoom, "scale-changed", G_CALLBACK(on_zoom_scale), wv); gtk_widget_add_controller(wv, GTK_EVENT_CONTROLLER(zoom));
    g_signal_connect(win, "notify::is-active", G_CALLBACK(on_win_active), wv); g_signal_connect(wv, "permission-request", G_CALLBACK(on_perm_req), NULL); g_signal_connect(wv, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    gtk_window_set_child(GTK_WINDOW(win), wv); webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), (dev_url && is_confined_shell_uri(dev_url)) ? dev_url : ((ui_root && *ui_root) ? "tauri://localhost/" : "http://127.0.0.1:1430"));
    gtk_window_present(GTK_WINDOW(win)); g_main_loop_run(loop); g_main_loop_unref(loop);
#else
    (void)argc; (void)argv;
#endif
    free(init_js);
    if (locald_pid > 0) {
        kill(locald_pid, SIGTERM); for (int i = 0; i < 25 && waitpid(locald_pid, NULL, WNOHANG) == 0; ++i) usleep(20000);
        if (waitpid(locald_pid, NULL, WNOHANG) == 0) { kill(locald_pid, SIGKILL); waitpid(locald_pid, NULL, 0); }
    }
    if (lock_fd >= 0) close(lock_fd);
    return 0;
}
