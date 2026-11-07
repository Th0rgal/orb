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
    for (const char *p = s; *p; ++p) {
        if (*p < '0' || *p > '9' || (v = v * 10u + (unsigned)(*p - '0')) > 65535u) return 0;
    }
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
    for (size_t i = 0; i < 32; ++i) {
        out_hex[i * 2] = hex[(raw[i] >> 4) & 0x0F];
        out_hex[i * 2 + 1] = hex[raw[i] & 0x0F];
    }
    return out_hex[64] = '\0', 0;
}

static char *json_escape_string(const char *s) {
    size_t len = strlen(s), j = 0;
    if (len > 4096) return NULL;
    char *out = malloc(len * 6 + 4);
    if (!out) return NULL;
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
    if (strncmp(u, "file:///", 8) == 0 || strcmp(u, "about:blank") == 0) return 1;
    const char *rest = strncmp(u, "http://127.0.0.1", 16) == 0 ? u + 16 :
                       (strncmp(u, "http://localhost", 16) == 0 ? u + 16 : NULL);
    if (!rest) return 0;
    if (*rest == ':') {
        if (*++rest < '1' || *rest > '9') return 0;
        for (unsigned p = 0; *rest >= '0' && *rest <= '9'; ) {
            if ((p = p * 10u + (unsigned)(*rest++ - '0')) > 65535u) return 0;
        }
    }
    return *rest == '\0' || *rest == '/' || *rest == '?' || *rest == '#';
}

