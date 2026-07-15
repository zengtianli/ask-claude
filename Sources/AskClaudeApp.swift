import SwiftUI
import AppKit

// =============================================================================
// Ask Claude — app entry point.
//
//   · WindowGroup hosts ContentView; initial size via .defaultSize, minimum
//     constraints live on the ContentView root.
//   · ⌘N (New Chat) is broadcast through NotificationCenter and consumed by
//     ContentView's onReceive (replaces the default File ▸ New).
// =============================================================================

extension Notification.Name {
    static let newChat = Notification.Name("newChat")
}

@main
struct AskClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 700, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
