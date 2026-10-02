import Foundation
import ImageIO

enum FilmLook: String, CaseIterable, Codable, Identifiable {
    case original = "Original"
    case clean = "Clean"
    case p400 = "P400"
    case harbor = "Harbor"
    case dusk = "Dusk"
    case relic = "Relic"
    case mono = "Mono"

    var id: String { rawValue }
}

enum PrintFrame: String, CaseIterable, Codable, Identifiable {
    case none = "None"
    case white = "White"
    case paper = "Paper"
    case speed = "Speed"
    case date = "Date"

    var id: String { rawValue }
}

struct SavedPhoto: Identifiable, Codable, Equatable {
    var id: String
    var fileName: String
    var originalFileName: String? = nil
    var rawFileName: String? = nil
    var createdAt: Date
    var look: FilmLook
    var frame: PrintFrame
}

struct CameraCapture {
    let processedData: Data
    let rawData: Data?
    let rawFormatName: String?
}

enum PhotoImageFormat {
    static func fileExtension(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return "jpg" }
        return type.contains("heic") || type.contains("heif") ? "heic" : "jpg"
    }
}

extension SavedPhoto {
    var title: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
