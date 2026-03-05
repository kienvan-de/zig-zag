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

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var serverState: ServerState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reduce tooltip delay from default ~1.5s to 0.3s
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
    }

    func applicationWillTerminate(_ notification: Notification) {
        serverState?.stop()
    }
}
