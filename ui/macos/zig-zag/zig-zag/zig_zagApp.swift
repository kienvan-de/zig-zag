// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI

@main
struct zig_zagApp: App {
    @State private var serverState = ServerState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var menuBarIcon: String {
        switch serverState.stats.status {
        case ServerStatusRunning:
            return "waveform.path.ecg.rectangle.fill"
        case ServerStatusStarting:
            return "waveform.path.ecg.rectangle"
        case ServerStatusStopped, ServerStatusError:
            return "waveform.path.ecg.rectangle"
        default:
            return "waveform.path.ecg.rectangle"
        }
    }

    var body: some Scene {
        MenuBarExtra("zig-zag", systemImage: menuBarIcon) {
            ContentView(serverState: serverState)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: serverState.stats.status) {
            appDelegate.serverState = serverState
        }
    }
}
