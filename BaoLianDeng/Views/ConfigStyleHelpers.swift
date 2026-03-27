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

enum ConfigStyleHelpers {
    static func groupTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "list.bullet"
        case "url-test": return "bolt.horizontal"
        case "fallback": return "arrow.triangle.branch"
        case "load-balance": return "scale.3d"
        default: return "square.stack.3d.up"
        }
    }

    static func groupTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "select": return .blue
        case "url-test": return .orange
        case "fallback": return .purple
        case "load-balance": return .green
        default: return .gray
        }
    }

    static func ruleTypeIcon(_ type: String) -> String {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
            return "globe"
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            return "network"
        case "GEOIP": return "map"
        case "GEOSITE": return "mappin.and.ellipse"
        case "MATCH": return "arrow.right.square"
        default: return "questionmark.circle"
        }
    }

    static func ruleTypeColor(_ type: String) -> Color {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
            return .blue
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            return .orange
        case "GEOIP", "GEOSITE": return .purple
        case "MATCH": return .gray
        default: return .secondary
        }
    }

    static func targetColor(_ target: String) -> Color {
        switch target {
        case "DIRECT": return .green
        case "REJECT": return .red
        case "PROXY": return .blue
        default: return .orange
        }
    }
}

// MARK: - Proxy Group Row

struct ProxyGroupRowView: View {
    let group: EditableProxyGroup

    var body: some View {
        HStack {
            Image(systemName: ConfigStyleHelpers.groupTypeIcon(group.type))
                .foregroundStyle(
                    ConfigStyleHelpers.groupTypeColor(group.type)
                )
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
}

// MARK: - Rule Row

struct RuleRowView: View {
    let rule: EditableRule

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: ConfigStyleHelpers.ruleTypeIcon(rule.type)
            )
            .font(.system(size: 12))
            .foregroundStyle(
                ConfigStyleHelpers.ruleTypeColor(rule.type)
            )
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if rule.type == "MATCH" {
                    Text("MATCH (catch-all)")
                        .font(.body)
                } else {
                    Text(rule.value)
                        .font(.body)
                        .lineLimit(1)
                    let suffix = rule.noResolve
                        ? " \u{00b7} no-resolve" : ""
                    Text(rule.type + suffix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(rule.target)
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    ConfigStyleHelpers.targetColor(rule.target)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    ConfigStyleHelpers.targetColor(rule.target)
                        .opacity(0.12)
                )
                .clipShape(Capsule())
        }
    }
}

// MARK: - Config Sections

struct ConfigSectionsView: View {
    @Binding var proxyGroups: [EditableProxyGroup]
    @Binding var rules: [EditableRule]
    let subscriptionProxyGroups: [EditableProxyGroup]
    let subscriptionRules: [EditableRule]
    let isSub: Bool
    @Binding var showAddGroup: Bool
    @Binding var showAddRule: Bool

    var body: some View {
        proxyGroupsSection
        rulesSection
    }

    private var proxyGroupsSection: some View {
        Section {
            if isSub {
                ForEach(subscriptionProxyGroups) { group in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: .constant(group), isEditable: false
                        )
                    } label: { ProxyGroupRowView(group: group) }
                }
            } else {
                ForEach($proxyGroups) { $group in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: $group, isEditable: true
                        )
                    } label: { ProxyGroupRowView(group: group) }
                }
                .onDelete { proxyGroups.remove(atOffsets: $0) }
            }
        } header: {
            HStack {
                Text("Proxy Groups")
                Spacer()
                if !isSub {
                    Button { showAddGroup = true } label: {
                        Image(systemName: "plus.circle").font(.body)
                    }
                }
            }
        }
    }

    private var rulesSection: some View {
        Section {
            if isSub {
                ForEach(subscriptionRules) { RuleRowView(rule: $0) }
            } else {
                ForEach(rules) { RuleRowView(rule: $0) }
                    .onDelete { rules.remove(atOffsets: $0) }
                    .onMove { from, dest in
                        rules.move(fromOffsets: from, toOffset: dest)
                    }
            }
        } header: {
            HStack {
                let count = isSub
                    ? subscriptionRules.count : rules.count
                Text("Rules (\(count))")
                Spacer()
                if !isSub {
                    Button { showAddRule = true } label: {
                        Image(systemName: "plus.circle").font(.body)
                    }
                }
            }
        }
    }
}

// MARK: - Validation Status Bar

struct ValidationStatusBar: View {
    let errors: [YAMLError]
    let isReadOnly: Bool
    @Binding var showErrors: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                if errors.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Valid YAML")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        withAnimation { showErrors.toggle() }
                    } label: {
                        errorLabel
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if isReadOnly {
                    Text("Read Only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            if showErrors && !errors.isEmpty {
                errorList
            }
        }
    }

    private var errorLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("\(errors.count) issue\(errors.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: showErrors
                  ? "chevron.down" : "chevron.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var errorList: some View {
        Group {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(errors) { error in
                        HStack(spacing: 6) {
                            Text("L\(error.line)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .frame(
                                    width: 40, alignment: .trailing
                                )
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 120)
            .background(.bar)
        }
    }
}
