import Vision
import AppKit
import ScreenCaptureKit

final class OCREngine: Sendable {
    static let shared = OCREngine()
    private init() {}

    /// Captures `rect` (CG coordinates, origin bottom-left) and runs Vision OCR.
    func recognize(in rect: CGRect) async throws -> String {
        let image = try await captureScreen(rect: rect)
        return try await recognizeText(in: image)
    }

    // MARK: - Screen capture via ScreenCaptureKit

    private func captureScreen(rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw OCRError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        // Use full display resolution; we'll crop afterwards
        cfg.width  = display.width
        cfg.height = display.height
        cfg.scalesToFit = false
        cfg.showsCursor = false

        let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        // Crop to the requested rectangle
        // SCScreenshotManager returns image in display pixel coords (origin top-left)
        let displayH = CGFloat(display.height)
        let cropRect = CGRect(
            x: rect.minX,
            y: displayH - rect.maxY, // flip Y
            width: rect.width,
            height: rect.height
        )
        guard let cropped = fullImage.cropping(to: cropRect) else {
            throw OCRError.captureFailed
        }
        return cropped
    }

    // MARK: - Vision OCR

    private func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["sk-SK", "en-US"]

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum OCRError: LocalizedError {
        case noDisplay
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .noDisplay:     "Nepodarilo sa nájsť displej."
            case .captureFailed: "Nepodarilo sa zachytiť oblasť. Skontroluj povolenie Screen Recording."
            }
        }
    }
}
