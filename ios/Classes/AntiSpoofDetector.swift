import CoreGraphics
import Foundation

/// Per-frame input to the passive anti-spoof stage. All points are in the
/// analysis buffer's coordinate space; offsets are normalized by face width
/// before use, so the absolute space does not matter.
struct AntiSpoofSample {
  let timestamp: TimeInterval
  let faceBox: CGRect
  let eulerY: CGFloat
  let nose: CGPoint?
  let leftCheek: CGPoint?
  let rightCheek: CGPoint?
  /// Mean absolute Laplacian of a dense gray patch at the face center
  /// (high-frequency texture measure, ~0–50 on a 0–255 gray scale).
  let sharpness: CGFloat
  /// True while a turnLeft/turnRight challenge is the active challenge.
  let isTurnChallenge: Bool
}

/// Pluggable passive anti-spoofing stage. Implementations receive every
/// analyzed frame that contains exactly one face and must produce a final
/// "realness" score in 0..1 (1 = certainly a live, present face).
protocol AntiSpoofDetector: AnyObject {
  func reset()
  func ingest(_ sample: AntiSpoofSample)
  func finalScore() -> Double
}

enum AntiSpoofDetectors {
  /// Returns the best available detector.
  ///
  /// TODO(production): drop a silent-face anti-spoofing model (e.g. a
  /// MiniVision/Silent-Face-Anti-Spoofing model converted to CoreML or run
  /// via TensorFlowLiteSwift) into the plugin's `Assets/` folder, implement
  /// `ModelAntiSpoofDetector: AntiSpoofDetector` that scores the face crops
  /// ingested here, detect the model file at runtime and return it *instead
  /// of* the heuristic below. The heuristic is a dependency-free fallback and
  /// is NOT production-grade against video replay on a high-quality screen
  /// (replay is primarily defeated by the randomized challenge order).
  static func makeDefault() -> AntiSpoofDetector {
    HeuristicAntiSpoofDetector()
  }
}

/// Dependency-free heuristic based on depth-from-motion (parallax), inter-
/// frame micro-motion, and a coarse texture check.
///
/// Score mapping to 0..1:
/// - **Parallax** — a real 3-D head turning produces *differential* motion:
///   the nose (closest to the camera) shifts laterally relative to the
///   cheeks/face-box more than a flat photo or screen (which moves as a
///   near-uniform affine transform) ever can. We record the normalized
///   nose-vs-cheek-midpoint x-offset while the head is frontal (|yaw| < 8°),
///   then the maximum deviation from that baseline while a turn challenge is
///   active and |yaw| >= 18°. `parallax = clamp(maxDeviation / 0.06, 0, 1)`
///   (a real head at ~25° yaw measures roughly 0.05–0.15 of face width).
/// - **Micro-motion** — a live subject always jitters. We take the mean
///   frame-to-frame face-center displacement normalized by face width and map
///   it with `smoothstep(0.0003, 0.0025)`. A perfectly rigid image (photo on
///   a stand, frozen video) scores ~0 and additionally hard-caps the total
///   score at 0.2.
/// - **Texture** — mean absolute Laplacian over a dense gray patch of the
///   face; blurry prints/screens lose high-frequency skin detail. Mapped with
///   `smoothstep(1.0, 4.0)` (lenient so real faces in mediocre light pass).
///
/// Combination: with turn-challenge data
///   `score = 0.55*parallax + 0.30*motion + 0.15*texture`;
/// without any turn challenge in the session
///   `score = 0.70*motion + 0.30*texture`.
final class HeuristicAntiSpoofDetector: AntiSpoofDetector {
  private var frontalOffsetSum: CGFloat = 0
  private var frontalOffsetCount: Int = 0
  private var maxParallaxDelta: CGFloat = 0
  private var sawTurnData = false

  private var motionSamples: [CGFloat] = []
  private var lastCenter: CGPoint?
  private var lastFaceWidth: CGFloat?

  private var sharpnessSamples: [CGFloat] = []

  private static let maxSamples = 600

  func reset() {
    frontalOffsetSum = 0
    frontalOffsetCount = 0
    maxParallaxDelta = 0
    sawTurnData = false
    motionSamples.removeAll()
    lastCenter = nil
    lastFaceWidth = nil
    sharpnessSamples.removeAll()
  }

  func ingest(_ sample: AntiSpoofSample) {
    let box = sample.faceBox
    guard box.width > 1 else { return }

    // Micro-motion: normalized frame-to-frame displacement of the face center.
    let center = CGPoint(x: box.midX, y: box.midY)
    if let last = lastCenter, let width = lastFaceWidth, width > 1,
       motionSamples.count < Self.maxSamples {
      motionSamples.append(hypot(center.x - last.x, center.y - last.y) / width)
    }
    lastCenter = center
    lastFaceWidth = box.width

    if sharpnessSamples.count < Self.maxSamples {
      sharpnessSamples.append(sample.sharpness)
    }

    // Parallax: nose x-offset against the cheek midpoint (face-box center as
    // fallback when a cheek landmark is missing at strong yaw).
    guard let nose = sample.nose else { return }
    let referenceX: CGFloat
    if let left = sample.leftCheek, let right = sample.rightCheek {
      referenceX = (left.x + right.x) / 2
    } else {
      referenceX = box.midX
    }
    let offset = (nose.x - referenceX) / box.width

    if abs(sample.eulerY) < 8 {
      frontalOffsetSum += offset
      frontalOffsetCount += 1
    } else if sample.isTurnChallenge, abs(sample.eulerY) >= 18, frontalOffsetCount > 0 {
      sawTurnData = true
      let baseline = frontalOffsetSum / CGFloat(frontalOffsetCount)
      maxParallaxDelta = max(maxParallaxDelta, abs(offset - baseline))
    }
  }

  func finalScore() -> Double {
    let motionMean = motionSamples.isEmpty
      ? 0 : motionSamples.reduce(0, +) / CGFloat(motionSamples.count)
    let motion = smoothstep(motionMean, from: 0.0003, to: 0.0025)

    let sharpMedian = median(sharpnessSamples)
    let texture = smoothstep(sharpMedian, from: 1.0, to: 4.0)

    var score: CGFloat
    if sawTurnData {
      let parallax = min(max(maxParallaxDelta / 0.06, 0), 1)
      score = 0.55 * parallax + 0.30 * motion + 0.15 * texture
    } else {
      score = 0.70 * motion + 0.30 * texture
    }

    // No inter-frame micro-motion at all: reject as a rigid reproduction.
    if !motionSamples.isEmpty, motionMean < 0.0002 {
      score = min(score, 0.2)
    }
    return Double(min(max(score, 0), 1))
  }

  private func smoothstep(_ x: CGFloat, from low: CGFloat, to high: CGFloat) -> CGFloat {
    guard high > low else { return x >= high ? 1 : 0 }
    let t = min(max((x - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }
}
