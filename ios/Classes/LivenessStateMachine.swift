import CoreGraphics
import Foundation

/// One detected face, in the (portrait, front-mirrored) buffer's coordinates.
struct FaceObservation {
  let box: CGRect
  /// Head pitch. Positive = tilted up, negative = tilted down (ML Kit).
  let eulerX: CGFloat
  /// Head yaw. The analysis buffer is mirrored for the front camera, so a
  /// *negative* value means the user turned toward the USER'S LEFT (see
  /// `LivenessPlatformView` for the calibration notes).
  let eulerY: CGFloat
  let leftEyeOpen: CGFloat?
  let rightEyeOpen: CGFloat?
  let smiling: CGFloat?
  let nose: CGPoint?
  let leftCheek: CGPoint?
  let rightCheek: CGPoint?
}

/// One analyzed camera frame.
struct FrameObservation {
  let timestamp: TimeInterval
  let imageSize: CGSize
  let faces: [FaceObservation]
  /// Mean luma (0–255) over the face box; nil when no single face.
  let faceLuminance: CGFloat?
}

/// What the state machine wants the host to do after a frame.
enum MachineEffect {
  /// Send `onEvent` with this map.
  case event([String: Any])
  /// All challenges passed: run anti-spoof + capture, then emit `onResult`.
  case success
  /// Terminal failure with this wire `failureReason`.
  case failure(String)
}

/// The gating + challenge state machine described in NATIVE_CONTRACT.md.
///
/// Pure logic — no camera, ML Kit or channel dependencies — driven by
/// `process(_:)` once per analyzed frame on the video queue.
final class LivenessStateMachine {

  // MARK: Tunables (keep in sync with the Android implementation)
  private enum Gate {
    static let minFaceWidthRatio: CGFloat = 0.25
    static let maxFaceWidthRatio: CGFloat = 0.60
    static let maxCenterOffsetXRatio: CGFloat = 0.15
    static let maxCenterOffsetYRatio: CGFloat = 0.18
    static let minLuminance: CGFloat = 60
    static let maxRestEuler: CGFloat = 12
    /// Gating must hold this long before a challenge starts.
    static let stableInterval: TimeInterval = 0.4
  }
  private enum Thresholds {
    static let eyeClosed: CGFloat = 0.35
    static let eyeOpen: CGFloat = 0.70
    static let smile: CGFloat = 0.70
    static let turnPeak: CGFloat = 25
    static let turnReturn: CGFloat = 10
    static let nodDown: CGFloat = -15
    static let nodUp: CGFloat = -5
  }
  private static let hintInterval: TimeInterval = 0.8
  private static let faceLostGrace: TimeInterval = 3.0
  private static let faceLostDebounce: TimeInterval = 0.4

  private enum Phase {
    case gating
    case challenge
    case done
  }

  private let challenges: [Challenge]
  private let timeout: TimeInterval

  private var phase: Phase = .gating
  private var index = 0
  private(set) var completed: [String] = []

  private var challengeStartedAt: TimeInterval = 0
  private var gateStableSince: TimeInterval?
  private var lastHintAt: TimeInterval = -1
  private var faceVisible = false
  private var lastFaceSeenAt: TimeInterval?
  private var faceLostEmitted = false

  // Per-challenge sub-state.
  private var blinkClosedSeen = false
  private var turnPeakSeen = false
  private var nodDownSeen = false

  init(challenges: [Challenge], timeoutMs: Int) {
    self.challenges = challenges
    self.timeout = TimeInterval(timeoutMs) / 1000.0
  }

  var currentChallenge: Challenge? {
    phase == .challenge && index < challenges.count ? challenges[index] : nil
  }

  var isFinished: Bool { phase == .done }

  func process(_ frame: FrameObservation) -> [MachineEffect] {
    guard phase != .done else { return [] }
    var effects: [MachineEffect] = []
    let now = frame.timestamp

    // Face presence bookkeeping + faceDetected/faceLost events.
    if !frame.faces.isEmpty {
      lastFaceSeenAt = now
      faceLostEmitted = false
      if !faceVisible {
        faceVisible = true
        effects.append(.event(["type": "faceDetected"]))
      }
    } else if faceVisible {
      if let seen = lastFaceSeenAt, now - seen > Self.faceLostDebounce, !faceLostEmitted {
        faceLostEmitted = true
        faceVisible = false
        effects.append(.event(["type": "faceLost"]))
      }
    }

    if phase == .challenge {
      // Per-challenge timeout keeps running even with no face in frame.
      if now - challengeStartedAt > timeout {
        return effects + fail("timeout")
      }
      // Losing the face for too long mid-challenge is unrecoverable.
      if frame.faces.isEmpty, let seen = lastFaceSeenAt,
         now - seen > Self.faceLostGrace {
        return effects + fail("faceLost")
      }
    }

    switch phase {
    case .gating:
      effects += gate(frame, now: now)
    case .challenge:
      guard frame.faces.count == 1, let face = frame.faces.first else { break }
      if isSatisfied(challenges[index], by: face) {
        let challenge = challenges[index]
        completed.append(challenge.rawValue)
        effects.append(.event([
          "type": "challengeCompleted",
          "challenge": challenge.rawValue,
          "index": index,
          "total": challenges.count,
        ]))
        index += 1
        if index >= challenges.count {
          phase = .done
          effects.append(.success)
        } else {
          phase = .gating
          gateStableSince = nil
        }
      }
    case .done:
      break
    }
    return effects
  }

