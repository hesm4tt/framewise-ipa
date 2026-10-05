import Foundation
import UIKit

/// Small diagnostic log that can be exported from the camera menu.
/// It records camera/Vision/OpenRouter status metadata and errors, never photo or video content or API keys.
final class AppDiagnostics {
    static let shared = AppDiagnostics()

    private let queue = DispatchQueue(label: "framewise.diagnostics")
    private let logURL: URL
    private let maximumLogSize = 1_000_000
    private let dateFormatter = ISO8601DateFormatter()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logURL = documents.appendingPathComponent("Framewise-Diagnostics.log")
    }

    func log(_ area: String, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(self.dateFormatter.string(from: Date())) [\(area)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: self.logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: self.logURL.path),
                   let attributes = try? FileManager.default.attributesOfItem(atPath: self.logURL.path),
                   ((attributes[.size] as? NSNumber)?.intValue ?? 0) > self.maximumLogSize {
                    let previousURL = self.logURL.appendingPathExtension("previous")
                    try? FileManager.default.removeItem(at: previousURL)
                    try FileManager.default.moveItem(at: self.logURL, to: previousURL)
                }
                if FileManager.default.fileExists(atPath: self.logURL.path) {
                    let handle = try FileHandle(forWritingTo: self.logURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: self.logURL, options: .atomic)
                }
            } catch {
                NSLog("Framewise diagnostics write failed: %@", error.localizedDescription)
            }
        }
    }

    /// Creates a timestamped, share-sheet-ready snapshot of the current log.
    func exportURL() -> URL? {
        queue.sync {
            do {
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Framewise-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
                let currentData = (try? Data(contentsOf: logURL)) ?? Data()
                var output = currentData
                let previousURL = logURL.appendingPathExtension("previous")
                if let previousData = try? Data(contentsOf: previousURL) {
                    output = previousData + output
                }
                try output.write(to: temporaryURL, options: .atomic)
                return temporaryURL
            } catch {
                NSLog("Framewise diagnostics export failed: %@", error.localizedDescription)
                return nil
            }
        }
    }
}
