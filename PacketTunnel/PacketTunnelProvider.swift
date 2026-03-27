// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import NetworkExtension
import MihomoCore
import os

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var proxyStarted = false
    private var gcTimer: DispatchSourceTimer?
    private var diagnosticTimer: DispatchSourceTimer?

    private lazy var logURL: URL = {
        let dir = ConfigManager.shared.configDirectoryURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tunnel.log")
    }()

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        AppLogger.tunnel.info("\(message, privacy: .public)")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Clear old log on each tunnel start
        try? FileManager.default.removeItem(at: logURL)
        log("startTunnel called")

        let configDir = setupConfigFromProvider()
        log("configDir: \(configDir)")

        let configPath = configDir + "/config.yaml"
        guard FileManager.default.fileExists(atPath: configPath) else {
            log("ERROR: config.yaml still not found at \(configPath)")
            completionHandler(PacketTunnelError.configNotFound)
            return
        }

        // Sanitize subscription configs (fix stack, DNS, geo-auto-update)
        ConfigManager.shared.sanitizeConfig()
        log("Config sanitized")

        // Log config summary for debugging
        if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8) {
            log("config.yaml preview: \(String(cfg.prefix(300)))")
        }

        let settings = createTunnelSettings()
        log("Setting tunnel network settings")

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.log("ERROR: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            self?.log("setTunnelNetworkSettings succeeded")

            // Enable Rust-side logging to the same directory as tunnel.log
            let rustLogPath = (configDir as NSString).deletingLastPathComponent + "/rust_bridge.log"
            self?.log("Setting Rust log file: \(rustLogPath)")
            BridgeSetLogFile(rustLogPath)

            // Step 1: Point mihomo at the config directory and start the engine
            self?.log("Setting home dir: \(configDir)")
            BridgeSetHomeDir(configDir)

            self?.log("Starting Mihomo proxy engine with external controller")
            var startError: NSError?
            BridgeStartWithExternalController(AppConstants.externalControllerAddr, "", &startError)
            if let startError = startError {
                self?.log("ERROR: BridgeStartWithExternalController failed: \(startError)")
                completionHandler(startError)
                return
            }
            self?.log("Proxy engine started")

            // Step 2: Find the TUN fd
            guard let fd = self?.tunnelFileDescriptor else {
                self?.log("ERROR: could not find utun file descriptor")
                completionHandler(PacketTunnelError.tunnelFDNotFound)
                return
            }
            self?.log("Found TUN fd: \(fd)")

            // Step 3: Start tun2socks (lwIP reads fd, forwards via SOCKS5 to engine)
            self?.log("Starting tun2socks: fd=\(fd), socks=7890, dns=1053")
            var tun2socksError: NSError?
            BridgeStartTun2Socks(Int32(fd), 7890, 1053, &tun2socksError)
            if let tun2socksError = tun2socksError {
                self?.log("ERROR: BridgeStartTun2Socks failed: \(tun2socksError)")
                completionHandler(tun2socksError)
                return
            }
            self?.log("tun2socks started successfully")

            self?.proxyStarted = true
            self?.setupLogging()
            self?.startMemoryManagement()
            self?.startDiagnosticLogging()
            completionHandler(nil)

            // Run connectivity diagnostics in background
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self?.log("TCP-TEST: direct TCP to www.baidu.com:80...")
                let directResult = BridgeTestDirectTCP("www.baidu.com", 80)
                self?.log("TCP-TEST direct: \(directResult ?? "nil")")

                self?.log("TCP-TEST: HTTP via proxy to http://www.baidu.com/...")
                let proxyResult = BridgeTestProxyHTTP("http://www.baidu.com/")
                self?.log("TCP-TEST proxy: \(proxyResult ?? "nil")")

                self?.log("DNS-TEST: resolving via Mihomo DNS...")
                let dnsResult = BridgeTestDNSResolver("127.0.0.1:1053")
                self?.log("DNS-TEST: \(dnsResult ?? "nil")")

                self?.log("PROXY-TEST: testing selected proxy node...")
                let proxyTestResult = BridgeTestSelectedProxy(AppConstants.externalControllerAddr)
                self?.log("PROXY-TEST: \(proxyTestResult ?? "nil")")
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        stopMemoryManagement()
        if proxyStarted {
            BridgeStopProxy()
            proxyStarted = false
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "get_traffic":
            let up = BridgeGetUploadTraffic()
            let down = BridgeGetDownloadTraffic()
            completionHandler?(responseData([
                "upload": up,
                "download": down
            ]))

        case "get_version":
            let version = BridgeVersion()
            completionHandler?(responseData(["version": version ?? "unknown"]))

        case "get_log":
            var logContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            // Append Rust bridge log
            let rustLogURL = logURL.deletingLastPathComponent().appendingPathComponent("rust_bridge.log")
            if let rustLog = try? String(contentsOf: rustLogURL, encoding: .utf8) {
                logContent += "\n--- Rust Bridge Log ---\n" + rustLog
            }
            completionHandler?(logContent.data(using: .utf8))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Config from Provider

    /// Decompress the full YAML config from providerConfiguration and write to disk.
    /// Falls back to the default config if no compressed data is available.
    private func setupConfigFromProvider() -> String {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let providerConfig = proto?.providerConfiguration

        guard let configDirURL = ConfigManager.shared.configDirectoryURL else {
            log("ERROR: could not resolve config directory")
            return ""
        }
        let configDir = configDirURL.path
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let config: String
        if let compressed = providerConfig?["configData"] as? Data,
           let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data,
           let yaml = String(data: decompressed, encoding: .utf8) {
            config = yaml
            log("Config from provider: \(compressed.count) -> \(decompressed.count) bytes")
        } else {
            config = ConfigManager.shared.defaultConfig()
            log("No compressed config in provider, using default")
        }

        let configPath = configDir + "/config.yaml"
        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
        log("Config written to \(configPath) (\(config.count) chars)")

        return configDir
    }

    // MARK: - TUN Configuration

    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")

        // IPv4 - route all traffic through the tunnel
        let ipv4 = NEIPv4Settings(
            addresses: [AppConstants.tunAddress],
            subnetMasks: [AppConstants.tunSubnetMask]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Exclude localhost so the extension's own outbound connections
        // (SOCKS5 to 127.0.0.1:7890, DNS to 127.0.0.1:1053) don't loop back through TUN
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
        ]
        settings.ipv4Settings = ipv4

        // IPv6 - route all IPv6 traffic through the tunnel
        let ipv6 = NEIPv6Settings(
            addresses: [AppConstants.tunIPv6Address],
            networkPrefixLengths: [NSNumber(value: AppConstants.tunIPv6PrefixLength)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = [
            NEIPv6Route(destinationAddress: "::1", networkPrefixLength: 128),
        ]
        settings.ipv6Settings = ipv6

        // DNS - point to Mihomo's fake-ip DNS server
        let dns = NEDNSSettings(servers: [AppConstants.tunDNS])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: AppConstants.defaultMTU)

        return settings
    }

    // MARK: - Memory Management

    /// iOS Network Extension has a ~15MB memory limit.
    /// Periodically trigger Go GC to return memory to the OS.
    /// Go also runs its own internal GC ticker every 10s, but this ensures
    /// we also reclaim after any Swift-side allocations or IPC activity.
    private func startMemoryManagement() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            BridgeForceGC()
        }
        timer.resume()
        gcTimer = timer
    }

    private func stopMemoryManagement() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    // MARK: - Helpers

    /// Find the utun file descriptor created by NEPacketTunnelProvider.
    /// This fd is passed to the Go core so Mihomo can read/write VPN packets directly.
    private var tunnelFileDescriptor: Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &buf, &len) == 0
                && String(cString: buf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    private func setupLogging() {
        let level = AppConstants.sharedDefaults
            .string(forKey: "logLevel") ?? "info"
        BridgeUpdateLogLevel(level)
    }

    /// Log traffic counters every 3s for the first 120s after startup.
    /// This reveals whether the TUN device is actually passing packets.
    private func startDiagnosticLogging() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        var count = 0
        timer.setEventHandler { [weak self] in
            let up = BridgeGetUploadTraffic()
            let down = BridgeGetDownloadTraffic()
            let running = BridgeIsRunning()
            self?.log("DIAG[\(count)]: running=\(running) upload=\(up) download=\(down)")
            count += 1
            if count >= 40 {
                self?.diagnosticTimer?.cancel()
                self?.diagnosticTimer = nil
                self?.log("DIAG: diagnostic logging stopped after 120s")
            }
        }
        timer.resume()
        diagnosticTimer = timer
    }

    private func responseData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }
}

enum PacketTunnelError: LocalizedError {
    case configDirectoryUnavailable
    case configNotFound
    case tunnelFDNotFound

    var errorDescription: String? {
        switch self {
        case .configDirectoryUnavailable:
            return "Shared container directory is not available"
        case .configNotFound:
            return "config.yaml not found. Please configure proxies first."
        case .tunnelFDNotFound:
            return "Could not find TUN file descriptor. The VPN tunnel may not have been created."
        }
    }
}
