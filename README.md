# BaoLianDeng

macOS VPN proxy app powered by [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) core.

## Features

- **Subscription Management** — Add, edit, refresh, and switch between proxy subscriptions (Clash YAML and base64 formats)
- **Proxy Node Selection** — Browse nodes by subscription with protocol icons and latency indicators
- **Traffic Analytics** — Daily bar charts, session stats, and monthly summaries for proxy-only traffic
- **Config Editor** — In-app YAML editor with validation for both local config and subscription configs
- **Proxy Groups** — View and switch proxy groups via Mihomo's REST API
- **Tunnel Logs** — Real-time log viewer for debugging the network extension

## Architecture

```
┌─────────────────────────────────────────────┐
│             macOS App (SwiftUI)             │
│  ┌──────────┬────────┬───────┬───────────┐ │
│  │  Home    │ Config │ Data  │ Settings  │ │
│  │ Subs &   │ YAML   │Charts │ Groups /  │ │
│  │  Nodes   │ Editor │& Stats│ Logs      │ │
│  └──────────┴────────┴───────┴───────────┘ │
│  ┌───────────────────────────────────────┐  │
│  │  VPNManager (NETunnelProviderManager) │  │
│  └──────────────────┬────────────────────┘  │
├─────────────────────┼───────────────────────┤
│      System Extension (PacketTunnel)        │
│  ┌──────────────────┴────────────────────┐  │
│  │    NEPacketTunnelProvider             │  │
│  │    ┌──────────────────────────────┐   │  │
│  │    │ MihomoCore.xcframework (Rust)│   │  │
│  │    │  - Proxy Engine              │   │  │
│  │    │  - DNS (fake-ip)             │   │  │
│  │    │  - Rules / Routing           │   │  │
│  │    └──────────────────────────────┘   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**IPC** between the app and tunnel extension uses `NETunnelProviderSession.sendMessage` for mode switching, traffic stats, and version queries. Both targets share config files and preferences via App Group `group.io.github.baoliandeng.macos`.

## Prerequisites

- macOS 14.0+ with Xcode 15+
- Rust toolchain (`rustup` with `aarch64-apple-darwin` and `x86_64-apple-darwin` targets)

## Build

### 1. Build the Rust framework

```bash
make framework    # macOS universal (arm64 + x86_64)
```

This compiles the Mihomo Rust FFI into `Framework/MihomoCore.xcframework`.

### 2. Configure signing

Copy the template and set your Apple development team ID:

```bash
cp Local.xcconfig.template Local.xcconfig
# Edit Local.xcconfig and set DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

> **Finding your Team ID:** Apple Developer portal → Membership → Team ID (10-character string, e.g. `AB12CD34EF`).

Both targets require these capabilities (already configured in entitlements):
- **App Groups** — `group.io.github.baoliandeng.macos`
- **Network Extensions** — Packet Tunnel Provider

If you distribute under a different bundle ID, also update `appGroupIdentifier` and `tunnelBundleIdentifier` in `Shared/Constants.swift` and the matching entitlement files.

### 3. Build and run

```bash
open BaoLianDeng.xcodeproj
# Select BaoLianDeng scheme → My Mac → Run (⌘R)
```

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
