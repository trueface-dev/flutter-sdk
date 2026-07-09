import AVFoundation
import Flutter
import MLKitFaceDetection
import MLKitVision
import UIKit

/// UIView whose backing layer is the capture preview layer.
private final class CameraPreviewView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

/// The platform view driving one liveness session.
///
/// ## Orientation / mirroring calibration
/// The video data output connection is forced to `.portrait` and — for the
/// front camera — `isVideoMirrored = true`, so the analysis buffer matches
/// what the (automatically mirrored) preview layer shows. With a mirrored
/// buffer, ML Kit's head-euler-Y convention ("positive = face turns toward
/// the right side of the image") means the USER turning to the USER'S LEFT
/// yields a **negative** euler Y — exactly what the contract and the Dart
/// docs specify for `turnLeft`. For the back camera nothing is mirrored and
/// the same sign convention holds from the subject's perspective.
final class LivenessPlatformView: NSObject, FlutterPlatformView,
  AVCaptureVideoDataOutputSampleBufferDelegate {

  private let previewView: CameraPreviewView
  private let channel: FlutterMethodChannel
  private let config: LivenessNativeConfig

  private let session = AVCaptureSession()
  private let videoQueue = DispatchQueue(label: "com.liveness.video")
  private let detector: FaceDetector
  private let antiSpoof: AntiSpoofDetector

  // All mutable session state below is confined to `videoQueue`.
  private var machine: LivenessStateMachine
  private var resultDelivered = false
  private var cameraConfigured = false
  private var lastFacePixelBuffer: CVPixelBuffer?
  private var lastFaceBox: CGRect?
  private var lastDiagAt: TimeInterval = 0

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
      name: "com.liveness/liveness_\(viewId)",
      binaryMessenger: messenger
    )

    let options = FaceDetectorOptions()
    options.performanceMode = .accurate
    options.classificationMode = .all
    options.landmarkMode = .all
    options.isTrackingEnabled = true
    detector = FaceDetector.faceDetector(options: options)

    antiSpoof = AntiSpoofDetectors.makeDefault()
    machine = LivenessStateMachine(
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

    requestCameraAccess()
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
      // Mirror the front-camera analysis buffer to match the preview; see the
      // class docs for how this fixes the turnLeft/turnRight euler-Y sign.
      if config.cameraPosition == .front, connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
      }
    }
  }

  /// Rotates the delivered buffers to upright portrait so ML Kit (fed `.up`)
  /// and all the downstream coordinate math see an upright face. On iOS 17+
  /// the legacy `videoOrientation` is deprecated and can silently no-op on the
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

  /// Mean brightness (0–255) over a coarse grid of the whole BGRA frame. A
  /// real camera feed is never ~0; the simulator's absent camera reads black.
  /// TODO: remove after debugging.
  private func avgLuma(_ pb: CVPixelBuffer) -> Int {
    guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return -1 }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return -1 }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let grid = 20
    var sum = 0, n = 0
    for gy in 0..<grid {
      for gx in 0..<grid {
        let x = w * gx / grid, y = h * gy / grid
        let p = y * bpr + x * 4
        sum += (Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2])) / 3
        n += 1
      }
    }
    return n > 0 ? sum / n : -1
  }

  // MARK: - Frame processing (videoQueue)

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !resultDelivered, !machine.isFinished else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let visionImage = VisionImage(buffer: sampleBuffer)
    visionImage.orientation = .up  // buffer already rotated to portrait
    let mlFaces = (try? detector.results(in: visionImage)) ?? []

    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    let now = CACurrentMediaTime()

    // Throttled diagnostic: try every orientation on the same buffer and report
    // which one ML Kit actually finds a face in. `-1` means the detector threw.
    // TODO: remove after debugging.
    if now - lastDiagAt > 1.0 {
      lastDiagAt = now
      let probes: [(String, UIImage.Orientation)] = [
        ("up", .up), ("rt", .right), ("lf", .left),
        ("lm", .leftMirrored), ("rm", .rightMirrored),
      ]
      var report = "\(Int(width))x\(Int(height)) lum=\(avgLuma(pixelBuffer))"
      for (name, o) in probes {
        let vi = VisionImage(buffer: sampleBuffer)
        vi.orientation = o
        let count = (try? detector.results(in: vi))?.count ?? -1
        report += " \(name)=\(count)"
      }
      NSLog("[liveness] \(report)")
      sendEvent(["type": "debug", "message": report])
    }

    let faces = mlFaces.map { face -> FaceObservation in
      FaceObservation(
        box: face.frame,
        eulerX: face.hasHeadEulerAngleX ? face.headEulerAngleX : 0,
        eulerY: face.hasHeadEulerAngleY ? face.headEulerAngleY : 0,
        leftEyeOpen: face.hasLeftEyeOpenProbability ? face.leftEyeOpenProbability : nil,
        rightEyeOpen: face.hasRightEyeOpenProbability ? face.rightEyeOpenProbability : nil,
        smiling: face.hasSmilingProbability ? face.smilingProbability : nil,
        nose: face.landmark(ofType: .noseBase)?.position.cgPoint,
        leftCheek: face.landmark(ofType: .leftCheek)?.position.cgPoint
          ?? face.landmark(ofType: .leftEar)?.position.cgPoint,
        rightCheek: face.landmark(ofType: .rightCheek)?.position.cgPoint
          ?? face.landmark(ofType: .rightEar)?.position.cgPoint
      )
    }

    var luminance: CGFloat?
    if faces.count == 1 {
      let face = faces[0]
      let stats = grayStats(pixelBuffer: pixelBuffer, faceBox: face.box)
      luminance = stats?.luma
      lastFacePixelBuffer = pixelBuffer
      lastFaceBox = face.box

      let current = machine.currentChallenge
      antiSpoof.ingest(
        AntiSpoofSample(
          timestamp: now,
          faceBox: face.box,
          eulerY: face.eulerY,
          nose: face.nose,
          leftCheek: face.leftCheek,
          rightCheek: face.rightCheek,
          sharpness: stats?.sharpness ?? 0,
          isTurnChallenge: current == .turnLeft || current == .turnRight
        ))
    }

    let effects = machine.process(
      FrameObservation(
        timestamp: now,
        imageSize: CGSize(width: width, height: height),
        faces: faces,
        faceLuminance: luminance
      ))
    handle(effects)
  }

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
    guard
      let pixelBuffer = lastFacePixelBuffer,
      let faceBox = lastFaceBox,
      let encoded = encodeFaceCrop(pixelBuffer: pixelBuffer, faceBox: faceBox)
    else {
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
    sendResult(result)
  }

  private func finish(failureReason: String, spoofScore: Double? = nil) {
    guard !resultDelivered else { return }
    resultDelivered = true
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
    machine = LivenessStateMachine(
      challenges: config.pickChallenges(),
      timeoutMs: config.challengeTimeoutMs
    )
    antiSpoof.reset()
    lastFacePixelBuffer = nil
    lastFaceBox = nil
    resultDelivered = false
    if cameraConfigured, !session.isRunning {
      session.startRunning()
    } else if !cameraConfigured {
      requestCameraAccess()
    }
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
    for gy in 0..<grid {
      for gx in 0..<grid {
        let x = Int(box.minX + box.width * (CGFloat(gx) + 0.5) / CGFloat(grid))
        let y = Int(box.minY + box.height * (CGFloat(gy) + 0.5) / CGFloat(grid))
        lumaSum += gray(x, y)
      }
    }
    let luma = lumaSum / CGFloat(grid * grid)

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

  /// Crops generously around the face box, encodes JPEG at the configured
  /// quality. `faceBox` is top-left origin (ML Kit); CoreImage is bottom-left
  /// origin, hence the y-flip. Runs on `videoQueue`.
  private func encodeFaceCrop(
    pixelBuffer: CVPixelBuffer, faceBox: CGRect
  ) -> (data: Data, width: Int, height: Int)? {
    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    var crop = faceBox.insetBy(dx: -faceBox.width * 0.35, dy: -faceBox.height * 0.45)
    crop = crop.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard crop.width > 16, crop.height > 16 else { return nil }
    let ciCrop = CGRect(
      x: crop.minX, y: height - crop.maxY, width: crop.width, height: crop.height)

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciCrop) else { return nil }
    let image = UIImage(cgImage: cgImage)
    let quality = CGFloat(config.imageQuality) / 100.0
    guard let data = image.jpegData(compressionQuality: quality) else { return nil }
    return (data, cgImage.width, cgImage.height)
  }
}

extension VisionPoint {
  fileprivate var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}
