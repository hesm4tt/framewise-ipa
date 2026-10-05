import AVFoundation
import CoreImage
import CoreML
import CoreMotion
import ImageIO
import SwiftUI
import Vision

final class CameraEngine: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case ready
        case unavailable(String)
    }

    let session = AVCaptureSession()

    @Published private(set) var status: Status = .idle
    @Published private(set) var subjectBox: CGRect?
    @Published private(set) var subjectLabel = "Subject"
    @Published private(set) var isSubjectLocked = false
    @Published private(set) var isScanPending = false
    @Published private(set) var isZoomingToIdeal = false
    @Published private(set) var guidance = "Tap ✦ to scan this scene"
    @Published private(set) var scanAnalysisLabel = "ON DEVICE"
    @Published private(set) var subjectFramingTip: String?
    @Published private(set) var movementInstruction = "Point at a subject"
    @Published private(set) var movementSymbol = "viewfinder"
    @Published private(set) var suggestedZoom: CGFloat?
    @Published private(set) var idealZoom: CGFloat?
    @Published private(set) var zoomSuggestion = ""
    @Published private(set) var isCapturing = false
    @Published private(set) var hasFlash = false
    @Published private(set) var zoomChoices: [CGFloat] = [1]
    @Published private(set) var isRawCaptureSupported = false
    @Published private(set) var isProRAWCaptureAvailable = false
    @Published private(set) var isRawCaptureEnabled = UserDefaults.standard.bool(forKey: "framewise.rawCaptureEnabled")
    @Published private(set) var currentZoom: CGFloat = 1
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var levelAngle: Double = 0
    @Published private(set) var previewFrameAspectRatio: CGFloat = 0.75
    @Published private(set) var isFramingReady = false
    @Published var isScanning = false
    @Published private(set) var scanHasProducedResult = false

    private let sessionQueue = DispatchQueue(label: "framewise.camera.session")
    private let analysisQueue = DispatchQueue(label: "framewise.camera.analysis", qos: .userInitiated)
    private let motionManager = CMMotionManager()
    private let photoOutput = AVCapturePhotoOutput()
    private let subjectAnalyzer = SubjectAnalyzer()
    private let photoCaptureStateLock = NSLock()
    private var cameraDevice: AVCaptureDevice?
    private var displayZoomMultiplier: CGFloat = 1
    private var rawCapturePixelFormatType: OSType?
    private var rawCaptureFormatName: String?
    private var lastMotionLogTime: TimeInterval = 0
    private var lastTargetLogTime: TimeInterval = 0
    private var pendingScanCaptureDelegate: ScanPhotoCaptureDelegate?
    private var activeScanID = UUID()
    private var zoomAnimationID = UUID()
    private var scanAnchorBox: CGRect?
    private var scanStartZoom: CGFloat = 1
    private var pendingScanZoom: CGFloat = 1
    private var scanReferenceAngles: (yaw: Double, pitch: Double, roll: Double)?
    private var pendingScanReferenceAngles: (yaw: Double, pitch: Double, roll: Double)?
    private var latestMotionAngles: (yaw: Double, pitch: Double, roll: Double)?
    private var portraitHorizontalFieldOfView: CGFloat = .pi / 4
    private var portraitVerticalFieldOfView: CGFloat = .pi / 3
    private var hasInitializedCameraZoom = false
    private var didApplyIdealZoom = false
    private var userAdjustedZoomForScan = false
    private var configured = false
    private var pendingPhotoCompletion: ((CameraCapture?) -> Void)?
    private var pendingPhotoError: Error?
    private var pendingProcessedPhotoData: Data?
    private var pendingRawPhotoData: Data?
    private var pendingPhotoRawFormatName: String?

    var rawCaptureSupportDescription: String {
        guard isRawCaptureSupported else { return "RAW is not available from this camera" }
        return isProRAWCaptureAvailable ? "Apple ProRAW supported on this iPhone" : "DNG RAW supported on this iPhone"
    }

    func setRawCaptureEnabled(_ enabled: Bool) {
        guard isRawCaptureSupported else { return }
        isRawCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "framewise.rawCaptureEnabled")
        AppDiagnostics.shared.log("capture", enabled ? "RAW + processed capture enabled · format=\(rawCaptureFormatName ?? "RAW DNG")" : "RAW capture disabled")
    }

    func start() {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        AppDiagnostics.shared.log("camera", "Start requested · authorization=\(authorization.rawValue)")
        switch authorization {
        case .authorized:
            prepareSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                AppDiagnostics.shared.log("camera", "Camera permission prompt result=\(granted)")
                Task { @MainActor in
                    if granted {
                        self.prepareSession()
                    } else {
                        self.status = .unavailable("Camera access is off. Allow it in Settings to use the live camera.")
                    }
                }
            }
        case .denied, .restricted:
            AppDiagnostics.shared.log("camera", "Camera permission unavailable · status=\(authorization.rawValue)")
            status = .unavailable("Camera access is off. Allow it in Settings to use the live camera.")
        @unknown default:
            status = .unavailable("Camera access is unavailable on this device.")
        }
    }

    func stop() {
        stopMotion()
        stopScanning()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
                AppDiagnostics.shared.log("camera", "Capture session stopped")
            }
            Task { @MainActor in self.status = .idle }
        }
    }

    func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.15
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let referenceFrame: CMAttitudeReferenceFrame = frames.contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical
            : .xArbitraryZVertical
        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let horizonAngle = Self.horizonAngle(from: motion.gravity)
            let angles = (
                yaw: motion.attitude.yaw,
                pitch: motion.attitude.pitch,
                roll: motion.attitude.roll
            )
            let now = ProcessInfo.processInfo.systemUptime
            if let self, now - self.lastMotionLogTime >= 5 {
                self.lastMotionLogTime = now
                AppDiagnostics.shared.log(
                    "motion",
                    String(format: "Gravity x=%.3f y=%.3f z=%.3f · portrait horizon angle=%.3f rad", motion.gravity.x, motion.gravity.y, motion.gravity.z, horizonAngle)
                )
            }
            Task { @MainActor in
                guard let self else { return }
                self.levelAngle = horizonAngle
                self.latestMotionAngles = angles
                if self.isScanning, let anchor = self.scanAnchorBox {
                    self.updateMotionAnchoredTarget(anchor: anchor, currentAngles: angles)
                }
            }
        }
    }

    func stopMotion() {
        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
    }

    func toggleScanning() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }

    func startScanning() {
        requestScan(at: nil)
    }

    func stopScanning() {
        isScanning = false
        isScanPending = false
        activeScanID = UUID()
        zoomAnimationID = UUID()
        subjectBox = nil
        scanAnchorBox = nil
        scanReferenceAngles = nil
        pendingScanReferenceAngles = nil
        subjectLabel = "Subject"
        isSubjectLocked = false
        suggestedZoom = nil
        idealZoom = nil
        zoomSuggestion = ""
        scanHasProducedResult = false
        isFramingReady = false
        isZoomingToIdeal = false
        didApplyIdealZoom = false
        userAdjustedZoomForScan = false
        guidance = "Tap Scan Scene to get a framing guide"
        movementInstruction = "Ready to scan"
        movementSymbol = "sparkles"
        AppDiagnostics.shared.log("scan", "Framing guide stopped")
    }

    func selectSubject(at point: CGPoint) {
        guard isScanning else { return }
        requestScan(at: point)
        AppDiagnostics.shared.log("guidance", String(format: "One-shot rescan requested at tapped point · x=%.3f y=%.3f", point.x, point.y))
    }

    func setZoom(_ requested: CGFloat) {
        if isScanning {
            userAdjustedZoomForScan = true
            didApplyIdealZoom = true
            isZoomingToIdeal = false
            zoomAnimationID = UUID()
        }
        applyZoom(requested, rate: 5)
    }

    func applySuggestedZoom() {
        guard let suggestedZoom else { return }
        didApplyIdealZoom = true
        userAdjustedZoomForScan = true
        isZoomingToIdeal = true
        self.suggestedZoom = nil
        zoomSuggestion = ""
        guidance = "Moving to ideal \(Self.zoomDescription(suggestedZoom)) zoom"
        applyZoom(suggestedZoom, rate: 4)
        finishIdealZoomAnimation(after: 0.6)
    }

    private func applyZoom(_ requested: CGFloat, rate: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                let multiplier = max(self.displayZoomMultiplier, 0.01)
                let nativeZoom = requested / multiplier
                guard nativeZoom >= device.minAvailableVideoZoomFactor - 0.01,
                      nativeZoom <= device.maxAvailableVideoZoomFactor + 0.01 else {
                    device.unlockForConfiguration()
                    AppDiagnostics.shared.log("zoom", "Rejected display stop \(requested)x · native factor \(nativeZoom)x outside \(device.minAvailableVideoZoomFactor)x…\(device.maxAvailableVideoZoomFactor)x")
                    return
                }
                let zoom = min(max(nativeZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.ramp(toVideoZoomFactor: zoom, withRate: rate)
                device.unlockForConfiguration()
                AppDiagnostics.shared.log("zoom", "Requested display stop \(requested)x · native factor \(zoom)x · multiplier \(multiplier)")
                Task { @MainActor in self.currentZoom = zoom * multiplier }
            } catch {
                AppDiagnostics.shared.log("zoom", "Could not set zoom · \(error.localizedDescription)")
            }
        }
    }

    private func requestScan(at selectionPoint: CGPoint?) {
        guard status == .ready else {
            guidance = "Camera is starting…"
            return
        }
        guard !isScanPending else { return }

        isScanning = true
        isScanPending = true
        let openRouterAPIKey = OpenRouterPreferences.enabledAPIKey()
        scanAnalysisLabel = openRouterAPIKey == nil ? "ANALYZED ON THIS IPHONE" : "SENT TO OPENROUTER"
        scanHasProducedResult = false
        isFramingReady = false
        subjectBox = nil
        scanAnchorBox = nil
        scanReferenceAngles = nil
        pendingScanReferenceAngles = latestMotionAngles
        pendingScanZoom = currentZoom
        subjectLabel = "Subject"
        subjectFramingTip = nil
        isSubjectLocked = selectionPoint != nil
        suggestedZoom = nil
        idealZoom = nil
        zoomSuggestion = ""
        isZoomingToIdeal = false
        zoomAnimationID = UUID()
        didApplyIdealZoom = false
        userAdjustedZoomForScan = false
        guidance = openRouterAPIKey == nil
            ? "Capturing one frame for on-device analysis…"
            : "Capturing one frame for OpenRouter AI…"
        movementInstruction = "Hold still"
        movementSymbol = "camera.metering.center.weighted"
        activeScanID = UUID()
        let scanID = activeScanID
        AppDiagnostics.shared.log("scan", "One-shot scan requested · mode=\(openRouterAPIKey == nil ? "on-device" : "openrouter") · selectionPoint=\(selectionPoint.map(Self.pointDescription) ?? "automatic") · cameraZoom=\(currentZoom)x")

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                Task { @MainActor in
                    guard self.activeScanID == scanID else { return }
                    self.finishScanFailure("Camera is not running. Wait a moment and scan again.", scanID: scanID)
                }
                return
            }

            let jpegCodec = self.photoOutput.availablePhotoCodecTypes.first(where: { $0 == .jpeg })
            let settings: AVCapturePhotoSettings
            if let jpegCodec {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: jpegCodec])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.flashMode = .off
            settings.photoQualityPrioritization = .speed
            var scanDimensionsLabel = "standard photo dimensions"
            if #available(iOS 17.0, *) {
                if let smallest = self.cameraDevice?.activeFormat.supportedMaxPhotoDimensions.min(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) {
                    settings.maxPhotoDimensions = smallest
                    scanDimensionsLabel = "\(smallest.width)x\(smallest.height)"
                }
            } else {
                settings.isHighResolutionPhotoEnabled = false
            }

            let delegate = ScanPhotoCaptureDelegate { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { self.pendingScanCaptureDelegate = nil }
                switch result {
                case let .success(data):
                    self.analysisQueue.async {
                        self.subjectAnalyzer.analyzeScanPhoto(
                            data,
                            selectionPoint: selectionPoint,
                            openRouterAPIKey: openRouterAPIKey
                        ) { result in
                            Task { @MainActor in
                                guard self.activeScanID == scanID, self.isScanning else { return }
                                self.finishScan(result, scanID: scanID)
                            }
                        }
                    }
                case let .failure(error):
                    Task { @MainActor in
                        guard self.activeScanID == scanID, self.isScanning else { return }
                        self.finishScanFailure("Couldn’t capture the scan frame. Tap Scan Again.", scanID: scanID)
                    }
                    AppDiagnostics.shared.log("scan", "One-shot scan photo failed · \(error.localizedDescription)")
                }
            }
            self.pendingScanCaptureDelegate = delegate
            AppDiagnostics.shared.log(
                "scan",
                "Temporary scan photo submitted · codec=\(jpegCodec?.rawValue ?? "default") · quality=speed · outputDimensions=\(scanDimensionsLabel)"
            )
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func finishScan(_ result: SceneAnalysisResult, scanID: UUID) {
        guard activeScanID == scanID else { return }
        isScanPending = false
        scanHasProducedResult = true
        previewFrameAspectRatio = result.frameAspectRatio
        subjectLabel = result.label ?? "Subject"
        subjectFramingTip = result.framingTip
        isSubjectLocked = result.isManuallySelected
        scanAnchorBox = result.box
        scanStartZoom = pendingScanZoom
        scanReferenceAngles = pendingScanReferenceAngles ?? latestMotionAngles
        subjectBox = result.box
        let diagnosticSubject = result.source.hasPrefix("openrouter:") ? "redacted" : (result.label ?? "none")
        AppDiagnostics.shared.log(
            "scan",
            "Scan completed · source=\(result.source) · subject=\(diagnosticSubject) · confidence=\(String(format: "%.2f", result.confidence)) · candidates=\(result.candidateCount) · jpegBytes=\(result.scanJPEGBytes) · point=\(result.box.map { Self.pointDescription(CGPoint(x: $0.midX, y: 1 - $0.midY)) } ?? "none") · box=\(result.box.map(Self.boxDescription) ?? "none") · frameRatio=\(result.frameAspectRatio)"
        )

        guard result.errorDescription == nil, let box = result.box else {
            idealZoom = nil
            suggestedZoom = nil
            zoomSuggestion = ""
            guidance = result.errorDescription ?? "No clear subject found. Tap a subject or scan again."
            movementInstruction = "Tap a subject to rescan"
            movementSymbol = "hand.tap"
            setFramingReady(false)
            return
        }

        let targetWidth: CGFloat = 0.40
        let continuousTarget = min(
            max(scanStartZoom * targetWidth / max(box.width, 0.04), zoomChoices.first ?? scanStartZoom),
            zoomChoices.last ?? scanStartZoom
        )
        let zoomTarget = roundedToOpticalStop(continuousTarget, zoomingIn: continuousTarget > scanStartZoom)
        idealZoom = zoomTarget
        didApplyIdealZoom = abs(zoomTarget - currentZoom) <= 0.18
        suggestedZoom = didApplyIdealZoom ? nil : zoomTarget
        zoomSuggestion = didApplyIdealZoom ? "" : "Ideal zoom"
        updateMotionAnchoredTarget(anchor: box, currentAngles: latestMotionAngles)
        if scanReferenceAngles == nil {
            guidance = "Scan complete. Move slowly to center the target."
            AppDiagnostics.shared.log("motion", "No attitude baseline was available at scan completion; retaining static subject point")
        }
    }

    private func finishScanFailure(_ message: String, scanID: UUID) {
        guard activeScanID == scanID else { return }
        isScanPending = false
        scanHasProducedResult = false
        guidance = message
        movementInstruction = "Scan again"
        movementSymbol = "arrow.clockwise"
        setFramingReady(false)
    }

    private func updateMotionAnchoredTarget(
        anchor: CGRect,
        currentAngles: (yaw: Double, pitch: Double, roll: Double)?
    ) {
        let targetBox: CGRect
        if let reference = scanReferenceAngles, let currentAngles {
            let zoomRatio = max(currentZoom / max(scanStartZoom, 0.01), 0.1)
            let horizontalHalfTangent = max(tan(Double(portraitHorizontalFieldOfView) / 2), 0.05)
            let verticalHalfTangent = max(tan(Double(portraitVerticalFieldOfView) / 2), 0.05)
            let yawDelta = Self.wrappedAngle(currentAngles.yaw - reference.yaw)
            let pitchDelta = currentAngles.pitch - reference.pitch
            let rollDelta = Self.wrappedAngle(currentAngles.roll - reference.roll)

            let initialHorizontalAngle = atan(Double(anchor.midX - 0.5) * 2 * horizontalHalfTangent)
            let initialVerticalAngle = atan(Double(anchor.midY - 0.5) * 2 * verticalHalfTangent)
            var offsetX = zoomRatio * tan(initialHorizontalAngle + yawDelta) / (2 * horizontalHalfTangent)
            var offsetY = zoomRatio * tan(initialVerticalAngle - pitchDelta) / (2 * verticalHalfTangent)
            let cosRoll = cos(rollDelta)
            let sinRoll = sin(rollDelta)
            let rolledOffsetX = offsetX * cosRoll + offsetY * sinRoll
            let rolledOffsetY = -offsetX * sinRoll + offsetY * cosRoll
            offsetX = rolledOffsetX
            offsetY = rolledOffsetY

            let centerX = min(max(0.5 + offsetX, -0.35), 1.35)
            let centerY = min(max(0.5 + offsetY, -0.35), 1.35)
            let width = min(max(anchor.width * zoomRatio, 0.025), 1.35)
            let height = min(max(anchor.height * zoomRatio, 0.025), 1.35)
            targetBox = CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        } else {
            targetBox = anchor
        }

        subjectBox = targetBox
        updateAdvice(box: targetBox, exposure: exposureBias, angle: levelAngle)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTargetLogTime >= 5 {
            lastTargetLogTime = now
            let point = CGPoint(x: targetBox.midX, y: 1 - targetBox.midY)
            let delta = scanReferenceAngles.flatMap { reference in
                currentAngles.map { "yaw=\(String(format: "%.3f", Self.wrappedAngle($0.yaw - reference.yaw))) pitch=\(String(format: "%.3f", $0.pitch - reference.pitch))" }
            } ?? "attitude=unavailable"
            AppDiagnostics.shared.log(
                "guidance",
                "Motion-anchored target · \(Self.pointDescription(point)) · \(delta) · idealZoom=\(idealZoom.map(Self.zoomDescription) ?? "none") · currentZoom=\(currentZoom)x"
            )
        }
        let targetCentered = abs(targetBox.midX - 0.5) <= 0.06 && abs(targetBox.midY - 0.5) <= 0.06
        if targetCentered, !didApplyIdealZoom, !userAdjustedZoomForScan, let idealZoom,
           abs(idealZoom - currentZoom) > 0.18 {
            startIdealZoom(to: idealZoom)
        }

        let zoomIsSettled = didApplyIdealZoom || idealZoom == nil || abs((idealZoom ?? currentZoom) - currentZoom) <= 0.18
        setFramingReady(targetCentered && zoomIsSettled && !isZoomingToIdeal && isGoodComposition(targetBox, exposure: exposureBias, angle: levelAngle))
    }

    private func startIdealZoom(to zoom: CGFloat) {
        didApplyIdealZoom = true
        isZoomingToIdeal = true
        suggestedZoom = nil
        zoomSuggestion = ""
        movementInstruction = "Hold steady"
        movementSymbol = "scope"
        guidance = "Centered · moving to \(Self.zoomDescription(zoom)) zoom"
        AppDiagnostics.shared.log("zoom", "Target centered · animating to local scan ideal zoom \(zoom)x")
        applyZoom(zoom, rate: 4)
        finishIdealZoomAnimation(after: 0.65)
    }

    private func finishIdealZoomAnimation(after duration: TimeInterval) {
        let animationID = UUID()
        zoomAnimationID = animationID
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.zoomAnimationID == animationID else { return }
            self.isZoomingToIdeal = false
            if let box = self.subjectBox {
                self.updateAdvice(box: box, exposure: self.exposureBias, angle: self.levelAngle)
                let centered = abs(box.midX - 0.5) <= 0.06 && abs(box.midY - 0.5) <= 0.06
                self.setFramingReady(centered && self.isGoodComposition(box, exposure: self.exposureBias, angle: self.levelAngle))
            }
            AppDiagnostics.shared.log("zoom", "Ideal zoom animation finished")
        }
    }

    func setExposure(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.cameraDevice else { return }
            let bias = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
            AppDiagnostics.shared.log("camera", "Exposure bias set to \(bias) EV")
            Task { @MainActor in self.exposureBias = bias }
        }
    }

    func focus(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.cameraDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func capture(flash: Bool, completion: @escaping (CameraCapture?) -> Void) {
        let shouldCaptureRaw = isRawCaptureEnabled
        AppDiagnostics.shared.log("capture", "Photo capture requested · flash=\(flash) · raw=\(shouldCaptureRaw)")
        Task { @MainActor in isCapturing = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                Task { @MainActor in
                    self.isCapturing = false
                    AppDiagnostics.shared.log("capture", "Capture skipped · session is not running")
                    completion(nil)
                }
                return
            }

            let rawFormat = shouldCaptureRaw ? self.rawCapturePixelFormatType : nil
            let processedCodec = self.photoOutput.availablePhotoCodecTypes.first(where: { $0 == .hevc })
                ?? self.photoOutput.availablePhotoCodecTypes.first(where: { $0 == .jpeg })
            let processedFormat: [String: Any]? = processedCodec.map { [AVVideoCodecKey: $0] }
            let settings: AVCapturePhotoSettings
            if let rawFormat, let processedFormat {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: processedFormat)
            } else if let processedFormat {
                settings = AVCapturePhotoSettings(format: processedFormat)
                if shouldCaptureRaw {
                    AppDiagnostics.shared.log("capture", "RAW requested, but no usable RAW + processed format was available · captured highest-quality processed image instead")
                }
            } else {
                settings = AVCapturePhotoSettings()
                if shouldCaptureRaw {
                    AppDiagnostics.shared.log("capture", "RAW requested, but no processed codec was available · captured using the output default")
                }
            }
            settings.photoQualityPrioritization = .quality
            var maxDimensionsLabel = "high-resolution default"
            if #available(iOS 17.0, *) {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                maxDimensionsLabel = "\(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height)"
            } else {
                settings.isHighResolutionPhotoEnabled = true
            }
            if let device = self.cameraDevice, device.hasFlash {
                settings.flashMode = flash ? .on : .off
            }
            self.photoCaptureStateLock.lock()
            self.pendingPhotoCompletion = completion
            self.pendingPhotoError = nil
            self.pendingProcessedPhotoData = nil
            self.pendingRawPhotoData = nil
            self.pendingPhotoRawFormatName = rawFormat == nil ? nil : self.rawCaptureFormatName
            self.photoCaptureStateLock.unlock()
            AppDiagnostics.shared.log(
                "capture",
                "AVCapturePhotoOutput capturePhoto submitted · quality=\(settings.photoQualityPrioritization.rawValue) · codec=\(processedCodec?.rawValue ?? "default") · rawFormat=\(rawFormat == nil ? "off" : self.rawCaptureFormatName ?? "DNG") · maxPhotoDimensions=\(maxDimensionsLabel)"
            )
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func prepareSession() {
        status = .starting
        AppDiagnostics.shared.log("camera", "Preparing capture session")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                do {
                    try self.configureSession()
                    self.configured = true
                } catch {
                    AppDiagnostics.shared.log("camera", "Session configuration failed · \(error.localizedDescription)")
                    Task { @MainActor in self.status = .unavailable(error.localizedDescription) }
                    return
                }
            }
            let device = self.cameraDevice
            let choices = self.makeZoomChoices(for: device)
            if let device, !self.hasInitializedCameraZoom {
                let preferred = choices.first ?? 1
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = preferred / max(self.displayZoomMultiplier, 0.01)
                    device.unlockForConfiguration()
                    self.hasInitializedCameraZoom = true
                    AppDiagnostics.shared.log("zoom", "Initial scan zoom selected · displayFactor=\(preferred)x")
                } catch {
                    AppDiagnostics.shared.log("zoom", "Could not select initial scan zoom · \(error.localizedDescription)")
                }
            }
            if !self.session.isRunning {
                self.session.startRunning()
                AppDiagnostics.shared.log("camera", "Capture session startRunning returned · running=\(self.session.isRunning)")
            }
            let initialZoom = (device?.videoZoomFactor ?? 1) * self.displayZoomMultiplier
            Task { @MainActor in
                self.currentZoom = initialZoom
                self.zoomChoices = choices
                self.hasFlash = device?.hasFlash ?? false
                self.status = .ready
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        let preferredDevice = types.lazy.compactMap { type in
            discovery.devices.first { $0.deviceType == type }
        }.first
        guard let device = preferredDevice else {
            throw CameraSetupError.noCamera
        }
        if #available(iOS 18.0, *) {
            displayZoomMultiplier = max(device.displayVideoZoomFactorMultiplier, 0.01)
        } else {
            displayZoomMultiplier = 1
        }
        let sensorDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let landscapeAspect = Double(max(sensorDimensions.width, sensorDimensions.height)) /
            Double(max(1, min(sensorDimensions.width, sensorDimensions.height)))
        let landscapeHorizontalFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
        portraitHorizontalFieldOfView = CGFloat(2 * atan(tan(landscapeHorizontalFOV / 2) / max(landscapeAspect, 1)))
        portraitVerticalFieldOfView = CGFloat(landscapeHorizontalFOV)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { String(describing: $0) }.joined(separator: ",")
        let constituents = device.constituentDevices.map(\.deviceType.rawValue).joined(separator: ",")
        AppDiagnostics.shared.log(
            "camera",
            "Selected \(device.localizedName) · type=\(device.deviceType.rawValue) · virtual=\(device.isVirtualDevice) · constituentTypes=[\(constituents)] · minNativeZoom=\(device.minAvailableVideoZoomFactor) · maxNativeZoom=\(device.maxAvailableVideoZoomFactor) · displayMultiplier=\(displayZoomMultiplier) · switchOvers=[\(switchOvers)] · activeFormatMaxZoom=\(device.activeFormat.videoMaxZoomFactor)"
        )
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraSetupError.cannotAddCamera }
        session.addInput(input)
        cameraDevice = device

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            if #available(iOS 17.0, *) {
                if let maximum = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) {
                    photoOutput.maxPhotoDimensions = maximum
                    AppDiagnostics.shared.log("capture", "Maximum still dimensions selected from active camera format · \(maximum.width)x\(maximum.height)")
                }
            } else {
                photoOutput.isHighResolutionCaptureEnabled = true
            }
            let proRAWSupported = photoOutput.isAppleProRAWSupported
            photoOutput.isAppleProRAWEnabled = proRAWSupported
            let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes
            let proRAWFormat = rawFormats.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
            let bayerFormat = rawFormats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
            rawCapturePixelFormatType = proRAWFormat ?? bayerFormat
            rawCaptureFormatName = proRAWFormat != nil ? "Apple ProRAW" : (bayerFormat != nil ? "Bayer RAW" : nil)
            AppDiagnostics.shared.log(
                "capture",
                "RAW capability discovered · AppleProRAW=\(proRAWSupported) · BayerRAW=\(bayerFormat != nil) · selected=\(rawCaptureFormatName ?? "none") · availableFormats=\(rawFormats.count)"
            )
            Task { @MainActor in
                self.isProRAWCaptureAvailable = proRAWSupported
                self.isRawCaptureSupported = self.rawCapturePixelFormatType != nil
                self.isRawCaptureEnabled = self.isRawCaptureSupported && UserDefaults.standard.bool(forKey: "framewise.rawCaptureEnabled")
            }
            if let connection = photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        } else {
            throw CameraSetupError.cannotAddPhotoOutput
        }
        AppDiagnostics.shared.log("scan", "Live video-frame analysis disabled · each scan uses one temporary camera photo")
    }

    private func makeZoomChoices(for device: AVCaptureDevice?) -> [CGFloat] {
        guard let device else { return [1] }
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        let multiplier = max(displayZoomMultiplier, 0.01)

        // Read the actual rear-camera system instead of assuming every iPhone
        // has the same lenses. The 48 MP sensor crops reproduce Apple's
        // optical-quality 2x/8x presets; telephoto focal length supplies the
        // model-specific physical lens stop (3x, 4x, 5x, and so on).
        let physicalCameras = [device] + device.constituentDevices
        let wideCamera = physicalCameras.first { $0.deviceType == .builtInWideAngleCamera } ?? device
        var candidates: [CGFloat] = [1]

        if physicalCameras.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
            candidates.append(0.5)
        }

        if Self.sensorMegapixels(for: wideCamera) >= 32 {
            candidates.append(2)
        }

        let telephotoCameras = physicalCameras.filter { $0.deviceType == .builtInTelephotoCamera }
        for telephoto in telephotoCameras {
            if let telephotoFactor = Self.advertisedTelephotoFactor(from: wideCamera, to: telephoto) {
                candidates.append(telephotoFactor)
                if Self.sensorMegapixels(for: telephoto) >= 32 {
                    candidates.append(telephotoFactor * 2)
                }
            }
        }

        let uniqueCandidates = candidates
            .sorted()
            .reduce(into: [CGFloat]()) { values, candidate in
                if !values.contains(where: { abs($0 - candidate) < 0.08 }) {
                    values.append(candidate)
                }
            }
        let choices = uniqueCandidates.filter { displayZoom in
            let nativeZoom = displayZoom / multiplier
            return nativeZoom >= minZoom - 0.02 && nativeZoom <= maxZoom + 0.02
        }
        let lensSummary = physicalCameras.map { camera in
            "\(camera.deviceType.rawValue):\(Int(Self.sensorMegapixels(for: camera)))MP"
        }.joined(separator: ",")
        AppDiagnostics.shared.log(
            "zoom",
            "Optical stops=\(choices.map(Self.zoomDescription).joined(separator: ",")) · detected lenses=[\(lensSummary)] · nativeRange=\(minZoom)…\(maxZoom) · displayMultiplier=\(multiplier)"
        )
        return choices.isEmpty ? [1] : choices
    }

    private static func sensorMegapixels(for device: AVCaptureDevice) -> Double {
        let dimensions: CMVideoDimensions
        if #available(iOS 17.0, *) {
            guard let maximum = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            }) else { return 0 }
            dimensions = maximum
        } else {
            dimensions = device.activeFormat.highResolutionStillImageDimensions
        }
        return Double(dimensions.width) * Double(dimensions.height) / 1_000_000
    }

    private static func advertisedTelephotoFactor(from wide: AVCaptureDevice, to telephoto: AVCaptureDevice) -> CGFloat? {
        let wideAngle = CGFloat(wide.activeFormat.videoFieldOfView) * .pi / 360
        let telephotoAngle = CGFloat(telephoto.activeFormat.videoFieldOfView) * .pi / 360
        guard wideAngle > 0, telephotoAngle > 0, telephotoAngle < wideAngle else { return nil }
        let measuredFactor = tan(wideAngle) / tan(telephotoAngle)
        let knownLensFactors: [CGFloat] = [2, 2.5, 3, 3.5, 4, 5, 6, 8]
        guard let factor = knownLensFactors.min(by: { abs($0 - measuredFactor) < abs($1 - measuredFactor) }),
              abs(factor - measuredFactor) <= max(0.28, factor * 0.10) else {
            return nil
        }
        return factor
    }

    private static func zoomDescription(_ zoom: CGFloat) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))x" : "\(zoom)x"
    }

    private static func pointDescription(_ point: CGPoint) -> String {
        String(format: "x=%.3f y=%.3f", point.x, point.y)
    }

    private static func boxDescription(_ box: CGRect) -> String {
        String(format: "x=%.3f y=%.3f w=%.3f h=%.3f", box.minX, box.minY, box.width, box.height)
    }

    private static func wrappedAngle(_ angle: Double) -> Double {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    private func updateAdvice(box: CGRect?, exposure: Float, angle: Double) {
        if !didApplyIdealZoom, !userAdjustedZoomForScan, !isZoomingToIdeal,
           let idealZoom, abs(idealZoom - currentZoom) > 0.18 {
            suggestedZoom = idealZoom
            zoomSuggestion = "Ideal zoom"
        } else {
            suggestedZoom = nil
            zoomSuggestion = ""
        }
        if abs(angle) > 0.055 {
            movementInstruction = "Level your phone"
            movementSymbol = "level"
            guidance = "Straighten the horizon for a calmer frame"
            return
        }
        if exposure < -0.7 {
            movementInstruction = "Raise exposure"
            movementSymbol = "sun.max.fill"
            guidance = "Raise exposure to bring back shadow detail"
            return
        }
        if exposure > 0.7 {
            movementInstruction = "Lower exposure"
            movementSymbol = "sun.min.fill"
            guidance = "Lower exposure to protect bright areas"
            return
        }
        guard let box else {
            movementInstruction = scanHasProducedResult ? "Tap a subject to rescan" : "Scan the scene"
            movementSymbol = scanHasProducedResult ? "hand.tap" : "sparkles"
            guidance = scanHasProducedResult ? "Tap a subject to choose a new target" : "Capture one frame for a local scan"
            return
        }
        let x = box.midX
        let yFromTop = 1 - box.midY
        var directions: [String] = []
        if x < 0.43 { directions.append("left") }
        if x > 0.57 { directions.append("right") }
        if yFromTop < 0.40 { directions.append("up") }
        if yFromTop > 0.60 { directions.append("down") }
        if directions.isEmpty {
            movementInstruction = "Hold steady"
            movementSymbol = "scope"
            if isZoomingToIdeal, let idealZoom {
                guidance = "Centered · moving to \(Self.zoomDescription(idealZoom)) zoom"
            } else if let idealZoom, abs(idealZoom - currentZoom) > 0.18, !userAdjustedZoomForScan {
                guidance = "\(subjectLabel) is centered · preparing ideal zoom"
            } else {
                guidance = "\(subjectLabel) is centered · take the shot"
            }
        } else {
            movementInstruction = "Move phone " + directions.joined(separator: " & ")
            if directions.count == 2 {
                let horizontal = directions[0]
                let vertical = directions[1]
                movementSymbol = vertical == "up"
                    ? (horizontal == "left" ? "arrow.up.left" : "arrow.up.right")
                    : (horizontal == "left" ? "arrow.down.left" : "arrow.down.right")
            } else {
                movementSymbol = "arrow." + directions[0]
            }
            guidance = "Bring \(subjectLabel.lowercased()) toward the center"
        }

        if box.width < 0.34 {
            guidance = "Give \(subjectLabel.lowercased()) a closer, more intentional frame"
        } else if box.width > 0.58 {
            guidance = "Back up or widen to give \(subjectLabel.lowercased()) room"
        }

    }

    private func roundedToOpticalStop(_ target: CGFloat, zoomingIn: Bool) -> CGFloat {
        let directionalStops = zoomChoices.filter { stop in
            zoomingIn ? stop > currentZoom + 0.12 : stop < currentZoom - 0.12
        }
        guard let nearestStop = directionalStops.min(by: { abs($0 - target) < abs($1 - target) }) else {
            return target
        }
        // Use a real lens or sensor-crop stop when it is a reasonable match.
        // Keep a precise intermediate zoom for subjects that would be poorly
        // framed by jumping to the next optical-quality choice.
        let relativeDifference = abs(nearestStop - target) / max(target, 0.1)
        return relativeDifference <= 0.70 ? nearestStop : target
    }

    private func isGoodComposition(_ box: CGRect, exposure: Float, angle: Double) -> Bool {
        abs(angle) <= 0.055 && exposure >= -0.7 && exposure <= 0.7 &&
        box.midX >= 0.44 && box.midX <= 0.56 &&
        (1 - box.midY) >= 0.36 && (1 - box.midY) <= 0.64 &&
        box.width >= 0.20 && box.width <= 0.62
    }

    private func setFramingReady(_ ready: Bool) {
        guard isFramingReady != ready else { return }
        isFramingReady = ready
        AppDiagnostics.shared.log("scan", ready ? "Composition ready · shutter glow enabled" : "Composition changed · shutter glow disabled")
    }

    private static func horizonAngle(from gravity: CMAcceleration) -> Double {
        // Gravity projected onto the portrait screen plane measures roll more
        // consistently than Euler roll across different phone poses.
        let angle = atan2(gravity.x, gravity.y)
        if angle > .pi / 2 { return angle - .pi }
        if angle < -.pi / 2 { return angle + .pi }
        return angle
    }

    private enum CameraSetupError: LocalizedError {
        case noCamera, cannotAddCamera, cannotAddPhotoOutput
        var errorDescription: String? {
            switch self {
            case .noCamera: "No rear camera is available on this device."
            case .cannotAddCamera: "The camera could not be started."
            case .cannotAddPhotoOutput: "Photo capture is unavailable."
            }
        }
    }
}

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        self.photoCaptureStateLock.lock()
        if photo.isRawPhoto {
            self.pendingRawPhotoData = data
        } else {
            self.pendingProcessedPhotoData = data
            self.pendingPhotoError = error
        }
        self.photoCaptureStateLock.unlock()
        let kind = photo.isRawPhoto ? "RAW DNG" : "processed image"
        AppDiagnostics.shared.log("capture", error.map { "\(kind) processing failed · \($0.localizedDescription)" } ?? "\(kind) processing completed · dataBytes=\(data?.count ?? 0)")
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        self.photoCaptureStateLock.lock()
        let processedData = self.pendingProcessedPhotoData
        let rawData = self.pendingRawPhotoData
        let processingError = self.pendingPhotoError
        let rawFormatName = self.pendingPhotoRawFormatName
        let completion = self.pendingPhotoCompletion
        self.pendingProcessedPhotoData = nil
        self.pendingRawPhotoData = nil
        self.pendingPhotoError = nil
        self.pendingPhotoRawFormatName = nil
        self.pendingPhotoCompletion = nil
        self.photoCaptureStateLock.unlock()

        let captureError = error ?? processingError
        let result = captureError == nil ? processedData.map {
            CameraCapture(processedData: $0, rawData: rawData, rawFormatName: rawData == nil ? nil : rawFormatName)
        } : nil
        AppDiagnostics.shared.log("capture", captureError.map { "Capture finished with error · \($0.localizedDescription)" } ?? (result == nil ? "Capture finished without processed image data" : "Capture finished successfully · processedBytes=\(result?.processedData.count ?? 0) · rawBytes=\(result?.rawData?.count ?? 0)"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            completion?(result)
        }
    }
}

