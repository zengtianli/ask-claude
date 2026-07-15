import Foundation

// =============================================================================
// BackendClient — a thin wrapper around the Claude Code CLI (`claude -p`).
//
// The app shells out to your locally installed `claude` binary in print mode
// with `--output-format stream-json`, parses the event stream line by line,
// and forwards progress (session start / model confirmed / text deltas) to
// the UI. No API key involved: requests run on your Claude subscription,
// exactly like using the CLI in a terminal.
//
// Process-handling rules baked in (each one learned the hard way):
//   · GUI apps inherit launchd's minimal PATH — inject common install dirs.
//   · Pipes deadlock past 64KB — stdout is drained incrementally via
//     readabilityHandler, stderr on a background queue; never read pipes
//     inside terminationHandler.
//   · Timeout → terminate + human-readable error; Task cancellation → terminate.
// =============================================================================

enum BackendError: LocalizedError {
    case cliNotFound
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput
    case claude(String)          // error reported by claude itself
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude Code CLI not found. Install it (https://claude.com/claude-code), "
                 + "or point the app at your binary: defaults write "
                 + "io.github.zengtianli.AskClaude claudePath /path/to/claude"
        case .launchFailed(let m):
            return "Failed to launch the claude CLI: \(m)"
        case .nonZeroExit(let c, let e):
            let detail = e.isEmpty ? "(no output)" : String(e.prefix(300))
            return "claude exited with code \(c): \(detail)"
        case .emptyOutput:
            return "claude produced no output"
        case .claude(let m):
            return m
        case .timeout(let t):
            return "claude timed out after \(Int(t))s. Retry, or try a shorter question."
        }
    }
}

/// Accumulated stream state. Written only from the (serially executing)
/// readability handler; read after process exit, ordered by the dispatch-group
/// wait — hence `@unchecked Sendable` is safe here.
private final class StreamState: @unchecked Sendable {
    var lineBuf = Data()
    var replyParts: [String] = []
    var sessionId = ""
    var model = ""
    var result: [String: Any]?
    var started = false
}

private final class DataBox: @unchecked Sendable { var data = Data() }
private final class FlagBox: @unchecked Sendable { var on = false }

