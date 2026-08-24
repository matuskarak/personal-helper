import SwiftUI
import AppKit

/// A pull-down field showing the current shortcut. Clicking it opens a menu to either record
/// the next key press, or pick modifiers + a function key directly — F13+ often isn't a
/// physical key on a laptop keyboard (and F-keys are frequently intercepted as brightness/
/// volume/media controls before they'd ever reach a key-press recorder), so picking one from a
/// list is the only reliable way to map it. Both paths live inside the same field/menu rather
/// than as separate controls.
struct ShortcutRecorderView: View {
    @Binding var shortcut: Shortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var pendingMods: NSEvent.ModifierFlags = [.command, .shift]

    var body: some View {
        Menu {
            Button("Nahrať stlačením klávesy…") { startRecording() }
            Divider()
            Toggle("⌃ Control", isOn: modBinding(.control))
            Toggle("⌥ Option",  isOn: modBinding(.option))
            Toggle("⇧ Shift",   isOn: modBinding(.shift))
            Toggle("⌘ Command", isOn: modBinding(.command))
            Menu("Funkčná klávesa") {
                ForEach(1...20, id: \.self) { n in
                    Button("F\(n)") {
                        shortcut = Shortcut(keyCode: Shortcut.fKeyCode(n), modifierFlags: pendingMods)
                    }
                }
            }
        } label: {
            Text(isRecording ? "Stlač skratku…" : shortcut.displayString)
                .monospacedDigit()
        }
        .fixedSize()
        .foregroundStyle(isRecording ? .red : .primary)
        .onDisappear { stopRecording() }
    }

    private func modBinding(_ flag: NSEvent.ModifierFlags) -> Binding<Bool> {
        Binding(
            get: { pendingMods.contains(flag) },
            set: { on in
                if on { pendingMods.insert(flag) } else { pendingMods.remove(flag) }
            }
        )
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Require at least one modifier (prevents accidental single-key capture)
            guard !mods.isEmpty, event.keyCode != 53 /* ESC cancels */ else {
                self.stopRecording()
                return nil
            }
            self.shortcut = Shortcut(keyCode: Int(event.keyCode), modifierFlags: mods)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// One shortcut-able action ("Diktovanie", "Čítať text", ...) with all of its mapped
/// shortcuts — the primary one plus any extras (e.g. a laptop-keyboard combo and a separate
/// external-keyboard combo for the same action). Any of them triggers the action. The label and
/// first shortcut share one line; any extra mapped shortcuts follow on their own line below.
struct ShortcutMappingRow: View {
    let label: String
    let action: ShortcutStore.Action

    @State private var list: [Shortcut] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 4) {
                    if index == 0 {
                        Text(label).font(.body)
                    }
                    Spacer()
                    if index == list.count - 1 && list.count < ShortcutStore.maxPerAction {
                        Button {
                            list.append(action.defaultShortcut)
                            save()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain).pointingHandCursor()
                        .foregroundStyle(.secondary)
                        .help("Pridať ďalšiu skratku pre túto akciu")
                    }
                    ShortcutRecorderView(shortcut: Binding(
                        get: { list[index] },
                        set: { list[index] = $0; save() }
                    ))
                    if index > 0 {
                        Button {
                            list.remove(at: index)
                            save()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).pointingHandCursor()
                        .foregroundStyle(.secondary)
                        .help("Odstrániť túto skratku")
                    } else {
                        // Invisible placeholder the same size as the x-button above/below, so the
                        // primary (non-removable) shortcut's pill lines up with the others instead
                        // of sitting further right.
                        Image(systemName: "xmark.circle.fill").hidden()
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear { list = ShortcutStore.shared.shortcuts(for: action) }
    }

    private func save() {
        ShortcutStore.shared.setShortcuts(list, for: action)
    }
}
