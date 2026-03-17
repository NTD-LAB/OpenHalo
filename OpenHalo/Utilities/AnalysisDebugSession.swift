import CoreGraphics
import Foundation

struct AnalysisDebugSession: Sendable {
    static let maximumRetainedImageCount = 300

    let rootURL: URL

    static func create(query: String, model: String) -> AnalysisDebugSession? {
        do {
            let fileManager = FileManager.default
            let libraryURL = try fileManager.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let logsRootURL = libraryURL
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("OpenHalo", isDirectory: true)
                .appendingPathComponent("analysis-runs", isDirectory: true)

            try fileManager.createDirectory(
                at: logsRootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let folderName = "\(timestamp)-\(sanitizeFileName(query, fallback: "analysis"))-\(model.replacingOccurrences(of: "/", with: "_"))"
            let rootURL = logsRootURL.appendingPathComponent(folderName, isDirectory: true)

            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let session = AnalysisDebugSession(rootURL: rootURL)
            session.appendLine("Started at: \(ISO8601DateFormatter().string(from: Date()))")
            session.appendLine("Model: \(model)")
            session.appendLine("Query: \(query)")
            return session
        } catch {
            print("[OpenHalo] Failed to create analysis debug session: \(error.localizedDescription)")
            return nil
        }
    }

    func writeImage(
        _ image: CGImage,
        named fileName: String,
        format: EncodedImageFormat = .png
    ) {
        let fileURL = rootURL.appendingPathComponent(fileName)

        do {
            let data = try image.encodedData(as: format)
            try data.write(to: fileURL, options: .atomic)
            Self.trimRetainedImagesIfNeeded(rootURL: logsRootURL())
            appendLine("image: \(fileURL.lastPathComponent)")
        } catch {
            appendLine("image-write-failed: \(fileURL.lastPathComponent) error=\(error.localizedDescription)")
        }
    }

    func writeText(
        _ text: String,
        named fileName: String
    ) {
        let fileURL = rootURL.appendingPathComponent(fileName)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            appendLine("text: \(fileURL.lastPathComponent)")
        } catch {
            appendLine("text-write-failed: \(fileURL.lastPathComponent) error=\(error.localizedDescription)")
        }
    }

    func appendLine(_ line: String) {
        let logURL = rootURL.appendingPathComponent("events.log")
        let content = "\(line)\n"
        let data = Data(content.utf8)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: data)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("[OpenHalo] Failed to append debug log: \(error.localizedDescription)")
        }
    }

    private static func sanitizeFileName(
        _ value: String,
        fallback: String
    ) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sanitized = trimmed
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if sanitized.isEmpty {
            return fallback
        }

        return String(sanitized.prefix(40))
    }

    private func logsRootURL() -> URL {
        rootURL.deletingLastPathComponent()
    }

    static func trimRetainedImagesIfNeeded(
        rootURL: URL,
        maxImageCount: Int = maximumRetainedImageCount,
        fileManager: FileManager = .default
    ) {
        guard maxImageCount >= 0 else {
            return
        }

        let imageFiles = retainedImageFiles(rootURL: rootURL, fileManager: fileManager)
        let overflow = imageFiles.count - maxImageCount
        guard overflow > 0 else {
            return
        }

        for fileURL in imageFiles.prefix(overflow) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    static func retainedImageFiles(
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return []
        }

        let imageExtensions = Set(["png", "jpg", "jpeg"])
        let urls = enumerator.compactMap { $0 as? URL }.filter { url in
            imageExtensions.contains(url.pathExtension.lowercased())
        }

        return urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

            if lhsDate == rhsDate {
                return lhs.path < rhs.path
            }

            return lhsDate < rhsDate
        }
    }
}
