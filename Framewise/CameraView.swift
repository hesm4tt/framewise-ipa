import AVFoundation
import SwiftUI
import UIKit

enum FramewiseStyle {
    static let ink = Color(red: 0.035, green: 0.04, blue: 0.04)
    static let panel = Color(red: 0.09, green: 0.10, blue: 0.10)
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.08)
    static let muted = Color.white.opacity(0.64)
}

struct CameraView: View {
    @ObservedObject var library: LocalPhotoLibrary
    @StateObject private var camera = CameraEngine()
    @AppStorage("framewise.didCompleteFirstRun") private var didCompleteFirstRun = false
    @State private var showGallery = false
    @State private var showReview = false
    @State private var showExposure = false
    @State private var showGrid = false
    @State private var flashEnabled = false
    @State private var reviewData: Data?
    @State private var reviewRawData: Data?
    @State private var reviewRawFormatName: String?
    @State private var showPermissionAlert = false
    @State private var showDiagnosticsShare = false
    @State private var showAIScanSettings = false
    @State private var diagnosticsURL: URL?
    @State private var onboardingPage = 0

    var body: some View {
        ZStack {
            FramewiseStyle.ink.ignoresSafeArea()
            CameraPreview(session: camera.session, imageAspectRatio: camera.previewFrameAspectRatio) { subjectPoint, focusPoint in
                camera.focus(at: focusPoint)
                camera.selectSubject(at: subjectPoint)
            }
            .ignoresSafeArea()

            if showGrid {
                CompositionGrid()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if camera.isScanning, let box = camera.subjectBox {
                GeometryReader { geometry in
                    SubjectMarker(
                        box: box,
                        subjectLabel: camera.subjectLabel,
                        imageAspectRatio: camera.previewFrameAspectRatio,
                        size: geometry.size,
                        isLocked: camera.isSubjectLocked
                    )
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if didCompleteFirstRun, camera.isScanning, camera.subjectBox != nil {
                VStack {
                    HStack(spacing: 9) {
                        Image(systemName: camera.movementSymbol)
                            .font(.system(size: 13, weight: .bold))
                        Text(camera.movementInstruction.uppercased())
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(0.75)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(camera.isSubjectLocked ? Color.green : FramewiseStyle.accent, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                    Spacer()
                }
                .padding(.top, 89)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 18)
                if showExposure { exposureControl }
                guideCard
                zoomPicker
                captureControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if case let .unavailable(message) = camera.status {
                cameraUnavailable(message)
            }

            if camera.isCapturing {
                Color.black.opacity(0.3).ignoresSafeArea()
                ProgressView().tint(.white).scaleEffect(1.2)
            }

            if !didCompleteFirstRun {
                firstRunGuide
                    .transition(.opacity)
            }
        }
        .onAppear {
            if didCompleteFirstRun { startCameraGuide() }
        }
        .onChange(of: didCompleteFirstRun) { completed in
            if completed { startCameraGuide() }
        }
        .onChange(of: camera.isFramingReady) { isReady in
            if isReady { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        .onChange(of: camera.isSubjectLocked) { isLocked in
            if isLocked { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .onDisappear { camera.stop() }
        .onChange(of: showGallery) { isPresented in
            if isPresented { camera.stop() }
        }
        .fullScreenCover(isPresented: $showReview, onDismiss: {
            camera.start()
            camera.startMotion()
        }) {
            if let reviewData {
                ReviewView(data: reviewData, rawData: reviewRawData, rawFormatName: reviewRawFormatName, library: library)
            }
        }
        .sheet(isPresented: $showGallery, onDismiss: {
            camera.start()
            camera.startMotion()
        }) {
            GalleryView(library: library)
        }
        .sheet(isPresented: $showDiagnosticsShare) {
            if let diagnosticsURL {
                ActivityShareSheet(items: [diagnosticsURL])
            }
        }
        .alert("Camera access needed", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Allow camera access in Settings to frame and take photos.")
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { showGallery = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(FramewiseStyle.accent).frame(width: 40, height: 40)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open your frames")

            VStack(alignment: .leading, spacing: 3) {
                Text("FRAMEWISE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.2)
                HStack(spacing: 5) {
                    Circle().fill(camera.status == .ready ? Color.green : FramewiseStyle.accent).frame(width: 5, height: 5)
                    Text(camera.status == .ready ? "CAMERA READY" : "CAMERA")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(FramewiseStyle.muted)
                }
            }

            Spacer()

            if camera.hasFlash {
                Button { flashEnabled.toggle() } label: {
                    Image(systemName: flashEnabled ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(flashEnabled ? FramewiseStyle.accent : .white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(flashEnabled ? "Flash on" : "Flash off")
            }

            Button { showExposure.toggle() } label: {
                Image(systemName: "sun.max")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.42), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exposure controls")

            Menu {
                Button {
                    showAIScanSettings = true
                } label: {
                    Label("OpenRouter AI scan settings", systemImage: "sparkles")
                }
                Button {
                    showGrid.toggle()
                } label: {
                    Label(showGrid ? "Hide composition grid" : "Show composition grid", systemImage: "grid")
                }
                Button {
                    camera.setExposure(0)
                } label: {
                    Label("Reset exposure", systemImage: "arrow.counterclockwise")
                }
                if camera.isScanning {
                    Button(role: .destructive) {
                        camera.stopScanning()
                    } label: {
                        Label("Clear framing guide", systemImage: "xmark.circle")
                    }
                }
                Toggle(isOn: Binding(
                    get: { camera.isRawCaptureEnabled },
                    set: { camera.setRawCaptureEnabled($0) }
                )) {
                    Label("RAW + Processed", systemImage: "camera.aperture")
                }
                .disabled(!camera.isRawCaptureSupported)
                Button {} label: {
                    Label(camera.rawCaptureSupportDescription, systemImage: "info.circle")
                }
                .disabled(true)
                Button {
                    AppDiagnostics.shared.log("diagnostics", "User requested log export")
                    diagnosticsURL = AppDiagnostics.shared.exportURL()
                    showDiagnosticsShare = diagnosticsURL != nil
                } label: {
                    Label("Share diagnostics", systemImage: "doc.text")
                }
                Button {
                    onboardingPage = 0
                    camera.stop()
                    didCompleteFirstRun = false
                } label: {
                    Label("Show setup guide again", systemImage: "questionmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.42), in: Circle())
            }
            .accessibilityLabel("Camera options")
            .sheet(isPresented: $showAIScanSettings) {
                OpenRouterSettingsView()
            }
        }
        .foregroundStyle(.white)
    }

    private var guideCard: some View {
        HStack(spacing: 11) {
            Image(systemName: camera.isFramingReady ? "checkmark.circle.fill" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(camera.isFramingReady ? FramewiseStyle.accent : .white)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(guideStatusTitle)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.15)
                    .foregroundStyle(FramewiseStyle.accent)
                Text(camera.guidance)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                if camera.isScanning {
                    Text(camera.isScanPending
                         ? "ONE FRAME · \(camera.scanAnalysisLabel)"
                         : "TAP A SUBJECT TO SCAN AND RETARGET")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.55)
                        .foregroundStyle(.white.opacity(0.58))
                }
                if let tip = camera.subjectFramingTip, camera.isScanning, !camera.isScanPending {
                    Text("AI TIP · \(tip)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .lineLimit(2)
                        .foregroundStyle(FramewiseStyle.accent.opacity(0.92))
                }
            }

            Spacer(minLength: 4)

            if camera.isScanning, let zoom = camera.suggestedZoom {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    camera.applySuggestedZoom()
                    AppDiagnostics.shared.log("guidance", "Applied suggested zoom \(zoom)x · reason=\(camera.zoomSuggestion)")
                } label: {
                    VStack(spacing: 3) {
                        Text(camera.zoomSuggestion.uppercased())
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .tracking(0.45)
                        Text("ZOOM TO \(zoomLabel(zoom))")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(FramewiseStyle.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use suggested \(zoomLabel(zoom)) zoom")
            } else if camera.isScanPending {
                ProgressView().tint(FramewiseStyle.accent).frame(width: 38, height: 38)
            } else if let zoom = camera.idealZoom, camera.isZoomingToIdeal {
                Text("ZOOMING TO \(zoomLabel(zoom))")
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundStyle(FramewiseStyle.accent)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.14), lineWidth: 1))
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.2), value: camera.guidance)
        .animation(.easeOut(duration: 0.2), value: camera.suggestedZoom)
    }

    private var exposureControl: some View {
        VStack(spacing: 8) {
            HStack {
                Text("EXPOSURE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                Spacer()
                Text(String(format: "%+.1f EV", camera.exposureBias))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(FramewiseStyle.accent)
            }
            Slider(value: Binding(
                get: { Double(camera.exposureBias) },
                set: { camera.setExposure(Float($0)) }
            ), in: -2...2, step: 0.1)
            .tint(FramewiseStyle.accent)
        }
        .padding(13)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 12)
    }

    private var zoomPicker: some View {
        HStack(spacing: 8) {
            ForEach(visibleZoomChoices, id: \.self) { zoom in
                Button { camera.setZoom(zoom) } label: {
                    Text(zoomLabel(zoom))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(abs(camera.currentZoom - zoom) < 0.15 ? .black : .white)
                        .frame(minWidth: 42, minHeight: 34)
                        .background(abs(camera.currentZoom - zoom) < 0.15 ? FramewiseStyle.accent : .black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 20)
    }

    private var captureControls: some View {
        HStack(alignment: .center) {
            Button { showGallery = true } label: {
                Group {
                    if let photo = library.photos.first {
                        PhotoThumbnailView(fileURL: library.photoURL(for: photo), contentMode: .fill)
                    } else {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.65), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open your frames")

            Spacer()

            Button(action: takePhoto) {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(camera.isFramingReady ? FramewiseStyle.accent : .white, lineWidth: camera.isFramingReady ? 5 : 4)
                            .frame(width: 74, height: 74)
                        Circle()
                            .fill(camera.isFramingReady ? FramewiseStyle.accent : .white)
                            .frame(width: 62, height: 62)
                            .shadow(color: camera.isFramingReady ? FramewiseStyle.accent.opacity(0.72) : .clear, radius: camera.isFramingReady ? 18 : 0)
                    }
                    Text("TAKE PHOTO")
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.92))
                }
                .overlay(alignment: .top) {
                    if camera.isFramingReady {
                        Text("TAKE THE SHOT")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .frame(height: 27)
                            .background(FramewiseStyle.accent, in: Capsule())
                            .offset(y: -34)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.28), value: camera.isFramingReady)
            }
            .buttonStyle(.plain)
            .disabled(camera.isCapturing || camera.isScanPending || camera.status != .ready)
            .accessibilityLabel("Take photo")

            Spacer()

            Button { camera.startScanning() } label: {
                VStack(spacing: 3) {
                    if camera.isScanPending {
                        ProgressView().tint(.black).scaleEffect(0.72)
                    } else {
                        Image(systemName: camera.scanHasProducedResult ? "arrow.clockwise" : "sparkles")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Text(camera.isScanPending ? "SCANNING" : (camera.scanHasProducedResult ? "SCAN AGAIN" : "SCAN SCENE"))
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .tracking(0.3)
                }
                .foregroundStyle(.black)
                .frame(width: 72, height: 48)
                .background(FramewiseStyle.accent, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(FramewiseStyle.accent.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(camera.isScanPending || camera.status != .ready)
            .accessibilityLabel(camera.isScanPending ? "Scanning scene" : (camera.scanHasProducedResult ? "Scan scene again" : "Scan scene"))
        }
        .foregroundStyle(.white)
        .padding(.bottom, 8)
    }

    private func cameraUnavailable(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 27))
                .foregroundStyle(FramewiseStyle.accent)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
            Button("Open Settings") { showPermissionAlert = true }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(FramewiseStyle.accent, in: Capsule())
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(FramewiseStyle.ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func takePhoto() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera.capture(flash: flashEnabled) { capture in
            guard let capture else { return }
            reviewData = capture.processedData
            reviewRawData = capture.rawData
            reviewRawFormatName = capture.rawFormatName
            showReview = true
        }
    }

    private func zoomLabel(_ zoom: CGFloat) -> String {
        if abs(zoom - 0.5) < 0.01 { return "0.5×" }
        if zoom.rounded() == zoom { return "\(Int(zoom))×" }
        return String(format: "%.1f×", zoom)
    }

    private var visibleZoomChoices: [CGFloat] {
        camera.zoomChoices
    }

    private func startCameraGuide() {
        camera.start()
        camera.startMotion()
    }

    private var guideStatusTitle: String {
        if camera.isScanPending { return "SCANNING ONE FRAME" }
        guard camera.isScanning else { return "READY TO SCAN" }
        if camera.subjectBox == nil {
            return camera.scanHasProducedResult ? "NO SUBJECT FOUND" : "READY TO SCAN"
        }
        return "\(camera.isSubjectLocked ? "TARGET LOCKED" : "TARGET FOUND") · \(camera.subjectLabel.uppercased())"
    }

    private var firstRunGuide: some View {
        let pages: [(String, String, String)] = [
            ("Make every photo\nfeel intentional.", "Scan one camera frame, then follow a quiet guide to shape the shot you already see.", "viewfinder"),
            ("Scan. Aim.\nCompose.", "A target is picked on your iPhone. Move until its marker enters the fixed frame; the camera eases to its ideal zoom.", "scope"),
            ("Ready when\nyou are.", "Your final photo is captured at full camera quality. The scan frame is never used as the photo.", "camera.aperture")
        ]
        let page = pages[min(onboardingPage, pages.count - 1)]
        return ZStack {
            FramewiseStyle.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 42, height: 42)
                        .background(FramewiseStyle.accent, in: RoundedRectangle(cornerRadius: 14))
                    Text("FRAMEWISE")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text("\(onboardingPage + 1) / \(pages.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(FramewiseStyle.muted)
                }
                Spacer()
                Image(systemName: page.2)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(FramewiseStyle.accent)
                    .padding(.bottom, 28)
                Text(page.0)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-1.1)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                    .padding(.bottom, 16)
                Text(page.1)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == onboardingPage ? FramewiseStyle.accent : .white.opacity(0.25))
                            .frame(width: index == onboardingPage ? 24 : 7, height: 7)
                    }
                }
                .padding(.bottom, 23)
                Button {
                    if onboardingPage < pages.count - 1 {
                        withAnimation(.easeInOut(duration: 0.22)) { onboardingPage += 1 }
                    } else {
                        didCompleteFirstRun = true
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(onboardingPage == pages.count - 1 ? "LET’S GO" : "CONTINUE")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .tracking(1.2)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(FramewiseStyle.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                Text("LOCAL BY DEFAULT · OPENROUTER OPTIONAL")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .frame(maxWidth: 520)
        }
        .zIndex(5)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let imageAspectRatio: CGFloat
    let onTap: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.imageAspectRatio = imageAspectRatio
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        uiView.previewLayer.session = session
        uiView.imageAspectRatio = imageAspectRatio
        uiView.onTap = onTap
        if let connection = uiView.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var imageAspectRatio: CGFloat = 0.75
    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(didTapPreview(_:)))
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func didTapPreview(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let sourceAspect = max(imageAspectRatio, 0.01)
        let viewAspect = bounds.width / bounds.height
        var x = point.x / bounds.width
        var yFromTop = point.y / bounds.height
        if sourceAspect > viewAspect {
            let contentWidth = bounds.height * sourceAspect
            let cropX = (contentWidth - bounds.width) / 2
            x = (point.x + cropX) / contentWidth
        } else {
            let contentHeight = bounds.width / sourceAspect
            let cropY = (contentHeight - bounds.height) / 2
            yFromTop = (point.y + cropY) / contentHeight
        }
        let subjectPoint = CGPoint(x: min(max(x, 0), 1), y: 1 - min(max(yFromTop, 0), 1))
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onTap?(subjectPoint, focusPoint)
    }
}

private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                path.move(to: CGPoint(x: width / 3, y: 0))
                path.addLine(to: CGPoint(x: width / 3, y: height))
                path.move(to: CGPoint(x: width * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: width * 2 / 3, y: height))
                path.move(to: CGPoint(x: 0, y: height / 3))
                path.addLine(to: CGPoint(x: width, y: height / 3))
                path.move(to: CGPoint(x: 0, y: height * 2 / 3))
                path.addLine(to: CGPoint(x: width, y: height * 2 / 3))
            }
            .stroke(.white.opacity(0.22), lineWidth: 0.65)
        }
    }
}

private struct SubjectMarker: View {
    let box: CGRect
    let subjectLabel: String
    let imageAspectRatio: CGFloat
    let size: CGSize
    let isLocked: Bool

    var body: some View {
        let sourceAspect = max(imageAspectRatio, 0.01)
        let viewAspect = size.width / max(size.height, 1)
        let contentWidth = sourceAspect > viewAspect ? size.height * sourceAspect : size.width
        let contentHeight = sourceAspect > viewAspect ? size.height : size.width / sourceAspect
        let cropX = (contentWidth - size.width) / 2
        let cropY = (contentHeight - size.height) / 2
        let rect = CGRect(
            x: box.minX * contentWidth - cropX,
            y: (1 - box.maxY) * contentHeight - cropY,
            width: box.width * contentWidth,
            height: box.height * contentHeight
        )
        let marker = CGPoint(x: rect.midX, y: rect.midY)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let frameWidth = min(contentWidth * 0.40, size.width * 0.76)
        let frameHeight = min(contentHeight * 0.34, size.height * 0.40)
        let frameRect = CGRect(
            x: center.x - frameWidth / 2,
            y: center.y - frameHeight / 2,
            width: frameWidth,
            height: frameHeight
        )
        let labelX = min(max(rect.midX, 68), max(68, size.width - 68))
        let labelY = min(max(rect.maxY + 20, 62), max(62, size.height - 45))
        let targetColor = isLocked ? Color.green : FramewiseStyle.accent

        ZStack {
            Path { path in
                path.move(to: center)
                path.addLine(to: marker)
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.25, dash: [4, 6]))

            RoundedRectangle(cornerRadius: 20)
                .stroke(targetColor, style: StrokeStyle(lineWidth: 2.2, dash: [8, 5]))
                .frame(width: frameRect.width, height: frameRect.height)
                .position(center)
                .shadow(color: targetColor.opacity(0.36), radius: 8)

            Text("FRAME TARGET")
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .frame(height: 21)
                .background(targetColor, in: Capsule())
                .position(x: center.x, y: max(16, frameRect.minY - 14))

            Circle().stroke(.white.opacity(0.92), lineWidth: 1.5).frame(width: 34, height: 34).position(center)
            Circle().stroke(targetColor, lineWidth: 2).frame(width: 21, height: 21).position(center)
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .position(center)

            Circle()
                .stroke(targetColor, lineWidth: 2)
                .frame(width: 30, height: 30)
                .position(marker)
            Circle()
                .fill(targetColor)
                .frame(width: 5, height: 5)
                .position(marker)

            HStack(spacing: 5) {
                Circle().fill(.black.opacity(0.75)).frame(width: 5, height: 5)
                Text(subjectLabel.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(0.55)
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(targetColor, in: Capsule())
            .position(x: labelX, y: labelY)
        }
        .animation(.linear(duration: 0.032), value: box)
        .animation(.easeInOut(duration: 0.28), value: isLocked)
    }
}