actor BackendClient {
    /// Hard ceiling for one answer. Long enough for big Opus answers,
    /// short enough that a wedged CLI doesn't hang the app forever.
    static let timeout: TimeInterval = 300

    /// Model passed to `claude --model`. Override with:
    ///   defaults write io.github.zengtianli.AskClaude model sonnet
    static var preferredModel: String {
        UserDefaults.standard.string(forKey: "model") ?? "opus"
    }

    /// Locate the `claude` binary: explicit override first, then the common
    /// install locations, then whatever PATH the app inherited.
    static func locateClaude() -> String? {
        let fm = FileManager.default
        if let raw = UserDefaults.standard.string(forKey: "claudePath") {
            let p = (raw as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: p) { return p }
        }
        var candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",   // native installer (default)
            "/opt/homebrew/bin/claude",                 // Homebrew / npm -g (Apple Silicon)
            "/usr/local/bin/claude",                    // npm -g (Intel) / manual installs
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Ask one streaming question. A non-empty `session` resumes a previous
    /// conversation (`--resume`). Events are delivered on a background queue;
    /// callers hop back to the MainActor themselves.
    func askStream(message: String, session: String,
                   onEvent: @escaping @Sendable (AskEvent) -> Void) async throws -> AskResult {
        guard let claude = Self.locateClaude() else { throw BackendError.cliNotFound }
        let requestedModel = Self.preferredModel
        let startedAt = Date()

        var args = ["-p", "--model", requestedModel,
                    "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose"]
        if !session.isEmpty { args += ["--resume", session] }
        args.append(message)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = args

        // GUI apps get launchd's minimal PATH; claude may spawn helpers (node,
        // ripgrep, …) that it expects to resolve, so prepend the usual dirs.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "\(NSHomeDirectory())/.local/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let state = StreamState()
        let canceled = FlagBox()
        let timedOut = FlagBox()

        // Incremental stdout read: buffer chunks, split on newlines, parse each
        // line as one stream-json event. The handler executes serially for a
        // given handle, so `state` needs no locking.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            state.lineBuf.append(chunk)
            while let nl = state.lineBuf.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(state.lineBuf[state.lineBuf.startIndex..<nl])
                state.lineBuf.removeSubrange(state.lineBuf.startIndex...nl)
                Self.parse(line: lineData, state: state, onEvent: onEvent)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AskResult, Error>) in
                let ioQueue = DispatchQueue(
                    label: "io.github.zengtianli.AskClaude.cli-io", attributes: .concurrent)
                let group = DispatchGroup()
                let errBox = DataBox()

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: BackendError.launchFailed(error.localizedDescription))
                    return
                }

                // Drain stderr concurrently (claude logs there); kept only for
                // error reporting on a non-zero exit.
                group.enter()
                ioQueue.async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                ioQueue.asyncAfter(deadline: .now() + Self.timeout) {
                    if process.isRunning {
                        timedOut.on = true
                        process.terminate()
                    }
                }

                ioQueue.async {
                    process.waitUntilExit()
                    group.wait()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    // Flush a trailing line that arrived without a newline.
                    if !state.lineBuf.isEmpty {
                        Self.parse(line: state.lineBuf, state: state, onEvent: onEvent)
                        state.lineBuf.removeAll()
                    }
                    if canceled.on {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if timedOut.on {
                        cont.resume(throwing: BackendError.timeout(Self.timeout))
                        return
                    }
                    do {
                        if process.terminationStatus != 0,
                           state.result == nil, state.replyParts.isEmpty {
                            let err = String(decoding: errBox.data, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            throw BackendError.nonZeroExit(
                                code: process.terminationStatus, stderr: err)
                        }
                        cont.resume(returning: try Self.finish(
                            state: state, requestedModel: requestedModel,
                            session: session, startedAt: startedAt))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            canceled.on = true
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - stream-json parsing

    /// One line of `claude -p --output-format stream-json` output. The events
    /// we care about:
    ///   {"type":"system","subtype":"init","session_id":…}          → session up
    ///   {"type":"stream_event","event":{"type":"message_start",
    ///        "message":{"model":…}}}                               → model known
    ///   {"type":"stream_event","event":{"type":"content_block_delta",
    ///        "delta":{"type":"text_delta","text":…}}}              → text token
    ///   {"type":"result", …}                                       → final envelope
    /// Anything else (tool events, thinking deltas, non-JSON noise) is skipped.
    private static func parse(line: Data, state: StreamState,
                              onEvent: (AskEvent) -> Void) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "system":
            guard obj["subtype"] as? String == "init" else { return }
            if let sid = obj["session_id"] as? String, !sid.isEmpty { state.sessionId = sid }
            if !state.started {
                state.started = true
                onEvent(.starting)
            }
        case "stream_event":
            guard let inner = obj["event"] as? [String: Any],
                  let innerType = inner["type"] as? String else { return }
            switch innerType {
            case "message_start":
                if let m = (inner["message"] as? [String: Any])?["model"] as? String,
                   !m.isEmpty {
                    state.model = m
                    onEvent(.model(m))
                }
            case "content_block_delta":
                guard let delta = inner["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return }
                state.replyParts.append(text)
                onEvent(.delta(text))
            default:
                break
            }
        case "result":
            state.result = obj
        default:
            break
        }
    }

    /// Assemble the final answer. The `result` event wins (the delta
    /// concatenation can miss a tail); deltas are the fallback so content is
    /// never dropped when the CLI dies before emitting `result`.
    private static func finish(state: StreamState, requestedModel: String,
                               session: String, startedAt: Date) throws -> AskResult {
        let model = state.model.isEmpty ? requestedModel : state.model
        let sessionId = state.sessionId.isEmpty ? session : state.sessionId
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        if let r = state.result {
            if (r["is_error"] as? Bool) == true {
                throw BackendError.claude((r["result"] as? String) ?? "claude reported an error")
            }
            let reply = (r["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? state.replyParts.joined()
            return AskResult(
                ok: true, reply: reply,
                sessionId: (r["session_id"] as? String) ?? sessionId,
                durationMs: (r["duration_ms"] as? Int) ?? elapsedMs,
                model: model)
        }
        if !state.replyParts.isEmpty {
            return AskResult(ok: true, reply: state.replyParts.joined(),
                             sessionId: sessionId, durationMs: elapsedMs, model: model)
        }
        throw BackendError.emptyOutput
    }
}
