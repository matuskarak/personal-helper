import SwiftUI
import AppKit

/// Brand design tokens (Ozvena design system). Source: `Vyvoj/DesignSystem/farby.md` +
/// `typografia.md` — a local design handoff folder, gitignored (see CLAUDE.md), not part of
/// this repo. That path only resolves on a machine that already has it; treat the values below
/// as the actual source of truth if you don't.
/// WCAG AAA verified pairs; light is the default appearance, dark is a supported secondary mode.
/// Light/dark is resolved through `NSColor(name:dynamicProvider:)` — SPM has no asset catalog,
/// and this keeps every literal in one file. Anything outside `Theme` should not spell a hex.
enum Theme {

    // MARK: - Adaptive tokens (follow macOS appearance)

    static let surfaceBase   = adaptive(light: 0xF7F4EC, dark: 0x14161C)
    static let surfaceCard   = adaptive(light: 0xEFEAD9, dark: 0x1C1F27)
    static let border        = adaptive(light: 0xDED5BE, dark: 0x2E323E)
    static let textPrimary   = adaptive(light: 0x181A1F, dark: 0xF2EFE6)
    static let textSecondary = adaptive(light: 0x524F47, dark: 0xA6A99C)

    /// Decorative brand colours — icons, logo, focus rings, chart fills. Not for text on light.
    static let brandBlue  = adaptive(light: 0x2E4BD1, dark: 0x8C9DF2)
    static let brandAmber = adaptive(light: 0xB8722A, dark: 0xE0A268)

    /// "Safe" variants — dark enough to carry white text / act as button fills.
    /// Dark mode keeps the saturated base colour: the pale dark-mode decorative tints
    /// (#8C9DF2 / #E0A268) read well as text but not as a fill under white labels.
    static let brandBlueSafe  = adaptive(light: 0x24399E, dark: 0x2E4BD1)
    static let brandAmberSafe = adaptive(light: 0x7A4A1C, dark: 0x7A4A1C)

    /// Semantic states. Blue doubles as "info", amber as "warning" — no extra hues for those.
    static let success = adaptive(light: 0x125A41, dark: 0x5FD1A8)
    static let error   = adaptive(light: 0x9E2318, dark: 0xF0897E)

    // MARK: - HUD (floating pills)

    /// Floating pills (dictation + reading) are always dark regardless of system appearance
    /// (client decision 2026-09-11, macOS HUD convention). Values from Komponenty/*.md.
    enum HUD {
        static let background = Color(hex: 0x1E212A).opacity(0.9)
        static let border     = Color.white.opacity(0.08)
        static let hover      = Color.white.opacity(0.07)
        static let divider    = Color.white.opacity(0.10)
        static let text       = Color(hex: 0xF2EFE6)
        static let textMeta   = Color(hex: 0xA6A99C)
        static let icon       = Color(hex: 0xC7C9D1)
        static let iconMuted  = Color(hex: 0xA6A99C)
        /// Equalizer bars / decorative accent on dark.
        static let blue       = Color(hex: 0x8C9DF2)
        /// Badge fills (white glyph on top).
        static let badgeActive  = Color(hex: 0x2E4BD1)
        static let badgeWarning = Color(hex: 0xE0A268)
        static let badgeError   = Color(hex: 0x9E2318)
        static let badgeSuccess = Color(hex: 0x125A41)
        static let shadow = Color.black.opacity(0.45)
    }

    /// Result of an API-key check: message + how to colour it, instead of an emoji-prefixed
/// string the UI had to sniff (also kept the emoji out of what the user actually reads).
enum KeyCheck {
    case ok(String), warning(String), failure(String)
    var message: String {
        switch self { case .ok(let m), .warning(let m), .failure(let m): m }
    }
    var color: Color {
        switch self {
        case .ok: Theme.success
        case .warning: Theme.brandAmberSafe
        case .failure: Theme.error
        }
    }
}

// MARK: - Typography

    /// Bricolage Grotesque SemiBold (600) — wordmark, window/tab titles, section headers. Never body copy.
    static func title(_ size: CGFloat) -> Font { .custom("BricolageGrotesque-SemiBold", size: size) }
    /// Atkinson Hyperlegible — all running UI text (designed for low-vision readers).
    static func body(_ size: CGFloat = 13) -> Font { .custom("AtkinsonHyperlegible-Regular", size: size) }
    static func bodyBold(_ size: CGFloat = 13) -> Font { .custom("AtkinsonHyperlegible-Bold", size: size) }

    // MARK: - Helpers

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

private extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
