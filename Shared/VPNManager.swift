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

#if canImport(AppKit)
import AppKit
#endif
import Foundation
import NetworkExtension
#if canImport(SystemExtensions)
import SystemExtensions
#endif

final class VPNManager: NSObject, ObservableObject {
    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .disconnected
    @Published var isProcessing = false
    @Published var errorMessage: String?
    #if canImport(SystemExtensions)
    @Published var extensionInstalled = false
    #endif
    private func dbg(_ msg: String) {
        #if DEBUG
        AppLogger.vpn.debug("\(msg, privacy: .public)")
        #endif
    }

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private override init() {
        super.init()
        #if canImport(SystemExtensions)
        activateSystemExtension()
        #else
        loadManager()
        #endif
    }

    // MARK: - System Extension Activation

    #if canImport(SystemExtensions)
    func activateSystemExtension() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: AppConstants.tunnelBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    #endif

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    // MARK: - Manager Lifecycle

    func loadManager() {
        dbg("loadManager called")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.dbg("loadManager load error: \(error.localizedDescription)")
            }
            // Reuse existing manager if one exists, otherwise create new
            let mgr: NETunnelProviderManager
            if let existing = managers?.first {
                self.dbg("loadManager: reusing existing config")
                mgr = existing
            } else {
                self.dbg("loadManager: creating new config")
                mgr = self.createManager()
            }
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                if let error = error {
                    self.dbg("loadManager save error: \(error.localizedDescription)")
                }
                mgr.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            self.dbg("loadManager reload error: \(error.localizedDescription)")
                        }
                        self.dbg("loadManager: manager ready")
                        self.manager = mgr
                        self.observeStatus()
                    }
                }
            }
        }
    }

    private func createManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleIdentifier
        proto.serverAddress = "BaoLianDeng"
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "BaoLianDeng"
        manager.isEnabled = true

        return manager
    }

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let connection = manager?.connection else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            self?.status = connection.status
            if connection.status != .connecting && connection.status != .disconnecting {
                self?.isProcessing = false
            }
            if connection.status == .connected {
                // Full config (with subscription) was already passed via providerConfiguration.
                // Just select the saved proxy node via REST API.
                self?.selectSavedProxyNode()
            }
            if connection.status == .disconnected {
                VPNManager.clearTunnelLog()
            }
        }

        status = connection.status
    }

    // MARK: - Connect / Disconnect

    func start() {
        dbg("start() called, isProcessing=\(isProcessing), manager=\(manager != nil), connStatus=\(manager?.connection.status.rawValue ?? -1)")
        guard !isProcessing else {
            dbg("start() blocked by isProcessing")
            return
        }

        isProcessing = true
        errorMessage = nil

        // If the tunnel is stuck in .connecting from a previous failed attempt,
        // stop it first — calling startTunnel while .connecting is a no-op.
        if let connection = manager?.connection,
           connection.status == .connecting || connection.status == .reasserting {
            dbg("start() detected stuck .connecting, stopping first")
            connection.stopVPNTunnel()
            DispatchQueue.global().async { [weak self] in
                for i in 0..<30 {
                    let s = self?.manager?.connection.status
                    if s == .disconnected { break }
                    if i == 29 { self?.dbg("start() timeout waiting for disconnect, status=\(s?.rawValue ?? -1)") }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                DispatchQueue.main.async {
                    self?.dbg("start() retrying after stop")
                    self?.isProcessing = false
                    self?.start()
                }
            }
            return
        }

        let saveAndStart = { [weak self] in
            guard let self = self, let manager = self.manager else {
                DispatchQueue.main.async {
                    self?.dbg("start() manager is nil!")
                    self?.isProcessing = false
                    self?.errorMessage = "VPN manager not loaded"
                }
                return
            }

            self.dbg("saveAndStart: saving preferences")
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.errorMessage = "Failed to save VPN config: \(error.localizedDescription)"
                    }
                    return
                }

                manager.loadFromPreferences { error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to reload VPN config: \(error.localizedDescription)"
                        }
                        return
                    }

                    // Re-observe status after loadFromPreferences
                    // (the connection object may have changed)
                    DispatchQueue.main.async {
                        self.observeStatus()
                    }

                    self.dbg("saveAndStart: calling startTunnel")
                    do {
                        try (manager.connection as? NETunnelProviderSession)?.startTunnel()
                        self.dbg("saveAndStart: startTunnel called OK")
                    } catch {
                        self.dbg("saveAndStart: startTunnel threw: \(error)")
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to start tunnel: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        // Ensure config exists before starting
        if !ConfigManager.shared.configExists() {
            do {
                let defaultConfig = ConfigManager.shared.defaultConfig()
                try ConfigManager.shared.saveConfig(defaultConfig)
            } catch {
                isProcessing = false
                errorMessage = "Failed to create default config: \(error.localizedDescription)"
                return
            }
        }

        // Pass subscription URL and settings to the extension via providerConfiguration
        // (avoids App Group which triggers Sequoia "access data from other apps" dialog)
        passSettingsToProvider()

        saveAndStart()
    }

    func stop() {
        isProcessing = true
        manager?.connection.stopVPNTunnel()
    }

    func toggle() {
        if isConnected {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Send Message to Tunnel

    func sendMessage(_ message: [String: Any], completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(nil)
            return
        }

        do {
            try session.sendProviderMessage(data) { response in
                completion(response)
            }
        } catch {
            completion(nil)
        }
    }

    func switchMode(_ mode: ProxyMode) {
        // Update config on disk, then restart the tunnel so it picks up the change
        ConfigManager.shared.setMode(mode.rawValue)
        guard isConnected else { return }
        isProcessing = true
        manager?.connection.stopVPNTunnel()

        // Wait for disconnect, then restart
        DispatchQueue.global().async { [weak self] in
            // Poll for disconnected state (up to 5s)
            for _ in 0..<50 {
                if self?.manager?.connection.status == .disconnected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.start()
            }
        }
    }

    /// Disconnect the VPN so subscription fetches bypass the tunnel.
    /// Returns true if the VPN was connected (caller should reconnect after fetching).
    func disconnectForFetch() async -> Bool {
        guard isConnected else { return false }
        manager?.connection.stopVPNTunnel()
        // Poll for disconnected state (up to 5s)
        for _ in 0..<50 {
            if manager?.connection.status == .disconnected { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// Select a specific proxy node via Mihomo's REST API.
    func selectNode(_ nodeName: String) {
        selectNodeViaRestAPI(nodeName)
    }

    /// Select the user's saved proxy node via Mihomo's REST API.
    private func selectSavedProxyNode() {
        let defaults = AppConstants.sharedDefaults
        guard let nodeName = defaults.string(forKey: "selectedNode"), !nodeName.isEmpty else {
            dbg("selectSavedProxyNode: no saved node")
            return
        }
        // Delay to let Mihomo's external controller finish initializing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.selectNodeViaRestAPI(nodeName, retriesLeft: 5)
        }
    }

    private func selectNodeViaRestAPI(_ nodeName: String, retriesLeft: Int = 0) {
        guard let url = URL(string: "http://\(AppConstants.externalControllerAddr)/proxies") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any] else {
                self?.dbg("selectNode: failed to fetch proxy list: \(error?.localizedDescription ?? "unknown") (retries=\(retriesLeft))")
                if retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.selectNodeViaRestAPI(nodeName, retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }
            let selectorGroups = proxies.compactMap { name, value -> String? in
                guard let info = value as? [String: Any],
                      (info["type"] as? String) == "Selector" else { return nil }
                return name
            }
            self?.dbg("selectNode: \(nodeName) in groups \(selectorGroups)")
            let body = try? JSONSerialization.data(withJSONObject: ["name": nodeName])
            for groupName in selectorGroups {
                guard let encoded = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let putURL = URL(string: "http://\(AppConstants.externalControllerAddr)/proxies/\(encoded)") else { continue }
                var request = URLRequest(url: putURL)
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                URLSession.shared.dataTask(with: request) { [weak self] _, response, putError in
                    if let putError = putError {
                        self?.dbg("selectNode \(groupName): \(putError.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self?.dbg("selectNode \(groupName): \(http.statusCode)")
                    }
                }.resume()
            }
        }.resume()
    }

    /// Build the full YAML config (base + subscription + user settings),
    /// zlib-compress it, and pass via providerConfiguration to overcome the 512 KB IPC limit.
    private func passSettingsToProvider() {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let defaults = AppConstants.sharedDefaults

        // Start with the base config
        var yaml = ConfigManager.shared.defaultConfig()

        // Merge selected subscription if available
        if let idString = defaults.string(forKey: "selectedSubscriptionID"),
           let data = defaults.data(forKey: "subscriptions") {
            struct Sub: Decodable { var id: UUID; var rawContent: String? }
            if let subs = try? JSONDecoder().decode([Sub].self, from: data),
               let selectedID = UUID(uuidString: idString),
               let selected = subs.first(where: { $0.id == selectedID }),
               let raw = selected.rawContent {
                yaml = ConfigManager.mergeSubscription(raw, baseConfig: yaml, defaultConfig: yaml)
            }
        }

        // Apply user settings
        if let logLevel = defaults.string(forKey: "logLevel") {
            yaml = yaml.replacingOccurrences(
                of: #"log-level:\s*\w+"#, with: "log-level: \(logLevel)",
                options: .regularExpression)
        }
        if let mode = defaults.string(forKey: "proxyMode") {
            yaml = yaml.replacingOccurrences(
                of: #"mode:\s*\w+"#, with: "mode: \(mode)",
                options: .regularExpression)
        }

        // Compress with zlib and store in providerConfiguration
        var providerConfig: [String: Any] = [:]
        if let yamlData = yaml.data(using: .utf8),
           let compressed = try? (yamlData as NSData).compressed(using: .zlib) as Data {
            providerConfig["configData"] = compressed
            dbg("passSettings: \(yamlData.count) -> \(compressed.count) bytes (zlib)")
        }

        proto.providerConfiguration = providerConfig
        manager?.protocolConfiguration = proto
    }

    private static func clearTunnelLog() {
        // Log is now in the extension's sandbox — cleared on next startTunnel
    }
}

#if canImport(SystemExtensions)
// MARK: - OSSystemExtensionRequestDelegate

extension VPNManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        dbg("didFinish: result=\(result.rawValue)")
        switch result {
        case .completed:
            extensionInstalled = true
            loadManager()
        case .willCompleteAfterReboot:
            errorMessage = "System extension will activate after reboot"
        @unknown default:
            loadManager()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        dbg("didFail: \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)")
        DispatchQueue.main.async {
            self.errorMessage = "Sysext error \(nsError.code): \(error.localizedDescription)"
        }
        // Proceed with loadManager anyway — the old VPN config may still work
        loadManager()
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        dbg("needsUserApproval")
        DispatchQueue.main.async {
            self.errorMessage = "Allow the network extension in System Settings"
            // Open System Settings to the Network Extensions pane
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        dbg("replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }
}
#endif
