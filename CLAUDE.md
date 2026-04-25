# Hex – Dev Notes for Agents

This file provides guidance for coding agents working in this repo.

`AGENTS.md` at the repo root is a symlink to this file, so tools that look for either will land here.

## Fork Notes

This repo is `pspelman/Hex`, a fork of [`kitlangton/Hex`](https://github.com/kitlangton/Hex). We carry our own fixes and tuning on top of upstream (recent focus areas: super‑fast capture path, warm‑mic startup, double‑tap lock stability, sound‑effect engine lifecycle). When guidance in this file conflicts with upstream docs, trust this file.

## Project Overview

Hex is a macOS menu bar application for on‑device voice‑to‑text. It supports Whisper (Core ML via WhisperKit) and Parakeet TDT v3 (Core ML via FluidAudio). Users activate transcription with hotkeys; text can be auto‑pasted into the active app.

## Build & Development Commands

```bash
# Build the app
xcodebuild -scheme Hex -configuration Release

# Run HexCore unit tests (pure-Swift logic, fastest feedback loop)
cd HexCore && swift test

# Run a single HexCore test class or method
cd HexCore && swift test --filter HotKeyProcessorTests
cd HexCore && swift test --filter HotKeyProcessorTests.testDoubleTapLocks

# Run all tests including Xcode-level integration tests
xcodebuild test -scheme Hex

# Lint (config at .swiftlint.yml)
swiftlint

# Open in Xcode (recommended for development)
open Hex.xcodeproj
```

### Test layout

- `HexCore/Tests/HexCoreTests/` — SwiftPM unit tests for pure logic: `HotKeyProcessorTests`, `HexSettingsMigrationTests`, `WordRemappingTests`, `WordRemovalTests`. Fixtures live in `Tests/HexCoreTests/Fixtures/`. Run with `swift test`.
- `HexTests/` — Xcode-level integration tests that need the app target (e.g. `RecordingRaceTests`). Run with `xcodebuild test -scheme Hex`.

New unit-testable logic should go into HexCore so it can be exercised by `swift test` without launching the app.

## Architecture

The app uses **The Composable Architecture (TCA)** for state management and is split across two Swift targets. Understanding the split is the single most important piece of context:

### Target split: `HexCore` vs `Hex`

- **`HexCore/`** — a local Swift Package (`swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`) containing the pure, unit‑testable core. No SwiftUI, no TCA reducers, minimal macOS‑framework coupling. Depends on Sauce, `swift-dependencies`, and `swift-log`. Contents:
  - `Logic/` — `HotKeyProcessor`, `ModelPatternMatcher`, `RecordingDecision`
  - `Settings/HexSettings.swift` — persisted settings, with migrations
  - `Models/` — `HotKey`, `KeyEvent`, `KeyboardCommand`, `ParakeetModel`, `TranscriptionHistory`, `WordRemapping`, `WordRemoval`
  - `PermissionClient/`, `SleepManagementClient/`, `TranscriptPersistenceClient/`
  - `Logging.swift` — the shared `HexLog` helper (see below)
  - `StoragePaths.swift`, `Constants.swift`
- **`Hex/`** — the macOS app target. Depends on HexCore. Contents:
  - `Features/` — TCA reducers (`App`, `Transcription`, `Settings`, `Settings/ModelDownload`, `History`, `Remappings`)
  - `Clients/` — concrete adapters over OS/third‑party frameworks
  - `Views/` — SwiftUI views (e.g. `InvisibleWindow` overlay host, `AutoDownloadBannerView`)
  - `App/` — `HexApp`, `HexAppDelegate`, notifications, diagnostics, menu‑bar entry points
  - `Models/` — app‑layer models (`AppHexSettings`, `HotkeyPermissionState`, `Language`, `ModelBootstrapState`)
  - `Resources/` — bundled `models.json`, changelog, audio clips

**Rule of thumb:** new pure logic belongs in HexCore so it can be covered by `swift test`. UI, TCA reducers, and code that pulls in AVFoundation / AppKit / WhisperKit / FluidAudio belongs under `Hex/`.

### Language & concurrency

- Swift 6 with strict concurrency. Prefer `Sendable`, actor isolation, and structured concurrency over Combine‑era patterns. Keep shared mutable state actor‑owned.
- macOS 15+ (Apple Silicon). Target platform for both the app and HexCore.

### Features (TCA Reducers, under `Hex/Features/`)
- `AppFeature`: Root feature coordinating the app lifecycle
- `TranscriptionFeature`: Core recording and transcription logic
- `SettingsFeature`: User preferences and configuration (delegates model install/list to `ModelDownloadFeature`)
- `ModelDownloadFeature`: Curated model list, download progress, install/delete
- `HistoryFeature`: Transcription history management
- `Remappings`: Word remapping/removal UI (`WordRemappingsView`)

### Dependency Clients (under `Hex/Clients/`)
- `TranscriptionClient`: WhisperKit integration for ML transcription
- `ParakeetClient` / `ParakeetClipPreparer`: FluidAudio (Parakeet TDT v3) adapter plus short‑clip padding/prep
- `RecordingClient`: AVAudioRecorder wrapper for audio capture
- `SuperFastCaptureController`: low‑latency warm‑mic capture path used for fast hotkey response
- `SoundEffect`: audio feedback engine (files under `Resources/Audio/`); gated by shared settings
- `PasteboardClient`: Clipboard operations
- `KeyEventMonitorClient`: Global hotkey monitoring via Sauce framework

### Key Dependencies
- **WhisperKit**: Core ML transcription (tracking main branch)
- **FluidAudio (Parakeet)**: Core ML ASR (multilingual) default model
- **Sauce**: Keyboard event monitoring
- **Sparkle**: Auto-updates (feed URL stripped from Info.plist; this fork ships personally and does not auto-update. Re-add `SUFeedURL` + `SUPublicEDKey` when ready to ship.)
- **Swift Composable Architecture**: State management
- **Inject** Hot Reloading for SwiftUI

## Important Implementation Details

1. **Hotkey Recording Modes**: The app supports both press-and-hold and double-tap recording modes, implemented in `HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift`. See `docs/hotkey-semantics.md` for detailed behavior specifications including:
   - **Modifier-only hotkeys** (e.g., Option) use a **0.3s threshold** to prevent accidental triggers from OS shortcuts
   - **Regular hotkeys** (e.g., Cmd+A) use user's `minimumKeyTime` setting (default 0.2s)
   - Mouse clicks and extra modifiers are discarded within threshold, ignored after
   - Only ESC cancels recordings after the threshold

2. **Model Management**: Models are managed by `ModelDownloadFeature`. Curated defaults live in `Hex/Resources/Data/models.json`. The Settings UI shows a compact opinionated list (Parakeet + three Whisper sizes). No dropdowns.

3. **Sound Effects**: Audio feedback is provided via `SoundEffect.swift` using files in `Resources/Audio/`

4. **Window Management**: Uses an `InvisibleWindow` for the transcription indicator overlay

5. **Permissions**: Requires audio input and automation entitlements (see `Hex.entitlements`)

6. **Logging**: All diagnostics should use the unified logging helper `HexLog` (`HexCore/Sources/HexCore/Logging.swift`). Pick an existing category (e.g., `.transcription`, `.recording`, `.settings`) or add a new case so Console predicates stay consistent. Avoid `print` and prefer privacy annotations (`, privacy: .private`) for anything potentially sensitive like transcript text or file paths.

## Models (2025‑11)

- Default: Parakeet TDT v3 (multilingual) via FluidAudio
- Additional curated: Whisper Small (Tiny), Whisper Medium (Base), Whisper Large v3
- Note: Distil‑Whisper is English‑only and not shown by default

### Storage Locations

- WhisperKit models
  - `~/Library/Application Support/com.pspelman.Hex/models/argmaxinc/whisperkit-coreml/<model>`
- Parakeet (FluidAudio)
  - We set `XDG_CACHE_HOME` on launch so Parakeet caches under the app container:
  - `~/Library/Containers/com.pspelman.Hex/Data/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml`
  - Legacy `~/.cache/fluidaudio/Models/…` is not visible to the sandbox; re‑download or import.

### Progress + Availability

- WhisperKit: native progress
- Parakeet: best‑effort progress by polling the model directory size during download
- Availability detection scans both `Application Support/FluidAudio/Models` and our app cache path

## Building & Running

- macOS 15+ (Apple Silicon), Xcode 16+
- HexCore uses `swift-tools-version: 6.0` with `platforms: [.macOS(.v15)]`

### Packages

- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio.git` (link `FluidAudio` to Hex target)

### Entitlements (Sandbox)

- `com.apple.security.app-sandbox = true`
- `com.apple.security.network.client = true` (HF downloads)
- `com.apple.security.files.user-selected.read-write = true` (optional import)
- `com.apple.security.automation.apple-events = true` (media control)

### Cache root (Parakeet)

Set at app launch and logged:

```
XDG_CACHE_HOME = ~/Library/Containers/com.pspelman.Hex/Data/Library/Application Support/com.pspelman.Hex/cache
```

FluidAudio models reside under `Application Support/FluidAudio/Models`.

## UI

- Settings → Transcription Model shows a compact list with radio selection, accuracy/speed dots, size on right, and trailing menu / download‑check icon.
- Context menu offers Show in Finder / Delete.

## Troubleshooting

- Repeated mic prompts during debug: ensure Debug signing uses "Apple Development" so TCC sticks
- Sandbox network errors (‑1003): add `com.apple.security.network.client = true` (already set)
- Parakeet not detected: ensure it resides under the container path above; downloading from Hex places it correctly.

## Changelog Workflow Expectations

1. **Always add a changeset:** Any feature, UX change, or bug fix that ships to users must come with a `.changeset/*.md` fragment. The summary should mention the user-facing impact plus the GitHub issue/PR number (for example, "Improve Fn hotkey stability (#89)").
2. **Use non-interactive changeset creation:** AI agents should use the non-interactive script:
   ```bash
   bun run changeset:add-ai patch "Your summary here"
   bun run changeset:add-ai minor "Add new feature"
   bun run changeset:add-ai major "Breaking change"
   ```
3. **Only create changesets, don't process them:** Agents should only create changeset fragments. The release tool is responsible for running `changeset version` to collect changesets into `CHANGELOG.md` and syncing to `Hex/Resources/changelog.md`.
4. **Reference GitHub issues:** When a change addresses a filed issue, link it in code comments and the changeset entry (`(#123)`) so release notes and Sparkle updates point users back to the discussion. If the work should close an issue, include "Fixes #123" (or "Closes #123") in the commit or PR description so GitHub auto-closes it once merged.

## Git Commit Messages

- Use a concise, descriptive subject line that captures the user-facing impact (roughly 50–70 characters).
- Follow up with as much context as needed in the body. Include the rationale, notable tradeoffs, relevant logs, or reproduction steps—future debugging benefits from having the full story directly in git history.
- Reference any related GitHub issues in the body if the change tracks ongoing work.

## Releasing a New Version

Releases are automated via a local CLI tool that handles building, signing, notarizing, and uploading.

### Prerequisites

1. **AWS credentials** must be set (for S3 uploads):
   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   ```

2. **Notarization credentials** stored in keychain (one-time setup):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD"
   ```

3. **Dependencies installed** at project root and in tools:
   ```bash
   bun install                # project root (for changesets)
   cd tools && bun install    # tools dependencies
   ```

### Release Steps

1. **Ensure all changes are committed** - the release tool requires a clean working tree

2. **Ensure changesets exist** - any user-facing change should have a `.changeset/*.md` file:
   ```bash
   bun run changeset:add-ai patch "Fix microphone selection"
   ```

3. **Run the release command** from project root:
   ```bash
   bun run tools/src/cli.ts release
   ```

### What the Release Tool Does

1. Checks for clean working tree
2. Finds pending changesets and applies them (bumps version in `package.json`)
3. Syncs changelog to `Hex/Resources/changelog.md`
4. Updates `Info.plist` and `project.pbxproj` with new version
5. Increments build number
6. Cleans DerivedData and archives with xcodebuild
7. Exports and signs with Developer ID
8. Notarizes app with Apple
9. Creates and signs DMG
10. Notarizes DMG
11. Generates Sparkle appcast
12. Uploads to S3 (versioned DMG + `hex-latest.dmg` + appcast.xml)
13. Commits version changes, creates git tag, pushes
14. Creates GitHub release with DMG and ZIP attachments

### If No Changesets Exist

The tool will prompt you to either:
- Stop and create a changeset (recommended)
- Continue with manual version bump (useful for re-running failed releases)

### Artifacts

Each release produces:
- `Hex-{version}.dmg` - Signed, notarized DMG
- `Hex-{version}.zip` - For Homebrew cask
- `hex-latest.dmg` - Always points to latest
- `appcast.xml` - Sparkle update feed

> The old GitHub Actions release workflows described in `.github/workflows/README.md` have been retired. All release work runs locally via the `tools/` CLI. Treat that README as historical.

### Troubleshooting

- **"Working tree is not clean"**: Commit or stash all changes before releasing
- **Notarization fails**: Check Apple ID credentials and app-specific password
- **S3 upload fails**: Verify AWS credentials and bucket permissions
- **Build fails**: Ensure Xcode 16+ and valid code signing certificates