private final class ScanPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void
    private var photoData: Data?
    private var processingError: Error?

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            processingError = error
        } else if !photo.isRawPhoto {
            photoData = photo.fileDataRepresentation()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? processingError {
            completion(.failure(error))
        } else if let photoData {
            completion(.success(photoData))
        } else {
            completion(.failure(NSError(
                domain: "Framewise.ScanPhoto",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The camera returned no scan image."]
            )))
        }
    }
}

private struct SceneAnalysisResult {
    let box: CGRect?
    let label: String?
    let isManuallySelected: Bool
    let source: String
    let errorDescription: String?
    let frameAspectRatio: CGFloat
    let confidence: Float
    let candidateCount: Int
    let scanJPEGBytes: Int
    let framingTip: String?

    init(
        box: CGRect?,
        label: String?,
        isManuallySelected: Bool,
        source: String,
        errorDescription: String?,
        frameAspectRatio: CGFloat,
        confidence: Float = 0,
        candidateCount: Int = 0,
        scanJPEGBytes: Int = 0,
        framingTip: String? = nil
    ) {
        self.box = box
        self.label = label
        self.isManuallySelected = isManuallySelected
        self.source = source
        self.errorDescription = errorDescription
        self.frameAspectRatio = frameAspectRatio
        self.confidence = confidence
        self.candidateCount = candidateCount
        self.scanJPEGBytes = scanJPEGBytes
        self.framingTip = framingTip
    }
}

