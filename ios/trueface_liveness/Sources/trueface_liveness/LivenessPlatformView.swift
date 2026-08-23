import AVFoundation
import CommonCrypto
import CoreImage
import Flutter
import UIKit
import Vision
import TrueFaceLiveness

/// UIView whose backing layer is the capture preview layer.
private final class CameraPreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer.frame = bounds
  }
}

/// The platform view driving one liveness session.
///
/// ## Why Apple Vision (not ML Kit)
/// ML Kit's on-device face detector returns no results on some iOS versions
/// (notably iOS 26) even though its model resources ship correctly, so iOS
/// uses Apple's built-in `Vision` framework instead. Android keeps ML Kit.
/// Vision gives us the bounding box, yaw/pitch/roll and face landmarks; eye
/// openness and smile are derived geometrically from the landmarks (see
/// `Calibration`) to reproduce the probabilities the state machine expects.
///
/// ## Orientation / mirroring
/// The data-output buffer is rotated to upright portrait and, for the front
/// camera, mirrored to match the preview. Vision runs on that upright buffer
/// with `.up`. Turn/nod direction depends on the yaw/pitch sign after
/// mirroring; if a challenge triggers on the wrong side on-device, flip
/// `Calibration.yawSign` / `Calibration.pitchSign`.
final class LivenessPlatformView: NSObject, FlutterPlatformView,
  AVCaptureVideoDataOutputSampleBufferDelegate {

  /// Geometry → probability calibration. These are principled defaults; tune on
  /// a device if blink/smile/turn feel too eager or too strict.
  private enum Calibration {
    /// Flip if the user turning left is detected as turning right (or nod is
    /// inverted). Mirroring of the front buffer determines the sign.
    static let yawSign: CGFloat = 1
    static let pitchSign: CGFloat = -1
    /// Eye openness = (eye-region height / width). Below `earClosed` reads as
    /// shut, above `earOpen` as fully open; mapped linearly to 0…1.
    static let earClosed: CGFloat = 0.10
    static let earOpen: CGFloat = 0.28
    /// Smile, primary cue: mouth-corner lift (corners rising above the mouth
    /// centre line, normalized by mouth width), mapped 0…1.
    static let smileLiftNeutral: CGFloat = 0.015
    static let smileLiftFull: CGFloat = 0.055
    /// Smile, secondary cue: mouth width / inter-ocular distance, mapped 0…1.
    static let smileNeutral: CGFloat = 0.92
    static let smileFull: CGFloat = 1.06
  }

  private let previewView: CameraPreviewView
  private let channel: FlutterMethodChannel
  private let config: LivenessNativeConfig

  private let session = AVCaptureSession()
  private let videoQueue = DispatchQueue(label: "com.trueface.video")
  private let landmarksRequest = VNDetectFaceLandmarksRequest()
  private let antiSpoof: TrueFaceLiveness.AntiSpoofDetector

  // All mutable session state below is confined to `videoQueue`.
  private var machine: TrueFaceLiveness.LivenessStateMachine
  private var resultDelivered = false
  private var cameraConfigured = false
  private var lastCapturedJPEG: (data: Data, width: Int, height: Int)?
  private var bestAttentiveJPEG: (data: Data, width: Int, height: Int)?
  private var bestAttentiveScore: CGFloat = -1
  private var bestEyesOpenJPEG: (data: Data, width: Int, height: Int)?
  private var bestEyesOpenScore: CGFloat = -1
  private var lastDiagAt: TimeInterval = 0  // TODO: remove after calibration
  private var lastSmileDebug = ""  // TODO: remove after calibration
  private var pitchMin: CGFloat = 999  // TODO: remove after calibration
  private var pitchMax: CGFloat = -999  // TODO: remove after calibration
  private var aspectMin: CGFloat = 999  // TODO: remove after calibration
  private var aspectMax: CGFloat = -999  // TODO: remove after calibration

  // Video recording (hosted verification). Confined to `videoQueue`.
  private var assetWriter: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var recordingStarted = false
  private var recordingFinalized = false
  private var challengesBegan = false
  private var firstFramePTS: CMTime?
  private var videoURL: URL?

  private var dynamicFlashColors: [UIColor] = []
  private var dynamicFlashDurationMs: Int = 200
  private var lastLightingHintAt: TimeInterval = 0
  private var awaitingAttentiveFrame = false
  private var awaitingAttentiveDeadline: TimeInterval = 0
  private var cachedSpoofScore: Double?

  init(
    frame: CGRect,
    viewId: Int64,
    config: LivenessNativeConfig,
    messenger: FlutterBinaryMessenger
  ) {
    self.config = config
    previewView = CameraPreviewView(frame: frame)
    previewView.backgroundColor = .black
    previewView.previewLayer.videoGravity = .resizeAspectFill
    channel = FlutterMethodChannel(
      name: "com.trueface/trueface_liveness_\(viewId)",
      binaryMessenger: messenger
    )

    antiSpoof = TrueFaceLiveness.AntiSpoofDetectors.makeDefault()
    machine = TrueFaceLiveness.LivenessStateMachine(
      challenges: config.pickChallenges(),
      timeoutMs: config.challengeTimeoutMs
    )

    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "cancel":
        self.videoQueue.async { self.finish(failureReason: "cancelled") }
        result(nil)
      case "restart":
        self.videoQueue.async { self.restart() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    fetchBackendSessionConfig()
    requestCameraAccess()
  }

  private func fetchBackendSessionConfig() {
    guard config.hasBackend,
          let baseUrl = config.backendBaseUrl,
          let vId = config.verificationId,
          let pubKey = config.publicKey,
          let sec = config.clientSecret,
          let url = URL(string: "\(baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/sessions/\(vId)/start") else {
      return
    }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(pubKey, forHTTPHeaderField: "x-public-key")
    req.setValue(sec, forHTTPHeaderField: "x-client-secret")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["clientSecret": sec])

    URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
      guard let self = self, let data = data,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return
      }

      var newChallenges: [Challenge]?
      if let chArr = json["challenges"] as? [String] {
        let parsed = chArr.compactMap { Challenge(rawValue: $0) }.filter { $0 != .nod }
        if !parsed.isEmpty {
          newChallenges = parsed
        }
      }

      var flashColors: [UIColor] = []
      var durationMs = 200
      if let flashObj = json["flashConfig"] as? [String: Any],
         let enabled = flashObj["enabled"] as? Bool, enabled,
         let hexes = flashObj["colors"] as? [String] {
        durationMs = flashObj["durationMsPerColor"] as? Int ?? 200
        flashColors = hexes.compactMap { hex -> UIColor? in
          var cString: String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
          if cString.hasPrefix("#") { cString.remove(at: cString.startIndex) }
          guard cString.count == 6 else { return nil }
          var rgbValue: UInt64 = 0
          Scanner(string: cString).scanHexInt64(&rgbValue)
          return UIColor(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
          )
        }
      }

      self.videoQueue.async {
        if let newChallenges {
          self.machine = TrueFaceLiveness.LivenessStateMachine(
            challenges: newChallenges,
            timeoutMs: self.config.challengeTimeoutMs
          )
        }
        self.dynamicFlashColors = flashColors
        self.dynamicFlashDurationMs = durationMs
      }
    }.resume()
  }

  func view() -> UIView { previewView }

  deinit {
    channel.setMethodCallHandler(nil)
    let session = self.session
    videoQueue.async {
      if session.isRunning { session.stopRunning() }
    }
  }

  // MARK: - Permissions & camera setup

  private func requestCameraAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      videoQueue.async { self.startCamera() }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.videoQueue.async { self.startCamera() }
        } else {
          self.failLater(reason: "cameraError")
        }
      }
    default:
      failLater(reason: "cameraError")
    }
  }

  /// Emits a failure result after a short delay so the Dart side has time to
  /// attach its method-call handler right after view creation.
  private func failLater(reason: String) {
    videoQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.finish(failureReason: reason)
    }
  }

  /// Runs on `videoQueue`.
  private func startCamera() {
    if !cameraConfigured {
      do {
        try configureSession()
        cameraConfigured = true
      } catch {
        finish(failureReason: "cameraError")
        return
      }
    }
    if !session.isRunning { session.startRunning() }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.previewView.previewLayer.session = self.session
      if let connection = self.previewView.previewLayer.connection,
        connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    }
  }

  private enum CameraError: Error { case unavailable }

  private func configureSession() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .high

    guard
      let device = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: config.cameraPosition)
    else { throw CameraError.unavailable }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CameraError.unavailable }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(output) else { throw CameraError.unavailable }
    session.addOutput(output)

    if let connection = output.connection(with: .video) {
      applyPortraitRotation(to: connection)
      // Mirror the front-camera analysis buffer so it matches the preview.
      if config.cameraPosition == .front, connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
      }
    }
  }

  /// Rotates the delivered buffers to upright portrait so Vision (fed `.up`)
  /// and the downstream coordinate math see an upright face. On iOS 17+ the
  /// legacy `videoOrientation` is deprecated and can silently no-op on the
  /// data-output connection, so prefer `videoRotationAngle` there.
  private func applyPortraitRotation(to connection: AVCaptureConnection) {
    if #available(iOS 17.0, *) {
      let portraitAngle: CGFloat = 90
      if connection.isVideoRotationAngleSupported(portraitAngle) {
        connection.videoRotationAngle = portraitAngle
        return
      }
    }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = .portrait
    }
  }

  // MARK: - Frame processing (videoQueue)

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !resultDelivered, !machine.isFinished else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    let size = CGSize(width: width, height: height)
    let now = CACurrentMediaTime()

    let faces = detectFaces(pixelBuffer, size: size)

    // Append face-present frames to the recorded video (hosted verification).
    recordFrame(sampleBuffer, pixelBuffer, hasFace: !faces.isEmpty)

    // TODO: remove after calibration — live pose/openness readout.
    if now - lastDiagAt > 0.5 {
      lastDiagAt = now
      let msg: String
      if let f = faces.first {
        pitchMin = min(pitchMin, f.eulerX)
        pitchMax = max(pitchMax, f.eulerX)
        let aspect = f.box.height / max(f.box.width, 1)
        aspectMin = min(aspectMin, aspect)
        aspectMax = max(aspectMax, aspect)
        msg = String(
          format: "pitch=%.0f(%.0f/%.0f) asp=%.2f(%.2f/%.2f) smile=%.2f",
          f.eulerX, pitchMin, pitchMax, aspect, aspectMin, aspectMax, f.smiling ?? -1)
      } else {
        msg = "no face"
      }
      sendEvent(["type": "debug", "message": msg])
    }

    var luminance: CGFloat?
    if faces.count == 1 {
      let face = faces[0]
      let stats = grayStats(pixelBuffer: pixelBuffer, faceBox: face.box)
      luminance = stats?.luma

      let leftOpen = face.leftEyeOpen ?? 0.8
      let rightOpen = face.rightEyeOpen ?? 0.8
      let absY = abs(face.eulerY)
      let absX = abs(face.eulerX)

      if let encoded = encodeFaceCrop(pixelBuffer: pixelBuffer, faceBox: face.box) {
        lastCapturedJPEG = encoded

        let eyesScore = leftOpen + rightOpen
        if eyesScore > bestEyesOpenScore {
          bestEyesOpenScore = eyesScore
          bestEyesOpenJPEG = encoded
        }

        let deltaX = abs(face.box.midX - size.width * 0.5) / size.width
        let deltaY = abs(face.box.midY - size.height * 0.5) / size.height
        let isCentered = deltaX <= 0.18 && deltaY <= 0.20
        let centeringScore = (max(0, 1.0 - (deltaX / 0.18)) + max(0, 1.0 - (deltaY / 0.20))) * 10.0

        let minEye = min(leftOpen, rightOpen)
        let sharpness = stats?.sharpness ?? 0
        // Evaluate face attentiveness: both eyes open, strictly frontal (<= 10 deg), centered, sharp focus
        if minEye >= 0.22 && absY <= 10 && absX <= 10 && isCentered {
          let frontalScore = max(0, 10.0 - absY) + max(0, 10.0 - absX)
          let score = (eyesScore * 10.0) + frontalScore + centeringScore + (min(sharpness, 30.0) / 3.0)
          if score > bestAttentiveScore {
            bestAttentiveScore = score
            bestAttentiveJPEG = encoded
          }
        }
      }

      let current = machine.currentChallenge
      antiSpoof.ingest(
        TrueFaceLiveness.AntiSpoofSample(
          timestamp: now,
          faceBox: face.box,
          eulerY: face.eulerY,
          nose: face.nose,
          leftCheek: face.leftCheek,
          rightCheek: face.rightCheek,
          sharpness: stats?.sharpness ?? 0,
          isTurnChallenge: current == .turnLeft || current == .turnRight
        ))
    } else {
      let centerBox = CGRect(x: size.width * 0.25, y: size.height * 0.25, width: size.width * 0.50, height: size.height * 0.50)
      luminance = grayStats(pixelBuffer: pixelBuffer, faceBox: centerBox)?.luma
    }

    if let luma = luminance {
      if luma < 55.0 && now - lastLightingHintAt > 0.8 {
        lastLightingHintAt = now
        sendEvent(["type": "hint", "code": "faceTooDark"])
      } else if luma > 230.0 && now - lastLightingHintAt > 0.8 {
        lastLightingHintAt = now
        sendEvent(["type": "hint", "code": "faceTooBright"])
      }
    }

    if awaitingAttentiveFrame {
      if bestAttentiveJPEG != nil || now >= awaitingAttentiveDeadline {
        awaitingAttentiveFrame = false
        proceedToFlashAndFinalize(spoofScore: cachedSpoofScore)
      }
      return
    }

    let effects = machine.process(
      TrueFaceLiveness.FrameObservation(
        timestamp: now,
        imageSize: size,
        faces: faces,
        faceLuminance: luminance
      ))
    handle(effects)
  }

  // MARK: - Vision detection

  /// Runs Apple Vision on the upright buffer and maps each detected face into a
  /// `FaceObservation` with the same semantics ML Kit produced on Android
  /// (pixel-space top-left box, euler angles in degrees, 0…1 eye/smile).
  private func detectFaces(_ pixelBuffer: CVPixelBuffer, size: CGSize) -> [TrueFaceLiveness.FaceObservation] {
    let handler = VNImageRequestHandler(
      cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
    do {
      try handler.perform([landmarksRequest])
    } catch {
      return []
    }
    guard let results = landmarksRequest.results else { return [] }
    return results.map { observation in
      map(observation, size: size)
    }
  }

  private func map(_ obs: VNFaceObservation, size: CGSize) -> TrueFaceLiveness.FaceObservation {
    // Vision boundingBox: normalized, bottom-left origin → pixel, top-left.
    let bb = obs.boundingBox
    let box = CGRect(
      x: bb.minX * size.width,
      y: (1 - bb.maxY) * size.height,
      width: bb.width * size.width,
      height: bb.height * size.height)

    let eulerY = degrees(obs.yaw) * Calibration.yawSign
    let eulerX: CGFloat = {
      if #available(iOS 15.0, *) { return degrees(obs.pitch) * Calibration.pitchSign }
      return 0
    }()

    let lm = obs.landmarks
    let leftEye = points(lm?.leftEye, size)
    let rightEye = points(lm?.rightEye, size)
    let lips = points(lm?.outerLips, size)
    let noseP = points(lm?.nose, size)
    let contour = points(lm?.faceContour, size)

    let leftOpen = eyeOpenness(leftEye)
    let rightOpen = eyeOpenness(rightEye)
    let smile = smileScore(lips: lips, leftEye: leftEye, rightEye: rightEye)
    let mouthOpen = computeMouthOpen(face: obs)

    return TrueFaceLiveness.FaceObservation(
      box: box,
      eulerX: eulerX,
      eulerY: eulerY,
      leftEyeOpen: leftOpen,
      rightEyeOpen: rightOpen,
      smiling: smile,
      mouthOpen: mouthOpen,
      nose: centroid(noseP),
      leftCheek: contour.min(by: { $0.x < $1.x }),
      rightCheek: contour.max(by: { $0.x < $1.x })
    )
  }

  private func computeMouthOpen(face: VNFaceObservation) -> CGFloat {
    if let inner = face.landmarks?.innerLips?.normalizedPoints, inner.count >= 4 {
      let pTop = inner[inner.count / 4]
      let pBot = inner[(3 * inner.count) / 4]
      let innerH = hypot(pBot.x - pTop.x, pBot.y - pTop.y)
      let pLeft = inner[0]
      let pRight = inner[inner.count / 2]
      let innerW = hypot(pRight.x - pLeft.x, pRight.y - pLeft.y)
      return innerW > 0 ? (innerH / innerW) : 0.0
    } else if let outer = face.landmarks?.outerLips?.normalizedPoints, outer.count >= 4 {
      let pTop = outer[outer.count / 4]
      let pBot = outer[(3 * outer.count) / 4]
      let outerH = hypot(pBot.x - pTop.x, pBot.y - pTop.y)
      let pLeft = outer[0]
      let pRight = outer[outer.count / 2]
      let outerW = hypot(pRight.x - pLeft.x, pRight.y - pLeft.y)
      let ratio = outerW > 0 ? (outerH / outerW) : 0.0
      return max(0, ratio - 0.38)
    }
    return 0.0
  }

  private func degrees(_ radians: NSNumber?) -> CGFloat {
    guard let r = radians?.doubleValue else { return 0 }
    return CGFloat(r * 180 / .pi)
  }

  /// Region landmark points in top-left pixel coordinates.
  private func points(_ region: VNFaceLandmarkRegion2D?, _ size: CGSize) -> [CGPoint] {
    guard let region else { return [] }
    return region.pointsInImage(imageSize: size).map {
      CGPoint(x: $0.x, y: size.height - $0.y)
    }
  }

  private func centroid(_ pts: [CGPoint]) -> CGPoint? {
    guard !pts.isEmpty else { return nil }
    let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
  }

  /// Eye openness (0…1) from the aspect ratio of the eye-contour points.
  private func eyeOpenness(_ pts: [CGPoint]) -> CGFloat? {
    guard pts.count >= 3 else { return nil }
    let xs = pts.map { $0.x }, ys = pts.map { $0.y }
    let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
    guard w > 0 else { return nil }
    let ratio = h / w
    return clamp01((ratio - Calibration.earClosed) / (Calibration.earOpen - Calibration.earClosed))
  }

  /// Smile (0…1). Primary cue is mouth-corner lift (corners rising above the
  /// mouth centre line); secondary cue is mouth width vs inter-ocular distance.
  /// The two are combined with `max` so either a wide grin or a strong corner
  /// lift registers. Records raw values in `lastSmileDebug` for calibration.
  private func smileScore(lips: [CGPoint], leftEye: [CGPoint], rightEye: [CGPoint]) -> CGFloat? {
    guard lips.count >= 3, let le = centroid(leftEye), let re = centroid(rightEye)
    else { return nil }
    let leftCorner = lips.min(by: { $0.x < $1.x })!
    let rightCorner = lips.max(by: { $0.x < $1.x })!
    let mouthWidth = rightCorner.x - leftCorner.x
    let interocular = hypot(re.x - le.x, re.y - le.y)
    guard mouthWidth > 0, interocular > 0 else { return nil }

    // Corner lift: mouth centre y minus average corner y, over mouth width.
    // Top-left coords, so corners *above* the centre give a positive lift.
    let centreY = lips.map { $0.y }.reduce(0, +) / CGFloat(lips.count)
    let lift = (centreY - (leftCorner.y + rightCorner.y) / 2) / mouthWidth
    let widthRatio = mouthWidth / interocular

    let liftScore = clamp01(
      (lift - Calibration.smileLiftNeutral)
        / (Calibration.smileLiftFull - Calibration.smileLiftNeutral))
    let widthScore = clamp01(
      (widthRatio - Calibration.smileNeutral)
        / (Calibration.smileFull - Calibration.smileNeutral))

    lastSmileDebug = String(format: "lift=%.3f wr=%.2f", lift, widthRatio)
    return max(liftScore, widthScore)
  }

  private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

  /// Runs on `videoQueue`.
  private func handle(_ effects: [MachineEffect]) {
    for effect in effects {
      switch effect {
      case .event(let map):
        sendEvent(map)
      case .failure(let reason):
        finish(failureReason: reason)
      case .success:
        completeSuccessfully()
      }
    }
  }

  // MARK: - Terminal outcomes (videoQueue)

  private func completeSuccessfully() {
    guard !resultDelivered else { return }
    var spoofScore: Double?
    if config.enablePassiveAntiSpoof {
      let score = antiSpoof.finalScore()
      spoofScore = score
      if score < config.spoofScoreThreshold {
        finish(failureReason: "spoofDetected", spoofScore: score)
        return
      }
    }

    if bestAttentiveJPEG == nil {
      awaitingAttentiveFrame = true
      awaitingAttentiveDeadline = CACurrentMediaTime() + 1.8
      cachedSpoofScore = spoofScore
      sendEvent(["type": "instruction", "instruction": "Look straight at the camera and hold still"])
      return
    }

    proceedToFlashAndFinalize(spoofScore: spoofScore)
  }

  private func proceedToFlashAndFinalize(spoofScore: Double?) {
    let activeColors = !config.flashColors.isEmpty ? config.flashColors : dynamicFlashColors
    let activeDuration = !config.flashColors.isEmpty ? config.flashDurationMs : dynamicFlashDurationMs

    if !activeColors.isEmpty {
      DispatchQueue.main.async {
        self.runFlashChallenge(colors: activeColors, durationMs: activeDuration) {
          self.videoQueue.async {
            self.finalizeAndDeliver(spoofScore: spoofScore)
          }
        }
      }
    } else {
      finalizeAndDeliver(spoofScore: spoofScore)
    }
  }

  private func runFlashChallenge(colors: [UIColor], durationMs: Int, completion: @escaping () -> Void) {
    sendEvent(["type": "instruction", "instruction": "Hold steady — analyzing reflection..."])
    let targetView = previewView.window ?? previewView
    let overlay = UIView(frame: targetView.bounds)
    overlay.backgroundColor = .clear
    overlay.isUserInteractionEnabled = false
    targetView.addSubview(overlay)
    targetView.bringSubviewToFront(overlay)

    executeFlashStep(index: 0, colors: colors, durationMs: durationMs, overlay: overlay, targetView: targetView, completion: completion)
  }

  private func executeFlashStep(index: Int, colors: [UIColor], durationMs: Int, overlay: UIView, targetView: UIView, completion: @escaping () -> Void) {
    guard index < colors.count else {
      UIView.animate(withDuration: 0.12, animations: {
        overlay.backgroundColor = .clear
      }) { _ in
        overlay.removeFromSuperview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
          completion()
        }
      }
      return
    }

    let color = colors[index]
    let duration = Double(durationMs) / 1000.0

    UIView.animate(withDuration: 0.08, animations: {
      overlay.backgroundColor = color.withAlphaComponent(0.45)
    }) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
        self?.executeFlashStep(index: index + 1, colors: colors, durationMs: durationMs, overlay: overlay, targetView: targetView, completion: completion)
      }
    }
  }

  private func finalizeAndDeliver(spoofScore: Double?) {
    guard let encoded = bestAttentiveJPEG ?? bestEyesOpenJPEG ?? lastCapturedJPEG else {
      finish(failureReason: "unknown", spoofScore: spoofScore)
      return
    }
    resultDelivered = true
    var result: [String: Any] = [
      "success": true,
      "imageBase64": encoded.data.base64EncodedString(),
      "imageWidth": encoded.width,
      "imageHeight": encoded.height,
      "completed": machine.completed,
    ]
    if let spoofScore { result["spoofScore"] = spoofScore }
    // Finalize the recording (if any), then attach its path and deliver.
    finalizeRecording { [weak self] path in
      guard let self = self else { return }
      var out = result
      if let path { out["videoPath"] = path }
      if self.config.hasBackend {
        self.performNativeHostedVerification(resultMap: out, score: spoofScore, completed: self.machine.completed)
      } else {
        self.sendResult(out)
      }
    }
  }

  private func performNativeHostedVerification(
    resultMap: [String: Any], score: Double?, completed: [String]
  ) {
    guard let backendUrl = config.backendBaseUrl,
          let verificationId = config.verificationId,
          let publicKey = config.publicKey,
          let clientSecret = config.clientSecret else {
      sendResult(resultMap)
      return
    }

    let imageBase64 = resultMap["imageBase64"] as? String ?? ""
    let imageData = Data(base64Encoded: imageBase64)

    let videoPath = resultMap["videoPath"] as? String
    let videoData = (videoPath != nil) ? try? Data(contentsOf: URL(fileURLWithPath: videoPath!)) : nil

    TrueFaceLiveness.HostedVerificationClient.performVerification(
      backendUrl: backendUrl,
      verificationId: verificationId,
      publicKey: publicKey,
      clientSecret: clientSecret,
      imageData: imageData,
      videoData: videoData,
      completedChallenges: completed,
      onDeviceSpoofScore: score,
      onProgress: { [weak self] type, progress in
        self?.sendEvent(["type": type, "progress": progress])
      },
      onSuccess: { [weak self] status in
        guard let self = self else { return }
        var finalMap = resultMap
        finalMap["verificationStatus"] = status
        finalMap["success"] = (status == "approved" || status == "completed" || status == "processing")
        self.sendResult(finalMap)
      },
      onError: { [weak self] reason, message in
        guard let self = self else { return }
        var failMap: [String: Any] = [
          "success": false,
          "failureReason": reason,
          "completed": completed
        ]
        if let score { failMap["spoofScore"] = score }
        self.sendResult(failMap)
      }
    )
  }

  private func finish(failureReason: String, spoofScore: Double? = nil) {
    guard !resultDelivered else { return }
    resultDelivered = true
    discardRecording()
    var result: [String: Any] = [
      "success": false,
      "failureReason": failureReason,
      "completed": machine.completed,
    ]
    if let spoofScore { result["spoofScore"] = spoofScore }
    sendResult(result)
  }

  /// Runs on `videoQueue`. Restarts the whole sequence from scratch.
  private func restart() {
    machine = TrueFaceLiveness.LivenessStateMachine(
      challenges: config.pickChallenges(),
      timeoutMs: config.challengeTimeoutMs
    )
    antiSpoof.reset()
    lastCapturedJPEG = nil
    bestAttentiveJPEG = nil
    bestAttentiveScore = -1
    bestEyesOpenJPEG = nil
    bestEyesOpenScore = -1
    awaitingAttentiveFrame = false
    awaitingAttentiveDeadline = 0
    cachedSpoofScore = nil
    resultDelivered = false
    discardRecording()
    resetRecordingState()
    if cameraConfigured, !session.isRunning {
      session.startRunning()
    } else if !cameraConfigured {
      requestCameraAccess()
    }
  }

  // MARK: - Video recording (videoQueue)

  /// Feeds face-present frames to the asset writer once challenges begin,
  /// stopping at the configured duration cap. Runs on `videoQueue`.
  private func recordFrame(
    _ sampleBuffer: CMSampleBuffer, _ pixelBuffer: CVPixelBuffer, hasFace: Bool
  ) {
    guard config.recordVideo, !recordingFinalized else { return }
    if machine.currentChallenge != nil { challengesBegan = true }
    guard challengesBegan, hasFace else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if !recordingStarted {
      guard setupWriter(
        width: CVPixelBufferGetWidth(pixelBuffer),
        height: CVPixelBufferGetHeight(pixelBuffer)
      ) else { return }
      assetWriter?.startSession(atSourceTime: pts)
      firstFramePTS = pts
      recordingStarted = true
    }
    if let input = writerInput, input.isReadyForMoreMediaData {
      pixelAdaptor?.append(pixelBuffer, withPresentationTime: pts)
    }
    let maxDur = max(Double(config.videoMaxDurationMs) / 1000.0, 20.0)
    if let first = firstFramePTS,
      CMTimeGetSeconds(CMTimeSubtract(pts, first)) >= maxDur
    {
      finalizeRecording(completion: nil)  // cap reached; keep the file
    }
  }

  private func setupWriter(width: Int, height: Int) -> Bool {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("liveness_\(UUID().uuidString).mp4")
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
      return false
    }
    let maxDim: CGFloat = 640
    let scale = min(1.0, maxDim / CGFloat(max(width, height)))
    let targetW = Int((CGFloat(width) * scale).rounded()) & ~1
    let targetH = Int((CGFloat(height) * scale).rounded()) & ~1
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: targetW,
      AVVideoHeightKey: targetH,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 600_000,
        AVVideoExpectedSourceFrameRateKey: 15,
        AVVideoMaxKeyFrameIntervalKey: 15
      ]
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    assetWriter = writer
    writerInput = input
    pixelAdaptor = adaptor
    videoURL = url
    return true
  }

  /// Finishes writing and hands back the file path (nil if no/failed recording).
  private func finalizeRecording(completion: ((String?) -> Void)?) {
    guard recordingStarted else { completion?(nil); return }
    if recordingFinalized { completion?(videoURL?.path); return }
    recordingFinalized = true
    writerInput?.markAsFinished()
    let url = videoURL
    assetWriter?.finishWriting { [weak self] in
      let ok = self?.assetWriter?.status == .completed
      completion?(ok ? url?.path : nil)
    }
  }

  /// Finalizes (if needed) and deletes the temp file — used on failure/cancel.
  private func discardRecording() {
    guard recordingStarted, !recordingFinalized else {
      if let url = videoURL { try? FileManager.default.removeItem(at: url) }
      return
    }
    recordingFinalized = true
    writerInput?.markAsFinished()
    let url = videoURL
    assetWriter?.finishWriting {
      if let url { try? FileManager.default.removeItem(at: url) }
    }
  }

  private func resetRecordingState() {
    assetWriter = nil
    writerInput = nil
    pixelAdaptor = nil
    recordingStarted = false
    recordingFinalized = false
    challengesBegan = false
    firstFramePTS = nil
    videoURL = nil
  }

  // MARK: - Channel plumbing

  private func sendEvent(_ map: [String: Any]) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onEvent", arguments: map)
    }
  }

  private func sendResult(_ map: [String: Any]) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onResult", arguments: map)
    }
  }

  // MARK: - Pixel helpers

  /// Mean luma over the face box (coarse grid) plus a dense-patch sharpness
  /// measure at the face center. BGRA buffers only. Runs on `videoQueue`.
  private func grayStats(
    pixelBuffer: CVPixelBuffer, faceBox: CGRect
  ) -> (luma: CGFloat, sharpness: CGFloat)? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
    else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let box = faceBox.intersection(bounds)
    guard box.width > 8, box.height > 8 else { return nil }
    let bytes = base.assumingMemoryBound(to: UInt8.self)

    func gray(_ x: Int, _ y: Int) -> CGFloat {
      let cx = min(max(x, 0), width - 1)
      let cy = min(max(y, 0), height - 1)
      let p = cy * bytesPerRow + cx * 4
      return 0.114 * CGFloat(bytes[p]) + 0.587 * CGFloat(bytes[p + 1])
        + 0.299 * CGFloat(bytes[p + 2])
    }

    // Luma: 16x16 grid over the face box.
    let grid = 16
    var lumaSum: CGFloat = 0
    var saturatedCount = 0
    for gy in 0..<grid {
      for gx in 0..<grid {
        let x = Int(box.minX + box.width * (CGFloat(gx) + 0.5) / CGFloat(grid))
        let y = Int(box.minY + box.height * (CGFloat(gy) + 0.5) / CGFloat(grid))
        let g = gray(x, y)
        if g >= 250 { saturatedCount += 1 }
        lumaSum += g
      }
    }
    let totalSamples = CGFloat(grid * grid)
    let rawLuma = lumaSum / totalSamples
    // If >25% of facial pixels are saturated, report overexposure (>230)
    let luma = (CGFloat(saturatedCount) / totalSamples > 0.25) ? 245.0 : rawLuma

    // Sharpness: mean |Laplacian| over a dense 32x32 patch at the box center.
    let patch = 32
    let originX = Int(box.midX) - patch / 2
    let originY = Int(box.midY) - patch / 2
    var lapSum: CGFloat = 0
    var lapCount = 0
    for py in 1..<(patch - 1) {
      for px in 1..<(patch - 1) {
        let x = originX + px
        let y = originY + py
        let lap =
          4 * gray(x, y) - gray(x - 1, y) - gray(x + 1, y)
          - gray(x, y - 1) - gray(x, y + 1)
        lapSum += abs(lap)
        lapCount += 1
      }
    }
    let sharpness = lapCount > 0 ? lapSum / CGFloat(lapCount) : 0
    return (luma, sharpness)
  }

  /// Encodes the full upright selfie frame as JPEG at the configured quality.
  /// Runs on `videoQueue`.
  private func encodeFaceCrop(
    pixelBuffer: CVPixelBuffer, faceBox: CGRect
  ) -> (data: Data, width: Int, height: Int)? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    let image = UIImage(cgImage: cgImage)
    let quality = CGFloat(config.imageQuality) / 100.0
    guard let data = image.jpegData(compressionQuality: quality) else { return nil }
    return (data, cgImage.width, cgImage.height)
  }
}
