import AVFoundation
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
    @Published private(set) var guidance = "Tap ✦ to scan this scene"
    @Published private(set) var movementInstruction = "Point at a subject"
    @Published private(set) var movementSymbol = "viewfinder"
    @Published private(set) var suggestedZoom: CGFloat?
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
    private let videoOutput = AVCaptureVideoDataOutput()
    private let subjectAnalyzer = SubjectAnalyzer()
    private let photoCaptureStateLock = NSLock()
    private var cameraDevice: AVCaptureDevice?
    private var displayZoomMultiplier: CGFloat = 1
    private var rawCapturePixelFormatType: OSType?
    private var rawCaptureFormatName: String?
    private var consecutiveGoodAnalyses = 0
    private var lastMotionLogTime: TimeInterval = 0
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
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let horizonAngle = Self.horizonAngle(from: motion.gravity)
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
                if self.isScanning, let box = self.subjectBox {
                    self.updateAdvice(box: box, exposure: self.exposureBias, angle: horizonAngle)
                }
            }
        }
    }

    func stopMotion() {
        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
    }

    func toggleScanning() {
        setScanning(!isScanning)
    }

    func startScanning() {
        setScanning(true)
    }

    private func setScanning(_ enabled: Bool) {
        guard isScanning != enabled else { return }
        isScanning = enabled
        subjectAnalyzer.isEnabled = enabled
        subjectBox = nil
        subjectLabel = "Subject"
        suggestedZoom = nil
        zoomSuggestion = ""
        scanHasProducedResult = false
        isFramingReady = false
        consecutiveGoodAnalyses = 0
        guidance = enabled ? "Finding your subject…" : "Tap Start Guide for live framing tips"
        movementInstruction = enabled ? "Point at a subject" : "Guide paused"
        movementSymbol = enabled ? "viewfinder" : "pause.fill"
        AppDiagnostics.shared.log("scan", enabled ? "Scene scan enabled" : "Scene scan disabled")
    }

    func selectSubject(at point: CGPoint) {
        guard isScanning else { return }
        subjectAnalyzer.selectSubject(at: point)
        AppDiagnostics.shared.log("guidance", String(format: "Manual subject selection requested · x=%.3f y=%.3f", point.x, point.y))
    }

    func setZoom(_ requested: CGFloat) {
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
                device.ramp(toVideoZoomFactor: zoom, withRate: 5)
                device.unlockForConfiguration()
                AppDiagnostics.shared.log("zoom", "Requested display stop \(requested)x · native factor \(zoom)x · multiplier \(multiplier)")
                Task { @MainActor in self.currentZoom = zoom * multiplier }
            } catch {
                AppDiagnostics.shared.log("zoom", "Could not set zoom · \(error.localizedDescription)")
            }
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
            if !self.session.isRunning {
                self.session.startRunning()
                AppDiagnostics.shared.log("camera", "Capture session startRunning returned · running=\(self.session.isRunning)")
            }
            let device = self.cameraDevice
            let initialZoom = (device?.videoZoomFactor ?? 1) * self.displayZoomMultiplier
            let choices = self.makeZoomChoices(for: device)
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
        } else {
            throw CameraSetupError.cannotAddPhotoOutput
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        subjectAnalyzer.onResult = { [weak self] result in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.subjectBox = result.box
                self.subjectLabel = result.label ?? "Subject"
                self.previewFrameAspectRatio = result.frameAspectRatio
                self.scanHasProducedResult = true
                if result.errorDescription != nil {
                    self.guidance = "Scan error · share diagnostics"
                    self.movementInstruction = "Point at a subject"
                    self.movementSymbol = "viewfinder"
                    self.suggestedZoom = nil
                    self.zoomSuggestion = ""
                    self.consecutiveGoodAnalyses = 0
                    self.setFramingReady(false)
                } else {
                    self.updateAdvice(box: result.box, exposure: self.exposureBias, angle: self.levelAngle)
                    let ready = result.box.map { self.isGoodComposition($0, exposure: self.exposureBias, angle: self.levelAngle) } ?? false
                    self.consecutiveGoodAnalyses = ready ? self.consecutiveGoodAnalyses + 1 : 0
                    self.setFramingReady(self.consecutiveGoodAnalyses >= 2)
                }
            }
        }
        videoOutput.setSampleBufferDelegate(subjectAnalyzer, queue: analysisQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraSetupError.cannotAddAnalysisOutput }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            AppDiagnostics.shared.log("camera", "Video output connected · orientation=portrait · pixelFormat=BGRA · discardsLateFrames=true")
        } else {
            AppDiagnostics.shared.log("camera", "Video output has no video connection")
        }
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

    private func updateAdvice(box: CGRect?, exposure: Float, angle: Double) {
        suggestedZoom = nil
        zoomSuggestion = ""
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
            movementInstruction = scanHasProducedResult ? "Tap the subject you want" : "Point at something to scan"
            movementSymbol = scanHasProducedResult ? "hand.tap" : "viewfinder"
            guidance = scanHasProducedResult ? "Tap any object to lock the guide onto it" : "Finding a subject in the scene…"
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
            guidance = "\(subjectLabel) is centered · take the shot"
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

        if directions.isEmpty, box.width < 0.34 {
            guidance = "Give \(subjectLabel.lowercased()) a closer, more intentional frame"
        } else if directions.isEmpty, box.width > 0.58 {
            guidance = "Back up or widen to give \(subjectLabel.lowercased()) room"
        }

        let targetWidth: CGFloat = 0.40
        let continuousTarget = min(max(currentZoom * targetWidth / max(box.width, 0.04), zoomChoices.first ?? 1), zoomChoices.last ?? currentZoom)
        let targetZoom = roundedToOpticalStop(continuousTarget, zoomingIn: box.width < targetWidth)
        if directions.isEmpty, box.width < 0.34, abs(targetZoom - currentZoom) > 0.18 {
            suggestedZoom = targetZoom
            zoomSuggestion = "Frame subject"
        } else if directions.isEmpty, box.width > 0.58, abs(targetZoom - currentZoom) > 0.18 {
            suggestedZoom = targetZoom
            zoomSuggestion = "Widen frame"
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
        case noCamera, cannotAddCamera, cannotAddPhotoOutput, cannotAddAnalysisOutput
        var errorDescription: String? {
            switch self {
            case .noCamera: "No rear camera is available on this device."
            case .cannotAddCamera: "The camera could not be started."
            case .cannotAddPhotoOutput: "Photo capture is unavailable."
            case .cannotAddAnalysisOutput: "Live composition analysis is unavailable."
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

private struct SceneAnalysisResult {
    let box: CGRect?
    let label: String?
    let source: String
    let errorDescription: String?
    let frameAspectRatio: CGFloat
}

private struct DetectedSubject {
    let box: CGRect
    let label: String
    let confidence: Float
}

private final class SubjectAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let stateLock = NSLock()
    private var enabled = false
    private var pendingSelectionPoint: CGPoint?
    private var shouldResetTracking = true
    private var lastDetectionTime: TimeInterval = 0
    private var lastTrackingTime: TimeInterval = 0
    private var lastFrameLogTime: TimeInterval = 0
    private var modelRequest: VNCoreMLRequest?
    private var modelLoadError: String?
    private var tracker: VNTrackObjectRequest?
    private var trackedSubject: DetectedSubject?
    private var manualSelectionActive = false
    private var latestCandidates: [DetectedSubject] = []
    private let sequenceHandler = VNSequenceRequestHandler()
    var onResult: ((SceneAnalysisResult) -> Void)?

    var isEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return enabled
        }
        set {
            stateLock.lock()
            let changed = enabled != newValue
            enabled = newValue
            if newValue {
                pendingSelectionPoint = nil
                shouldResetTracking = true
            }
            stateLock.unlock()
            if changed {
                AppDiagnostics.shared.log("scan", newValue ? "Analyzer enabled · waiting for incoming video frames" : "Analyzer disabled")
            }
        }
    }

    func selectSubject(at point: CGPoint) {
        stateLock.lock()
        pendingSelectionPoint = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        stateLock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard isEnabled else { return }
        if now - lastFrameLogTime >= 5 {
            lastFrameLogTime = now
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                AppDiagnostics.shared.log("scan", "Video frames arriving · size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) · format=\(String(format: "0x%08x", CVPixelBufferGetPixelFormatType(pixelBuffer))) · connectionEnabled=\(connection.isEnabled)")
            } else {
                AppDiagnostics.shared.log("scan", "Video sample arrived without an image pixel buffer")
            }
        }
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        guard let imageBuffer else { return }
        if consumeTrackingReset() {
            lastDetectionTime = 0
            lastTrackingTime = 0
            lastFrameLogTime = 0
            tracker = nil
            trackedSubject = nil
            manualSelectionActive = false
            latestCandidates = []
        }
        let frameWidth = CVPixelBufferGetWidth(imageBuffer)
        let frameHeight = CVPixelBufferGetHeight(imageBuffer)
        let frameAspectRatio = CGFloat(frameWidth) / CGFloat(max(1, frameHeight))
        let selection = takePendingSelection()
        if selection != nil || now - lastDetectionTime >= 0.70 {
            lastDetectionTime = now
            detectSubjects(in: sampleBuffer, frameAspectRatio: frameAspectRatio, selectionPoint: selection)
        } else if tracker != nil, now - lastTrackingTime >= 0.10 {
            lastTrackingTime = now
            trackSubject(in: imageBuffer, frameAspectRatio: frameAspectRatio)
        }
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
            AppDiagnostics.shared.log("vision", "YOLOv3Tiny loaded · 80 on-device object classes · Core ML computeUnits=all · confidenceThreshold=0.16 · iouThreshold=0.55")
            return request
        } catch {
            modelLoadError = error.localizedDescription
            AppDiagnostics.shared.log("vision", "Object model load failed · \(error.localizedDescription)")
            return nil
        }
    }

    private func detectSubjects(in sampleBuffer: CMSampleBuffer, frameAspectRatio: CGFloat, selectionPoint: CGPoint? = nil) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var found: [DetectedSubject] = []
        var requestError: String?
        if let request = ensureModel() {
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
            do {
                try handler.perform([request])
                found = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation in
                    guard let label = observation.labels.first, label.confidence >= 0.12 else { return nil }
                    let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    guard box.width > 0.025, box.height > 0.025, box.width * box.height < 0.88 else { return nil }
                    return DetectedSubject(box: box, label: Self.displayName(label.identifier), confidence: label.confidence)
                }
            } catch {
                requestError = error.localizedDescription
                AppDiagnostics.shared.log("vision", "YOLO request failed · \(error.localizedDescription)")
            }
        } else {
            requestError = modelLoadError
        }

        if found.isEmpty, let fallback = saliencySubject(in: sampleBuffer) {
            found = [fallback]
            AppDiagnostics.shared.log("vision", "Object detector fallback · objectness saliency selected a region")
        }
        latestCandidates = found

        if let selectionPoint {
            manualSelectionActive = true
            lockSubject(at: selectionPoint, frameAspectRatio: frameAspectRatio)
        } else if trackedSubject == nil, let candidate = Self.bestCandidate(in: found) {
            trackedSubject = candidate
            startTracking(candidate)
            AppDiagnostics.shared.log("vision", "Automatic subject lock · label=\(candidate.label) · confidence=\(String(format: "%.2f", candidate.confidence)) · box=\(Self.boxText(candidate.box))")
        } else if let trackedSubject, let match = Self.match(for: trackedSubject, in: found) {
            self.trackedSubject = DetectedSubject(box: match.box, label: trackedSubject.label == "Subject" ? match.label : trackedSubject.label, confidence: match.confidence)
            startTracking(self.trackedSubject!)
            AppDiagnostics.shared.log("vision", "Detector refreshed tracked target · label=\(self.trackedSubject!.label) · confidence=\(String(format: "%.2f", match.confidence))")
        } else if let trackedSubject {
            if manualSelectionActive, tracker == nil {
                startTracking(trackedSubject)
                AppDiagnostics.shared.log("vision", "Detector found no replacement · restarted tracking the manually selected region")
            } else {
                AppDiagnostics.shared.log("vision", "Detector refreshed · kept current Vision tracker target")
            }
        } else if let requestError {
            publish(source: "error", frameAspectRatio: frameAspectRatio, errorDescription: requestError)
            return
        }

        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let detections = found.map { "\($0.label):\(String(format: "%.2f", $0.confidence))@\(Self.boxText($0.box))" }.joined(separator: ";")
        AppDiagnostics.shared.log("vision", "Object scan completed · ms=\(elapsed) · candidates=\(found.count) · [\(detections)] · selected=\(trackedSubject?.label ?? "none") · frame=\(Int(frameAspectRatio * 1_000))‰")
        publish(source: found.isEmpty ? "empty" : "yoloObject", frameAspectRatio: frameAspectRatio, errorDescription: requestError)
    }

    private func trackSubject(in pixelBuffer: CVPixelBuffer, frameAspectRatio: CGFloat) {
        guard let tracker else { return }
        do {
            try sequenceHandler.perform([tracker], on: pixelBuffer, orientation: .up)
            guard let next = (tracker.results as? [VNDetectedObjectObservation])?.first,
                  next.confidence >= 0.12,
                  next.boundingBox.width > 0.02,
                  next.boundingBox.height > 0.02 else {
                self.tracker = nil
                if manualSelectionActive {
                    AppDiagnostics.shared.log("vision", "Vision tracker lost the manually selected subject · retaining its last region for detector recovery")
                } else {
                    trackedSubject = nil
                    AppDiagnostics.shared.log("vision", "Vision tracker lost the subject · returning to object scan")
                }
                publish(source: "trackingLost", frameAspectRatio: frameAspectRatio)
                return
            }
            tracker.inputObservation = next
            if let current = trackedSubject {
                trackedSubject = DetectedSubject(box: next.boundingBox, label: current.label, confidence: next.confidence)
            }
            publish(source: "visionTracker", frameAspectRatio: frameAspectRatio)
        } catch {
            self.tracker = nil
            if manualSelectionActive {
                AppDiagnostics.shared.log("vision", "Vision tracking failed for the manually selected subject · retaining its last region · \(error.localizedDescription)")
            } else {
                trackedSubject = nil
                AppDiagnostics.shared.log("vision", "Vision tracking failed · \(error.localizedDescription)")
            }
            publish(source: "trackingError", frameAspectRatio: frameAspectRatio)
        }
    }

    private func lockSubject(at point: CGPoint, frameAspectRatio: CGFloat) {
        let candidate = latestCandidates.min { Self.distance($0.box, point) < Self.distance($1.box, point) }
        if let candidate, candidate.box.contains(point) || Self.distance(candidate.box, point) < 0.24 {
            trackedSubject = candidate
            AppDiagnostics.shared.log("guidance", "Tapped detected subject · label=\(candidate.label) · confidence=\(String(format: "%.2f", candidate.confidence)) · box=\(Self.boxText(candidate.box))")
        } else {
            let width: CGFloat = 0.22
            let height = min(0.22 * max(frameAspectRatio, 0.25), 0.30)
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            trackedSubject = DetectedSubject(box: rect, label: "Subject", confidence: 1)
            AppDiagnostics.shared.log("guidance", "Tapped region without an object label · tracking a custom subject region · box=\(Self.boxText(rect))")
        }
        if let trackedSubject { startTracking(trackedSubject) }
    }

    private func startTracking(_ subject: DetectedSubject) {
        let observation = VNDetectedObjectObservation(boundingBox: subject.box)
        if let tracker {
            // Re-seed the existing request. Creating a new Vision tracker on each
            // detector refresh exhausts Vision's per-type tracker limit.
            tracker.inputObservation = observation
            tracker.trackingLevel = .accurate
            AppDiagnostics.shared.log("vision", "Re-seeded existing Vision tracker · label=\(subject.label)")
        } else {
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            tracker = request
            AppDiagnostics.shared.log("vision", "Created Vision tracker · label=\(subject.label)")
        }
    }

    private func saliencySubject(in sampleBuffer: CMSampleBuffer) -> DetectedSubject? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.preferBackgroundProcessing = false
        do {
            try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up).perform([request])
            let candidate = request.results?.first?.salientObjects?
                .filter { $0.confidence > 0.08 && $0.boundingBox.width * $0.boundingBox.height < 0.85 }
                .max(by: { $0.confidence < $1.confidence })
            return candidate.map { DetectedSubject(box: $0.boundingBox, label: "Subject", confidence: $0.confidence) }
        } catch {
            AppDiagnostics.shared.log("vision", "Objectness fallback failed · \(error.localizedDescription)")
            return nil
        }
    }

    private func publish(source: String, frameAspectRatio: CGFloat, errorDescription: String? = nil) {
        onResult?(SceneAnalysisResult(
            box: trackedSubject?.box,
            label: trackedSubject?.label,
            source: source,
            errorDescription: errorDescription,
            frameAspectRatio: frameAspectRatio
        ))
    }

    private func takePendingSelection() -> CGPoint? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let point = pendingSelectionPoint
        pendingSelectionPoint = nil
        return point
    }

    private func consumeTrackingReset() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let shouldReset = shouldResetTracking
        shouldResetTracking = false
        return shouldReset
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

    private static func match(for current: DetectedSubject, in candidates: [DetectedSubject]) -> DetectedSubject? {
        candidates
            .filter { $0.label == current.label || $0.label == "Subject" }
            .map { ($0, intersectionOverUnion(current.box, $0.box)) }
            .filter { $0.1 > 0.08 || distance($0.0.box, CGPoint(x: current.box.midX, y: current.box.midY)) < 0.15 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let union = a.width * a.height + b.width * b.height - intersection.width * intersection.height
        return union > 0 ? intersection.width * intersection.height / union : 0
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
