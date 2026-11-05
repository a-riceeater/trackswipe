import AppKit
import SwiftUI

// MARK: - Icon badge

struct IconBadge: View {
    enum Style { case accent, neutral }

    let symbol: String
    var style: Style = .accent
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(style == .accent ? theme.accent : theme.badgeNeutral)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(style == .accent ? .white : theme.badgeNeutralGlyph)
        }
        .frame(width: Metrics.badgeSize, height: Metrics.badgeSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Setting row

struct SettingRow<Trailing: View>: View {
    let symbol: String?
    var badgeStyle: IconBadge.Style = .accent
    let title: String
    var subtitle: String?
    var titleAccessory: AnyView?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.badgeGap) {
            if let symbol {
                IconBadge(symbol: symbol, style: badgeStyle)
            } else {
                Color.clear.frame(width: Metrics.badgeSize, height: 1)
            }
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(Typography.rowTitle)
                        .foregroundColor(theme.primary)
                    if let titleAccessory { titleAccessory }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.rowSubtitle)
                        .foregroundColor(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: Metrics.badgeSize)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(symbol: String?, badgeStyle: IconBadge.Style = .accent, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, badgeStyle: badgeStyle, title: title, subtitle: subtitle, titleAccessory: nil) { EmptyView() }
    }
}

// MARK: - Switch

/// Compact accent-coloured switch. Uses a real `Toggle`, so accessibility and the
/// keyboard (Space when focused) behave like a native switch.
struct EdgeSwitchStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? theme.accent : theme.switchOff)
                .overlay(Capsule().strokeBorder(on ? Color.clear : theme.switchOffBorder, lineWidth: 0.75))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 0.8, x: 0, y: 0.5)
                .padding(2)
        }
        .frame(width: 29, height: 17)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

struct EdgeSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(EdgeSwitchStyle())
    }
}

// MARK: - Tick slider

/// Discrete slider with a capsule track, accent fill, white thumb and tick dots, as in the reference.
struct TickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accessibilityLabel: String
    let valueText: (Double) -> String

    @Environment(\.theme) private var theme

    private let height: CGFloat = 17
    private let thumbInset: CGFloat = 1.5
    private var thumbSize: CGFloat { height - thumbInset * 2 }
    private var tickCount: Int { Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 }
    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - thumbSize - thumbInset * 2
            let thumbX = thumbInset + travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                // Tick dots in the unfilled part of the track.
                ForEach(0..<tickCount, id: \.self) { index in
                    let x = thumbInset + thumbSize / 2 + travel * Double(index) / Double(max(tickCount - 1, 1))
                    if x > thumbX + thumbSize + 3 {
                        Circle()
                            .fill(theme.trackDot)
                            .frame(width: 2.5, height: 2.5)
                            .position(x: x, y: height / 2)
                    }
                }
                Capsule()
                    .fill(theme.accent)
                    .frame(width: thumbX + thumbSize + thumbInset)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbX)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = (drag.location.x - thumbInset - thumbSize / 2) / max(travel, 1)
                        set(fraction: raw)
                    }
            )
        }
        .frame(height: height)
        // Deliberately not keyboard-focusable: as the first focusable control in the popover it would grab
        // focus on every open (showing the system focus ring) and stray arrow keys would change the value.
        // VoiceOver can still adjust it through the adjustable action below.
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func set(fraction raw: Double) {
        let f = min(max(raw, 0), 1)
        let steps = (f * (range.upperBound - range.lowerBound) / step).rounded()
        let newValue = range.lowerBound + steps * step
        if abs(newValue - value) > step / 10 { value = newValue }
    }

    private func nudge(_ direction: Double) {
        value = min(max(value + direction * step, range.lowerBound), range.upperBound)
    }
}

// MARK: - Segmented choice

struct SegmentedChoice<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let accessibilityLabel: String

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12))
                        .foregroundColor(theme.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(selected ? theme.controlFill : Color.clear)
                                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 0.6, x: 0, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(1.5)
        .frame(width: 82)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Pop-up menu button

/// Compact pop-up button (white bezel + accent chevron box) that opens a genuine `NSMenu`
/// positioned over the control, like `NSPopUpButton`.
struct PopupMenuButton<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let accessibilityLabel: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(title(selection))
                .font(.system(size: 12))
                .foregroundColor(theme.primary)
                .padding(.leading, 7)
            Spacer(minLength: 4)
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(theme.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
            .padding(.trailing, 2.5)
        }
        .frame(width: 77, height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.controlFill)
                .shadow(color: .black.opacity(0.10), radius: 0.8, x: 0, y: 0.5)
        )
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(theme.controlBorder, lineWidth: 0.5))
        .overlay(
            MenuTrigger(items: options.map { ($0, title($0)) }, selected: selection) { selection = $0 }
        )
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title(selection))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            switch direction {
            case .increment: selection = options[min(index + 1, options.count - 1)]
            case .decrement: selection = options[max(index - 1, 0)]
            @unknown default: break
            }
        }
    }
}

private struct MenuTrigger<Option: Hashable>: NSViewRepresentable {
    let items: [(Option, String)]
    let selected: Option
    let onSelect: (Option) -> Void

    func makeNSView(context: Context) -> TriggerView {
        let view = TriggerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: TriggerView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: MenuTrigger

        init(parent: MenuTrigger) { self.parent = parent }

        func showMenu(in view: NSView) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            var selectedItem: NSMenuItem?
            for (index, entry) in parent.items.enumerated() {
                let item = NSMenuItem(title: entry.1, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                if entry.0 == parent.selected {
                    item.state = .on
                    selectedItem = item
                }
                menu.addItem(item)
            }
            menu.font = NSFont.systemFont(ofSize: 12)
            menu.popUp(positioning: selectedItem, at: NSPoint(x: -2, y: view.bounds.height - 1), in: view)
        }

        @objc func pick(_ sender: NSMenuItem) {
            guard parent.items.indices.contains(sender.tag) else { return }
            parent.onSelect(parent.items[sender.tag].0)
        }
    }

    final class TriggerView: NSView {
        weak var coordinator: Coordinator?
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) { coordinator?.showMenu(in: self) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Footer button

struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(theme.footerGlyph)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Divider

struct PanelDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.divider).frame(height: 1)
    }
}
