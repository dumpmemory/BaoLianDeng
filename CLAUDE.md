# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BaoLianDeng is an iOS VPN proxy app powered by Mihomo (Clash Meta). It combines a SwiftUI app with a Go-based proxy engine compiled via gomobile into an xcframework.

## Build Commands

### Go Framework (must be built first)
```bash
make framework          # Build MihomoCore.xcframework for iOS + Simulator
make framework-arm64    # Build for arm64 only (faster, device-only)
make clean              # Remove built framework
```

Go tooling setup is done automatically by `make framework`. The gomobile build uses tags `ios,with_gvisor` and `-ldflags="-s -w"` to strip debug info.

### iOS App (Xcode)
```bash
open BaoLianDeng.xcodeproj          # Open project in Xcode, then Cmd+R

# CI-style simulator build (no signing):
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Linting
```bash
swiftlint lint --strict    # No .swiftlint.yml — uses SwiftLint defaults
```

### Screenshot Tests
```bash
scripts/take_screenshots.sh    # Runs XCUITests across 4 device simulators, exports PNGs
```
The test source is `BaoLianDengUITests/ScreenshotTests.swift` — captures each tab (Home, Config, Data, Settings).

### Fastlane (App Store uploads)
Requires `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_PATH` environment variables.
```bash
fastlane upload_screenshots    # Upload screenshots to App Store Connect
fastlane upload_metadata       # Upload metadata only
fastlane upload_all            # Upload both
fastlane submit_for_review     # Submit current version for App Store review
```

## Release Deployment

Full release checklist. Credentials are in `~/.appstoreconnect/` (gitignored).

### 1. Bump version
```bash
xcrun agvtool new-marketing-version 2.x
xcrun agvtool new-version -all <build>   # increment from previous build number
```

### 2. Update landing page
Edit `docs/index.html` — update the `hero-version` badge tag and all IPA download links to the new version.

### 3. Build & upload to App Store Connect
```bash
# Archive
xcodebuild archive \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/BaoLianDeng-<version>.xcarchive

# Export IPA  (ExportOptions.plist: method=app-store-connect, signingStyle=automatic)
xcodebuild -exportArchive \
  -archivePath /tmp/BaoLianDeng-<version>.xcarchive \
  -exportPath /tmp/BaoLianDeng-<version>-export \
  -exportOptionsPlist ExportOptions.plist

# Upload (credentials stored in ~/.appstoreconnect/, see auto-memory for values)
xcrun altool --upload-app \
  -f /tmp/BaoLianDeng-<version>-export/BaoLianDeng.ipa \
  -t ios \
  --apiKey $ASC_KEY_ID \
  --apiIssuer $ASC_ISSUER_ID
```

### 4. Submit for review
```bash
# Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_PATH env vars (see auto-memory for values)
fastlane submit_for_review
```
Notes:
- The build must be `VALID` (processed) before submitting — usually takes a few minutes after upload.
- If a previous version is `WAITING_FOR_REVIEW`, cancel its submission via ASC before creating a new version entry.
- Set `usesNonExemptEncryption: false` on the build via ASC API if the submission is blocked by an encryption compliance error.

### 5. Commit, tag, and GitHub release
```bash
git add BaoLianDeng.xcodeproj/project.pbxproj \
        BaoLianDeng/Info.plist PacketTunnel/Info.plist \
        docs/index.html
git commit -m "Bump version to <version>"
git push origin main

gh release create v<version> \
  --title "v<version>" \
  --notes "..."

# Attach IPA to release
gh release upload v<version> /tmp/BaoLianDeng-<version>-export/BaoLianDeng.ipa \
  --repo madeye/BaoLianDeng --clobber
```

### 6. Install on device (debug)
```bash
# Build debug for connected device
xcodebuild build \
  -project BaoLianDeng.xcodeproj -scheme BaoLianDeng \
  -configuration Debug -destination 'id=<device-udid>'

# Install
xcrun devicectl device install app \
  --device <device-udid> \
  ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug-iphoneos/BaoLianDeng.app
