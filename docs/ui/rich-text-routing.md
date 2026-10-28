# Native Markdown and math routing

Native iOS and Android render simple Markdown and pipe tables directly. LaTeX
and embedded images route through the existing WebView renderer. The routing
scanner ignores fenced and inline code and leaves ordinary currency native.
`shared/orb-spec/fixtures/rich-text-routing.json` defines the same cases for both
clients. Inline math must trigger this route on its own, without relying on a
second display formula elsewhere in the message.

The iOS inline detector was inadvertently narrowed in a1a7aade47 while addressing
large-conversation memory use. Restoring the existing detector matches Android's
unchanged scanner. This does not change parsing, the renderer pool or caches.