private struct DetectedSubject {
    let box: CGRect
    let label: String
    let confidence: Float
}

private final class SubjectAnalyzer: NSObject {
    private var modelRequest: VNCoreMLRequest?
    private var modelLoadError: String?

    func analyzeScanPhoto(
        _ photoData: Data,
        selectionPoint: CGPoint?,
        openRouterAPIKey: String?,
        completion: @escaping (SceneAnalysisResult) -> Void
    ) {
        guard let (scanJPEG, scanImage) = Self.makeCompactScanImage(from: photoData) else {
            completion(SceneAnalysisResult(
                box: nil,
                label: nil,
                isManuallySelected: selectionPoint != nil,
                source: "preprocessError",
                errorDescription: "Couldn’t prepare the camera frame for analysis. Scan again.",
                frameAspectRatio: 0.75
            ))
            return
        }

        let aspectRatio = CGFloat(scanImage.width) / CGFloat(max(1, scanImage.height))
        if let openRouterAPIKey {
            OpenRouterScanner.scan(jpegData: scanJPEG, selectionPoint: selectionPoint, apiKey: openRouterAPIKey) { result in
                switch result {
                case let .success(remoteResult):
                    completion(SceneAnalysisResult(
                        box: remoteResult.box,
                        label: remoteResult.label,
                        isManuallySelected: selectionPoint != nil,
                        source: "openrouter:\(OpenRouterScanner.modelID)",
                        errorDescription: nil,
                        frameAspectRatio: aspectRatio,
                        confidence: remoteResult.confidence,
                        candidateCount: 1,
                        scanJPEGBytes: scanJPEG.count,
                        framingTip: remoteResult.framingTip
                    ))
                case let .failure(error):
                    AppDiagnostics.shared.log("openrouter", "Using local scan fallback · code=\(error.diagnosticCode)")
                    self.analyzeLocally(
                        scanJPEG: scanJPEG,
                        scanImage: scanImage,
                        selectionPoint: selectionPoint,
                        remoteFallbackCode: error.diagnosticCode,
                        completion: completion
                    )
                }
            }
            return
        }

        analyzeLocally(
            scanJPEG: scanJPEG,
            scanImage: scanImage,
            selectionPoint: selectionPoint,
            remoteFallbackCode: nil,
            completion: completion
        )
    }