```

### TestFlight testers
Add an external tester via fastlane (set ASC env vars first, see auto-memory for values):
```bash
fastlane pilot add <email> --app_identifier io.github.baoliandeng
```
External testers require a beta group (see auto-memory for group ID).

## Architecture

**Two-target iOS app** communicating via IPC:

1. **BaoLianDeng** (main app) — SwiftUI with TabView (Home, Config Editor, Traffic, Settings). Uses `VPNManager` to control the tunnel via `NETunnelProviderManager`.

2. **PacketTunnel** (network extension) — `NEPacketTunnelProvider` that hosts the Go proxy engine. Discovers the TUN file descriptor by scanning fds 0–1024 for `utun*` interfaces, then passes it to Go via `BridgeSetTUNFd()`.

3. **MihomoCore.xcframework** (Go) — Compiled from `Go/mihomo-bridge/` via gomobile. Exports functions prefixed with `Bridge` (e.g., `BridgeStartProxy`, `BridgeSetTUNFd`).

**Shared code** in `Shared/` is used by both targets:
- `Constants.swift` — App group ID, bundle IDs, network constants
- `ConfigManager.swift` — YAML config file I/O in shared container
- `VPNManager.swift` — VPN lifecycle as an ObservableObject

**IPC protocol** — Main app sends dictionaries to PacketTunnel via `sendMessage`:
- `["action": "switch_mode", "mode": "rule|global|direct"]`
- `["action": "get_traffic"]`
- `["action": "get_version"]`

**Data sharing** — Both targets use App Group `group.io.github.baoliandeng` for shared UserDefaults and config files at `mihomo/config.yaml`.

## Key Constraints

- **Network Extension memory limit is ~15MB.** Go runtime is configured with `SetGCPercent(5)`, `SetMemoryLimit(8MB)`, `GOMAXPROCS(1)`, and a background GC goroutine every 10 seconds. Swift side also calls `ForceGC()` every 10 seconds. Be careful adding dependencies or allocations in PacketTunnel.
- **TUN address space**: `198.18.0.0/16` (fake-ip range), DNS at `198.18.0.2:53`, TUN at `198.18.0.1`.
- **External controller**: Mihomo REST API at `127.0.0.1:9090` (used by ProxyGroupView for group/node info).
- **iOS 17.0** minimum deployment target.
- Both targets require matching entitlements: App Groups, Network Extension (packet-tunnel-provider), and Keychain sharing.

## Go Bridge

`Go/mihomo-bridge/bridge.go` is the gomobile boundary. All exported functions must follow gomobile constraints (simple types only — no slices, maps, or interfaces in signatures). Key exports:
- `SetHomeDir`, `SetConfig`, `SetLogFile`, `SetTUNFd` — setup
- `StartProxy`, `StartWithExternalController`, `StopProxy`, `IsRunning` — lifecycle
- `GetUploadTraffic`, `GetDownloadTraffic` — traffic stats (int64 bytes)
- `ValidateConfig`, `ReadConfig` — config operations
- `UpdateLogLevel`, `Version`, `ForceGC` — runtime control
- `TestDirectTCP`, `TestProxyHTTP`, `TestDNSResolver`, `TestSelectedProxy` — diagnostics

**Go patches** (`Go/mihomo-bridge/patches/`): Stubs for `gopsutil/process` and `go-m1cpu` that replace iOS-incompatible system calls (IOKit, procfs). These are `replace` directives in `go.mod`.

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on push/PR to `main`:
1. **build-framework** — Go 1.25 on macos-15, builds xcframework, uploads as artifact
2. **build-app** — Downloads framework artifact, builds Debug + Release for iOS Simulator (creates empty `Local.xcconfig` to bypass signing)
3. **swiftlint** — Runs `swiftlint lint --strict`, continues on error

## Sensitive Information

- **DEVELOPMENT_TEAM** is defined in `Local.xcconfig` (gitignored). Copy `Local.xcconfig.template` to `Local.xcconfig` and set your team ID. The project-level configs inherit it via `baseConfigurationReference` — no team ID in `project.pbxproj`.
- **xcuserdata/** directories — gitignored, never commit these.
- Never commit signing identities, provisioning profile names, or Apple developer account details.

## Prerequisites

- macOS with Xcode 15+
- Go 1.22+ (CI uses 1.25, go.mod requires 1.25)
- Signing requires: development team set for both targets, App Group and Network Extension capabilities enabled
