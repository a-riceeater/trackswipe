import AppKit
import CoreGraphics
import os

protocol CursorFreezing: AnyObject {
    var isFrozen: Bool { get }
    func freeze()
    /// Called on every touch frame while frozen; re-pins the pointer and feeds the watchdog.
    func maintain()
    func release()
}

/// Keeps the pointer still while an edge slide is active.
///
/// Two layers, both public CoreGraphics API:
/// 1. `CGAssociateMouseAndMouseCursorPosition(false)` decouples trackpad motion from the cursor.
/// 2. If anything still moves the cursor (the association is per-connection and macOS may restore it
///    for a background app), it is warped back to the pinned point on the next frame.
///
/// Guaranteed release: `release()` is called on slide end, multi-finger cancellation, device loss,
/// sleep, session switch, settings change and app termination; additionally a watchdog releases the
/// cursor if no touch frame has arrived for 0.6 s while frozen, so a lost "finger up" can never leave the
/// pointer stuck.
final class CursorManager: CursorFreezing {
    private let lock = NSLock()
    private let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "Cursor")
    private var frozen = false
    private var pinnedPoint: CGPoint = .zero
    private var lastActivity: CFAbsoluteTime = 0
    private var watchdog: DispatchSourceTimer?
    private let watchdogTimeout: CFTimeInterval = 0.6

    var isFrozen: Bool { lock.sync { frozen } }

    func freeze() {
        lock.sync {
            guard !frozen else { return }
            pinnedPoint = CGEvent(source: nil)?.location ?? .zero
            lastActivity = CFAbsoluteTimeGetCurrent()
            frozen = true
            CGAssociateMouseAndMouseCursorPosition(0)
            startWatchdog()
        }
    }

    func maintain() {
        if !isFrozen {
            // The watchdog may have released during a pause in frames; the slide is still active.
            freeze()
            return
        }
        lock.sync {
            guard frozen else { return }
            lastActivity = CFAbsoluteTimeGetCurrent()
            if let current = CGEvent(source: nil)?.location,
               abs(current.x - pinnedPoint.x) > 0.5 || abs(current.y - pinnedPoint.y) > 0.5 {
                CGWarpMouseCursorPosition(pinnedPoint)
                CGAssociateMouseAndMouseCursorPosition(0)
            }
        }
    }

    func release() {
        lock.sync { releaseLocked() }
    }

    /// Unconditional restore used at launch and termination, even if we think we are not frozen.
    func forceRelease() {
        lock.sync {
            releaseLocked()
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private func releaseLocked() {
        watchdog?.cancel()
        watchdog = nil
        guard frozen else { return }
        frozen = false
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.sync {
                guard self.frozen, CFAbsoluteTimeGetCurrent() - self.lastActivity > self.watchdogTimeout else { return }
                self.log.notice("Watchdog released a frozen cursor after touch frames stopped")
                self.releaseLocked()
            }
        }
        watchdog = timer
        timer.resume()
    }
}
