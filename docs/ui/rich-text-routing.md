# Native Markdown, math, and image rendering

Mobile iOS and Android render all transcript Markdown, pipe tables, LaTeX math
(`$...$`, `$$...$$`, `\(...\)`, `\[...\]`), and Markdown images (`![alt](url)`)
natively in SwiftUI and Jetpack Compose without mounting `WKWebView` or
`android.webkit.WebView` inside conversation turns.

`shared/orb-spec/fixtures/rich-text-routing.json` defines the shared test cases
for both clients:
- `web` is always `false`: no transcript turn routes to a WebView renderer.
- `rich` records whether `OrbMath.containsMathOrMedia` detects admitted LaTeX
  math or Markdown image syntax outside fenced and inline code spans while
  keeping ordinary currency (`$15 and $20`, `$0.072/hr ... $50`, `\$100`) plain
  prose.

Both `OrbMath` implementations enforce identical resource bounds (`maxDepth = 16`,
`maxSpanChars = 8192`) and degrade incomplete or malformed TeX to readable
monospace spans without throwing.
