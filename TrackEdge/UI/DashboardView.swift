import SwiftUI

struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            AppGlyph(size: 18)
            Text(title)
                .font(Typography.header)
                .foregroundColor(theme.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .frame(height: 20)
    }
}

struct StatusBadge: View {
    let health: AppModel.Health
    let action: () -> Void
    @Environment(\.theme) private var theme

    private var color: Color {
        switch health {
        case .ready: return theme.green
        case .attention, .starting, .paused: return theme.yellow
        case .noTrackpad: return theme.orange
        case .unavailable: return theme.red
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(health.title)
                    .font(Typography.status)
                    .foregroundColor(theme.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(health.detail)
        .accessibilityLabel("Status: \(health.title). \(health.detail)")
        .accessibilityHint("Opens Diagnostics")
    }
}

struct TelemetryCard: View {
    let brightness: Double?
    let brightnessNote: String?
    let volume: Double?
    let volumeNote: String?
    let muted: Bool
    let activeSlide: SlideTarget?

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            LevelBar(value: brightness, color: theme.orange, highlighted: activeSlide == .brightness)
            column(title: "BRIGHTNESS", symbol: "sun.max.fill", symbolColor: theme.orange,
                   value: brightness, note: brightnessNote, alignment: .leading)
            Spacer(minLength: 8)
            column(title: "VOLUME", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", symbolColor: theme.blue,
                   value: volume, note: muted ? "Muted" : volumeNote, alignment: .trailing)
            LevelBar(value: volume, color: theme.blue, highlighted: activeSlide == .volume, dimmed: muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .frame(height: 108)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.insetBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func column(title: String, symbol: String, symbolColor: Color, value: Double?, note: String?, alignment: HorizontalAlignment) -> some View {
        let leading = alignment == .leading
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                if leading {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(symbolColor)
                }
                Text(title)
                    .font(Typography.caption)
                    .kerning(1.1)
                    .foregroundColor(theme.primary.opacity(0.85))
                if !leading {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(symbolColor)
                }
            }
            .padding(.top, 2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { "\(StepMath.percent($0))" } ?? "—")
                    .font(.system(size: 40, weight: .light).monospacedDigit())
                    .foregroundColor(theme.primary)
                if value != nil {
                    Text("%")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(theme.primary)
                }
            }
            Text(note ?? " ")
                .font(.system(size: 10.5))
                .foregroundColor(theme.secondary)
                .lineLimit(1)
                .opacity(note == nil ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(value.map { "\(StepMath.percent($0)) percent" + (note.map { ", \($0)" } ?? "") } ?? (note ?? "Unavailable"))
    }
}

/// Slim vertical level indicator along the card edge.
struct LevelBar: View {
    let value: Double?
    let color: Color
    var highlighted = false
    var dimmed = false
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(theme.barTrack.opacity(0.55))
                Capsule()
                    .fill(color.opacity(dimmed ? 0.35 : 1))
                    .frame(height: max(value.map { geo.size.height * $0 } ?? 0, value == nil || value == 0 ? 0 : 3))
            }
        }
        .frame(width: highlighted ? 4 : 3)
        .padding(.vertical, 3)
        .animation(.easeOut(duration: 0.12), value: value)
        .accessibilityHidden(true)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let actions: PanelActions

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: AppInfo.name) {
                // Only surface status when something needs attention; "Ready" is implied.
                if model.health != .ready {
                    StatusBadge(health: model.health, action: actions.openDiagnostics)
                }
            }
            .padding(.top, 15)

            TelemetryCard(
                brightness: model.brightness.brightness,
                brightnessNote: model.brightness.isAvailable ? nil : model.brightness.displayName,
                volume: model.volume.volume,
                volumeNote: volumeNote,
                muted: model.volume.muted,
                activeSlide: model.activeSlide
            )
            .padding(.top, 15)

            if !model.accessibilityTrusted {
                AccessibilityHint(systemIndicator: settings.indicatorStyle == .system, action: model.requestAccessibility)
                    .padding(.top, 12)
            }

            VStack(spacing: Metrics.rowSpacing) {
                SettingRow(symbol: "hand.tap.fill", title: "Haptic Feedback", subtitle: hapticSubtitle, titleAccessory: nil) {
                    PopupMenuButton(options: HapticStrength.allCases, selection: $settings.hapticStrength,
                                    title: { $0.title }, accessibilityLabel: "Haptic Feedback strength")
                }
                SettingRow(symbol: "speaker.slash.fill", title: "Quick Mute", subtitle: "Double-tap the top-right corner", titleAccessory: nil) {
                    EdgeSwitch(label: "Quick Mute", isOn: $settings.quickMuteEnabled)
                }
                SettingRow(symbol: "forward.fill", title: "Media Strip", subtitle: "Swipe the bottom edge to skip songs",
                           titleAccessory: AnyView(expandChevron)) {
                    EdgeSwitch(label: "Media Strip", isOn: $settings.mediaStripEnabled)
                }
                if settings.mediaStripExpanded {
                    SettingRow(symbol: "playpause.fill", title: "Tap to Play or Pause", subtitle: "Clicks near the edge can set it off", titleAccessory: nil) {
                        EdgeSwitch(label: "Tap to Play or Pause", isOn: $settings.mediaTapEnabled)
                    }
                    .disabled(!settings.mediaStripEnabled)
                    .transition(.opacity)
                }
            }
            .padding(.top, model.accessibilityTrusted ? 18 : 14)

            PanelDivider().padding(.top, 16)

            VStack(spacing: 0) {
                sliderHeader(symbol: "gauge.with.dots.needle.33percent", title: "Sensitivity",
                             value: String(format: "%g×", settings.sensitivity))
                TickSlider(value: $settings.sensitivity, range: AppSettings.sensitivityRange, step: AppSettings.sensitivityStep,
                           accessibilityLabel: "Sensitivity", valueText: { String(format: "%g times", $0) })
                    .padding(.leading, Metrics.textInset)
                    .padding(.top, 6)
                sliderHeader(symbol: "arrow.left.and.right", title: "Edge Width",
                             value: "\(Int((settings.edgeWidth * 100).rounded()))%")
                    .padding(.top, 13)
                TickSlider(value: $settings.edgeWidth, range: AppSettings.edgeWidthRange, step: AppSettings.edgeWidthStep,
                           accessibilityLabel: "Edge Width", valueText: { "\(Int(($0 * 100).rounded())) percent" })
                    .padding(.leading, Metrics.textInset)
                    .padding(.top, 6)
            }
            .padding(.top, 15)

            Spacer(minLength: 18)
            PanelDivider()
            HStack(spacing: 4) {
                Button(action: actions.showSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape").font(.system(size: 14))
                        Text("Settings").font(Typography.footer)
                    }
                    .foregroundColor(theme.footerGlyph)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                MoreMenu(actions: actions)
                FooterIconButton(symbol: "power", help: "Quit \(AppInfo.name)", action: actions.quit)
            }
            .frame(height: 24)
            .padding(.top, 8)
            .padding(.bottom, 11)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .animation(.easeOut(duration: 0.18), value: settings.mediaStripExpanded)
    }

    private var expandChevron: some View {
        Button {
            settings.mediaStripExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(theme.primary)
                .rotationEffect(.degrees(settings.mediaStripExpanded ? 0 : -90))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.mediaStripExpanded ? "Hide Media Strip options" : "Show Media Strip options")
    }

    private var hapticSubtitle: String {
        switch model.hapticSupport {
        case .unsupported where !model.trackpads.isEmpty: return "Not supported by this trackpad"
        default: return "Clicks as you slide"
        }
    }

    private var volumeNote: String? {
        if model.volume.deviceID == 0 { return "No output device" }
        if model.volume.volume == nil || !model.volume.canSetVolume { return "Fixed volume output" }
        return nil
    }

    private func sliderHeader(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: Metrics.badgeGap) {
            IconBadge(symbol: symbol, style: .neutral)
            Text(title).font(Typography.rowTitle).foregroundColor(theme.primary)
            Spacer()
            Text(value)
                .font(Typography.value)
                .foregroundColor(theme.primary)
                .accessibilityHidden(true)
        }
    }
}

struct AccessibilityHint: View {
    var systemIndicator = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.accent)
            Text(systemIndicator ? "Allow Accessibility for the macOS HUD and media keys" : "Allow Accessibility for media keys")
                .font(.system(size: 11))
                .foregroundColor(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Allow", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }
}

struct MoreMenu: View {
    let actions: PanelActions
    @Environment(\.theme) private var theme
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Menu {
            Button("About \(AppInfo.name)", action: actions.about)
            Button("Check for Updates…", action: actions.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
            Toggle("Automatically Check for Updates", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.setAutomaticallyChecks($0) }
            ))
            Divider()
            Button("Diagnostics…", action: actions.openDiagnostics)
            Divider()
            Button("Reset Settings…", action: actions.resetSettings)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundColor(theme.footerGlyph)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(theme.footerGlyph)
        .accentColor(theme.footerGlyph)
        .fixedSize()
        .frame(width: 26, height: 24)
        .help("More")
        .accessibilityLabel("More")
    }
}
