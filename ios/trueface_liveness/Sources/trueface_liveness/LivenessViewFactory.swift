import AVFoundation
import Flutter
import UIKit
import TrueFaceLiveness

/// Factory for the `com.trueface/trueface_liveness_view` platform view.
final class LivenessViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let config = LivenessNativeConfig(map: args as? [String: Any] ?? [:])
    return LivenessPlatformView(
      frame: frame,
      viewId: viewId,
      config: config,
      messenger: messenger
    )
  }
}

/// Creation params decoded from the Dart `LivenessConfig.toMap()`.
struct LivenessNativeConfig {
  let challengePool: [Challenge]
  let numberOfChallenges: Int
  let randomizeOrder: Bool
  let challengeTimeoutMs: Int
  let imageQuality: Int
  let enablePassiveAntiSpoof: Bool
  let spoofScoreThreshold: Double
  let cameraPosition: AVCaptureDevice.Position
  let recordVideo: Bool
  let videoMaxDurationMs: Int
  let showInstructions: Bool?
  let backendBaseUrl: String?
  let publicKey: String?
  let verificationId: String?
  let clientSecret: String?
  let colors: TrueFaceColors

  var hasBackend: Bool {
    guard let b = backendBaseUrl, !b.isEmpty,
          let p = publicKey, !p.isEmpty,
          let v = verificationId, !v.isEmpty,
          let c = clientSecret, !c.isEmpty else {
      return false
    }
    return true
  }

  init(map: [String: Any]) {
    let pool = (map["challengePool"] as? [Any])?
      .compactMap { ($0 as? String).flatMap(Challenge.init(rawValue:)) } ?? []
    // Apple Vision cannot reliably detect a nod: its pitch is too compressed
    // for a gentle nod, and a strong nod tilts the head enough that Vision
    // loses the face. So nod is excluded from the iOS challenge set (Android,
    // which uses ML Kit, keeps it). Falls back to the non-nod set if a caller
    // requested only nod.
    let requested = pool.isEmpty ? Challenge.allCases : pool
    let usable = requested.filter { $0 != .nod }
    challengePool = usable.isEmpty ? [.blink, .smile, .turnLeft, .turnRight, .openMouth] : usable
    numberOfChallenges = max(1, map["numberOfChallenges"] as? Int ?? 3)
    randomizeOrder = map["randomizeOrder"] as? Bool ?? true
    challengeTimeoutMs = map["challengeTimeoutMs"] as? Int ?? 12000
    imageQuality = min(100, max(1, map["imageQuality"] as? Int ?? 90))
    enablePassiveAntiSpoof = map["enablePassiveAntiSpoof"] as? Bool ?? true
    spoofScoreThreshold = map["spoofScoreThreshold"] as? Double ?? 0.6
    cameraPosition =
      (map["cameraLensDirection"] as? String) == "back" ? .back : .front
    recordVideo = map["recordVideo"] as? Bool ?? false
    videoMaxDurationMs = map["videoMaxDurationMs"] as? Int ?? 3000
    showInstructions = map["showInstructions"] as? Bool
    backendBaseUrl = (map["backendBaseUrl"] as? String) ?? "https://api.trueface.dev"
    publicKey = map["publicKey"] as? String
    verificationId = map["verificationId"] as? String
    clientSecret = map["clientSecret"] as? String

    if let cMap = map["colors"] as? [String: Any] {
      func parseColor(_ key: String, fallback: UIColor) -> UIColor {
        guard let argb = (cMap[key] as? NSNumber)?.int64Value else { return fallback }
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
      }
      colors = TrueFaceColors(
        primaryColor: parseColor("primaryColor", fallback: UIColor(red: 79/255, green: 70/255, blue: 229/255, alpha: 1)),
        backgroundColor: parseColor("backgroundColor", fallback: UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1)),
        cardBackgroundColor: parseColor("cardBackgroundColor", fallback: .white),
        textColor: parseColor("textColor", fallback: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)),
        subtitleColor: parseColor("subtitleColor", fallback: UIColor(red: 100/255, green: 116/255, blue: 139/255, alpha: 1)),
        promptBackgroundColor: parseColor("promptBackgroundColor", fallback: .white),
        promptTextColor: parseColor("promptTextColor", fallback: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)),
        promptBorderColor: parseColor("promptBorderColor", fallback: UIColor(red: 226/255, green: 232/255, blue: 240/255, alpha: 1)),
        ovalBorderColor: parseColor("ovalBorderColor", fallback: UIColor(red: 79/255, green: 70/255, blue: 229/255, alpha: 1)),
        overlayScrimColor: parseColor("overlayScrimColor", fallback: UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 0.5))
      )
    } else {
      colors = TrueFaceColors()
    }
  }

  /// Draws the session's challenge sequence from the pool. If more challenges
  /// are requested than the pool holds, the pool is re-drawn (challenges may
  /// repeat, but never twice in a row across a bag boundary if avoidable).
  func pickChallenges() -> [Challenge] {
    var sequence: [Challenge] = []
    var bag: [Challenge] = []
    while sequence.count < numberOfChallenges {
      if bag.isEmpty {
        bag = randomizeOrder ? challengePool.shuffled() : challengePool
        // Avoid an immediate repeat across bag refills when possible.
        if randomizeOrder, let last = sequence.last, bag.first == last, bag.count > 1 {
          bag.swapAt(0, 1)
        }
      }
      sequence.append(bag.removeFirst())
    }
    return sequence
  }
}