  // MARK: - Gating

  private func gate(_ frame: FrameObservation, now: TimeInterval) -> [MachineEffect] {
    var effects: [MachineEffect] = []
    if frame.faces.count != 1 {
      gateStableSince = nil
      if frame.faces.count > 1 {
        effects += hint("multipleFaces", now: now)
      }
      return effects
    }
    let face = frame.faces[0]
    if let issue = gateIssue(face, frame) {
      gateStableSince = nil
      return hint(issue, now: now)
    }
    if gateStableSince == nil { gateStableSince = now }
    if now - gateStableSince! >= Gate.stableInterval {
      startChallenge(now: now, into: &effects)
    } else {
      effects += hint("holdStill", now: now)
    }
    return effects
  }

  private func gateIssue(_ face: FaceObservation, _ frame: FrameObservation) -> String? {
    let imgW = frame.imageSize.width
    let imgH = frame.imageSize.height
    guard imgW > 0, imgH > 0 else { return nil }
    let widthRatio = face.box.width / imgW
    if widthRatio < Gate.minFaceWidthRatio { return "moveCloser" }
    if widthRatio > Gate.maxFaceWidthRatio { return "moveBack" }
    if abs(face.box.midX - imgW / 2) > Gate.maxCenterOffsetXRatio * imgW
      || abs(face.box.midY - imgH / 2) > Gate.maxCenterOffsetYRatio * imgH {
      return "centerFace"
    }
    if let luma = frame.faceLuminance, luma < Gate.minLuminance { return "faceTooDark" }
    if abs(face.eulerY) > Gate.maxRestEuler || abs(face.eulerX) > Gate.maxRestEuler {
      return "lookStraight"
    }
    return nil
  }

  private func startChallenge(now: TimeInterval, into effects: inout [MachineEffect]) {
    blinkClosedSeen = false
    turnPeakSeen = false
    nodDownSeen = false
    phase = .challenge
    challengeStartedAt = now
    effects.append(.event([
      "type": "challengeStarted",
      "challenge": challenges[index].rawValue,
      "index": index,
      "total": challenges.count,
    ]))
  }

  // MARK: - Challenge satisfaction

  private func isSatisfied(_ challenge: Challenge, by face: FaceObservation) -> Bool {
    switch challenge {
    case .blink:
      guard let left = face.leftEyeOpen, let right = face.rightEyeOpen else { return false }
      if left < Thresholds.eyeClosed && right < Thresholds.eyeClosed {
        blinkClosedSeen = true
        return false
      }
      return blinkClosedSeen && left > Thresholds.eyeOpen && right > Thresholds.eyeOpen

    case .smile:
      return (face.smiling ?? 0) > Thresholds.smile

    case .turnLeft:
      // Mirrored front buffer: user's left == negative euler Y.
      if face.eulerY <= -Thresholds.turnPeak { turnPeakSeen = true; return false }
      return turnPeakSeen && abs(face.eulerY) < Thresholds.turnReturn

    case .turnRight:
      if face.eulerY >= Thresholds.turnPeak { turnPeakSeen = true; return false }
      return turnPeakSeen && abs(face.eulerY) < Thresholds.turnReturn

    case .nod:
      if face.eulerX <= Thresholds.nodDown { nodDownSeen = true; return false }
      return nodDownSeen && face.eulerX >= Thresholds.nodUp
    }
  }

  // MARK: - Helpers

  private func hint(_ code: String, now: TimeInterval) -> [MachineEffect] {
    guard lastHintAt < 0 || now - lastHintAt >= Self.hintInterval else { return [] }
    lastHintAt = now
    return [.event(["type": "hint", "code": code])]
  }

  private func fail(_ reason: String) -> [MachineEffect] {
    phase = .done
    return [.failure(reason)]
  }
}
