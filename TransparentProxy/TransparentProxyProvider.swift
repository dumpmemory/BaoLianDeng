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

@preconcurrency import NetworkExtension
import MihomoCore
import Network
import os
import Yams

// MARK: - DNS Table (IP → Domain mapping)

/// Shared IP→domain lookup table (reference: trans_proxy dns.rs DnsTable).
/// When DNS queries are intercepted, A record responses populate this table.
/// Later, TCP flows use it to send domain-based SOCKS5 CONNECT requests.
final class DNSTable {
    private var table: [String: String] = [:]  // IP → domain
    private let lock = NSLock()
    private let maxEntries = 10_000

    func lookup(_ ipAddress: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return table[ipAddress]
    }

    func insert(ipAddress: String, domain: String) {
        lock.lock()
        defer { lock.unlock() }
        if table.count >= maxEntries {
            // Simple eviction: clear half
            let keys = Array(table.keys.prefix(maxEntries / 2))
            for key in keys { table.removeValue(forKey: key) }
        }
        table[ipAddress] = domain
    }
}

// MARK: - Transparent Proxy Provider

class TransparentProxyProvider: NETransparentProxyProvider {
    private var proxyStarted = false
    private var gcTimer: DispatchSourceTimer?
    private var diagnosticTimer: DispatchSourceTimer?
    private var logTrimTimer: DispatchSourceTimer?
    private let dnsTable = DNSTable()
    private var perAppSettings: PerAppProxySettings?
    private var perAppBundleIDSet: Set<String> = []

    private static let socksHost = "127.0.0.1"
    private static let socksPort: UInt16 = 7890
    private static let dohURL = "https://cloudflare-dns.com/dns-query"

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

    // MARK: - Proxy Lifecycle

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        try? FileManager.default.removeItem(at: logURL)
        log("startProxy called (NETransparentProxyProvider)")

        let configDir = setupConfigFromProvider()
        log("configDir: \(configDir)")

        let configPath = configDir + "/config.yaml"
        guard FileManager.default.fileExists(atPath: configPath) else {
            log("ERROR: config.yaml not found at \(configPath)")
            completionHandler(ProviderError.configNotFound)
            return
        }

        ConfigManager.shared.sanitizeConfig()
        log("Config sanitized")

        // Pre-resolve proxy server hostnames while DNS still works
        let resolvedIPs = preResolveProxyServers(configPath: configPath)
        log("Pre-resolved \(resolvedIPs.count) proxy server IP(s)")

