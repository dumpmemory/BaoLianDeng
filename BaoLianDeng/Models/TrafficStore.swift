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

import Foundation
import Combine

struct DailyTraffic: Codable, Identifiable {
    let date: String // yyyy-MM-dd
    var proxyUpload: Int64
    var proxyDownload: Int64

    var id: String { date }
    var total: Int64 { proxyUpload + proxyDownload }
}

struct SubscriptionUsage: Codable, Identifiable {
    var id: String       // UUID string of the subscription
    var name: String     // Display name, kept fresh on each attribution
    var upload: Int64
    var download: Int64
    var total: Int64 { upload + download }
}

private struct TrackedConnection {
    let id: String
    var upload: Int64
    var download: Int64
    var isProxy: Bool
}

@MainActor
final class TrafficStore: ObservableObject {
    static let shared = TrafficStore()

    @Published var sessionProxyUpload: Int64 = 0
    @Published var sessionProxyDownload: Int64 = 0
    @Published var dailyRecords: [DailyTraffic] = []
    @Published var activeProxyCount: Int = 0
    @Published var activeTotalCount: Int = 0
    @Published var subscriptionUsages: [SubscriptionUsage] = []

    var sessionTotal: Int64 { sessionProxyUpload + sessionProxyDownload }

    var currentMonthRecords: [DailyTraffic] {
        let prefix = currentMonthPrefix()
        return dailyRecords.filter { $0.date.hasPrefix(prefix) }
    }

    var currentMonthUpload: Int64 { currentMonthRecords.reduce(0) { $0 + $1.proxyUpload } }
    var currentMonthDownload: Int64 { currentMonthRecords.reduce(0) { $0 + $1.proxyDownload } }
    var currentMonthTotal: Int64 { currentMonthUpload + currentMonthDownload }

