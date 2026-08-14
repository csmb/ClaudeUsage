import AppKit
import ScreenCaptureKit

/// Screenshot plumbing for `--demo` runs.
///
/// The app captures itself rather than shelling out to `screencapture`: it
/// already knows the exact geometry of its status item, popover and Settings
/// window, and driving ScreenCaptureKit in-process means the one Screen
/// Recording grant we need belongs to this app rather than to whatever
/// terminal happens to be running the script.
enum DemoCapture {

    /// Triggers the one-time system prompt on first run. Returns false if the
    /// grant hasn't landed yet, in which case the caller should bail out and
    /// ask the user to approve it and re-run.
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Captures a rect given in AppKit screen coordinates (origin bottom-left).
    static func capture(screenRect: NSRect, to url: URL) async {
        guard #available(macOS 14.0, *) else {
            report("screenshots require macOS 14 or later", url)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                report("no display available", url)
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale  = CGFloat(filter.pointPixelScale)
            let rect   = displayRect(from: screenRect)

            let config = SCStreamConfiguration()
            config.sourceRect  = rect
            config.width       = Int((rect.width  * scale).rounded())
            config.height      = Int((rect.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            write(image, to: url)
        } catch {
            report("could not capture rect: \(error.localizedDescription)", url)
        }
    }

    /// Captures a single window on its own, so the PNG has a transparent
    /// background and the popover keeps its rounded corners and arrow.
    static func capture(windowNumber: Int, to url: URL) async {
        guard #available(macOS 14.0, *) else {
            report("screenshots require macOS 14 or later", url)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard windowNumber > 0,
                  let target = content.windows.first(where: {
                      $0.windowID == CGWindowID(windowNumber)
                  }) else {
                report("window \(windowNumber) is not shareable", url)
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let scale  = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width           = Int((filter.contentRect.width  * scale).rounded())
            config.height          = Int((filter.contentRect.height * scale).rounded())
            config.showsCursor     = false
            config.backgroundColor = .clear
            config.captureResolution = .best
            if #available(macOS 14.2, *) {
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
            }

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            write(image, to: url)
        } catch {
            report("could not capture window: \(error.localizedDescription)", url)
        }
    }

    // MARK: - Private

    /// AppKit screen coordinates (origin bottom-left of the primary display)
    /// → display coordinates (origin top-left), which is what SCK expects.
    private static func displayRect(from rect: NSRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x:      rect.minX,
            y:      primary.frame.maxY - rect.maxY,
            width:  rect.width,
            height: rect.height
        )
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            report("could not encode PNG", url)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            print("[demo] wrote \(url.lastPathComponent) (\(image.width)x\(image.height))")
        } catch {
            report("could not write file: \(error.localizedDescription)", url)
        }
    }

    private static func report(_ message: String, _ url: URL) {
        FileHandle.standardError.write(Data("[demo] \(url.lastPathComponent): \(message)\n".utf8))
    }
}
