import Foundation

// =============================================================================
// Ask Claude — data types shared between the CLI wrapper and the UI.
// =============================================================================

/// Final answer assembled from the claude CLI's stream-json output.
struct AskResult {
    let ok: Bool
    let reply: String
    /// Session id returned by the CLI; pass it back to resume the conversation.
    let sessionId: String
    let durationMs: Int
    /// Full model id actually used, e.g. "claude-opus-4-8".
    let model: String
}

/// Progress event surfaced while claude is working.
enum AskEvent {
    case starting        // session established (init event seen)
    case model(String)   // model confirmed, first token imminent
    case delta(String)   // incremental answer text
}
