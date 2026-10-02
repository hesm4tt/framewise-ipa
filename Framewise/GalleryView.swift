import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var library: LocalPhotoLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: SavedPhoto?

    private let columns = [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)]

    var body: some View {
        NavigationView {
            ZStack {
                FramewiseStyle.ink.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if library.photos.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 9) {
                                ForEach(library.photos) { photo in
                                    Button { selectedPhoto = photo } label: {
                                        ZStack(alignment: .bottomLeading) {
                                            PhotoThumbnailView(fileURL: library.photoURL(for: photo), contentMode: .fill)
                                                .frame(height: 166)
                                                .frame(maxWidth: .infinity)
                                                .clipped()
                                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(photo.look.rawValue.uppercased())
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .tracking(0.7)
                                                Text(photo.createdAt.formatted(date: .abbreviated, time: .omitted))
                                                    .font(.system(size: 8, weight: .medium))
                                                    .foregroundStyle(.white.opacity(0.7))
                                            }
                                            .padding(8)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 15)
                            .padding(.top, 7)
                            .padding(.bottom, 28)
                        }
                    }
                    Text("Stored on this device · no account or server")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.43))
                        .padding(.vertical, 12)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedPhoto) { photo in
                PhotoDetailSheet(photo: photo, library: library)
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text("YOUR FRAMES")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.8)
                Text("\(library.photos.count) saved \(library.photos.count == 1 ? "photo" : "photos")")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FramewiseStyle.accent)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: "camera.macro")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FramewiseStyle.accent)
            Text("Your first frame is waiting")
                .font(.system(size: 18, weight: .semibold, design: .serif))
            Text("Take a photo, choose a film look, and save it here.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct PhotoThumbnailView: View {
    let fileURL: URL
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.white.opacity(0.055))
                    .overlay(ProgressView().tint(.white.opacity(0.5)).scaleEffect(0.7))
            }
        }
        .task(id: fileURL) {
            let url = fileURL
            let result = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return PhotoRenderer.preview(data: data, look: .original, frame: .none)
            }.value
            image = result
        }
    }
}

private struct PhotoDetailSheet: View {
    let photo: SavedPhoto
    @ObservedObject var library: LocalPhotoLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            FramewiseStyle.ink.ignoresSafeArea()
            VStack(spacing: 15) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(photo.title.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        library.delete(photo)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete photo")
                }
                .padding(.horizontal, 18)

                PhotoThumbnailView(fileURL: library.photoURL(for: photo), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    Label(photo.look.rawValue, systemImage: "sparkles")
                    Text("·")
                    Text(photo.frame.rawValue == "None" ? "Original frame" : photo.frame.rawValue + " print")
                    if photo.rawFileName != nil {
                        Text("·")
                        Label("RAW", systemImage: "camera.aperture")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))

                Button { showShareSheet = true } label: {
                    Label(photo.rawFileName == nil ? "Share photo" : "Share photo + RAW", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(FramewiseStyle.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .padding(.top, 10)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: library.shareURLs(for: photo))
        }
        .preferredColorScheme(.dark)
    }
}
