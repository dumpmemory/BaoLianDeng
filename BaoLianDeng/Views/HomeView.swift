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

import SwiftUI
import NetworkExtension
import os

struct HomeView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var selectedMode: ProxyMode = .rule
    @State private var subscriptions: [Subscription] = []
    @State private var selectedNode: String?
    @State private var selectedSubscriptionID: UUID?
    @State private var showAddSubscription = false
    @State private var editingSubscription: Subscription?
    @State private var isReloading = false
    @State private var reloadResult: ReloadResult?
    @State private var expandedSubscriptionIDs: Set<UUID> = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    connectSection
                }
                .scrollDisabled(false)
                .frame(height: vpnManager.errorMessage != nil ? 185 : 155)

                ScrollViewReader { proxy in
                    List {
                        Section(header:
                            Text("Subscriptions")
                                .id("subscriptionsTop")
                        ) {
                            subscriptionSections
                        }
                    }
                    .onAppear { scrollProxy = proxy }
                }
            }
            .navigationTitle("BaoLianDeng")
            .onTapGesture(count: 2) {
                withAnimation {
                    scrollProxy?.scrollTo("subscriptionsTop", anchor: .top)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { showAddSubscription = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await reloadAllSubscriptions() }
                    } label: {
                        if isReloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(subscriptions.isEmpty || isReloading)
                }
            }
            .alert(item: $reloadResult) { result in
                Alert(
                    title: Text("Reload Complete"),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showAddSubscription, onDismiss: {
                fetchNewSubscriptions()
            }) {
                AddSubscriptionView(subscriptions: $subscriptions)
            }
            .sheet(item: $editingSubscription) { sub in
                EditSubscriptionView(subscription: sub) { updated in
                    if let i = subscriptions.firstIndex(where: { $0.id == updated.id }) {
                        subscriptions[i] = updated
                        saveSubscriptions()
                    }
                }
            }
            .onAppear { loadSubscriptions() }
            .overlay {
                if showToast {
                    VStack {
                        Spacer()
                        Text(toastMessage)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 80)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func displayToast(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { self.showToast = false }
        }
    }

    // MARK: - Connect Section

    private var connectSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .font(.headline)
                    if let node = selectedNode {
                        Text(node)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { vpnManager.isConnected },
                    set: { _ in vpnManager.toggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(vpnManager.isProcessing)
            }
            .padding(.vertical, 4)

            if let err = vpnManager.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Routing", selection: $selectedMode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedMode) { _, newMode in
                vpnManager.switchMode(newMode)
            }
        }
    }

    // MARK: - Subscription Sections

    @ViewBuilder
    private var subscriptionSections: some View {
        if subscriptions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Subscriptions")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tap + to add a subscription URL")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ForEach($subscriptions) { $sub in
                HStack {
                        Button(action: {
                            if selectedSubscriptionID != sub.id {
                                selectSubscription(sub)
                            }
                            withAnimation {
                                if expandedSubscriptionIDs.contains(sub.id) {
                                    expandedSubscriptionIDs.remove(sub.id)
                                } else {
                                    expandedSubscriptionIDs.insert(sub.id)
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: expandedSubscriptionIDs.contains(sub.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(sub.nodes.count) nodes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedSubscriptionID == sub.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Button(action: { refreshSubscription(&sub) }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if let i = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                                deleteSubscription(at: IndexSet(integer: i))
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingSubscription = sub
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }

                if expandedSubscriptionIDs.contains(sub.id) {
                    ForEach(sub.nodes) { node in
                        NodeRow(
                            node: node,
                            isSelected: node.name == selectedNode,
                            onSelect: {
                                selectedNode = node.name
                                saveSelectedNode(node.name)
                                if selectedSubscriptionID != sub.id {
                                    // Switch subscription: merge its config, then select node
                                    selectSubscription(sub)
                                }
                                vpnManager.selectNode(node.name)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var statusText: String {
        switch vpnManager.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Not Connected"
        case .reasserting: return "Reconnecting..."
        case .invalid: return "Not Configured"
        @unknown default: return "Unknown"
        }
    }

    private func selectSubscription(_ sub: Subscription) {
        selectedSubscriptionID = sub.id
        AppConstants.sharedDefaults
            .set(sub.id.uuidString, forKey: "selectedSubscriptionID")
        // Auto-select first node if current node isn't from this subscription
        let nodeNames = Set(sub.nodes.map(\.name))
        if selectedNode == nil || !nodeNames.contains(selectedNode ?? "") {
            if let first = sub.nodes.first {
                selectedNode = first.name
                saveSelectedNode(first.name)
            }
        }
        // Apply the subscription YAML to config.yaml so the VPN uses it
        if let raw = sub.rawContent {
            Task.detached {
                let merged = (try? ConfigManager.shared.applySubscriptionConfig(raw)) ?? ""
                await Self.reloadMihomoConfig(with: merged)
            }
        }
    }

    private func loadSubscriptions() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> (subs: [Subscription], selectedNode: String?, selectedID: UUID?)? in
                let defaults = AppConstants.sharedDefaults
                guard let data = defaults.data(forKey: "subscriptions"),
                      var subs = try? JSONDecoder().decode([Subscription].self, from: data) else {
                    return nil
                }
                // Re-parse nodes for subscriptions that have raw content but empty nodes
                var needsSave = false
                for i in subs.indices {
                    if subs[i].nodes.isEmpty, let raw = subs[i].rawContent, !raw.isEmpty {
                        subs[i].nodes = SubscriptionParser.parse(raw)
                        if !subs[i].nodes.isEmpty { needsSave = true }
                    }
                }
                if needsSave, let saveData = try? JSONEncoder().encode(subs) {
                    defaults.set(saveData, forKey: "subscriptions")
                }
                let selectedNode = defaults.string(forKey: "selectedNode")
                let selectedID: UUID?
                if let idStr = defaults.string(forKey: "selectedSubscriptionID"),
                   let id = UUID(uuidString: idStr),
                   subs.contains(where: { $0.id == id }) {
                    selectedID = id
                } else {
                    selectedID = nil
                }
                return (subs, selectedNode, selectedID)
            }.value

            guard let result else { return }
            subscriptions = result.subs
            selectedNode = result.selectedNode
            if let id = result.selectedID {
                selectedSubscriptionID = id
                expandedSubscriptionIDs.insert(id)
                // Apply cached subscription config to config.yaml on launch
                if let sub = result.subs.first(where: { $0.id == id }),
                   let raw = sub.rawContent {
                    try? ConfigManager.shared.applySubscriptionConfig(raw)
                }
            }
        }
    }

    private func saveSubscriptions() {
        let snapshot = subscriptions
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: "subscriptions")
        }
    }

    private func saveSelectedNode(_ name: String) {
        AppConstants.sharedDefaults
            .set(name, forKey: "selectedNode")
    }

    /// Reload Mihomo's running config via the external controller REST API.
    /// Passes the YAML as an inline payload so Mihomo doesn't need filesystem access
    /// to the main app's sandboxed container.
    static func reloadMihomoConfig(with yaml: String) async {
        guard let url = URL(string: "http://\(AppConstants.externalControllerAddr)/configs?force=true") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["payload": yaml])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func fetchNewSubscriptions() {
        for sub in subscriptions where sub.rawContent == nil && sub.nodes.isEmpty {
            let id = sub.id
            let url = sub.url
            let name = sub.name
            Task {
                let wasConnected = await vpnManager.disconnectForFetch()
                defer { if wasConnected { vpnManager.start() } }
                do {
                    let result = try await fetchSubscription(from: url)
                    if let validationError = ConfigManager.shared.validateSubscriptionConfig(result.raw) {
                        displayToast("Invalid: \(validationError)")
                        AppLogger.ui.error("Validation failed for \(name, privacy: .public): \(validationError, privacy: .public)")
                        return
                    }
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        subscriptions[i].nodes = result.nodes
                        subscriptions[i].rawContent = result.raw
                    }
                    saveSubscriptions()
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        selectSubscription(subscriptions[i])
                    }
                    displayToast("Fetched \(name)")
                } catch {
                    displayToast("Failed to fetch \(name)")
                }
            }
        }
    }

    private func deleteSubscription(at offsets: IndexSet) {
        for i in offsets where subscriptions[i].id == selectedSubscriptionID {
            selectedSubscriptionID = nil
            AppConstants.sharedDefaults
                .removeObject(forKey: "selectedSubscriptionID")
        }
        subscriptions.remove(atOffsets: offsets)
        saveSubscriptions()
    }

    private func refreshSubscription(_ sub: inout Subscription) {
        let id = sub.id
        let url = sub.url
        let name = sub.name
        sub.isUpdating = true
        Task {
            let wasConnected = await vpnManager.disconnectForFetch()
            defer { if wasConnected { vpnManager.start() } }
            do {
                let result = try await fetchSubscription(from: url)
                if let validationError = ConfigManager.shared.validateSubscriptionConfig(result.raw) {
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        subscriptions[i].isUpdating = false
                    }
                    displayToast("Invalid: \(validationError)")
                    return
                }
                if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                    subscriptions[i].nodes = result.nodes
                    subscriptions[i].rawContent = result.raw
                    subscriptions[i].isUpdating = false
                }
                saveSubscriptions()
                // Apply to config.yaml if this is the selected subscription
                if id == selectedSubscriptionID {
                    let merged = (try? ConfigManager.shared.applySubscriptionConfig(result.raw)) ?? ""
                    await Self.reloadMihomoConfig(with: merged)
                }
                displayToast("Updated \(name) (\(result.nodes.count) nodes)")
            } catch {
                if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                    subscriptions[i].isUpdating = false
                }
                displayToast("Failed to fetch \(name)")
            }
        }
    }

    private func reloadAllSubscriptions() async {
        guard !subscriptions.isEmpty else { return }
        isReloading = true
        let wasConnected = await vpnManager.disconnectForFetch()
        defer { if wasConnected { vpnManager.start() } }
        var succeeded: [String] = []
        var failed: [(String, String)] = []

        await withTaskGroup(of: (Int, Result<(nodes: [ProxyNode], raw: String), Error>).self) { group in
            for (i, sub) in subscriptions.enumerated() {
                group.addTask {
                    do {
                        let result = try await fetchSubscription(from: sub.url)
                        return (i, .success(result))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            for await (i, result) in group {
                switch result {
                case .success(let fetched):
                    if let validationError = ConfigManager.shared.validateSubscriptionConfig(fetched.raw) {
                        failed.append((subscriptions[i].name, "Invalid config: \(validationError)"))
                    } else {
                        subscriptions[i].nodes = fetched.nodes
                        subscriptions[i].rawContent = fetched.raw
                        succeeded.append(subscriptions[i].name)
                    }
                case .failure(let error):
                    failed.append((subscriptions[i].name, error.localizedDescription))
                }
            }
        }

        saveSubscriptions()
        // Apply the selected subscription's updated config to config.yaml
        if let selID = selectedSubscriptionID,
           let sub = subscriptions.first(where: { $0.id == selID }),
           let raw = sub.rawContent {
            let merged = (try? ConfigManager.shared.applySubscriptionConfig(raw)) ?? ""
            await Self.reloadMihomoConfig(with: merged)
        }
        isReloading = false
        reloadResult = ReloadResult(succeeded: succeeded, failed: failed)
    }

    private func fetchSubscription(from urlString: String) async throws -> (nodes: [ProxyNode], raw: String) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("ClashMetaForAndroid/2.11.1.Meta", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription URL=\(urlString) status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count)")
        guard let text = String(data: data, encoding: .utf8) else {
            AppLogger.log(AppLogger.network, category: "network", "ERROR: fetchSubscription cannot decode as UTF-8")
            throw URLError(.cannotDecodeContentData)
        }
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription raw preview (first 500 chars): \(String(text.prefix(500)))")
        let nodes = SubscriptionParser.parse(text)
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription parsed \(nodes.count) nodes")
        return (nodes, text)
    }
}

// MARK: - Node Row

struct NodeRow: View {
    let node: ProxyNode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: node.typeIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(node.typeColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(node.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let delay = node.delay {
                    Text("\(delay) ms")
                        .font(.caption)
                        .foregroundStyle(delayColor(delay))
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay < 200 { return .green }
        if delay < 500 { return .orange }
        return .red
    }
}

// MARK: - Models

struct Subscription: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var nodes: [ProxyNode]
    var rawContent: String?
    var isUpdating: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, url, nodes, rawContent
    }
}

struct ProxyNode: Identifiable, Codable {
    var id = UUID()
    var name: String
    var type: String
    var server: String
    var port: Int
    var delay: Int?

    var typeIcon: String {
        switch type.lowercased() {
        case "ss", "shadowsocks": return "lock.shield"
        case "vmess": return "v.circle"
        case "vless": return "v.circle.fill"
        case "trojan": return "bolt.shield"
        case "hysteria", "hysteria2": return "hare"
        case "wireguard": return "network.badge.shield.half.filled"
        default: return "globe"
        }
    }

    var typeColor: Color {
        switch type.lowercased() {
        case "ss", "shadowsocks": return .blue
        case "vmess": return .purple
        case "vless": return .indigo
        case "trojan": return .red
        case "hysteria", "hysteria2": return .orange
        case "wireguard": return .green
        default: return .gray
        }
    }
}

// MARK: - Add Subscription Sheet

struct AddSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var subscriptions: [Subscription]
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Enter a subscription URL to import proxy nodes. Supported formats: Clash YAML, base64-encoded links.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSubscription()
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }

    private func addSubscription() {
        let sub = Subscription(name: name, url: url, nodes: [])
        subscriptions.append(sub)
        let snapshot = subscriptions
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: "subscriptions")
        }
    }
}

