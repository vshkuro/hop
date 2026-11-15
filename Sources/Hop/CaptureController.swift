import AppKit
import HopCore
import ScreenCaptureKit
import SwiftUI

/// Takes the picture: an area framed by hand, the window under the pointer, a
/// whole display, or the last rectangle again.
///
/// The frame is ours rather than the system's `screencapture -i`, which never
/// says WHICH rectangle was chosen — without that "repeat the last area" cannot
/// exist. An area is framed over a still of the screen taken the moment the
/// button is pressed, not over the live one. SPEC: docs/spec.md — "Screenshot".
@MainActor
final class CaptureController: ObservableObject {
    enum Mode {
        case area
        case window
        case screen
        case repeatLast
    }

    enum State: Equatable {
        case idle
        case framing
        case counting(Int)
        case denied
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastRect: CaptureRect?

    /// Handed the picture and the rectangle it came from.
    var onCaptured: ((NSImage, CaptureRect) -> Void)?

    private let overlay = MarkupOverlayController()
    private var delaySeconds: Int { UserDefaults.standard.integer(forKey: "shotDelay") }
    private var showsPointer: Bool { UserDefaults.standard.bool(forKey: "shotPointer") }

    func capture(_ mode: Mode) {
        // SPEC: docs/spec.md — a refusal or a failed capture does not lock the module.
        switch state {
        case .framing, .counting: return
        case .idle, .denied, .failed: break
        }
        guard !Snapshot.active else { return }
        // SPEC: docs/spec.md — "Screen recording is asked for before a module that reads the screen opens".
        guard CGPreflightScreenCaptureAccess() else {
            PermissionRepair.askForTheScreen()
            state = .denied
            return
        }

        switch mode {
        case .area:
            frameAnArea()
        case .window:
            takeWindowUnderPointer()
        case .screen:
            takeWholeScreen()
        case .repeatLast:
            guard let rect = lastRect else {
                frameAnArea()
                return
            }
            shoot(rect)
        }
    }

    /// The screens as they stood when the button was pressed, one still per
    /// display. The frame is drawn over these and the pick is cut out of them,
    /// so a menu, a tooltip or a hover state that dies with the first click
    /// is still in the shot. SPEC: docs/spec.md — "Screenshot", the frozen screen.
    private struct Still {
        let image: CGImage
        let scale: Double
    }

    private var stills: [UInt32: Still] = [:]

    /// The delay runs BEFORE the screen is frozen: once it is, nothing that
    /// happens on it can reach the picture.
    private func frameAnArea() {
        let delay = delaySeconds
        guard delay > 0 else {
            freezeAndFrame()
            return
        }
        countdown(from: delay) { [weak self] in self?.freezeAndFrame() }
    }

    private func freezeAndFrame() {
        state = .framing
        let screens = NSScreen.screens.map { (Self.displayID(of: $0), Double($0.backingScaleFactor)) }
        Task { [weak self] in
            guard let self else { return }
            let taken = await Self.stills(of: screens, showsPointer: self.showsPointer)
            guard !taken.isEmpty else {
                self.state = .failed
                return
            }
            self.stills = taken.mapValues { Still(image: $0.image, scale: $0.scale) }
            self.showFrame()
            // The frame's keys — escape, space, r — reach it only from the key
            // window, and a hotkey pressed over another app leaves Hop inactive.
            NSApp.activate(ignoringOtherApps: true)
            self.overlay.makeKey(on: Self.screenUnderPointer())
        }
    }

    private func showFrame() {
        overlay.show { [weak self] screen in
            let id = Self.displayID(of: screen)
            let host = FirstMouseHostingView(rootView: CaptureSelectionView(
                screenSize: screen.frame.size,
                scale: screen.backingScaleFactor,
                lang: L10n.current,
                backdrop: self?.stills[id]?.image,
                onPick: { [weak self] rect in
                    guard let self else { return }
                    var picked = rect
                    picked.displayID = id
                    self.finishFraming(with: picked)
                },
                onWindowMode: { [weak self] in
                    guard let self else { return }
                    self.finishFraming(with: self.windowRectUnderPointer() ?? self.wholeScreenRect())
                },
                onRepeat: { [weak self] in
                    guard let self, let rect = self.lastRect else { return }
                    self.finishFraming(with: rect)
                },
                onCancel: { [weak self] in
                    self?.overlay.hide()
                    self?.stills = [:]
                    self?.state = .idle
                }
            ))
            return host
        }
    }

