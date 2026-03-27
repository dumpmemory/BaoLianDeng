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

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @AppStorage("logLevel", store: AppConstants.sharedDefaults)
    private var logLevel = "info"

    var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    Picker("Log Level", selection: $logLevel) {
                        Text("Silent").tag("silent")
                        Text("Error").tag("error")
                        Text("Warning").tag("warning")
                        Text("Info").tag("info")
                        Text("Debug").tag("debug")
                    }
                }

                Section("Debug") {
                    NavigationLink("Tunnel Log") {
                        TunnelLogView()
                    }
                }

                Section("About") {
                    NavigationLink("About BaoLianDeng") {
                        AboutView()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(VPNManager.shared)
}