// MARK: - Reload Result

struct ReloadResult: Identifiable {
    let id = UUID()
    let succeeded: [String]
    let failed: [(String, String)]

    var message: String {
        var parts: [String] = []
        if !succeeded.isEmpty {
            parts.append("✓ \(succeeded.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            let names = failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            parts.append("✗ \(names)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Subscription Parser

enum SubscriptionParser {
    static func parse(_ text: String) -> [ProxyNode] {
        // Normalize CRLF / bare CR to LF so trailing \r doesn't break value parsing
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var nodes: [ProxyNode] = []
        var inProxies = false
        var current: [String: String] = [:]

        AppLogger.log(AppLogger.parser, category: "parser", "total lines: \(lines.count), text length: \(text.count)")

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("proxies:") {
                inProxies = true
                AppLogger.log(AppLogger.parser, category: "parser", "found 'proxies:' at line \(lineNum)")
                continue
            }
            // Top-level key ends the proxies section
            if inProxies, !line.hasPrefix(" "), !line.isEmpty, line.contains(":") {
                AppLogger.log(AppLogger.parser, category: "parser", "proxies section ended at line \(lineNum): '\(String(line.prefix(80)))'")
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                inProxies = false
                continue
            }
            guard inProxies else { continue }

            if trimmed == "-" {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
            } else if trimmed.hasPrefix("- {") && trimmed.hasSuffix("}") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                let inner = String(trimmed.dropFirst(3).dropLast())
                for pair in splitFlowMapping(inner) {
                    parseKV(pair, into: &current)
                }
            } else if trimmed.hasPrefix("- ") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                parseKV(String(trimmed.dropFirst(2)), into: &current)
            } else {
                parseKV(trimmed, into: &current)
            }
        }
        if let node = makeNode(from: current) { nodes.append(node) }
        AppLogger.log(AppLogger.parser, category: "parser", "result: \(nodes.count) nodes parsed")
        if nodes.isEmpty {
            // Dump first few proxies-section lines for debugging
            var proxiesStart = -1
            for (i, l) in lines.enumerated() {
                if l.hasPrefix("proxies:") { proxiesStart = i; break }
            }
            if proxiesStart >= 0 {
                let end = min(proxiesStart + 10, lines.count)
                for i in proxiesStart..<end {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            } else {
                AppLogger.log(AppLogger.parser, category: "parser", "WARNING: no 'proxies:' section found in text")
                // Log first 10 lines to see what we got
                for i in 0..<min(10, lines.count) {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            }
        }
        return nodes
    }

    private static func parseKV(_ s: String, into dict: inout [String: String]) {
        guard let idx = s.firstIndex(of: ":") else { return }
        let key = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        var value = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { dict[key] = value }
    }

    /// Split a YAML flow mapping interior on commas, respecting quoted values.
    /// e.g. `name: "a, b", type: ss` → [`name: "a, b"`, `type: ss`]
    private static func splitFlowMapping(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote: Character? = nil
        for ch in s {
            if inQuote != nil {
                current.append(ch)
                if ch == inQuote { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func makeNode(from dict: [String: String]) -> ProxyNode? {
        guard !dict.isEmpty else { return nil }
        guard let name = dict["name"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'name', keys=\(dict.keys.sorted().joined(separator: ","))")
            return nil
        }
        guard let type_ = dict["type"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'type' for '\(name)'")
            return nil
        }
        guard let server = dict["server"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'server' for '\(name)'")
            return nil
        }
        guard let portStr = dict["port"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'port' for '\(name)'")
            return nil
        }
        guard let port = Int(portStr) else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: invalid port '\(portStr)' for '\(name)'")
            return nil
        }
        return ProxyNode(name: name, type: type_, server: server, port: port)
    }
}

// MARK: - Edit Subscription Sheet

struct EditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    let onSave: (Subscription) -> Void

    @State private var name: String
    @State private var url: String

    init(subscription: Subscription, onSave: @escaping (Subscription) -> Void) {
        self.subscription = subscription
        self.onSave = onSave
        _name = State(initialValue: subscription.name)
        _url = State(initialValue: subscription.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = subscription
                        updated.name = name
                        updated.url = url
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(VPNManager.shared)
}
