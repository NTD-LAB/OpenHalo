import ScreenCaptureKit
import CoreGraphics

actor ScreenCaptureService {

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // TCC denied or not yet granted
            throw ScreenCaptureError.permissionDenied
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            throw ScreenCaptureError.captureFailure(error.localizedDescription)
        }
    }

    func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
    }
}

enum ScreenCaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplayFound
    case captureFailure(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission not granted"
        case .noDisplayFound:
            return "No display found for capture"
        case .captureFailure(let msg):
            return "Capture failed: \(msg)"
        }
    }
}
