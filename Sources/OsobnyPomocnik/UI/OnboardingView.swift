import SwiftUI
import AVFoundation
import Speech

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var axGranted = AXIsProcessTrusted()
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized

    var allGranted: Bool { axGranted && micGranted && speechGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nastavenie povolení")
                .font(.title2.bold())

            Text("Osobný pomocník potrebuje nasledujúce povolenia:")
                .foregroundStyle(.secondary)

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "Potrebné pre globálne klávesové skratky a vloženie textu.",
                granted: axGranted
            ) {
                PermissionsChecker.shared.openAccessibilitySettings()
            }

            PermissionRow(
                icon: "mic.fill",
                title: "Mikrofón",
                description: "Potrebný pre diktovanie.",
                granted: micGranted
            ) {
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async { micGranted = ok }
                }
            }

            PermissionRow(
                icon: "waveform",
                title: "Rozpoznávanie reči",
                description: "Potrebné pre diktovanie do textových polí.",
                granted: speechGranted
            ) {
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async { speechGranted = status == .authorized }
                }
            }

            PermissionRow(
                icon: "camera.viewfinder",
                title: "Nahrávanie obrazovky",
                description: "Potrebné pre OCR – zachytenie oblasti obrazovky.",
                granted: false // runtime-checked by CGWindowList
            ) {
                PermissionsChecker.shared.openScreenRecordingSettings()
            }

            Divider()

            HStack {
                Button("Skontrolovať znova") { refresh() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Zavrieť") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allGranted)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { refresh() }
    }

    private func refresh() {
        axGranted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Povoliť", action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
