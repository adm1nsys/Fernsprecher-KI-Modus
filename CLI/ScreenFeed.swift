//
//  ScreenFeed.swift
//  fernsprecher-ki-modus-an
//
//  `show --screen`: puts the Mac's display on the agent's tile, refreshed every `interval` seconds.
//  Needs Screen Recording permission for whatever app the CLI runs under.
//

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class ScreenFeed {
    private var task: Task<Void, Never>?
    private(set) var running = false

    /// Calls `frame` with a JPEG data URL of the display every `interval` seconds until `stop()`.
    func start(display index: Int, interval: Double, maxWidth: Int, frame: @escaping (String) async -> Void,
               failed: @escaping (String) -> Void) {
        stop()
        running = true
        task = Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard content.displays.indices.contains(index) else {
                    failed("no display \(index) (have \(content.displays.count))"); self?.running = false; return
                }
                let display = content.displays[index]
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                let scale = min(1, Double(maxWidth) / Double(display.width))
                cfg.width = Int(Double(display.width) * scale)
                cfg.height = Int(Double(display.height) * scale)
                cfg.showsCursor = true
                while !Task.isCancelled {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    if let url = ScreenFeed.jpegDataURL(image) { await frame(url) }
                    try await Task.sleep(for: .seconds(interval))
                }
            } catch is CancellationError {
            } catch {
                failed("screen capture failed: \(error.localizedDescription) — allow Screen Recording for the app running fernsprecher-ki-modus-an")
            }
            self?.running = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    static func jpegDataURL(_ image: CGImage, quality: Double = 0.7) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}
