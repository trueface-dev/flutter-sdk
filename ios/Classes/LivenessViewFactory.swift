import AVFoundation
import Flutter
import UIKit

/// Factory for the `com.liveness/liveness_view` platform view.
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

/// The active challenges, matching the Dart `LivenessChallenge` wire names.
enum Challenge: String, CaseIterable {
  case blink
  case smile
  case turnLeft
  case turnRight
  case nod
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

  init(map: [String: Any]) {
    let pool = (map["challengePool"] as? [Any])?
      .compactMap { ($0 as? String).flatMap(Challenge.init(rawValue:)) } ?? []
    challengePool = pool.isEmpty ? Challenge.allCases : pool
    numberOfChallenges = max(1, map["numberOfChallenges"] as? Int ?? 3)
    randomizeOrder = map["randomizeOrder"] as? Bool ?? true
    challengeTimeoutMs = map["challengeTimeoutMs"] as? Int ?? 12000
    imageQuality = min(100, max(1, map["imageQuality"] as? Int ?? 90))
    enablePassiveAntiSpoof = map["enablePassiveAntiSpoof"] as? Bool ?? true
    spoofScoreThreshold = map["spoofScoreThreshold"] as? Double ?? 0.6
    cameraPosition =
      (map["cameraLensDirection"] as? String) == "back" ? .back : .front
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
