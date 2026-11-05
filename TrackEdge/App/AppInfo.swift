import Foundation

/// Central place for product naming so the working name "TrackEdge" is easy to change later
/// (also update `PRODUCT_NAME` / `CFBundleDisplayName` in project.yml).
enum AppInfo {
    static let name: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TrackEdge"
    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "dev.trackedge.TrackEdge"
    static let version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// "1.0" style string for the footer: drops a trailing ".0" patch component.
    static var shortVersion: String {
        var parts = version.split(separator: ".").map(String.init)
        if parts.count == 3, parts[2] == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
