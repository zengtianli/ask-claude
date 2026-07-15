import Foundation
import SwiftUI

// =============================================================================
// Ask Claude — chat view model.
//
// Shape rules:
//   · @MainActor ObservableObject; backend calls are async, errors land in a
//     human-readable banner (never a modal alert).
//   · Multi-turn context rides on the session id returned by the CLI:
//     empty on the first turn → captured → sent back on every later turn.
//   · One in-flight request at a time (isThinking lock) so sessions never
//     interleave.
// =============================================================================

/// Persistent status/error banner.
struct BannerMsg: Equatable {
    enum Kind { case error, warning, info }
    var kind: Kind
    var text: String

    static func error(_ t: String) -> BannerMsg { .init(kind: .error, text: t) }
    static func warning(_ t: String) -> BannerMsg { .init(kind: .warning, text: t) }
    static func info(_ t: String) -> BannerMsg { .init(kind: .info, text: t) }
}

/// One chat message. `meta` is the small caption above assistant bubbles
/// (e.g. "Claude · opus · 4.5s"); nil falls back to the default label.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var meta: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var isThinking = false
    @Published var banner: BannerMsg?
    /// Streaming progress caption: connecting → session up → <model> responding.
    @Published var thinkingStatus = "Connecting to Claude…"
    /// Bumped on every delta so the view keeps scrolling as text grows
    /// (in-place text edits don't change `messages.count`).
    @Published var streamTick = 0

    /// Current session id (filled in by the CLI). Empty = fresh conversation.
    private var sessionId: String = ""
    /// Index of the assistant bubble receiving deltas; nil until the first one.
    private var streamingIndex: Int?
    private let backend = BackendClient()

    /// Send the current input. Ignored while empty or already in flight.
    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        messages.append(ChatMessage(role: .user, text: text))
        input = ""
        isThinking = true
        thinkingStatus = "Connecting to Claude…"
        streamingIndex = nil
        defer { isThinking = false; streamingIndex = nil }

        do {
            let r = try await backend.askStream(message: text, session: sessionId) { [weak self] ev in
                Task { @MainActor [weak self] in self?.handle(ev) }
            }
            if !r.sessionId.isEmpty { sessionId = r.sessionId }
            let reply = r.reply.isEmpty ? "(Claude returned no content)" : r.reply
            let meta = Self.bubbleMeta(model: r.model, ms: r.durationMs)
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text = reply          // final envelope wins over deltas
                messages[i].meta = meta
            } else {
                messages.append(ChatMessage(role: .assistant, text: reply, meta: meta))
            }
            if banner?.kind == .error { banner = nil }
        } catch is CancellationError {
            // user canceled — stay quiet
        } catch {
            banner = .error("Error: \(error.localizedDescription)")
        }
    }

    /// Stream event → UI state (MainActor). newChat() invalidates the index,
    /// so the guard drops late events from a discarded request.
    private func handle(_ ev: AskEvent) {
        guard isThinking else { return }
        switch ev {
        case .starting:
            thinkingStatus = "Session established, waiting for the model…"
        case .model(let m):
            thinkingStatus = "\(Self.shortModel(m)) is responding…"
        case .delta(let t):
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text += t
            } else {
                messages.append(ChatMessage(role: .assistant, text: t))
                streamingIndex = messages.count - 1
            }
            streamTick &+= 1
        }
    }

    /// New conversation: clear messages and drop the session id.
    func newChat() {
        messages = []
        sessionId = ""
        input = ""
        banner = nil
        streamingIndex = nil
    }

    /// "claude-opus-4-8" → "opus"; unknown shapes pass through unchanged.
    static func shortModel(_ m: String) -> String {
        if m.isEmpty { return "Claude" }
        let parts = m.split(separator: "-")
        return parts.count >= 2 && parts[0] == "claude" ? String(parts[1]) : m
    }

    static func bubbleMeta(model: String, ms: Int) -> String? {
        guard !model.isEmpty else { return nil }
        let secs = Double(ms) / 1000
        return ms > 0 ? String(format: "Claude · %@ · %.1fs", shortModel(model), secs)
                      : "Claude · \(shortModel(model))"
    }
}