    /// Cut out of the frozen still. A display that has no still — plugged in
    /// while the frame was up — is read live instead, with no second delay.
    private func finishFraming(with rect: CaptureRect?) {
        overlay.hide()
        let taken = stills
        stills = [:]
        guard let rect else {
            state = .idle
            return
        }
        lastRect = rect
        if let still = taken[rect.displayID], still.scale == rect.scale,
           let image = Self.cut(still.image, to: rect) {
            state = .idle
            onCaptured?(image, rect)
        } else {
            grab(rect)
        }
    }

    private func takeWholeScreen() {
        guard let rect = wholeScreenRect() else { return }
        shoot(rect)
    }

    private func takeWindowUnderPointer() {
        guard let rect = windowRectUnderPointer() ?? wholeScreenRect() else { return }
        shoot(rect)
    }

    private func wholeScreenRect() -> CaptureRect? {
        guard let screen = Self.screenUnderPointer() else { return nil }
        return CaptureRect(x: 0, y: 0,
                           width: screen.frame.width, height: screen.frame.height,
                           scale: screen.backingScaleFactor,
                           displayID: Self.displayID(of: screen))
    }

    private func windowRectUnderPointer() -> CaptureRect? {
        guard let screen = Self.screenUnderPointer(),
              let frame = WindowUnderPointer.frame(at: NSEvent.mouseLocation) else { return nil }
        let local = CaptureRect(x: frame.minX - screen.frame.minX,
                                y: screen.frame.maxY - frame.maxY,
                                width: frame.width, height: frame.height,
                                scale: screen.backingScaleFactor,
                                displayID: Self.displayID(of: screen))
        let bounds = CaptureRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height,
                                 scale: screen.backingScaleFactor, displayID: local.displayID)
        return local.clamped(to: bounds)
    }

    private func shoot(_ rect: CaptureRect) {
        lastRect = rect
        let delay = delaySeconds
        guard delay > 0 else {
            grab(rect)
            return
        }
        countdown(from: delay) { [weak self] in self?.grab(rect) }
    }

    private func countdown(from seconds: Int, then done: @escaping () -> Void) {
        guard seconds > 0 else {
            state = .idle
            done()
            return
        }
        state = .counting(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.countdown(from: seconds - 1, then: done)
        }
    }

    private func grab(_ rect: CaptureRect) {
        Task { [weak self] in
            guard let self else { return }
            let taken = await Self.stills(of: [(rect.displayID, rect.scale)], showsPointer: self.showsPointer)
            guard let full = taken[rect.displayID]?.image, let image = Self.cut(full, to: rect) else {
                self.state = .failed
                return
            }
            self.state = .idle
            self.onCaptured?(image, rect)
        }
    }

    /// Each display whole, in its own backing pixels. Hop's own windows are
    /// left out, so the panel never lands in the shot.
    private static func stills(
        of displays: [(UInt32, Double)], showsPointer: Bool
    ) async -> [UInt32: (image: CGImage, scale: Double)] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            return [:]
        }
        let ours = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        var taken: [UInt32: (image: CGImage, scale: Double)] = [:]
        for (id, scale) in displays {
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: ours)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(Double(display.width) * scale)
            configuration.height = Int(Double(display.height) * scale)
            configuration.showsCursor = showsPointer
            configuration.captureResolution = .best
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            ) {
                taken[id] = (image, scale)
            }
        }
        return taken
    }

    private static func cut(_ full: CGImage, to rect: CaptureRect) -> NSImage? {
        let crop = CGRect(x: rect.x * rect.scale, y: rect.y * rect.scale,
                          width: Double(rect.pixelWidth), height: Double(rect.pixelHeight))
        guard let cut = full.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cut, size: NSSize(width: rect.width, height: rect.height))
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// The frame of the window under the pointer, in AppKit's global coordinates.
enum WindowUnderPointer {
    static func frame(at point: NSPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        let flipped = flip(point)
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int,
                  owner != Int(ProcessInfo.processInfo.processIdentifier),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            if rect.contains(flipped) {
                return CGRect(x: rect.minX, y: unflip(rect.maxY), width: rect.width, height: rect.height)
            }
        }
        return nil
    }

    /// CoreGraphics counts down from the top of the main display; AppKit counts
    /// up from its bottom.
    private static func flip(_ point: NSPoint) -> CGPoint {
        guard let main = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: main.frame.maxY - point.y)
    }

    private static func unflip(_ y: CGFloat) -> CGFloat {
        guard let main = NSScreen.screens.first else { return y }
        return main.frame.maxY - y
    }
}