        if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8) {
            log("config.yaml preview: \(String(cfg.prefix(300)))")
        }

        // Build transparent proxy network settings
        let settings = createProxySettings()
        log("Setting transparent proxy network settings")

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.log("ERROR: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            self?.log("setTunnelNetworkSettings succeeded")

            let rustLogPath = (configDir as NSString).deletingLastPathComponent
                + "/rust_bridge.log"
            BridgeSetLogFile(rustLogPath)

            self?.log("Setting home dir: \(configDir)")
            BridgeSetHomeDir(configDir)

            self?.log("Starting Mihomo proxy engine")
            var startError: NSError?
            BridgeStartWithExternalController(
                AppConstants.externalControllerAddr, "", &startError
            )
            if let startError = startError {
                self?.log("ERROR: BridgeStartWithExternalController failed: \(startError)")
                completionHandler(startError)
                return
            }
            self?.log("Proxy engine started")

            self?.proxyStarted = true
            self?.setupLogging()
            self?.startMemoryManagement()
            self?.startDiagnosticLogging()
            self?.startLogTrimming()
            completionHandler(nil)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self?.log("TCP-TEST: HTTP via proxy...")
                let proxyResult = BridgeTestProxyHTTP("http://www.baidu.com/")
                self?.log("TCP-TEST proxy: \(proxyResult ?? "nil")")

                self?.log("DNS-TEST: resolving via Mihomo DNS...")
                let dnsResult = BridgeTestDNSResolver("127.0.0.1:1053")
                self?.log("DNS-TEST: \(dnsResult ?? "nil")")
            }
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        logTrimTimer?.cancel()
        logTrimTimer = nil
        stopMemoryManagement()
        if proxyStarted {
            BridgeStopProxy()
            proxyStarted = false
        }
        completionHandler()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Per-app filtering: return false to let bypassed flows connect directly
        if let settings = perAppSettings, settings.enabled {
            let appID = flow.metaData.sourceAppSigningIdentifier
            let shouldProxy = settings.shouldProxy(
                bundleID: appID, knownBundleIDs: perAppBundleIDSet
            )
            if !shouldProxy {
                log("BYPASS flow from \(appID)")
                return false
            }
        }

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow)
            return true
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow)
            return true
        }
        return false
    }

    // MARK: - TCP Flow (SOCKS5 relay)

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }

        let destHost = endpoint.hostname
        let destPort = endpoint.port

        // Look up domain from DNS table (like trans_proxy's dns_table.lookup())
        let hostname = dnsTable.lookup(destHost) ?? destHost

        Task {
            do {
                // Connect to Mihomo's SOCKS5 proxy
                let socksConn = try await connectTCP(
                    host: Self.socksHost, port: Self.socksPort
                )

                // SOCKS5 handshake
                try await socks5Handshake(
                    connection: socksConn,
                    destHost: hostname,
                    destPort: UInt16(destPort) ?? 0
                )

                // Open the flow
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    flow.open(withLocalEndpoint: nil) { error in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }

                // Relay bidirectionally: flow ↔ SOCKS5 connection
                await relayTCP(flow: flow, connection: socksConn)

            } catch {
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
        }
    }

    // MARK: - UDP Flow (DNS interception)

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        Task {
            do {
                // Open the UDP flow
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    flow.open(withLocalEndpoint: nil) { error in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                }

                // Read datagrams and handle DNS
                await handleUDPDatagrams(flow: flow)

            } catch {
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
        }
    }

    private func handleUDPDatagrams(flow: NEAppProxyUDPFlow) async {
        while true {
            var datagrams: [Data] = []
            var endpoints: [NWHostEndpoint] = []
            var readError: Error?

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                flow.readDatagrams { dgs, eps, err in
                    datagrams = dgs ?? []
                    endpoints = (eps ?? []).compactMap {
                        $0 as? NWHostEndpoint
                    }
                    readError = err
                    cont.resume()
                }
            }

            if let readError = readError {
                log("UDP read error: \(readError)")
                break
            }

            if datagrams.isEmpty {
                break  // Flow closed
            }

            for (index, datagram) in datagrams.enumerated() {
                guard let endpoint = endpoints[safe: index] else {
                    continue
                }

                let port = UInt16(endpoint.port) ?? 0

                if port == 53 {
                    await handleDNSQuery(
                        query: datagram, flow: flow, endpoint: endpoint
                    )
                }
            }
        }
    }

    /// Handle a DNS query: forward via DoH through SOCKS5, parse response,
    /// populate DNS table, return response to the flow.
    /// Reference: trans_proxy/src/dns.rs run_doh()
    private func handleDNSQuery(
        query: Data, flow: NEAppProxyUDPFlow, endpoint: NWHostEndpoint
    ) async {
        guard query.count >= 12 else { return }

        // Extract queried domain name for DNS table
        let queriedDomain = extractDomainFromQuery(query)

        do {
            // Forward DNS via DoH through SOCKS5 proxy
            let response = try await resolveDNSviaDoH(query: query)

            // Parse A records and populate DNS table
            if let domain = queriedDomain {
                let ips = extractARecords(from: response)
                for ipAddr in ips {
                    dnsTable.insert(ipAddress: ipAddr, domain: domain)
                }
            }

            // Restore original transaction ID (DoH server may echo a different ID)
            var fixedResponse = response
            if fixedResponse.count >= 2 {
                fixedResponse[0] = query[0]
                fixedResponse[1] = query[1]
            }

            // Send response back to the flow
            flow.writeDatagrams([fixedResponse], sentBy: [endpoint]) { error in
                if let error = error {
                    AppLogger.tunnel.error(
                        "DNS write error: \(error, privacy: .public)"
                    )
                }
            }

        } catch {
            log("DoH error: \(error)")
        }
    }

    // MARK: - DoH Client (reference: trans_proxy dns.rs)

    /// URLSession configured to route through the local SOCKS5 proxy.
    private lazy var dohSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFProxyTypeKey: kCFProxyTypeSOCKS,
            kCFStreamPropertySOCKSProxyHost: Self.socksHost,
            kCFStreamPropertySOCKSProxyPort: Self.socksPort
        ]
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Resolve a DNS query via DNS-over-HTTPS through the SOCKS5 proxy.
    private func resolveDNSviaDoH(query: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://cloudflare-dns.com/dns-query")!)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = query

        let (data, response) = try await dohSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderError.unexpectedEOF
        }
        return data
    }

    // MARK: - SOCKS5 Handshake

    /// Perform SOCKS5 handshake (RFC 1928) with domain-based CONNECT.
    private func socks5Handshake(
        connection: NWConnection,
        destHost: String,
        destPort: UInt16
    ) async throws {
        // Step 1: Greeting — no auth
        let greeting = Data([0x05, 0x01, 0x00])
        try await sendAll(connection: connection, data: greeting)

        let authResp = try await readExact(connection: connection, count: 2)
        guard authResp[0] == 0x05, authResp[1] == 0x00 else {
            throw ProviderError.socks5AuthFailed
        }

        // Step 2: CONNECT request
        var request = Data([0x05, 0x01, 0x00])

        // Determine address type
        if IPv4Address(destHost) != nil {
            // IPv4
            request.append(0x01)
            let parts = destHost.split(separator: ".").compactMap {
                UInt8($0)
            }
            request.append(contentsOf: parts)
        } else if let ipv6 = IPv6Address(destHost) {
            // IPv6
            request.append(0x04)
            withUnsafeBytes(of: ipv6.rawValue) { request.append(contentsOf: $0) }
        } else {
            // Domain name (ATYP 0x03)
            request.append(0x03)
            let domainBytes = Array(destHost.utf8)
            request.append(UInt8(domainBytes.count))
            request.append(contentsOf: domainBytes)
        }

        // Port (big-endian)
        request.append(UInt8(destPort >> 8))
        request.append(UInt8(destPort & 0xFF))

        try await sendAll(connection: connection, data: request)

        // Read response: version, status, rsv, atyp
        let connResp = try await readExact(connection: connection, count: 4)
        guard connResp[0] == 0x05, connResp[1] == 0x00 else {
            throw ProviderError.socks5ConnectFailed
        }

        // Skip bound address
        switch connResp[3] {
        case 0x01:  // IPv4
            _ = try await readExact(connection: connection, count: 4 + 2)
        case 0x03:  // Domain
            let lenData = try await readExact(connection: connection, count: 1)
            _ = try await readExact(
                connection: connection, count: Int(lenData[0]) + 2
            )
        case 0x04:  // IPv6
            _ = try await readExact(connection: connection, count: 16 + 2)
        default:
            break
        }
    }

    // MARK: - TCP Relay

    private func relayTCP(flow: NEAppProxyTCPFlow, connection: NWConnection) async {
        await withTaskGroup(of: Void.self) { group in
            // Flow → SOCKS5
            group.addTask {
                while true {
                    let data: Data? = await withCheckedContinuation { cont in
                        flow.readData(completionHandler: { data, error in
                            if error != nil || data == nil || data!.isEmpty {
                                cont.resume(returning: nil)
                            } else {
                                cont.resume(returning: data)
                            }
                        })
                    }
                    guard let data = data else { break }
                    do {
                        try await self.sendAll(connection: connection, data: data)
                    } catch {
                        break
                    }
                }
                connection.cancel()
            }

            // SOCKS5 → Flow
            group.addTask {
                while true {
                    do {
                        let data = try await self.readSome(connection: connection)
                        guard !data.isEmpty else { break }
                        let writeOK: Bool = await withCheckedContinuation { cont in
                            flow.write(data) { error in
                                cont.resume(returning: error == nil)
                            }
                        }
                        if !writeOK { break }
                    } catch {
                        break
                    }
                }
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
            }
        }
    }

    // MARK: - NWConnection Helpers

    private func connectTCP(host: String, port: UInt16) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume(returning: connection)
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: ProviderError.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func sendAll(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    private func readExact(connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, data.count >= count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: ProviderError.unexpectedEOF)
                }
            }
        }
    }

    private func readSome(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func readHTTPResponse(connection: NWConnection) async throws -> Data {
        var buffer = Data()
        // Read until we find \r\n\r\n (end of headers)
        while true {
            let chunk = try await readSome(connection: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let headerEnd = buffer.range(
                of: Data("\r\n\r\n".utf8)
            ) {
                // Find Content-Length
                let headerStr = String(
                    data: buffer[..<headerEnd.lowerBound], encoding: .utf8
                ) ?? ""
                let bodyStart = headerEnd.upperBound
                var contentLength = 0
                for line in headerStr.split(separator: "\r\n")
                    where line.lowercased().hasPrefix("content-length:") {
                    let val = line.dropFirst("content-length:".count)
                        .trimmingCharacters(in: .whitespaces)
                    contentLength = Int(val) ?? 0
                }

                // Read remaining body if needed
                let bodyReceived = buffer.count - bodyStart
                while buffer.count - bodyStart < contentLength {
                    let more = try await readSome(connection: connection)
                    if more.isEmpty { break }
                    buffer.append(more)
                }

                return Data(buffer[bodyStart...])
            }
        }
        throw ProviderError.unexpectedEOF
    }

    // MARK: - DNS Parsing (reference: trans_proxy dns.rs)

    /// Extract the queried domain name from a DNS query packet.
    private func extractDomainFromQuery(_ packet: Data) -> String? {
        guard packet.count >= 12 else { return nil }
        var pos = 12
        var labels: [String] = []
        while pos < packet.count {
            let len = Int(packet[pos])
            if len == 0 { break }
            if len >= 0xC0 { break }  // Compression pointer
            pos += 1
            guard pos + len <= packet.count else { return nil }
            if let label = String(
                data: packet[pos..<pos + len], encoding: .utf8
            ) {
                labels.append(label)
            }
            pos += len
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }

    /// Extract A record IPs from a DNS response packet.
    private func extractARecords(from packet: Data) -> [String] {
        guard packet.count >= 12 else { return [] }
        let ancount = (UInt16(packet[6]) << 8) | UInt16(packet[7])
        let qdcount = (UInt16(packet[4]) << 8) | UInt16(packet[5])
        var pos = 12

        // Skip question section
        for _ in 0..<qdcount {
            pos = skipDNSName(packet, pos: pos) ?? packet.count
            pos += 4  // QTYPE + QCLASS
        }

        // Parse answer records
        var ips: [String] = []
        for _ in 0..<ancount {
            guard let nextPos = skipDNSName(packet, pos: pos) else { break }
            pos = nextPos
            guard pos + 10 <= packet.count else { break }
            let rtype = (UInt16(packet[pos]) << 8) | UInt16(packet[pos + 1])
            let rdlength = (UInt16(packet[pos + 8]) << 8)
                | UInt16(packet[pos + 9])
            pos += 10
            if rtype == 1 && rdlength == 4 && pos + 4 <= packet.count {
                // A record
                let addr =
                    "\(packet[pos]).\(packet[pos+1]).\(packet[pos+2]).\(packet[pos+3])"
                ips.append(addr)
            }
            pos += Int(rdlength)
        }
        return ips
    }

    /// Skip a DNS name (handles compression pointers).
    private func skipDNSName(_ packet: Data, pos: Int) -> Int? {
        var current = pos
        while current < packet.count {
            let len = Int(packet[current])
            if len == 0 {
                return current + 1
            }
            if len >= 0xC0 {
                // Compression pointer — 2 bytes
                return current + 2
            }
            current += 1 + len
        }
        return nil
    }

    // MARK: - IPC

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let message = try? JSONSerialization.jsonObject(
            with: messageData
        ) as? [String: Any],
            let action = message["action"] as? String
        else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "get_traffic":
            let upload = BridgeGetUploadTraffic()
            let download = BridgeGetDownloadTraffic()
            completionHandler?(
                responseData(["upload": upload, "download": download])
            )

        case "get_version":
            let version = BridgeVersion()
            completionHandler?(
                responseData(["version": version ?? "unknown"])
            )

        case "get_log":
            var logContent =
                (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let rustLogURL = logURL.deletingLastPathComponent()
                .appendingPathComponent("rust_bridge.log")
            if let rustLog = try? String(
                contentsOf: rustLogURL, encoding: .utf8
            ) {
                logContent += "\n--- Rust Bridge Log ---\n" + rustLog
            }
            completionHandler?(logContent.data(using: .utf8))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Proxy Network Settings

    private func createProxySettings() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )

        // Include all TCP and UDP traffic
        let tcpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        let udpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .UDP,
            direction: .outbound
        )
        settings.includedNetworkRules = [tcpRule, udpRule]

        // Exclude localhost and LAN traffic
        var excluded: [NENetworkRule] = []
        let excludedRanges: [(String, Int)] = [
            ("127.0.0.0", 8),     // Loopback
            ("10.0.0.0", 8),      // Private
            ("172.16.0.0", 12),   // Private
            ("192.168.0.0", 16),  // Private
            ("169.254.0.0", 16),  // Link-local
            ("224.0.0.0", 4),     // Multicast
            ("100.64.0.0", 10)    // CGNAT
        ]
        for (network, prefix) in excludedRanges {
            excluded.append(
                NENetworkRule(
                    remoteNetwork: NWHostEndpoint(
                        hostname: network, port: "0"
                    ),
                    remotePrefix: prefix,
                    localNetwork: nil,
                    localPrefix: 0,
                    protocol: .any,
                    direction: .outbound
                )
            )
        }
        settings.excludedNetworkRules = excluded

        return settings
    }

    // MARK: - Config from Provider

    private func setupConfigFromProvider() -> String {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let providerConfig = proto?.providerConfiguration

        guard let configDirURL = ConfigManager.shared.configDirectoryURL else {
            log("ERROR: could not resolve config directory")
            return ""
        }
        let configDir = configDirURL.path
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )

        let config: String
        if let compressed = providerConfig?["configData"] as? Data,
            let decompressed = try? (compressed as NSData).decompressed(
                using: .zlib
            ) as Data,
            let yaml = String(data: decompressed, encoding: .utf8) {
            config = yaml
            log(
                "Config from provider: \(compressed.count) -> \(decompressed.count) bytes"
            )
        } else {
            config = ConfigManager.shared.defaultConfig()
            log("No compressed config in provider, using default")
        }

        let configPath = configDir + "/config.yaml"
        try? config.write(
            toFile: configPath, atomically: true, encoding: .utf8
        )
        log("Config written to \(configPath) (\(config.count) chars)")

        // Load per-app proxy settings
        if let perAppData = providerConfig?["perAppProxy"] as? Data,
           let settings = try? JSONDecoder().decode(PerAppProxySettings.self, from: perAppData) {
            self.perAppSettings = settings
            self.perAppBundleIDSet = Set(settings.apps.map(\.bundleID))
            log("Per-app proxy: enabled=\(settings.enabled) mode=\(settings.mode.rawValue) apps=\(settings.apps.count)")
        }

        return configDir
    }

    // MARK: - Memory Management

    private func startMemoryManagement() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { BridgeForceGC() }
        timer.resume()
        gcTimer = timer
    }

    private func stopMemoryManagement() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    // MARK: - Helpers

    private func setupLogging() {
        let level = AppConstants.sharedDefaults
            .string(forKey: "logLevel") ?? "info"
        BridgeUpdateLogLevel(level)
    }

    private func startDiagnosticLogging() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            let upload = BridgeGetUploadTraffic()
            let download = BridgeGetDownloadTraffic()
            let running = BridgeIsRunning()
            self?.log(
                "DIAG: running=\(running) upload=\(upload) download=\(download)"
            )
        }
        timer.resume()
        diagnosticTimer = timer
    }

    /// Trim the log file every 10 minutes, keeping only lines from the last hour.
    private func startLogTrimming() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 600, repeating: 600)
        timer.setEventHandler { [weak self] in
            self?.trimLogFile()
        }
        timer.resume()
        logTrimTimer = timer
    }

    private func trimLogFile() {
        guard let content = try? String(
            contentsOf: logURL, encoding: .utf8
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let lines = content.components(separatedBy: "\n")
        let kept = lines.filter { line in
            // Lines look like: [2026-04-04 12:34:56 +0000] message
            guard line.hasPrefix("["),
                  let end = line.firstIndex(of: "]")
            else { return false }
            let dateStr = String(
                line[line.index(after: line.startIndex)..<end]
            )
            guard let date = formatter.date(from: dateStr) else {
                return true
            }
            return date >= cutoff
        }
        let trimmed = kept.joined(separator: "\n") + "\n"
        try? trimmed.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func preResolveProxyServers(configPath: String) -> Set<String> {
        guard var yaml = try? String(
            contentsOfFile: configPath, encoding: .utf8
        ) else { return [] }

        guard let dict = (try? Yams.load(yaml: yaml)) as? [String: Any],
            let proxies = dict["proxies"] as? [[String: Any]]
        else { return [] }

        var hostToIP: [String: String] = [:]
        var allIPs = Set<String>()
        for proxy in proxies {
            guard let server = proxy["server"] as? String, !server.isEmpty
            else { continue }
            if server.contains(":") { continue }
            if IPv4Address(server) != nil {
                allIPs.insert(server)
                continue
            }
            if hostToIP[server] != nil { continue }

            if let resolvedIP = resolveHostnameToIPv4(server) {
                hostToIP[server] = resolvedIP
                allIPs.insert(resolvedIP)
                log("Resolved proxy server: \(server) -> \(resolvedIP)")
            }
        }

        if !hostToIP.isEmpty {
            for (hostname, resolvedIP) in hostToIP {
                yaml = yaml.replacingOccurrences(
                    of: "server: \(hostname)",
                    with: "server: \(resolvedIP)"
                )
                yaml = yaml.replacingOccurrences(
                    of: "server: '\(hostname)'",
                    with: "server: '\(resolvedIP)'"
                )
                yaml = yaml.replacingOccurrences(
                    of: "server: \"\(hostname)\"",
                    with: "server: \"\(resolvedIP)\""
                )
            }
            try? yaml.write(
                toFile: configPath, atomically: true, encoding: .utf8
            )
            log(
                "Config rewritten with \(hostToIP.count) resolved proxy server IP(s)"
            )
        }

        return allIPs
    }

    private func resolveHostnameToIPv4(_ hostname: String) -> String? {
        let hostRef = CFHostCreateWithName(nil, hostname as CFString)
            .takeRetainedValue()
        var resolved = DarwinBoolean(false)
        CFHostStartInfoResolution(hostRef, .addresses, nil)
        guard
            let addresses = CFHostGetAddressing(hostRef, &resolved)?
                .takeUnretainedValue() as? [Data]
        else { return nil }
        for addrData in addresses {
            guard addrData.count >= MemoryLayout<sockaddr_in>.size else {
                continue
            }
            var addr = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &addr) {
                addrData.copyBytes(to: $0)
            }
            if addr.sin_family == UInt8(AF_INET) {
                return String(cString: inet_ntoa(addr.sin_addr))
            }
        }
        return nil
    }

    private func responseData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Array Safe Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case configNotFound
    case socks5AuthFailed
    case socks5ConnectFailed
    case connectionCancelled
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "config.yaml not found. Please configure proxies first."
        case .socks5AuthFailed:
            return "SOCKS5 authentication failed"
        case .socks5ConnectFailed:
            return "SOCKS5 CONNECT failed"
        case .connectionCancelled:
            return "Connection was cancelled"
        case .unexpectedEOF:
            return "Unexpected end of data"
        }
    }
}