    private func analyzeLocally(
        scanJPEG: Data,
        scanImage: CGImage,
        selectionPoint: CGPoint?,
        remoteFallbackCode: String?,
        completion: @escaping (SceneAnalysisResult) -> Void
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let aspectRatio = CGFloat(scanImage.width) / CGFloat(max(1, scanImage.height))
        var candidates: [DetectedSubject] = []
        var requestError: String? = remoteFallbackCode
        var source = "YOLOv3Tiny"
        if let request = ensureModel() {
            do {
                try VNImageRequestHandler(cgImage: scanImage, orientation: .up, options: [:]).perform([request])
                candidates = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation in
                    guard let label = observation.labels.first, label.confidence >= 0.12 else { return nil }
                    let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard box.width > 0.025, box.height > 0.025, box.width * box.height < 0.88 else { return nil }
                    return DetectedSubject(box: box, label: Self.displayName(label.identifier), confidence: label.confidence)
                }
            } catch {
                requestError = error.localizedDescription
                AppDiagnostics.shared.log("vision", "One-shot YOLO request failed · \(error.localizedDescription)")
            }
        } else {
            requestError = modelLoadError
        }

        if candidates.isEmpty, let salient = saliencySubject(in: scanImage) {
            candidates = [salient]
            source = "objectnessSaliency"
            AppDiagnostics.shared.log("vision", "One-shot objectness saliency fallback selected a region")
        }

