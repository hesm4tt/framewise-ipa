import SwiftUI
import UIKit

struct ReviewView: View {
    let data: Data
    let rawData: Data?
    let rawFormatName: String?
    @ObservedObject var library: LocalPhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var look: FilmLook = .original
    @State private var frame: PrintFrame = .none
    @State private var preview: UIImage?
    @State private var isRendering = false
    @State private var isSaving = false
    @State private var isPreparingShare = false
    @State private var shareURLs: [URL]?
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            FramewiseStyle.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 10)

                ZStack {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                            .transition(.opacity)
                    } else {
                        ProgressView().tint(FramewiseStyle.accent)
                    }
                    if isRendering {
                        ProgressView().tint(.white)
                            .padding(14)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("FILM LOOK", detail: rawData == nil ? "Choose the light" : "RAW + processed captured")
                    if rawData != nil {
                        Text("\(rawFormatName ?? "RAW") DNG saved with the processed photo. RAW files are large and can look flatter until edited.")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(FramewiseStyle.muted)
                            .padding(.horizontal, 21)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilmLook.allCases) { option in
                                ChoiceChip(title: option.rawValue, selected: look == option) {
                                    look = option
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("PRINT", detail: "Add a little room")
                    HStack(spacing: 7) {
                        ForEach(PrintFrame.allCases) { option in
                            Button { frame = option } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: frameSymbol(option))
                                        .font(.system(size: 15, weight: .medium))
                                    Text(option.rawValue.uppercased())
                                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                        .tracking(0.4)
                                }
                                .foregroundStyle(frame == option ? FramewiseStyle.accent : FramewiseStyle.muted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 47)
                                .background(frame == option ? FramewiseStyle.accent.opacity(0.12) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(frame == option ? FramewiseStyle.accent.opacity(0.7) : .white.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 19)

                HStack(spacing: 12) {
                    Button(action: sharePhoto) {
                        Group {
                            if isPreparingShare {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 52)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingShare || isSaving)
                    .accessibilityLabel("Share this photo")

                    Button(action: savePhoto) {
                        HStack(spacing: 9) {
                            if isSaving { ProgressView().tint(.black) }
                            else { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)) }
                            Text(isSaving ? "SAVING" : "SAVE TO FRAMES")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .tracking(1.2)
                        }
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(FramewiseStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || isPreparingShare)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
        }
        .onAppear { updatePreview() }
        .onChange(of: look) { _ in updatePreview() }
        .onChange(of: frame) { _ in updatePreview() }
        .alert("Couldn’t finish that photo", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURLs { ActivityShareSheet(items: shareURLs) }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retake photo")
            Spacer()
            VStack(spacing: 4) {
                Text("THE FILM LAB")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                Text("Choose a look, then keep it")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(FramewiseStyle.muted)
            }
            Spacer()
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(FramewiseStyle.accent)
                .frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(FramewiseStyle.accent)
            Spacer()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(FramewiseStyle.muted)
        }
        .padding(.horizontal, 21)
    }

    private func frameSymbol(_ option: PrintFrame) -> String {
        switch option {
        case .none: "viewfinder"
        case .white: "square"
        case .paper: "rectangle.portrait"
        case .speed: "text.aligncenter"
        case .date: "calendar"
        }
    }

    private func updatePreview() {
        let chosenLook = look
        let chosenFrame = frame
        isRendering = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.preview(data: data, look: chosenLook, frame: chosenFrame)
            }.value
            guard look == chosenLook, frame == chosenFrame else { return }
            preview = result
            isRendering = false
        }
    }

    private func savePhoto() {
        guard !isSaving else { return }
        isSaving = true
        let chosenLook = look
        let chosenFrame = frame
        Task {
            do {
                let savedImage: Data
                if chosenLook == .original && chosenFrame == .none {
                    savedImage = data
                } else {
                    savedImage = try await Task.detached(priority: .userInitiated) {
                        try PhotoRenderer.finalJPEG(data: data, look: chosenLook, frame: chosenFrame)
                    }.value
                }
                _ = try await library.save(data: savedImage, originalData: data, rawData: rawData, look: chosenLook, frame: chosenFrame)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func sharePhoto() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        let chosenLook = look
        let chosenFrame = frame
        Task {
            do {
                let identifier = UUID().uuidString
                var urls: [URL] = []
                if chosenLook == .original && chosenFrame == .none {
                    let ext = PhotoImageFormat.fileExtension(for: data)
                    let originalURL = FileManager.default.temporaryDirectory.appendingPathComponent("framewise-\(identifier).\(ext)")
                    try await Task.detached(priority: .utility) { try data.write(to: originalURL, options: .atomic) }.value
                    urls.append(originalURL)
                } else {
                    let jpeg = try await Task.detached(priority: .userInitiated) {
                        try PhotoRenderer.finalJPEG(data: data, look: chosenLook, frame: chosenFrame)
                    }.value
                    let editedURL = FileManager.default.temporaryDirectory.appendingPathComponent("framewise-\(identifier)-edited.jpg")
                    let originalURL = FileManager.default.temporaryDirectory.appendingPathComponent("framewise-\(identifier)-original.\(PhotoImageFormat.fileExtension(for: data))")
                    try await Task.detached(priority: .utility) {
                        try jpeg.write(to: editedURL, options: .atomic)
                        try data.write(to: originalURL, options: .atomic)
                    }.value
                    urls.append(contentsOf: [editedURL, originalURL])
                }
                if let rawData {
                    let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("framewise-\(identifier)-RAW.dng")
                    try await Task.detached(priority: .utility) { try rawData.write(to: rawURL, options: .atomic) }.value
                    urls.append(rawURL)
                }
                shareURLs = urls
                showShareSheet = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingShare = false
        }
    }
}

private struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(selected ? .black : .white.opacity(0.77))
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(selected ? FramewiseStyle.accent : .white.opacity(0.075), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
