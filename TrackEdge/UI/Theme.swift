import SwiftUI

/// Design tokens tuned against `references/03_menu_bar_ui.png` (light) with an intentional dark counterpart.
struct Theme {
    let surface: Color
    let panelBorder: Color
    let inset: Color
    let insetBorder: Color
    let primary: Color
    let secondary: Color
    let divider: Color
    let accent: Color
    let badgeNeutral: Color
    let badgeNeutralGlyph: Color
    let orange: Color
    let blue: Color
    let green: Color
    let yellow: Color
    let red: Color
    let track: Color
    let trackDot: Color
    let barTrack: Color
    let switchOff: Color
    let switchOffBorder: Color
    let controlFill: Color
    let controlBorder: Color
    let footerGlyph: Color

    static let light = Theme(
        surface: Color(hex: 0xEBEBED),
        panelBorder: Color.black.opacity(0.10),
        inset: Color(hex: 0xDFDFE1),
        insetBorder: Color.black.opacity(0.05),
        primary: Color(hex: 0x1C1C1E),
        secondary: Color(hex: 0x4E4E55),
        divider: Color(hex: 0xD3D3D7),
        accent: Color(hex: 0x6A44EF),
        badgeNeutral: Color(hex: 0xDADADD),
        badgeNeutralGlyph: Color(hex: 0x2C2C30),
        orange: Color(hex: 0xFF9A17),
        blue: Color(hex: 0x1684FF),
        green: Color(hex: 0x21CB53),
        yellow: Color(hex: 0xF5B400),
        red: Color(hex: 0xFF453A),
        track: Color(hex: 0xDCDCDF),
        trackDot: Color(hex: 0xB3B3B9),
        barTrack: Color(hex: 0xCDCDD1),
        switchOff: Color(hex: 0xE4E4E6),
        switchOffBorder: Color(hex: 0xC9C9CE),
        controlFill: Color.white,
        controlBorder: Color.black.opacity(0.12),
        footerGlyph: Color(hex: 0x3A3A3E)
    )

    static let dark = Theme(
        surface: Color(hex: 0x232326),
        panelBorder: Color.white.opacity(0.12),
        inset: Color(hex: 0x2E2E32),
        insetBorder: Color.white.opacity(0.06),
        primary: Color(hex: 0xF2F2F5),
        secondary: Color(hex: 0xA3A3AB),
        divider: Color(hex: 0x3A3A3F),
        accent: Color(hex: 0x7D5CF7),
        badgeNeutral: Color(hex: 0x3A3A40),
        badgeNeutralGlyph: Color(hex: 0xE6E6EA),
        orange: Color(hex: 0xFF9F2E),
        blue: Color(hex: 0x3D95FF),
        green: Color(hex: 0x30D158),
        yellow: Color(hex: 0xFFC83D),
        red: Color(hex: 0xFF5A4F),
        track: Color(hex: 0x3A3A3F),
        trackDot: Color(hex: 0x65656D),
        barTrack: Color(hex: 0x45454B),
        switchOff: Color(hex: 0x3A3A3F),
        switchOffBorder: Color(hex: 0x4A4A50),
        controlFill: Color(hex: 0x48484E),
        controlBorder: Color.white.opacity(0.10),
        footerGlyph: Color(hex: 0xD0D0D6)
    )

    static func resolve(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .dark : .light }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Metrics {
    static let panelWidth: CGFloat = 336
    static let panelCornerRadius: CGFloat = 18
    static let horizontalPadding: CGFloat = 15
    static let badgeSize: CGFloat = 27
    static let badgeGap: CGFloat = 11
    static var textInset: CGFloat { badgeSize + badgeGap }
    static let rowSpacing: CGFloat = 11
}

enum Typography {
    static let header = Font.system(size: 14.5, weight: .semibold)
    static let rowTitle = Font.system(size: 13.5, weight: .medium)
    static let rowSubtitle = Font.system(size: 11.5)
    static let sectionHeading = Font.system(size: 12, weight: .semibold)
    static let caption = Font.system(size: 10.5, weight: .semibold)
    static let value = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let footer = Font.system(size: 12.5)
    static let status = Font.system(size: 11.5)
}
