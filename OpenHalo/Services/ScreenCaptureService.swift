import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedFrame: @unchecked Sendable {
    let sequence: UInt64
    let capturedAt: Date
    let displayID: CGDirectDisplayID
    let image: CGImage
}

private struct SendableSampleBuffer: @unchecked Sendable {
    let rawValue: CMSampleBuffer
}

protocol ScreenFrameProviding: Sendable {
    func ensureRunning(for displayID: CGDirectDisplayID) async throws
    func latestFrame(
        for displayID: CGDirectDisplayID,
        maxAge: TimeInterval,
        waitUpTo: TimeInterval
    ) async throws -> CapturedFrame
    func nextFrame(
        for displayID: CGDirectDisplayID,
        after sequence: UInt64,
        waitUpTo: TimeInterval
    ) async throws -> CapturedFrame?
}

struct CapturedFrameBuffer {
    private(set) var frames: [CapturedFrame] = []
    let capacity: Int

    init(capacity: Int = 3) {
        self.capacity = max(capacity, 1)
    }

    mutating func append(_ frame: CapturedFrame) {
        frames.append(frame)
        let overflow = frames.count - capacity
        if overflow > 0 {
            frames.removeFirst(overflow)
        }
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }

    func latestFrame(
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> CapturedFrame? {
        guard let frame = frames.last else {
            return nil
        }

        guard now.timeIntervalSince(frame.capturedAt) <= maxAge else {
            return nil
        }

        return frame
    }

    func nextFrame(after sequence: UInt64) -> CapturedFrame? {
        frames.first(where: { $0.sequence > sequence })
    }
}

actor ScreenCaptureService: ScreenFrameProviding {
    private let targetFPS: Int32 = 10
    private let frameBufferCapacity = 3
    private let pollIntervalNanoseconds: UInt64 = 25_000_000
    private let ciContext = CIContext()
    private let sampleQueue = DispatchQueue(label: "com.openhalo.capture.sample-output")

    private var stream: SCStream?
    private var outputSink: StreamOutputSink?
    private var activeDisplayID: CGDirectDisplayID?
    private var nextSequence: UInt64 = 1
    private var frameBuffer = CapturedFrameBuffer(capacity: 3)

    func ensureRunning(for displayID: CGDirectDisplayID) async throws {
        let shareableContent = try await loadShareableContent()
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.noDisplayFound
        }

        let filter = makeContentFilter(
            display: display,
            shareableContent: shareableContent
        )
        let configuration = makeStreamConfiguration(display: display)

        if let stream {
            guard activeDisplayID != displayID else {
                return
            }

            do {
                try await stream.updateContentFilter(filter)
                try await stream.updateConfiguration(configuration)
            } catch {
                throw ScreenCaptureError.captureFailure(error.localizedDescription)
            }

            activeDisplayID = displayID
            nextSequence = 1
            frameBuffer.removeAll()
            return
        }

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        let sink = makeOutputSink()

        do {
            try stream.addStreamOutput(
                sink,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            try await stream.startCapture()
        } catch {
            throw ScreenCaptureError.captureFailure(error.localizedDescription)
        }

        self.stream = stream
        self.outputSink = sink
        self.activeDisplayID = displayID
        nextSequence = 1
        frameBuffer.removeAll()
    }

    func latestFrame(
        for displayID: CGDirectDisplayID,
        maxAge: TimeInterval,
        waitUpTo: TimeInterval
    ) async throws -> CapturedFrame {
        try await ensureRunning(for: displayID)

        let deadline = Date().addingTimeInterval(waitUpTo)
        while true {
            if let frame = try? Self.selectLatestFrame(
                from: frameBuffer,
                maxAge: maxAge,
                now: Date()
            ) {
                return frame
            }

            if Date() >= deadline {
                throw ScreenCaptureError.noRecentFrameAvailable
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    func nextFrame(
        for displayID: CGDirectDisplayID,
        after sequence: UInt64,
        waitUpTo: TimeInterval
    ) async throws -> CapturedFrame? {
        try await ensureRunning(for: displayID)

        let deadline = Date().addingTimeInterval(waitUpTo)
        while true {
            if let frame = Self.selectNextFrame(
                from: frameBuffer,
                after: sequence
            ) {
                return frame
            }

            if Date() >= deadline {
                return nil
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
    }

    nonisolated static func selectLatestFrame(
        from frameBuffer: CapturedFrameBuffer,
        maxAge: TimeInterval,
        now: Date = Date()
    ) throws -> CapturedFrame {
        guard let frame = frameBuffer.latestFrame(maxAge: maxAge, now: now) else {
            throw ScreenCaptureError.noRecentFrameAvailable
        }
        return frame
    }

    nonisolated static func selectNextFrame(
        from frameBuffer: CapturedFrameBuffer,
        after sequence: UInt64
    ) -> CapturedFrame? {
        frameBuffer.nextFrame(after: sequence)
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureError.permissionDenied
        }
    }

    private func makeContentFilter(
        display: SCDisplay,
        shareableContent: SCShareableContent
    ) -> SCContentFilter {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let excludedApplications = shareableContent.applications.filter {
            $0.processID == currentProcessID
        }

        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }

    private func makeStreamConfiguration(display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: targetFPS)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = frameBufferCapacity
        return configuration
    }

    private func makeOutputSink() -> StreamOutputSink {
        StreamOutputSink { [service = self] sampleBuffer in
            Task {
                await service.handleSampleBuffer(sampleBuffer)
            }
        }
    }

    private func handleSampleBuffer(_ sampleBuffer: SendableSampleBuffer) {
        let rawSampleBuffer = sampleBuffer.rawValue
        guard CMSampleBufferIsValid(rawSampleBuffer),
              CMSampleBufferDataIsReady(rawSampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(rawSampleBuffer),
              let activeDisplayID else {
            return
        }

        do {
            let image = try makeImage(from: pixelBuffer)
            let frame = CapturedFrame(
                sequence: nextSequence,
                capturedAt: Date(),
                displayID: activeDisplayID,
                image: image
            )
            nextSequence += 1
            frameBuffer.append(frame)
        } catch {
            print("[OpenHalo] Failed to convert stream frame: \(error.localizedDescription)")
        }
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard let image = ciContext.createCGImage(ciImage, from: rect) else {
            throw ScreenCaptureError.captureFailure("Failed to create image from stream frame")
        }

        return image
    }
}

private final class StreamOutputSink: NSObject, SCStreamOutput {
    private let handler: @Sendable (SendableSampleBuffer) -> Void

    init(handler: @escaping @Sendable (SendableSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else {
            return
        }

        handler(SendableSampleBuffer(rawValue: sampleBuffer))
    }
}

enum ScreenCaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplayFound
    case noRecentFrameAvailable
    case captureFailure(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission not granted"
        case .noDisplayFound:
            return "No display found for capture"
        case .noRecentFrameAvailable:
            return "No recent screen frame is available yet"
        case .captureFailure(let msg):
            return "Capture failed: \(msg)"
        }
    }
}
