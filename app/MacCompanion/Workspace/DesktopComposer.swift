import RemoteKit
import SwiftUI
import UniformTypeIdentifiers

/// The prompt bar, desktop grammar: Return sends, Shift-Return or
/// Option-Return breaks the line, files arrive by drag, paste, or the open
/// panel. Same rounded container and chip row as the phone — it should
/// read as the same product at a different desk.
struct DesktopComposer: View {
    @Binding var input: String
    let running: Bool
    @ObservedObject var attachments: PromptAttachments
    @ObservedObject var models: ModelStore
    @ObservedObject var agents: AgentStore
    @ObservedObject var mcp: McpStore
    let onSend: () -> Void
    let onAbort: () -> Void

    @State private var showingFiles = false
    @FocusState private var focused: Bool
    /// The Shift-Return interceptor; installed while this composer exists.
    @State private var keyMonitor: Any?

    private var empty: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Send needs something to send — text or files; stop is always
    /// available while a turn runs.
    private var sendEnabled: Bool { running || !empty || !attachments.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments)
            }

            TextField("Ask the agent…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 10)
                .focused($focused)
                .onSubmit(onSend)
                .onChange(of: input) { old, new in liftLargeInsertion(from: old, to: new) }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A tap anywhere near the text focuses it, not only on the
                // line itself, and the bottom padding is the gutter that keeps
                // a tap meant for the text off the controls below.
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .padding(.bottom, 6)

            HStack(spacing: 8) {
                addButton
                // Always present, even before the catalogue arrives:
                // hiding it made a failed fetch look like a missing
                // feature, which is exactly how it was first reported.
                ModelMenu(models: models)
                if !agents.agents.isEmpty {
                    AgentMenu(agents: agents)
                }
                if mcp.configured {
                    McpMenu(mcp: mcp)
                }
                Spacer(minLength: 4)
                CircleButton(
                    systemName: running ? "stop.fill" : "arrow.up",
                    foreground: sendEnabled ? .white : .secondary,
                    background: sendEnabled ? Color.accentColor : Color.primary.opacity(0.08),
                    action: { running ? onAbort() : onSend() }
                )
                .disabled(!sendEnabled)
                .accessibilityLabel(running ? "Stop the agent" : "Send")
                .keyboardShortcut(running ? "." : .return, modifiers: .command)
            }
        }
        // Room around the text on the top and sides; the bottom stays
        // tighter because the controls carry their own padding.
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: sendEnabled)
        .animation(.easeInOut(duration: 0.2), value: attachments.items.count)
        .fileImporter(
            isPresented: $showingFiles, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            for url in urls { attachments.add(fileAt: url) }
        }
        // Drag anything onto the composer; images get the same shrinking
        // the phone applies before they reach the wire.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { attachments.add(fileAt: url) }
            return !urls.isEmpty
        }
        .onPasteCommand(of: [UTType.image.identifier, UTType.fileURL.identifier]) { providers in
            paste(providers)
        }
        .task { focused = true }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused else { return event }
                if isPasteKey(event), liftPasteboardText() { return nil }
                return breakLine(event)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Shift-Return breaks the line — the chat-app convention everyone's
    /// hands already know. AppKit has no binding for it (a field editor
    /// treats it as plain Return, which submits), so the event is re-keyed
    /// as Option-Return, the break AppKit does honor: the field editor
    /// inserts the newline at the caret, where appending to the binding
    /// would dump it at the end of the text. Transforming rather than
    /// swallowing keeps this idempotent when several workspace windows
    /// each hold a monitor.
    private func breakLine(_ event: NSEvent) -> NSEvent? {
        guard focused,
              event.keyCode == 36,   // Return; the keypad's Enter stays a submit.
              event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
        else { return event }
        return NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.shift).union(.option),
            timestamp: event.timestamp, windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters ?? "\r",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "\r",
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) ?? event
    }

    // MARK: - Large pastes

    /// ⌘V, and nothing else: Paste and Match Style (⌥⇧⌘V) and the Edit
    /// menu reach the field directly and are caught by `liftLargeInsertion`.
    private func isPasteKey(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.shift, .command, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// A large block of text on the pasteboard becomes a chip instead of
    /// landing in the field, the convention the terminal agents use: the
    /// field never lays out a wall of log output, and the chip is removed
    /// like any attachment. Returns false when the paste should proceed
    /// as usual, short text and anything the image and file handlers own.
    private func liftPasteboardText() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return false
        }
        guard let text = pasteboard.string(forType: .string),
              PromptAttachments.isLargePaste(text)
        else { return false }
        attachments.add(pastedText: text)
        return true
    }

    /// A large insertion that got past the key monitor (the Edit menu, a
    /// dropped text clipping, Paste and Match Style) is lifted out after
    /// the fact: the field takes one slow layout instead of one per
    /// keystroke from then on. Typing never inserts this much at once.
    private func liftLargeInsertion(from old: String, to new: String) {
        guard new.count - old.count > PromptAttachments.pasteCharacterLimit else { return }
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        let inserted = String(after[prefix ..< after.count - suffix])
        guard PromptAttachments.isLargePaste(inserted) else { return }
        attachments.add(pastedText: inserted)
        input = old
    }

    private var addButton: some View {
        Button {
            showingFiles = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add files to the conversation")
    }

    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in attachments.add(fileAt: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in attachments.add(imageData: data, name: "pasted.jpg") }
                }
            }
        }
    }
}
