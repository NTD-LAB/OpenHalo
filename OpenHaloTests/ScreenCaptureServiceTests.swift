import CoreGraphics
import Foundation
import XCTest
@testable import OpenHalo

final class ScreenCaptureServiceTests: XCTestCase {
    func testCapturedFrameBufferEvictsOldestFrameWhenCapacityExceeded() {
        var buffer = CapturedFrameBuffer(capacity: 3)

        buffer.append(makeFrame(sequence: 1, age: 0.3))
        buffer.append(makeFrame(sequence: 2, age: 0.2))
        buffer.append(makeFrame(sequence: 3, age: 0.1))
        buffer.append(makeFrame(sequence: 4, age: 0.0))

        XCTAssertEqual(buffer.frames.map(\.sequence), [2, 3, 4])
    }

    func testCapturedFrameBufferLatestFrameReturnsNewestFreshFrame() {
        let now = Date()
        var buffer = CapturedFrameBuffer(capacity: 3)
        buffer.append(makeFrame(sequence: 1, capturedAt: now.addingTimeInterval(-0.8)))
        buffer.append(makeFrame(sequence: 2, capturedAt: now.addingTimeInterval(-0.2)))

        let frame = buffer.latestFrame(maxAge: 0.5, now: now)

        XCTAssertEqual(frame?.sequence, 2)
    }

    func testCapturedFrameBufferNextFrameReturnsFirstStrictlyNewerSequence() {
        var buffer = CapturedFrameBuffer(capacity: 4)
        buffer.append(makeFrame(sequence: 4, age: 0.3))
        buffer.append(makeFrame(sequence: 5, age: 0.2))
        buffer.append(makeFrame(sequence: 6, age: 0.1))

        let frame = buffer.nextFrame(after: 4)

        XCTAssertEqual(frame?.sequence, 5)
    }

    func testSelectLatestFrameThrowsWhenNewestFrameIsStale() {
        let now = Date()
        var buffer = CapturedFrameBuffer(capacity: 3)
        buffer.append(makeFrame(sequence: 1, capturedAt: now.addingTimeInterval(-1.2)))

        XCTAssertThrowsError(
            try ScreenCaptureService.selectLatestFrame(
                from: buffer,
                maxAge: 0.5,
                now: now
            )
        ) { error in
            guard case ScreenCaptureError.noRecentFrameAvailable = error else {
                return XCTFail("Expected noRecentFrameAvailable, got \(error)")
            }
        }
    }

    func testSelectNextFrameReturnsNilWhenNoNewerFrameExists() {
        var buffer = CapturedFrameBuffer(capacity: 3)
        buffer.append(makeFrame(sequence: 7, age: 0.1))

        let frame = ScreenCaptureService.selectNextFrame(
            from: buffer,
            after: 7
        )

        XCTAssertNil(frame)
    }

    func testAnalysisDebugSessionTrimsDiskImagesToMaximumCount() throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootURL) }

        let baseDate = Date(timeIntervalSince1970: 1_000)
        for index in 0..<305 {
            let fileURL = rootURL.appendingPathComponent(String(format: "frame-%03d.png", index))
            try Data("x".utf8).write(to: fileURL)
            try fileManager.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: fileURL.path
            )
        }

        let textURL = rootURL.appendingPathComponent("events.log")
        try Data("log".utf8).write(to: textURL)

        AnalysisDebugSession.trimRetainedImagesIfNeeded(rootURL: rootURL, maxImageCount: 300)

        let remainingImages = AnalysisDebugSession.retainedImageFiles(rootURL: rootURL)
        XCTAssertEqual(remainingImages.count, 300)
        XCTAssertFalse(fileManager.fileExists(atPath: rootURL.appendingPathComponent("frame-000.png").path))
        XCTAssertFalse(fileManager.fileExists(atPath: rootURL.appendingPathComponent("frame-004.png").path))
        XCTAssertTrue(fileManager.fileExists(atPath: rootURL.appendingPathComponent("frame-005.png").path))
        XCTAssertTrue(fileManager.fileExists(atPath: textURL.path))
    }

    private func makeFrame(
        sequence: UInt64,
        age: TimeInterval,
        displayID: CGDirectDisplayID = 1
    ) -> CapturedFrame {
        makeFrame(
            sequence: sequence,
            capturedAt: Date().addingTimeInterval(-age),
            displayID: displayID
        )
    }

    private func makeFrame(
        sequence: UInt64,
        capturedAt: Date,
        displayID: CGDirectDisplayID = 1
    ) -> CapturedFrame {
        CapturedFrame(
            sequence: sequence,
            capturedAt: capturedAt,
            displayID: displayID,
            image: makeImage()
        )
    }

    private func makeImage(
        width: Int = 2,
        height: Int = 2
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("Failed to create bitmap context")
            fatalError()
        }

        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            XCTFail("Failed to create test image")
            fatalError()
        }

        return image
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenHaloTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }
}