static char *build_init_script(unsigned port, const char *token) {
    char *tok_lit = json_escape_string(token);
    if (!tok_lit) return NULL;
    static const char tmpl[] =
        "(() => {\n"
        "  const _fetch = window.fetch.bind(window), _jsonStringify = JSON.stringify;\n"
        "  const ORB_LOCALD_URL = \"http://127.0.0.1:%u/__orb_rpc\", ORB_TOKEN = %s;\n"
        "  class Channel { constructor() { this.onmessage = () => {}; } }\n"
        "  const listeners = new Map(), channels = new Map(); let timer = 0;\n"
        "  async function drain() {\n"
        "    if (!channels.size) { if (timer) { clearInterval(timer); timer = 0; } return; }\n"
        "    try {\n"
        "      const r = await _fetch(ORB_LOCALD_URL, { method: 'POST',\n"
        "        headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n"
        "        body: _jsonStringify({ command: '__orb_poll_events', args: {} }) });\n"
        "      const b = await r.json();\n"
        "      if (Array.isArray(b.result)) for (const ev of b.result) channels.get(ev.token)?.onmessage(ev.payload);\n"
        "    } catch {}\n"
        "  }\n"
        "  async function invoke(command, args = {}) {\n"
        "    const clean = { ...(args || {}) }; let bound = null;\n"
        "    if (clean.onEvent instanceof Channel) { bound = clean.onEvent; delete clean.onEvent; }\n"
        "    if (command.endsWith('_unsubscribe') && typeof clean.token === 'number') channels.delete(clean.token);\n"
        "    const r = await _fetch(ORB_LOCALD_URL, { method: 'POST',\n"
        "      headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },\n"
        "      body: _jsonStringify({ command, args: clean }) });\n"
        "    const b = await r.json();\n"
        "    if (!r.ok || b.error) throw new Error(b.error || command);\n"
        "    if (bound && typeof b.result === 'number') {\n"
        "      channels.set(b.result, bound);\n"
        "      if (!timer) timer = setInterval(drain, 250);\n"
        "      void drain();\n"
        "    }\n"
        "    return b.result;\n"
        "  }\n"
        "  async function listen(n, h) {\n"
        "    if (!listeners.has(n)) listeners.set(n, new Set());\n"
        "    listeners.get(n).add(h); return () => listeners.get(n)?.delete(h);\n"
        "  }\n"
        "  window.__TAURI_INTERNALS__ = { invoke };\n"
        "  window.__ORB_DESKTOP__ = window.__TAURI__ = { core: { invoke, Channel }, event: { listen },\n"
        "    window: { getCurrentWindow: () => ({\n"
        "      innerSize: async () => { const s = window.devicePixelRatio || 1; return { width: Math.round(window.innerWidth * s), height: Math.round(window.innerHeight * s) }; },\n"
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
        WebKitNavigationAction *act = webkit_navigation_policy_decision_get_navigation_action(
            WEBKIT_NAVIGATION_POLICY_DECISION(dec));
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
    char eph_tok[65];
    const char *token = getenv("ORB_LOCALD_TOKEN");
    if (!token || strlen(token) < 32 || strcmp(token, "orb-locald-default-token") == 0) {
        if (gen_csprng_hex(eph_tok) != 0) return 1;
        token = eph_tok;
    }
    char *init_js = build_init_script(port, token);
    if (!init_js) return 1;

    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        int ok = strstr(init_js, "__ORB_DESKTOP__") != NULL && strstr(init_js, "__orb_poll_events") != NULL &&
                 strstr(init_js, "const _fetch = window.fetch.bind(window)") != NULL &&
                 is_confined_shell_uri("http://127.0.0.1:5173") && is_confined_shell_uri("http://localhost/") &&
                 !is_confined_shell_uri("http://127.0.0.1:80@evil.com/") && !is_confined_shell_uri("https://evil.example");
        free(init_js);
        return ok ? (printf("orb-linux-shell self-test: ok\n"), 0) : 1;
    }

    pid_t locald_pid = -1;
    const char *locald_bin = getenv("ORB_LOCALD_BIN");
    if (locald_bin && *locald_bin && (locald_pid = fork()) == 0) {
        static const char *const keep[] = { "HOME", "PATH", "TMPDIR", "USER", "LANG", "ORB_SIGNER_BIN", "ORB_APPROVAL_KEY_PATH" };
        char pkv[40], tkv[4200], kv[7][1024], *envp[10];
        size_t n = 0;
        snprintf(pkv, sizeof(pkv), "ORB_LOCALD_PORT=%u", port); envp[n++] = pkv;
        snprintf(tkv, sizeof(tkv), "ORB_LOCALD_TOKEN=%s", token); envp[n++] = tkv;
        for (size_t i = 0; i < 7; ++i) {
            const char *v = getenv(keep[i]);
            if (v && (size_t)snprintf(kv[i], sizeof(kv[i]), "%s=%s", keep[i], v) < sizeof(kv[i])) envp[n++] = kv[i];
        }
        envp[n] = NULL;
        execle(locald_bin, locald_bin, (char *)NULL, envp);
        _exit(127);
    }

#if defined(ORB_HAS_WEBKITGTK)
    gtk_init(&argc, &argv);
    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(win), "Orb");
    gtk_window_set_default_size(GTK_WINDOW(win), 1470, 923);
    GdkGeometry geom = { .min_width = 720, .min_height = 480 };
    gtk_window_set_geometry_hints(GTK_WINDOW(win), NULL, &geom, GDK_HINT_MIN_SIZE);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    static const gchar *const allow_list[] = { "http://127.0.0.1/*", "http://localhost/*", "file:///*", NULL };
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    WebKitUserScript *script = webkit_user_script_new(
        init_js, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, allow_list, NULL);
    webkit_user_content_manager_add_script(ucm, script);
    webkit_user_script_unref(script);

    GtkWidget *wv = webkit_web_view_new_with_user_content_manager(ucm);
    g_signal_connect(wv, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    gtk_container_add(GTK_CONTAINER(win), wv);
    const char *url = getenv("ORB_DEV_URL");
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), (url && is_confined_shell_uri(url)) ? url : "http://127.0.0.1:5173");
    gtk_widget_show_all(win);
    gtk_main();
#else
    (void)argc; (void)argv;
#endif
    free(init_js);
    if (locald_pid > 0) { kill(locald_pid, SIGTERM); waitpid(locald_pid, NULL, 0); }
    return 0;
}
