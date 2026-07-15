import SwiftUI
import AppKit

// =============================================================================
// Ask Claude — chat view.
//
// Design language (native macOS):
//   · No hard-coded colors: .primary/.secondary/.tertiary plus
//     controlBackgroundColor / textBackgroundColor / separatorColor;
//     accentColor only tints the user's bubbles.
//   · No fixedSize(horizontal:false, vertical:true) on long text — under a
//     zero-width proposal it wraps per character and explodes the height.
//     Bubbles use Spacer(minLength:) + the container's width proposal instead.
//   · Auto-scroll to bottom: ScrollViewReader + onChange(count / isThinking /
//     streamTick).
// =============================================================================

// MARK: - Status banner (error / warning / info)

struct StatusBanner: View {
    let msg: BannerMsg
    var onClose: () -> Void

    private var color: Color {
        switch msg.kind {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
    private var icon: String {
        switch msg.kind {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(msg.text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(isUser ? "You" : (message.meta ?? "Claude"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(isUser ? Color.accentColor.opacity(0.18)
                                         : Color(nsColor: .controlBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            if !isUser { Spacer(minLength: 64) }
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let b = vm.banner {
                StatusBanner(msg: b) { vm.banner = nil }
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            messagesScroll
            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("Ask Claude")
        .toolbar {
            ToolbarItemGroup {
                Button { vm.newChat() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("Clear the conversation and start a new session (⌘N)")
                .disabled(vm.messages.isEmpty && !vm.isThinking)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            vm.newChat()
            inputFocused = true
        }
        .onAppear { inputFocused = true }
    }

    // MARK: Message scroll area

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.messages.isEmpty && !vm.isThinking {
                        emptyState
                    }
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    if vm.isThinking {
                        thinkingRow.id("thinking")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: vm.messages.count) { _ in scrollToBottom(proxy) }
            .onChange(of: vm.isThinking) { _ in scrollToBottom(proxy) }
            .onChange(of: vm.streamTick) { _ in scrollToBottom(proxy) }   // follow growing text
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if vm.isThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = vm.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Ask anything").font(.headline).foregroundStyle(.secondary)
            Text("Opus by default · Runs on your Claude subscription, no API key · Multi-turn memory · ⌘N for a new chat")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(vm.thinkingStatus).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Claude…  (⏎ to send, ⌥⏎ for a new line)", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.body)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .focused($inputFocused)
                .onSubmit { Task { await vm.send() } }
                .disabled(vm.isThinking)

            Button { Task { await vm.send() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .help("Send")
        }
        .padding(12)
    }

    private var canSend: Bool {
        !vm.isThinking && !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
