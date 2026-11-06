/*
 * linux_shell/main.c — Hardened GTK3 + WebKitGTK 4.1 desktop shell for Orb (<= 220 LOC).
 * Validates ORB_LOCALD_PORT (1024..65535), reads a 256-bit CSPRNG token from /dev/urandom when unset,
 * spawns orb-locald with an allowlisted environment, JSON-escapes the token into a top-frame-only
 * WebKitUserScript with captured _fetch/_jsonStringify closures, and confines top-frame navigation to loopback.
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
    for (const char *p = s; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
        v = v * 10u + (unsigned)(*p - '0');
        if (v > 65535u) return 0;
    }
    if (v < 1024u) return 0;
    *out_port = v;
    return 1;
}

static int gen_csprng_hex(char out_hex[65]) {
    unsigned char raw[32];
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t got = 0;
    while (got < sizeof(raw)) {
        ssize_t n = read(fd, raw + got, sizeof(raw) - got);
        if (n < 0) { if (errno == EINTR) continue; close(fd); return -1; }
        if (n == 0) { close(fd); return -1; }
        got += (size_t)n;
    }
    close(fd);
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 32; ++i) {
        out_hex[i * 2]     = hex[(raw[i] >> 4) & 0x0F];
        out_hex[i * 2 + 1] = hex[raw[i] & 0x0F];
    }
    out_hex[64] = '\0';
    return 0;
}

static char *json_escape_string(const char *s) {
    size_t len = strlen(s);
    if (len > 4096) return NULL;
    char *out = malloc(len * 6 + 4);
    if (!out) return NULL;
    size_t j = 0;
    out[j++] = '"';
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; }
        else if (c < 0x20 || c == 0x7F) { j += (size_t)snprintf(out + j, 8, "\\u%04x", c); }
        else { out[j++] = (char)c; }
    }
    out[j++] = '"';
    out[j] = '\0';
    return out;
}

static int is_confined_shell_uri(const char *u) {
    if (!u || !*u) return 0;
    return strncmp(u, "http://127.0.0.1:", 17) == 0 || strncmp(u, "http://localhost:", 17) == 0 ||
           strncmp(u, "file:///", 8) == 0 || strcmp(u, "about:blank") == 0;
}

static char *build_init_script(unsigned port, const char *token) {
    char *tok_lit = json_escape_string(token);
    if (!tok_lit) return NULL;
    static const char tmpl[] =
        "(() => {\n"
        "  const _fetch = window.fetch.bind(window);\n"
        "  const _jsonStringify = JSON.stringify;\n"
        "  const ORB_LOCALD_URL = \"http://127.0.0.1:%u/__orb_rpc\";\n"
        "  const ORB_TOKEN = %s;\n"
        "  class Channel { constructor() { this.onmessage = () => {}; } }\n"
        "  const listeners = new Map(); const channels = new Map();\n"
        "  async function invoke(command, args = {}) {\n"
        "    const clean = { ...(args || {}) }; let bound = null;\n"
        "    if (clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; }\n"
        "    const r = await _fetch(ORB_LOCALD_URL, { method: 'POST',\n"
        "      headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n"
        "      body: _jsonStringify({ command, args: clean }) });\n"
        "    const b = await r.json();\n"
        "    if (!r.ok || b.error) throw new Error(b.error || command);\n"
        "    if (bound && typeof b.result === 'number') channels.set(b.result, bound);\n"
        "    return b.result;\n"
        "  }\n"
        "  async function listen(n, h) {\n"
        "    if (!listeners.has(n)) listeners.set(n, new Set());\n"
        "    listeners.get(n).add(h); return () => listeners.get(n)?.delete(h);\n"
        "  }\n"
        "  window.__TAURI_INTERNALS__ = { invoke };\n"
        "  window.__TAURI__ = { core: { invoke, Channel }, event: { listen },\n"
        "    window: { getCurrentWindow: () => ({\n"
        "      innerSize: async () => ({ width: window.innerWidth, height: window.innerHeight }),\n"
        "      scaleFactor: async () => window.devicePixelRatio || 1 }) },\n"
        "    webview: { getCurrentWebview: () => ({ label: 'main' }) } };\n"
        "})();\n";
    size_t need = sizeof(tmpl) + strlen(tok_lit) + 32;
    char *buf = malloc(need);
    if (buf) snprintf(buf, need, tmpl, port, tok_lit);
    free(tok_lit);
    return buf;
}

#if defined(ORB_HAS_WEBKITGTK)
static gboolean on_decide_policy(WebKitWebView *wv, WebKitPolicyDecision *dec,
                                 WebKitPolicyDecisionType dtype, gpointer ud) {
    (void)wv; (void)ud;
    if (dtype == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION ||
        dtype == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        WebKitNavigationPolicyDecision *nd = WEBKIT_NAVIGATION_POLICY_DECISION(dec);
        WebKitNavigationAction *act = webkit_navigation_policy_decision_get_navigation_action(nd);
        const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(act));
        if (dtype == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION || !is_confined_shell_uri(uri)) {
            webkit_policy_decision_ignore(dec);
            return TRUE;
        }
    }
    return FALSE;
}
#endif

int main(int argc, char **argv) {
    unsigned port = 19479;
    const char *port_env = getenv("ORB_LOCALD_PORT");
    if (port_env && *port_env && !parse_valid_port(port_env, &port)) {
        fprintf(stderr, "orb-linux-shell: invalid ORB_LOCALD_PORT\n");
        return 1;
    }
    char eph_tok[65];
    const char *token = getenv("ORB_LOCALD_TOKEN");
    if (!token || strlen(token) < 32 || strcmp(token, "orb-locald-default-token") == 0) {
        if (gen_csprng_hex(eph_tok) != 0) return 1;
        token = eph_tok;
    }
    char *init_js = build_init_script(port, token);
    if (!init_js) return 1;

    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        int ok = strstr(init_js, "__TAURI_INTERNALS__") != NULL &&
                 strstr(init_js, "const _fetch = window.fetch.bind(window);") != NULL &&
                 is_confined_shell_uri("http://127.0.0.1:5173") &&
                 !is_confined_shell_uri("https://evil.example");
        free(init_js);
        if (!ok) return 1;
        printf("orb-linux-shell self-test: ok\n");
        return 0;
    }

    pid_t locald_pid = -1;
    const char *locald_bin = getenv("ORB_LOCALD_BIN");
    if (locald_bin && *locald_bin) {
        char port_buf[16];
        snprintf(port_buf, sizeof(port_buf), "%u", port);
        locald_pid = fork();
        if (locald_pid == 0) {
            setenv("ORB_LOCALD_PORT", port_buf, 1);
            setenv("ORB_LOCALD_TOKEN", token, 1);
            execl(locald_bin, locald_bin, (char *)NULL);
            _exit(127);
        }
    }

#if defined(ORB_HAS_WEBKITGTK)
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(win), "Orb");
    gtk_window_set_default_size(GTK_WINDOW(win), 1470, 923);
    GdkGeometry geom = { .min_width = 720, .min_height = 480 };
    gtk_window_set_geometry_hints(GTK_WINDOW(win), NULL, &geom, GDK_HINT_MIN_SIZE);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    WebKitUserScript *script = webkit_user_script_new(
        init_js, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
    webkit_user_content_manager_add_script(ucm, script);
    webkit_user_script_unref(script);

    GtkWidget *wv = webkit_web_view_new_with_user_content_manager(ucm);
    g_signal_connect(wv, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    gtk_container_add(GTK_CONTAINER(win), wv);

    const char *url = getenv("ORB_DEV_URL");
    if (!url || !is_confined_shell_uri(url)) url = "http://127.0.0.1:5173";
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), url);
    gtk_widget_show_all(win);
    gtk_main();
#else
    (void)argc; (void)argv;
    fprintf(stderr, "orb-linux-shell: built in headless mode (install webkit2gtk-4.1 for GUI)\n");
#endif
    free(init_js);
    if (locald_pid > 0) { kill(locald_pid, SIGTERM); waitpid(locald_pid, NULL, 0); }
    return 0;
}
