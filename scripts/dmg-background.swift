#!/usr/bin/env swift
// ---------------------------------------------------------------------
// dmg-background.swift — Generuje pozadie pre inštalačné DMG okno (Ozvena).
//
// Použitie:
//   swift scripts/dmg-background.swift <out.png>
//
// Kreslí retina PNG (1440×960 px @ 144 dpi, zobrazené vo Finderi ako 720×480 pt).
//
// DÔLEŽITÉ PREVIAZANIE S make-dmg.sh:
// Táto vrstva necháva prázdne miesto, kam Finder sám vykreslí ikony (app a
// Applications symlink) na súradniciach, ktoré make-dmg.sh nastavuje cez
// AppleScript (`set position of item … to {x, y}`). Ak sa tu zmenia
// POINT_APP_ICON_CENTER / POINT_APPLICATIONS_CENTER, treba zrkadlovo upraviť
// aj pozície v make-dmg.sh (a naopak) — inak ikony prekryjú text alebo šípku.
//   Aktuálne (v bodoch, origin top-left, 720×540 plátno):
//     app ikona:      x=190, y=185
//     Applications:    x=530, y=185
// Layout (2026-09-19 prerobené — ikony+panel sa predtým prekrývali):
//   title y≈40, ikony/šípka stred y≈185 (ikony 112pt + label musí skončiť dosť nad
//   panelom), panel od y≈330 po y≈520 (≥20pt nad spodným okrajom 540pt plátna).
// ---------------------------------------------------------------------

import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("Použitie: swift dmg-background.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = CommandLine.arguments[1]

// Plátno v bodoch — musí zodpovedať content veľkosti Finder okna v make-dmg.sh.
let widthPt: CGFloat = 720
let heightPt: CGFloat = 540
let scale: CGFloat = 2.0 // retina

// Brand farby "Ozvena"
let colorBackground = NSColor(srgbRed: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEC / 255, alpha: 1)
let colorTextPrimary = NSColor(srgbRed: 0x18 / 255, green: 0x1A / 255, blue: 0x1F / 255, alpha: 1)
let colorTextSecondary = NSColor(srgbRed: 0x52 / 255, green: 0x4F / 255, blue: 0x47 / 255, alpha: 1)
let colorAccentBlue = NSColor(srgbRed: 0x2E / 255, green: 0x4B / 255, blue: 0xD1 / 255, alpha: 1)
let colorAccentAmber = NSColor(srgbRed: 0xB8 / 255, green: 0x72 / 255, blue: 0x2A / 255, alpha: 1)
let colorPanelFill = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.70)
let colorPanelBorder = NSColor(srgbRed: 0xDE / 255, green: 0xD5 / 255, blue: 0xBE / 255, alpha: 1)

// Empty slots for Finder icon placement (points, origin top-left) — see header comment.
let appIconCenter = CGPoint(x: 190, y: 185)
let applicationsCenter = CGPoint(x: 530, y: 185)

let pixelWidth = Int(widthPt * scale)
let pixelHeight = Int(heightPt * scale)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("Nepodarilo sa vytvoriť NSBitmapImageRep\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: widthPt, height: heightPt) // 144 dpi keď je pixel-rozmer 2×

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("Nepodarilo sa vytvoriť NSGraphicsContext\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.current = ctx

// Helper: convert top-left-origin y (as specified in the design) to AppKit bottom-left origin.
func flipY(_ yFromTop: CGFloat) -> CGFloat { heightPt - yFromTop }

// Background fill
colorBackground.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: widthPt, height: heightPt)).fill()

// --- Title ---
let titleFont = NSFont.boldSystemFont(ofSize: 26)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: colorTextPrimary,
]
let title = "Inštalácia Ozveny"
let titleSize = title.size(withAttributes: titleAttrs)
let titleOrigin = CGPoint(x: 40, y: flipY(40) - titleSize.height)
title.draw(at: titleOrigin, withAttributes: titleAttrs)

// --- Arrow between app icon slot and Applications slot ---
let arrowY = flipY(185)
let arrowStartX: CGFloat = 280
let arrowEndX: CGFloat = 440
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 4
colorAccentBlue.setStroke()
arrowPath.move(to: CGPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: CGPoint(x: arrowEndX - 14, y: arrowY))
arrowPath.stroke()
// Arrowhead
let headPath = NSBezierPath()
headPath.move(to: CGPoint(x: arrowEndX - 14, y: arrowY + 10))
headPath.line(to: CGPoint(x: arrowEndX, y: arrowY))
headPath.line(to: CGPoint(x: arrowEndX - 14, y: arrowY - 10))
colorAccentBlue.setFill()
headPath.lineJoinStyle = .round
headPath.fill()
headPath.close()

