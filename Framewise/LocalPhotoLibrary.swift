import Foundation
import Combine

@MainActor
final class LocalPhotoLibrary: ObservableObject {
    @Published private(set) var photos: [SavedPhoto] = []

    private let fileManager = FileManager.default

    init() {
        loadIndex()
    }

    func photoURL(for photo: SavedPhoto) -> URL {
        Self.libraryDirectory.appendingPathComponent(photo.fileName)
    }

    func originalPhotoURL(for photo: SavedPhoto) -> URL? {
        photo.originalFileName.map { Self.libraryDirectory.appendingPathComponent($0) }
    }

    func rawPhotoURL(for photo: SavedPhoto) -> URL? {
        photo.rawFileName.map { Self.libraryDirectory.appendingPathComponent($0) }
    }

    func shareURLs(for photo: SavedPhoto) -> [URL] {
        var urls = [photoURL(for: photo)]
        if let originalURL = originalPhotoURL(for: photo), originalURL != urls[0] {
            urls.append(originalURL)
        }
        if let rawURL = rawPhotoURL(for: photo) {
            urls.append(rawURL)
        }
        return urls.filter { fileManager.fileExists(atPath: $0.path) }
    }

    func save(data: Data, originalData: Data, rawData: Data?, look: FilmLook, frame: PrintFrame) async throws -> SavedPhoto {
        try fileManager.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let originalFileName = "\(identifier).\(PhotoImageFormat.fileExtension(for: originalData))"
        let isUnedited = look == .original && frame == .none
        let photo = SavedPhoto(
            id: identifier,
            fileName: isUnedited ? originalFileName : "\(identifier).jpg",
            originalFileName: originalFileName,
            rawFileName: rawData == nil ? nil : "\(identifier).dng",
            createdAt: Date(),
            look: look,
            frame: frame
        )
        let destination = photoURL(for: photo)
        let originalDestination = Self.libraryDirectory.appendingPathComponent(originalFileName)
        let rawDestination = photo.rawFileName.map { Self.libraryDirectory.appendingPathComponent($0) }
        try await Task.detached(priority: .userInitiated) {
            if isUnedited {
                try originalData.write(to: destination, options: .atomic)
            } else {
                try data.write(to: destination, options: .atomic)
                try originalData.write(to: originalDestination, options: .atomic)
            }
            if let rawData, let rawDestination { try rawData.write(to: rawDestination, options: .atomic) }
        }.value
        photos.insert(photo, at: 0)
        persistIndex()
        return photo
    }

    func delete(_ photo: SavedPhoto) {
        try? fileManager.removeItem(at: photoURL(for: photo))
        if let originalURL = originalPhotoURL(for: photo), originalURL != photoURL(for: photo) {
            try? fileManager.removeItem(at: originalURL)
        }
        if let rawURL = rawPhotoURL(for: photo) { try? fileManager.removeItem(at: rawURL) }
        photos.removeAll { $0.id == photo.id }
        persistIndex()
    }

    private func loadIndex() {
        let indexURL = Self.libraryDirectory.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([SavedPhoto].self, from: data) else {
            photos = []
            return
        }
        photos = saved.filter { fileManager.fileExists(atPath: photoURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func persistIndex() {
        let indexURL = Self.libraryDirectory.appendingPathComponent("index.json")
        guard let data = try? JSONEncoder().encode(photos) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static var libraryDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("FramewiseLibrary", isDirectory: true)
    }
}
