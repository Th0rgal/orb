# Orb for iOS

Native SwiftUI iOS client for **Orb**, located in `SandboxedDashboard/Orb`.

> **Note:** The iOS target builds `Orb.app` (`PRODUCT_NAME: "Orb"`) and connects to your `sandboxed.sh` backend (`sandboxed.sh` is the former name of the project and is now the backend to the Orb clients).

<p align="center">
  <img src="../screenshots/orb-ios-projects.webp" width="260" alt="Orb on iOS showing the production projects list with synced project colors" />
  &nbsp;&nbsp;&nbsp;
  <img src="../screenshots/orb-ios.webp" width="260" alt="Orb on iOS showing the Pareto mission conversation in Verity" />
</p>

## Features

- **Projects & Synced Colors** (`OrbProjects.swift`, `OrbProjectAppearance.swift`) — Browse projects with synchronized colors, mission trees, and finished groups.
- **Live Conversations & Rich Transcripts** (`OrbConversation.swift`, `OrbRichText.swift`, `OrbMath.swift`, `OrbQuiz.swift`) — Follow real-time SSE streams, expand `Worked — …` tool and thinking folds, answer interactive agent questions (`OrbQuestions.swift`), view KaTeX math and quizzes, and send or queue follow-ups.
- **Shared Project Context & Files** (`OrbDocuments.swift`, `OrbAttachments.swift`, `OrbMessageImages.swift`) — Read and edit synchronized Markdown `@context` files, preview images, and upload attachments.
- **Unified Settings** (`OrbSettings.swift`, `OrbMachinesSettings.swift`, `OrbProvidersSettings.swift`) — Configure your **Backend** connection, manage **Providers** (including CLIProxyAPI OAuth logins and quota inspection), and view **Machines** (registered remote nodes plus the shared `/api/settings/ssh-hosts` address book).

## Requirements

- Xcode 16.0+ (with iOS 26 SDK in CI)
- Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

Generate the Xcode project from `project.yml` and build:

```bash
cd ios_dashboard
xcodegen generate
open SandboxedDashboard.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project SandboxedDashboard.xcodeproj \
  -scheme SandboxedDashboard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

## Xcode Cloud & CI

1. `ci_scripts/ci_post_clone.sh` runs automatically in Xcode Cloud and GitHub Actions (`iOS Build`).
2. It downloads pinned XcodeGen `2.46.0`, regenerates `SandboxedDashboard.xcodeproj`, and fails if the committed project file is out of sync with `project.yml`.
3. GitHub’s `iOS Build` workflow compiles without signing (`CODE_SIGNING_ALLOWED=NO`). TestFlight distribution is handled by Xcode Cloud on the `master` branch.

## Project Structure

```text
ios_dashboard/
├── project.yml                      # XcodeGen specification (builds Orb.app)
├── ci_scripts/
│   └── ci_post_clone.sh             # Xcode Cloud & CI project verification hook
├── SandboxedDashboard/
│   ├── SandboxedDashboardApp.swift  # App entrypoint
│   ├── ContentView.swift            # Auth gate + OrbHome root view
│   ├── Orb/                         # Primary Orb iOS UI
│   │   ├── OrbCore.swift
│   │   ├── OrbProjects.swift
│   │   ├── OrbProjectAppearance.swift
│   │   ├── OrbConversation.swift
│   │   ├── OrbRichText.swift
│   │   ├── OrbMath.swift
│   │   ├── OrbQuiz.swift
│   │   ├── OrbQuestions.swift
│   │   ├── OrbDocuments.swift
│   │   ├── OrbAttachments.swift
│   │   ├── OrbMessageImages.swift
│   │   ├── OrbSettings.swift
│   │   ├── OrbMachinesSettings.swift
│   │   └── OrbProvidersSettings.swift
│   ├── Services/                    # APIService (HTTP + SSE), Keychain, Haptics
│   └── Views/                       # Legacy tab views & shared components
├── SandboxedDashboardTests/         # Unit tests
└── SandboxedDashboardUITests/       # UI & fixture server tests
```
