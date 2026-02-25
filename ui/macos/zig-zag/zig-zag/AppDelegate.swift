import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var serverState: ServerState?

    func applicationWillTerminate(_ notification: Notification) {
        serverState?.stop()
    }
}