    private var trackedConnections: [String: TrackedConnection] = [:]
    private var closedProxyUpload: Int64 = 0
    private var closedProxyDownload: Int64 = 0
    private var lastAttributedUpload: Int64 = 0
    private var lastAttributedDownload: Int64 = 0
    private var todayBaseUpload: Int64 = 0
    private var todayBaseDownload: Int64 = 0
    private var currentDate: String = ""
    private var timer: Timer?
    private let defaults = AppConstants.sharedDefaults
    private var subscriptionNameCache: [String: String] = [:]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        loadRecords()
        loadSubscriptionUsages()
        refreshSubscriptionCache()
    }

    func startPolling() {
        stopPolling()
        currentDate = Self.dateFormatter.string(from: Date())
        refreshSubscriptionCache()
        fetchConnections()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchConnections()
            }
        }
    }

    private func refreshSubscriptionCache() {
        Task.detached(priority: .utility) { [weak self] in
            let defaults = AppConstants.sharedDefaults
            var cache: [String: String] = [:]
            if let data = defaults.data(forKey: "subscriptions"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for sub in arr {
                    if let sid = sub["id"] as? String, let n = sub["name"] as? String, !n.isEmpty {
                        cache[sid] = n
                    }
                }
            }
            await MainActor.run { self?.subscriptionNameCache = cache }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func resetSession() {
        stopPolling()
        trackedConnections.removeAll()
        closedProxyUpload = 0
        closedProxyDownload = 0
        sessionProxyUpload = 0
        sessionProxyDownload = 0
        activeProxyCount = 0
        activeTotalCount = 0
        lastAttributedUpload = 0
        lastAttributedDownload = 0

        loadRecords()
        currentDate = Self.dateFormatter.string(from: Date())
        if let todayRecord = dailyRecords.first(where: { $0.date == currentDate }) {
            todayBaseUpload = todayRecord.proxyUpload
            todayBaseDownload = todayRecord.proxyDownload
        } else {
            todayBaseUpload = 0
            todayBaseDownload = 0
        }
    }

    private func fetchConnections() {
        let url = URL(string: "http://\(AppConstants.externalControllerAddr)/connections")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = json["connections"] as? [[String: Any]] else {
                return
            }
            Task { @MainActor [weak self] in
                self?.processConnections(connections)
            }
        }.resume()
    }

    private func processConnections(_ connections: [[String: Any]]) {
        let today = Self.dateFormatter.string(from: Date())
        if today != currentDate {
            persistToday()
            currentDate = today
            todayBaseUpload = 0
            todayBaseDownload = 0
        }

        var currentIds = Set<String>()
        var proxyCount = 0

        for conn in connections {
            guard let id = conn["id"] as? String else { continue }

            let upload = (conn["upload"] as? NSNumber)?.int64Value ?? 0
            let download = (conn["download"] as? NSNumber)?.int64Value ?? 0
            let chains = conn["chains"] as? [String] ?? []
            let isProxy = !isDirect(chains: chains)

            currentIds.insert(id)
            if isProxy { proxyCount += 1 }

            trackedConnections[id] = TrackedConnection(
                id: id, upload: upload, download: download, isProxy: isProxy
            )
        }

        // Accumulate traffic from connections that disappeared (closed)
        for (id, tracked) in trackedConnections where !currentIds.contains(id) {
            if tracked.isProxy {
                closedProxyUpload += tracked.upload
                closedProxyDownload += tracked.download
            }
            trackedConnections.removeValue(forKey: id)
        }

        // Calculate session totals: closed + live proxy connections
        var liveProxyUp: Int64 = 0
        var liveProxyDown: Int64 = 0
        for (_, tracked) in trackedConnections where tracked.isProxy {
            liveProxyUp += tracked.upload
            liveProxyDown += tracked.download
        }

        sessionProxyUpload = closedProxyUpload + liveProxyUp
        sessionProxyDownload = closedProxyDownload + liveProxyDown
        activeProxyCount = proxyCount
        activeTotalCount = connections.count

        let deltaUp = sessionProxyUpload - lastAttributedUpload
        let deltaDown = sessionProxyDownload - lastAttributedDownload
        if (deltaUp > 0 || deltaDown > 0),
           let subID = defaults.string(forKey: "selectedSubscriptionID"),
           !subID.isEmpty {
            attributeDelta(upload: deltaUp, download: deltaDown, toSubscriptionID: subID)
        }
        lastAttributedUpload = sessionProxyUpload
        lastAttributedDownload = sessionProxyDownload

        persistToday()
    }

    private func isDirect(chains: [String]) -> Bool {
        if chains.count == 1 && chains[0].uppercased() == "DIRECT" {
            return true
        }
        if chains.isEmpty {
            return true
        }
        return false
    }

    private func persistToday() {
        let todayUp = todayBaseUpload + sessionProxyUpload
        let todayDown = todayBaseDownload + sessionProxyDownload

        if let idx = dailyRecords.firstIndex(where: { $0.date == currentDate }) {
            dailyRecords[idx].proxyUpload = todayUp
            dailyRecords[idx].proxyDownload = todayDown
        } else {
            dailyRecords.append(DailyTraffic(
                date: currentDate, proxyUpload: todayUp, proxyDownload: todayDown
            ))
        }

        pruneOldRecords()
        saveRecords()
    }

    private func pruneOldRecords() {
        guard dailyRecords.count > 30 else { return }
        let sorted = dailyRecords.sorted { $0.date > $1.date }
        dailyRecords = Array(sorted.prefix(30))
    }

    private func loadRecords() {
        guard let data = defaults.data(forKey: AppConstants.dailyTrafficKey),
              let records = try? JSONDecoder().decode([DailyTraffic].self, from: data) else {
            dailyRecords = []
            return
        }
        dailyRecords = records
    }

    private func saveRecords() {
        let snapshot = dailyRecords
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: AppConstants.dailyTrafficKey)
        }
    }

    private func currentMonthPrefix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Subscription Usage

    private func attributeDelta(upload: Int64, download: Int64, toSubscriptionID subID: String) {
        let displayName = subscriptionNameCache[subID] ?? subID
        if let idx = subscriptionUsages.firstIndex(where: { $0.id == subID }) {
            subscriptionUsages[idx].upload += upload
            subscriptionUsages[idx].download += download
            subscriptionUsages[idx].name = displayName
        } else {
            subscriptionUsages.append(SubscriptionUsage(
                id: subID, name: displayName, upload: upload, download: download
            ))
        }
        saveSubscriptionUsages()
    }

    private func loadSubscriptionUsages() {
        guard let data = defaults.data(forKey: AppConstants.subscriptionUsageKey),
              let usages = try? JSONDecoder().decode([SubscriptionUsage].self, from: data) else {
            subscriptionUsages = []
            return
        }
        subscriptionUsages = usages
    }

    private func saveSubscriptionUsages() {
        let snapshot = subscriptionUsages
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: AppConstants.subscriptionUsageKey)
        }
    }

    func resetSubscriptionUsages() {
        subscriptionUsages.removeAll()
        defaults.removeObject(forKey: AppConstants.subscriptionUsageKey)
        refreshSubscriptionCache()
    }
}
