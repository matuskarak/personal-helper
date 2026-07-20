import SwiftUI
import AppKit

/// A button that, when clicked, records the next key press as a shortcut.
struct ShortcutRecorderView: View {
    @Binding var shortcut: Shortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Stlač skratku…" : shortcut.displayString)
                .monospacedDigit()
                .frame(minWidth: 80)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isRecording ? .red : .primary)
        .onDisappear { stopRecording() }
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