        var selected: DetectedSubject?
        let manuallySelected = selectionPoint != nil
        if let selectionPoint {
            selected = candidates
                .filter { $0.box.contains(selectionPoint) || Self.distance($0.box, selectionPoint) < 0.04 }
                .min { Self.distance($0.box, selectionPoint) < Self.distance($1.box, selectionPoint) }
            if selected == nil {
                let width: CGFloat = 0.22
                let height = min(width * max(aspectRatio, 0.25), 0.30)
                let box = CGRect(
                    x: selectionPoint.x - width / 2,
                    y: selectionPoint.y - height / 2,
                    width: width,
                    height: height
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                selected = DetectedSubject(box: box, label: "Subject", confidence: 1)
                source = "manualPoint"
            } else {
                source = "manuallySelectedDetection"
            }
        } else {
            selected = Self.bestCandidate(in: candidates)
        }

        if remoteFallbackCode != nil {
            source = "localFallback(\(source))"
        }
        let errorDescription: String?
        if selected == nil && remoteFallbackCode != nil {
            errorDescription = "OpenRouter was unavailable and the local scan found no subject. Tap a subject to frame it manually or scan again."
        } else if selected == nil && requestError != nil {
            errorDescription = "On-device subject scan failed. Tap a subject to frame it manually or scan again."
        } else {
            errorDescription = nil
        }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let result = SceneAnalysisResult(
            box: selected?.box,
            label: selected?.label,
            isManuallySelected: manuallySelected,
            source: source,
            errorDescription: errorDescription,
            frameAspectRatio: aspectRatio,
            confidence: selected?.confidence ?? 0,
            candidateCount: candidates.count,
            scanJPEGBytes: scanJPEG.count
        )
        AppDiagnostics.shared.log(
            "vision",
            "One-shot local scan inference finished · ms=\(elapsed) · image=\(scanImage.width)x\(scanImage.height) · jpegBytes=\(scanJPEG.count) · candidates=\(candidates.count) · source=\(source) · selected=\(selected?.label ?? "none") · box=\(selected.map { Self.boxText($0.box) } ?? "none")"
        )
        completion(result)
    }

