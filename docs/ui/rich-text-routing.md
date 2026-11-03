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

## Glued opening code fences

Agents occasionally emit an opening triple-backtick code fence directly at the
end of a prose sentence without a preceding newline (for example
`Let's present the updated diagram cleanly!```mermaid`), which would otherwise
miss line-initial fence detection and turn the closing ```` ``` ```` into an
opening code block that swallows trailing prose.

Desktop (`orb/src/codeFences.ts`), iOS (`OrbCodeFences.swift`), and Android
(`OrbCodeFences.kt`) normalize admitted glued opening fences onto their own line
outside existing code fences before block parsing and loose pipe-table
normalization, and recognize them in the checkpointed incremental streaming
scanners (`incrementalMarkdown`, `OrbStreamCommit`, `OrbStreamBlocks`) so
streamed prefixes remain equivalent to full parses in linear time. Shared cases
live in `shared/orb-spec/fixtures/glued-code-fences.json`.
