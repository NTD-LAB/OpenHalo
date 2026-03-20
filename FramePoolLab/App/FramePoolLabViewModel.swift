import AppKit
import Foundation

struct FramePoolLabEntry: Identifiable {
    let id = UUID()
    let requestedAt: Date
    let receivedAt: Date
    let frameSequence: UInt64
    let capturedAt: Date
    let summary: String
    let latencyMilliseconds: Int
}

@MainActor
final class FramePoolLabViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var modelID: String = "openai/gpt-5.3-chat"
    @Published var interpretationPrompt: String = "Describe the current desktop page in 4 short bullets: app or site, visible section, important UI controls, and whether anything changed from the previous summary."
    @Published var autoInterpretationEnabled: Bool = true
    @Published var refreshIntervalSeconds: Double = 2.0
    @Published private(set) var isMonitoring = false
    @Published private(set) var isInterpreting = false
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var latestFrameImage: NSImage?
    @Published private(set) var latestFrameSequence: UInt64?
    @Published private(set) var latestFrameCapturedAt: Date?
    @Published private(set) var lastErrorText: String?
    @Published private(set) var entries: [FramePoolLabEntry] = []

    private let captureService = ScreenCaptureService()
    private let visionClient = FramePoolLabVisionClient()
    private let capturePollIntervalNanoseconds: UInt64 = 250_000_000
    private var monitoringTask: Task<Void, Never>?
    private var previousSummary: String?
    private var lastAutomaticInterpretationAt: Date = .distantPast

    func startMonitoring() {
        guard monitoringTask == nil else { return }

        lastErrorText = nil
        statusText = "Starting screen stream..."
        monitoringTask = Task { [weak self] in
            await self?.monitorLoop()
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        isInterpreting = false
        statusText = "Stopped"
    }

    func interpretNow() {
        Task { [weak self] in
            await self?.runInterpretationCycle(force: true)
        }
    }

    var latestFrameAgeText: String {
        guard let latestFrameCapturedAt else {
            return "n/a"
        }
        return String(format: "%.2fs", max(0, Date().timeIntervalSince(latestFrameCapturedAt)))
    }

    private func monitorLoop() async {
        do {
            let displayID = try resolveMainDisplayID()
            try await captureService.ensureRunning(for: displayID)
            isMonitoring = true
            statusText = "Monitoring main display"

            while !Task.isCancelled {
                do {
                    let frame = try await captureService.latestFrame(
                        for: displayID,
                        maxAge: 3.0,
                        waitUpTo: 1.5
                    )
                    updatePreview(with: frame)
                    statusText = "Monitoring main display"
                    lastErrorText = nil

                    if autoInterpretationEnabled {
                        let now = Date()
                        if now.timeIntervalSince(lastAutomaticInterpretationAt) >= refreshIntervalSeconds,
                           !isInterpreting {
                            await interpret(frame: frame)
                            lastAutomaticInterpretationAt = now
                        }
                    }
                } catch {
                    lastErrorText = error.localizedDescription
                    statusText = "Waiting for a usable frame..."
                }

                try? await Task.sleep(nanoseconds: capturePollIntervalNanoseconds)
            }
        } catch {
            lastErrorText = error.localizedDescription
            statusText = "Failed to start screen stream"
            isMonitoring = false
            monitoringTask = nil
        }
    }

    private func runInterpretationCycle(force: Bool) async {
        do {
            let displayID = try resolveMainDisplayID()
            try await captureService.ensureRunning(for: displayID)
            let frame = try await captureService.latestFrame(
                for: displayID,
                maxAge: force ? 5.0 : 3.0,
                waitUpTo: 2.0
            )
            updatePreview(with: frame)
            await interpret(frame: frame)
        } catch {
            lastErrorText = error.localizedDescription
            statusText = "Interpretation failed"
        }
    }

    private func interpret(frame: CapturedFrame) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastErrorText = "Enter an OpenRouter API key first."
            statusText = "Missing API key"
            return
        }

        isInterpreting = true
        statusText = "Interpreting frame \(frame.sequence)..."
        defer {
            isInterpreting = false
        }

        do {
            let base64 = try frame.image.toBase64JPEG(quality: 0.7)
            let requestedAt = Date()
            let result = try await visionClient.interpret(
                base64Image: base64,
                prompt: interpretationPrompt,
                previousSummary: previousSummary,
                model: modelID,
                apiKey: apiKey
            )
            let entry = FramePoolLabEntry(
                requestedAt: requestedAt,
                receivedAt: Date(),
                frameSequence: frame.sequence,
                capturedAt: frame.capturedAt,
                summary: result.summary,
                latencyMilliseconds: result.latencyMilliseconds
            )
            entries.insert(entry, at: 0)
            if entries.count > 30 {
                entries.removeLast(entries.count - 30)
            }
            previousSummary = result.summary
            statusText = "Last interpretation succeeded"
            lastErrorText = nil
        } catch {
            lastErrorText = error.localizedDescription
            statusText = "Interpretation failed"
        }
    }

    private func updatePreview(with frame: CapturedFrame) {
        latestFrameSequence = frame.sequence
        latestFrameCapturedAt = frame.capturedAt
        latestFrameImage = NSImage(
            cgImage: frame.image,
            size: NSSize(width: frame.image.width, height: frame.image.height)
        )
    }

    private func resolveMainDisplayID() throws -> CGDirectDisplayID {
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenCaptureError.noDisplayFound
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
