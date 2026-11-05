import SwiftUI

/// Actions the popover needs from the app shell (implemented by `MenuBarController`).
struct PanelActions {
    var showSettings: () -> Void = {}
    var showDashboard: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var about: () -> Void = {}
    var resetSettings: () -> Void = {}
    var quit: () -> Void = {}
}

final class PanelNavigation: ObservableObject {
    enum Page { case dashboard, settings }
    @Published var page: Page = .dashboard
}

/// The single popover surface: one panel that navigates between the dashboard and settings.
struct PopoverRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var navigation: PanelNavigation
    let actions: PanelActions
    let minimumHeight: CGFloat

    private var scheme: ColorScheme { settings.appearance == .dark ? .dark : .light }

    var body: some View {
        let theme = Theme.resolve(scheme)
        var pageActions = actions
        pageActions.showSettings = { withAnimation(.easeInOut(duration: 0.18)) { navigation.page = .settings } }
        pageActions.showDashboard = { withAnimation(.easeInOut(duration: 0.18)) { navigation.page = .dashboard } }

        return ZStack {
            switch navigation.page {
            case .dashboard:
                DashboardView(model: model, settings: settings, actions: pageActions)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            case .settings:
                SettingsView(model: model, settings: settings, actions: pageActions)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(width: Metrics.panelWidth)
        .frame(minHeight: minimumHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous)
                .strokeBorder(theme.panelBorder, lineWidth: 0.5)
        )
        .environment(\.theme, theme)
        .environment(\.colorScheme, scheme)
        .tint(theme.accent)
    }
}
