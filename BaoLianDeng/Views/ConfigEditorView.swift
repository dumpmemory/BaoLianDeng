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

enum ConfigSource: Hashable {
    case local
    case subscription(UUID)
}

struct ConfigEditorView: View {
    @State private var configText = ""
    @State private var proxyGroups: [EditableProxyGroup] = []
    @State private var rules: [EditableRule] = []
    @State private var subscriptionText = ""
    @State private var subscriptionProxyGroups: [EditableProxyGroup] = []
    @State private var subscriptionRules: [EditableRule] = []
    @State private var source: ConfigSource = .local
    @State private var selectedSubscription: Subscription?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var showAddGroup = false
    @State private var showAddRule = false
    @State private var isLoaded = false
    @State private var scrollToTopTrigger = false

    var isSubscriptionSource: Bool {
        if case .subscription = source { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if selectedSubscription != nil {
                        Section {
                            Picker("Source", selection: $source) {
                                Text("Local Config").tag(ConfigSource.local)
                                if let sub = selectedSubscription {
                                    Text(sub.name).tag(ConfigSource.subscription(sub.id))
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .id("sourcePicker")
                    }

                    proxyGroupsSection
                        .id("proxyGroupsTop")
                    rulesSection
                }
                .onChange(of: scrollToTopTrigger) { _, _ in
                    withAnimation {
                        if selectedSubscription != nil {
                            proxy.scrollTo("sourcePicker", anchor: .top)
                        } else {
                            proxy.scrollTo("proxyGroupsTop", anchor: .top)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Config")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            scrollToTopTrigger.toggle()
                        }
                }
                ToolbarItem(placement: .automatic) {
                    if !isSubscriptionSource {
                        Button("Save") { saveConfig() }
                            .disabled(isSaving)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    if !isSubscriptionSource {
                        Button("Reset Default", role: .destructive) { resetConfig() }
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showAddGroup) {
                AddProxyGroupSheet { group in
                    proxyGroups.append(group)
                }
            }
            .sheet(isPresented: $showAddRule) {
                AddRuleSheet(groupNames: proxyGroups.map(\.name)) { rule in
                    rules.append(rule)
                }
            }
            .overlay {
                if showSaved {
                    savedToast
                }
            }
            .onAppear {
                guard !isLoaded else { return }
                isLoaded = true
                loadConfig()
                loadSelectedSubscription()
            }
            .onChange(of: source) { _, newSource in
                if case .subscription = newSource {
                    loadConfig()
                    loadSelectedSubscription()
                }
            }
        }
    }

    // MARK: - Proxy Groups Section

    private var proxyGroupsSection: some View {
        Section {
            if isSubscriptionSource {
                ForEach(subscriptionProxyGroups) { group in
                    NavigationLink {
                        ProxyGroupDetailView(group: .constant(group), isEditable: false)
                    } label: {
                        proxyGroupRow(group)
                    }
                }
            } else {
                ForEach($proxyGroups) { $group in
                    NavigationLink {
                        ProxyGroupDetailView(group: $group, isEditable: true)
                    } label: {
                        proxyGroupRow(group)
                    }
                }
                .onDelete { offsets in
                    proxyGroups.remove(atOffsets: offsets)
                }
            }
        } header: {
            HStack {
                Text("Proxy Groups")
                Spacer()
                if !isSubscriptionSource {
                    Button { showAddGroup = true } label: {
                        Image(systemName: "plus.circle")
                            .font(.body)
                    }
                }
            }
        }
    }

    private func proxyGroupRow(_ group: EditableProxyGroup) -> some View {
        HStack {
            Image(systemName: groupTypeIcon(group.type))
                .foregroundStyle(groupTypeColor(group.type))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                Text(group.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.proxies.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Rules Section

    private var rulesSection: some View {
        Section {
            if isSubscriptionSource {
                ForEach(subscriptionRules) { rule in
                    ruleRow(rule)
                }
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
                .onDelete { offsets in
                    rules.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    rules.move(fromOffsets: from, toOffset: to)
                }
            }
        } header: {
            HStack {
                Text("Rules (\(isSubscriptionSource ? subscriptionRules.count : rules.count))")
                Spacer()
                if !isSubscriptionSource {
                    Button { showAddRule = true } label: {
                        Image(systemName: "plus.circle")
                            .font(.body)
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: EditableRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ruleTypeIcon(rule.type))
                .font(.system(size: 12))
                .foregroundStyle(ruleTypeColor(rule.type))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if rule.type == "MATCH" {
                    Text("MATCH (catch-all)")
                        .font(.body)
                } else {
                    Text(rule.value)
                        .font(.body)
                        .lineLimit(1)
                    Text(rule.type + (rule.noResolve ? " \u{00b7} no-resolve" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(rule.target)
                .font(.caption.weight(.medium))
                .foregroundStyle(targetColor(rule.target))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(targetColor(rule.target).opacity(0.12))
                .clipShape(Capsule())
        }
    }

    // MARK: - Style Helpers

    private var savedToast: some View {
        VStack {
            Spacer()
            Text("Saved")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func groupTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "list.bullet"
        case "url-test": return "bolt.horizontal"
        case "fallback": return "arrow.triangle.branch"
        case "load-balance": return "scale.3d"
        default: return "square.stack.3d.up"
        }
    }

    private func groupTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "select": return .blue
        case "url-test": return .orange
        case "fallback": return .purple
        case "load-balance": return .green
        default: return .gray
        }
    }

    private func ruleTypeIcon(_ type: String) -> String {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD": return "globe"
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR": return "network"
        case "GEOIP": return "map"
        case "GEOSITE": return "mappin.and.ellipse"
        case "MATCH": return "arrow.right.square"
        default: return "questionmark.circle"
        }
    }

    private func ruleTypeColor(_ type: String) -> Color {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD": return .blue
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR": return .orange
        case "GEOIP", "GEOSITE": return .purple
        case "MATCH": return .gray
        default: return .secondary
        }
    }

    private func targetColor(_ target: String) -> Color {
        switch target {
        case "DIRECT": return .green
        case "REJECT": return .red
        case "PROXY": return .blue
        default: return .orange
        }
    }

    // MARK: - Data

    private func loadConfig() {
        if ConfigManager.shared.configExists() {
            configText = (try? ConfigManager.shared.loadConfig()) ?? ConfigManager.shared.defaultConfig()
        } else {
            configText = ConfigManager.shared.defaultConfig()
        }
        proxyGroups = ConfigManager.shared.parseProxyGroups(from: configText)
        rules = ConfigManager.shared.parseRules(from: configText)
    }

    private func loadSelectedSubscription() {
        let defaults = AppConstants.sharedDefaults
        guard let data = defaults.data(forKey: "subscriptions"),
              let subs = try? JSONDecoder().decode([Subscription].self, from: data),
              let idString = defaults.string(forKey: "selectedSubscriptionID"),
              let id = UUID(uuidString: idString),
              let sub = subs.first(where: { $0.id == id }) else {
            selectedSubscription = nil
            return
        }
        selectedSubscription = sub
        subscriptionText = sub.rawContent ?? ""
        if subscriptionText.isEmpty {
            source = .local
        } else {
            // Re-apply the subscription merge to ensure config.yaml has the correct
            // proxy groups (with selected node) and default rules as fallback.
            try? ConfigManager.shared.applySubscriptionConfig(subscriptionText)
            configText = (try? ConfigManager.shared.loadConfig()) ?? ConfigManager.shared.defaultConfig()
            proxyGroups = ConfigManager.shared.parseProxyGroups(from: configText)
            rules = ConfigManager.shared.parseRules(from: configText)
            subscriptionProxyGroups = proxyGroups
            subscriptionRules = rules
        }
    }

    private func saveConfig() {
        isSaving = true
        var yaml = configText
        yaml = ConfigManager.shared.updateProxyGroups(proxyGroups, in: yaml)
        yaml = ConfigManager.shared.updateRules(rules, in: yaml)
        do {
            try ConfigManager.shared.saveConfig(yaml)
            configText = yaml
            withAnimation { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showSaved = false }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func resetConfig() {
        configText = ConfigManager.shared.defaultConfig()
        proxyGroups = ConfigManager.shared.parseProxyGroups(from: configText)
        rules = ConfigManager.shared.parseRules(from: configText)
    }
}

// MARK: - Proxy Group Detail View

struct ProxyGroupDetailView: View {
    @Binding var group: EditableProxyGroup
    let isEditable: Bool

    @State private var newProxyName = ""

    var body: some View {
        List {
            Section("Group Info") {
                if isEditable {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Name", text: $group.name)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Type", selection: $group.type) {
                        Text("select").tag("select")
                        Text("url-test").tag("url-test")
                        Text("fallback").tag("fallback")
                        Text("load-balance").tag("load-balance")
                    }
                    if group.type == "url-test" || group.type == "fallback" {
                        HStack {
                            Text("URL")
                            Spacer()
                            TextField("Test URL", text: Binding(
                                get: { group.url ?? "" },
                                set: { group.url = $0.isEmpty ? nil : $0 }
                            ))
                            .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Interval")
                            Spacer()
                            TextField("300", value: Binding(
                                get: { group.interval ?? 300 },
                                set: { group.interval = $0 }
                            ), format: .number)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } else {
                    LabeledContent("Name", value: group.name)
                    LabeledContent("Type", value: group.type)
                    if let url = group.url {
                        LabeledContent("URL", value: url)
                    }
                    if let interval = group.interval {
                        LabeledContent("Interval", value: "\(interval)s")
                    }
                }
            }

            Section {
                if isEditable {
                    ForEach(group.proxies, id: \.self) { proxy in
                        Text(proxy)
                    }
                    .onDelete { offsets in
                        group.proxies.remove(atOffsets: offsets)
                    }
                    .onMove { from, to in
                        group.proxies.move(fromOffsets: from, toOffset: to)
                    }
                    HStack {
                        TextField("Add proxy name", text: $newProxyName)
                        Button {
                            let name = newProxyName.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                group.proxies.append(name)
                                newProxyName = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newProxyName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    ForEach(group.proxies, id: \.self) { proxy in
                        Text(proxy)
                    }
                }
            } header: {
                Text("Proxies (\(group.proxies.count))")
            }
        }
        .navigationTitle(group.name)
    }
}

// MARK: - Add Proxy Group Sheet

struct AddProxyGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (EditableProxyGroup) -> Void

    @State private var name = ""
    @State private var type = "select"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group Name", text: $name)
                Picker("Type", selection: $type) {
                    Text("select").tag("select")
                    Text("url-test").tag("url-test")
                    Text("fallback").tag("fallback")
                    Text("load-balance").tag("load-balance")
                }
            }
            .navigationTitle("Add Proxy Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(EditableProxyGroup(name: name, type: type, proxies: []))
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Add Rule Sheet

struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupNames: [String]
    let onAdd: (EditableRule) -> Void

    @State private var type = "DOMAIN-SUFFIX"
    @State private var value = ""
    @State private var target = "PROXY"
    @State private var noResolve = false

    private let ruleTypes = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
        "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR",
        "GEOIP", "GEOSITE", "MATCH"
    ]

    private var targets: [String] {
        var t = ["PROXY", "DIRECT", "REJECT"]
        for name in groupNames where !t.contains(name) {
            t.append(name)
        }
        return t
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(ruleTypes, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }

                if type != "MATCH" {
                    TextField(valuePlaceholder, text: $value)
                        .autocorrectionDisabled()
                }

                Picker("Target", selection: $target) {
                    ForEach(targets, id: \.self) { t in
                        Text(t).tag(t)
                    }
                }

                if type.contains("IP") {
                    Toggle("no-resolve", isOn: $noResolve)
                }
            }
            .navigationTitle("Add Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(EditableRule(type: type, value: value, target: target, noResolve: noResolve))
                        dismiss()
                    }
                    .disabled(type != "MATCH" && value.isEmpty)
                }
            }
        }
    }

    private var valuePlaceholder: String {
        switch type {
        case "DOMAIN": return "example.com"
        case "DOMAIN-SUFFIX": return "google.com"
        case "DOMAIN-KEYWORD": return "google"
        case "IP-CIDR", "IP-CIDR6": return "10.0.0.0/8"
        case "GEOIP": return "CN"
        case "GEOSITE": return "google"
        default: return "Value"
        }
    }
}

#Preview {
    ConfigEditorView()
}
