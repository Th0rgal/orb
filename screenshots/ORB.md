# Orb README screenshots

Captured from Orb, not generated mockups. Only cropping and WebP compression
were applied; the UI and conversation content were not retouched.

- `orb-desktop.webp`: native macOS Orb, Verity mission
  `ebb2f1fe-8d03-4cc0-b966-68b3cb86077f`, selected by the operator.
- `orb-setup.webp`: native New Agent form, before submission.
- Both desktop captures use the actual forest wallpaper on Desktop 6, with a
  1120 × 740 point window and a 1240 × 840 point capture around it.
- `orb-ios.webp`: iPhone 13 mini Simulator, captured by
  `OrbFlowUITests/testRichChatGPTConversationAndReopen` on 2026-09-27.
  The conversation is served by `ios_dashboard/TestsSupport/orb_fixture_server.py`
  using `fixtures/chatgpt-rich.md`. This is a rendering fixture, not a live
  provider response. The test passed, including reopening the conversation and
  previewing its image artifact.

The bounded live ChatGPT README demo also completed successfully (mission
`f3d62473-832d-45ea-8316-ea7ff55493fb`), but it is not pictured here.