// Caption under the arrow — sits between the icons horizontally (so it clears the icon
// labels below each icon slot), well above the panel starting at y=330.
let captionFont = NSFont.systemFont(ofSize: 13)
let captionAttrs: [NSAttributedString.Key: Any] = [
    .font: captionFont,
    .foregroundColor: colorTextSecondary,
]
let caption = "1. Potiahni Ozvenu do Aplikácií"
let captionSize = caption.size(withAttributes: captionAttrs)
let captionCenterX = (arrowStartX + arrowEndX) / 2
caption.draw(
    at: CGPoint(x: captionCenterX - captionSize.width / 2, y: flipY(232)),
    withAttributes: captionAttrs
)

// --- Lower panel (rounded rect) ---
// y≈330 to y≈520 (≥20pt above the 540pt bottom edge), per layout note in header comment.
let panelRect = NSRect(x: 40, y: flipY(520), width: widthPt - 80, height: 520 - 330)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 14, yRadius: 14)
colorPanelFill.setFill()
panelPath.fill()
colorPanelBorder.setStroke()
panelPath.lineWidth = 1
panelPath.stroke()

// Panel text — numbered steps, wrapped, with bold keywords via a paragraph-by-paragraph
// attributed string built from segments. Panel is 190pt tall (330→520) minus 20pt inset on
// each side = 150pt usable height. Rebalanced 2026-09-19 (see CLAUDE.md): the panel used to
// hold a third note ("appka sa zatiaľ volá OsobnyPomocnik", no longer true — CFBundleExecutable
// is Ozvena since the rename); removing it freed up room, so paragraphSpacing widened from the
// original tight 10 to 16 instead of leaving that space empty at the bottom.
let paragraphStyle = NSMutableParagraphStyle()
paragraphStyle.lineSpacing = 4
paragraphStyle.paragraphSpacing = 16

let bodyFont = NSFont.systemFont(ofSize: 13)
let boldBodyFont = NSFont.boldSystemFont(ofSize: 13)

func segment(_ text: String, bold: Bool = false) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: bold ? boldBodyFont : bodyFont,
        .foregroundColor: colorTextPrimary,
        .paragraphStyle: paragraphStyle,
    ])
}

let panelText = NSMutableAttributedString()
panelText.append(segment("2. Otvor Ozvenu v priečinku Aplikácie. macOS ju prvýkrát zablokuje — klikni "))
panelText.append(segment("Hotovo", bold: true))
panelText.append(segment(".\n"))
panelText.append(segment("3. Otvor Systémové nastavenia → Súkromie a bezpečnosť, zroluj úplne dole a klikni "))
panelText.append(segment("Otvoriť napriek tomu", bold: true))
panelText.append(segment(". Potvrď heslom alebo Touch ID.\n"))
let lastNoteStyle = NSMutableParagraphStyle()
lastNoteStyle.lineSpacing = 4
lastNoteStyle.paragraphSpacing = 0
panelText.append(NSAttributedString(string: "Toto robíš len raz — ďalej ťa prevedie Ozvena sama.", attributes: [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: colorTextSecondary,
    .paragraphStyle: lastNoteStyle,
]))

let textInset: CGFloat = 20
let textRect = NSRect(
    x: panelRect.minX + textInset,
    y: panelRect.minY + textInset,
    width: panelRect.width - textInset * 2,
    height: panelRect.height - textInset * 2
)
panelText.draw(with: textRect, options: [.usesLineFragmentOrigin])

NSGraphicsContext.restoreGraphicsState()

// Suppress "unused" warnings for slot constants that document icon placement (used only
// as documentation for make-dmg.sh coupling — keep referenced so the compiler is happy).
_ = appIconCenter
_ = applicationsCenter

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Nepodarilo sa zakódovať PNG\n".data(using: .utf8)!)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("✅ Pozadie vygenerované: \(outPath) (\(pixelWidth)×\(pixelHeight)px)")
} catch {
    FileHandle.standardError.write("Zápis zlyhal: \(error)\n".data(using: .utf8)!)
    exit(1)
}
