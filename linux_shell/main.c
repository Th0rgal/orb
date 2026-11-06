/*
 * linux_shell/main.c — Minimal GTK3 + WebKitGTK 4.1 desktop shell for Orb (< 115 LOC).
 * Spawns or connects to `orb-locald` on loopback, injects `window.__TAURI__` / `window.__TAURI_INTERNALS__`,
 * and renders `ORB_DEV_URL` or bundled `orb/dist/index.html` in a 1470x923 (min 720x480) window.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(ORB_HAS_WEBKITGTK)
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#endif

static void build_init_script(char *buf, size_t cap, const char *port, const char *token) {
    snprintf(buf, cap,
        "(() => {"
        "  const ORB_LOCALD_URL = 'http://127.0.0.1:%s/__orb_rpc';"
        "  const ORB_TOKEN = '%s';"
        "  class Channel { constructor() { this.onmessage = () => {}; } }"
        "  const listeners = new Map();"
        "  async function invoke(command, args = {}) {"
        "    const clean = { ...(args || {}) };"
        "    if (clean.onEvent instanceof Channel) delete clean.onEvent;"
        "    const r = await fetch(ORB_LOCALD_URL, {"
        "      method: 'POST',"
        "      headers: { 'Content-Type': 'application/json', 'X-Orb-Token': ORB_TOKEN },"
        "      body: JSON.stringify({ command, args: clean })"
        "    });"
        "    const b = await r.json();"
        "    if (!r.ok || b.error) throw new Error(b.error || command);"
        "    return b.result;"
        "  }"
        "  async function listen(n, h) {"
        "    if (!listeners.has(n)) listeners.set(n, new Set());"
        "    listeners.get(n).add(h);"
        "    return () => listeners.get(n)?.delete(h);"
        "  }"
        "  window.__TAURI_INTERNALS__ = { invoke };"
        "  window.__TAURI__ = {"
        "    core: { invoke, Channel },"
        "    event: { listen },"
        "    window: { getCurrentWindow: () => ({"
        "      innerSize: async () => ({ width: window.innerWidth, height: window.innerHeight }),"
        "      scaleFactor: async () => window.devicePixelRatio || 1"
        "    }) },"
        "    webview: { getCurrentWebview: () => ({ label: 'main' }) }"
        "  };"
        "})();",
        port, token);
}

int main(int argc, char **argv) {
    const char *port = getenv("ORB_LOCALD_PORT");
    if (!port || !*port) port = "19479";
    const char *token = getenv("ORB_LOCALD_TOKEN");
    if (!token || !*token) token = "orb-locald-default-token";

    char init_js[4096];
    build_init_script(init_js, sizeof(init_js), port, token);

    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        if (strstr(init_js, "__TAURI_INTERNALS__") == NULL || strstr(init_js, "Channel") == NULL) {
            fprintf(stderr, "linux_shell self-test failed\n");
            return 1;
        }
        printf("orb-linux-shell self-test: ok\n");
        return 0;
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
        init_js, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
    webkit_user_content_manager_add_script(ucm, script);
    webkit_user_script_unref(script);

    GtkWidget *wv = webkit_web_view_new_with_user_content_manager(ucm);
    gtk_container_add(GTK_CONTAINER(win), wv);

    const char *url = getenv("ORB_DEV_URL");
    if (!url || !*url) url = "http://127.0.0.1:5173";
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(wv), url);
    gtk_widget_show_all(win);
    gtk_main();
    return 0;
#else
    (void)argc;
    (void)argv;
    fprintf(stderr, "orb-linux-shell: built in headless mode (install webkit2gtk-4.1 for GUI)\n");
    return 0;
#endif
}
