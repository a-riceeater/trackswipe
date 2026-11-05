import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let actions: PanelActions

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Settings") { EmptyView() }
                .padding(.top, 15)

            sectionHeading("Edge Gestures").padding(.top, 14)
            VStack(spacing: Metrics.rowSpacing) {
                SettingRow(symbol: "arrow.left.arrow.right", badgeStyle: .neutral, title: "Swap Sides",
                           subtitle: settings.swapSides ? "Left: Volume · Right: Brightness" : "Left: Brightness · Right: Volume",
                           titleAccessory: nil) {
                    EdgeSwitch(label: "Swap Sides", isOn: $settings.swapSides)
                }
                SettingRow(symbol: "rectangle.bottomhalf.filled", badgeStyle: .neutral, title: "Bottom Quarter Only",
                           subtitle: "Ignore touches above the lower 25%", titleAccessory: nil) {
                    EdgeSwitch(label: "Bottom Quarter Only", isOn: $settings.bottomQuarterOnly)
                }
                SettingRow(symbol: "option", badgeStyle: .neutral, title: "Require Fn or ⌥",
                           subtitle: "Only slide while holding a modifier", titleAccessory: nil) {
                    EdgeSwitch(label: "Require Fn or Option", isOn: $settings.requireModifier)
                }
            }
            .padding(.top, 8)

            PanelDivider().padding(.top, 16)
            sectionHeading("While Sliding").padding(.top, 11)
            VStack(spacing: Metrics.rowSpacing) {
                SettingRow(symbol: "cursorarrow", title: "Freeze Cursor", subtitle: "Pointer stays put while sliding", titleAccessory: nil) {
                    EdgeSwitch(label: "Freeze Cursor", isOn: $settings.freezeCursor)
                }
                SettingRow(symbol: "dial.medium.fill", title: "Fine Control", subtitle: "Hold ⇧⌥ for quarter steps", titleAccessory: nil) {
                    EdgeSwitch(label: "Fine Control", isOn: $settings.fineControl)
                }
            }
            .padding(.top, 8)

            PanelDivider().padding(.top, 16)
            sectionHeading("General").padding(.top, 11)
            VStack(spacing: 13) {
                SettingRow(symbol: "circle.lefthalf.filled", badgeStyle: .neutral, title: "Appearance", subtitle: nil, titleAccessory: nil) {
                    SegmentedChoice(options: AppearanceMode.allCases, selection: $settings.appearance,
                                    title: { $0.title }, accessibilityLabel: "Appearance")
                }
                SettingRow(symbol: "rectangle.bottomthird.inset.filled", badgeStyle: .neutral, title: "Indicator",
                           subtitle: settings.indicatorStyle == .trackEdge ? "Bottom of the screen" : "Apple's volume HUD",
                           titleAccessory: nil) {
                    PopupMenuButton(options: IndicatorStyle.allCases, selection: $settings.indicatorStyle,
                                    title: { $0.title }, accessibilityLabel: "Indicator style", width: 94)
                }
                SettingRow(symbol: "power", title: "Open at Login", subtitle: loginSubtitle, titleAccessory: nil) {
                    EdgeSwitch(label: "Open at Login", isOn: Binding(
                        get: { model.loginItem.isOn },
                        set: { model.setOpenAtLogin($0) }
                    ))
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 18)
            PanelDivider()
            HStack(spacing: 4) {
                Button(action: actions.showDashboard) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                        Text("Back").font(Typography.footer)
                    }
                    .foregroundColor(theme.footerGlyph)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                Text("Version \(AppInfo.shortVersion)")
                    .font(Typography.footer)
                    .foregroundColor(theme.footerGlyph)
                    .padding(.leading, 18)
                    .help("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
                Spacer()
                MoreMenu(actions: actions)
                FooterIconButton(symbol: "power", help: "Quit \(AppInfo.name)", action: actions.quit)
            }
            .frame(height: 24)
            .padding(.top, 8)
            .padding(.bottom, 11)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
    }

    private var loginSubtitle: String? {
        switch model.loginItem {
        case .requiresApproval: return "Approve in System Settings › Login Items"
        case let .unavailable(reason): return reason
        default: return nil
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(Typography.sectionHeading)
            .foregroundColor(theme.primary)
            .accessibilityAddTraits(.isHeader)
    }
}