    private func ensureModel() -> VNCoreMLRequest? {
        if let modelRequest { return modelRequest }
        if modelLoadError != nil { return nil }
        do {
            guard let url = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc") else {
                throw NSError(domain: "Framewise.Model", code: 1, userInfo: [NSLocalizedDescriptionKey: "The on-device subject model is missing from the app bundle."])
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let coreMLModel = try MLModel(contentsOf: url, configuration: configuration)
            let visionModel = try VNCoreMLModel(for: coreMLModel)
            visionModel.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
                "confidenceThreshold": MLFeatureValue(double: 0.16),
                "iouThreshold": MLFeatureValue(double: 0.55)
            ])
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFit
            request.preferBackgroundProcessing = false
            modelRequest = request
            AppDiagnostics.shared.log("vision", "YOLOv3Tiny loaded · one inference per scan · Core ML computeUnits=all · network=none")
            return request
        } catch {
            modelLoadError = error.localizedDescription
            AppDiagnostics.shared.log("vision", "Object model load failed · \(error.localizedDescription)")
            return nil
        }
    }

    private static func makeCompactScanImage(from photoData: Data) -> (Data, CGImage)? {
        guard let source = CGImageSourceCreateWithData(photoData as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceShouldCache: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let jpegBuffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegBuffer as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.53] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let compressedSource = CGImageSourceCreateWithData(jpegBuffer as CFData, nil),
              let compressedImage = CGImageSourceCreateImageAtIndex(compressedSource, 0, nil) else {
            return nil
        }
        return (jpegBuffer as Data, compressedImage)
    }

    private func saliencySubject(in image: CGImage) -> DetectedSubject? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.preferBackgroundProcessing = false
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            let candidate = request.results?.first?.salientObjects?
                .filter { $0.confidence > 0.08 && $0.boundingBox.width * $0.boundingBox.height < 0.85 }
                .max(by: { $0.confidence < $1.confidence })
            return candidate.map { DetectedSubject(box: $0.boundingBox, label: "Subject", confidence: $0.confidence) }
        } catch {
            AppDiagnostics.shared.log("vision", "One-shot objectness fallback failed · \(error.localizedDescription)")
            return nil
        }
    }

    private static func bestCandidate(in candidates: [DetectedSubject]) -> DetectedSubject? {
        candidates
            .filter { $0.box.width * $0.box.height > 0.004 }
            .max { score($0) < score($1) }
    }

    private static func score(_ subject: DetectedSubject) -> CGFloat {
        let centerDistance = hypot(subject.box.midX - 0.5, subject.box.midY - 0.5)
        let centrality = max(0, 1 - centerDistance / 0.72)
        let area = max(subject.box.width * subject.box.height, 0.001)
        let sizeFit = max(0, 1 - abs(log(area / 0.12)) / 4)
        return CGFloat(subject.confidence) * 0.38 + centrality * 0.42 + sizeFit * 0.20
    }

    private static func distance(_ box: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(max(box.minX - point.x, 0), point.x - box.maxX)
        let dy = max(max(box.minY - point.y, 0), point.y - box.maxY)
        return hypot(dx, dy)
    }

    private static func boxText(_ box: CGRect) -> String {
        String(format: "x=%.3f y=%.3f w=%.3f h=%.3f", box.minX, box.minY, box.width, box.height)
    }

    private static func displayName(_ identifier: String) -> String {
        let replacements = ["pottedplant": "Plant", "diningtable": "Table", "tvmonitor": "Screen"]
        if let replacement = replacements[identifier.lowercased()] { return replacement }
        return identifier.capitalized
    }
}
