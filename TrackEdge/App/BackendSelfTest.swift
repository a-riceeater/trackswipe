#if DEBUG
import Foundation

/// DEBUG-only end-to-end check of the real system backends, independent of gesture recognition.
/// Run: `TrackEdge.app/Contents/MacOS/TrackEdge -selfTest YES`
/// Nudges volume and brightness by one step each way through every available route, then restores
/// the original values with direct writes. Prints a report to stdout and exits.
@MainActor
enum BackendSelfTest {
    static func run(model: AppModel) {
        func line(_ s: String) { print("[selftest] \(s)") }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }

        line("version \(AppInfo.version) (\(AppInfo.build))")
        line("multitouch: \(model.providerState)")
        for d in model.trackpads {
            line("trackpad: \(d.name) \(d.widthMM)×\(d.heightMM)mm family \(d.familyID) forceTouch=\(d.forceTouch) haptics=\(model.haptics.support(for: d.id).description)")
        }
        line("accessibility trusted: \(PermissionsController.accessibilityTrusted) → level route: \(model.volumeService.route.rawValue)")
        line("media route: \(model.media.route.rawValue); direct-route feedback: \(model.osd.route.rawValue)")

        // Volume
        let audioBefore = model.audio.snapshot()
        line("volume: \(audioBefore.deviceName) value=\(audioBefore.volume.map { String(format: "%.4f", $0) } ?? "nil") settable=\(audioBefore.canSetVolume) muted=\(audioBefore.muted)")
        if let original = audioBefore.volume, audioBefore.canSetVolume {
            for (label, steps, fine) in [("up", 1, false), ("down", -1, false), ("fine up", 1, true), ("fine down", -1, true)] {
                model.volumeService.beginAdjust()
                let expected = model.volumeService.adjust(steps: steps, fine: fine)?.value ?? -1
                model.volumeService.endAdjust()
                settle()
                let actual = model.audio.snapshot().volume ?? -1
                line(String(format: "volume %@: expected %.4f actual %.4f %@", label, expected, actual, abs(expected - actual) < 0.02 ? "OK" : "MISMATCH"))
            }
            model.audio.setVolume(original)
            if audioBefore.muted { model.audio.setMuted(true) }
            settle()
            line(String(format: "volume restored to %.4f", model.audio.snapshot().volume ?? -1))
        }

        // Brightness
        let display = model.display.snapshot()
        line("brightness: \(display.displayName) value=\(display.brightness.map { String(format: "%.4f", $0) } ?? "nil")")
        if let original = display.brightness {
            for (label, steps, fine) in [("up", 1, false), ("down", -1, false), ("fine up", 1, true), ("fine down", -1, true)] {
                model.brightnessService.beginAdjust()
                let expected = model.brightnessService.adjust(steps: steps, fine: fine)?.value ?? -1
                model.brightnessService.endAdjust()
                settle()
                let actual = model.display.read(display.displayID) ?? -1
                line(String(format: "brightness %@: expected %.4f actual %.4f %@", label, expected, actual, abs(expected - actual) < 0.02 ? "OK" : "MISMATCH"))
            }
            model.display.set(original, on: display.displayID)
            settle()
            line(String(format: "brightness restored to %.4f", model.display.read(display.displayID) ?? -1))
        }

        // Cursor freeze/release
        model.cursor.freeze()
        let frozen = model.cursor.isFrozen
        model.cursor.release()
        line("cursor freeze: frozen=\(frozen) released=\(!model.cursor.isFrozen)")
        model.shutdown()
    }
}
#endif
