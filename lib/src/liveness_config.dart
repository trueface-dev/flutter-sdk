import 'liveness_challenge.dart';

/// Which camera to use for the liveness session.
enum CameraLensDirection { front, back }

/// Configuration for a liveness session.
///
/// The defaults are tuned for a robust anti-spoofing flow: three randomly
/// ordered challenges drawn from the full pool, with the passive anti-spoof
/// model enabled.
class LivenessConfig {
  const LivenessConfig({
    this.challengePool = LivenessChallenge.values,
    this.numberOfChallenges = 3,
    this.randomizeOrder = true,
    this.challengeTimeout = const Duration(seconds: 12),
    this.imageQuality = 90,
    this.enablePassiveAntiSpoof = true,
    this.spoofScoreThreshold = 0.6,
    this.cameraLensDirection = CameraLensDirection.front,
  })  : assert(numberOfChallenges > 0),
        assert(imageQuality >= 1 && imageQuality <= 100),
        assert(spoofScoreThreshold >= 0 && spoofScoreThreshold <= 1);

  /// The pool of challenges to draw from.
  final List<LivenessChallenge> challengePool;

  /// How many challenges the user must complete. If greater than the pool
  /// size, challenges may repeat.
  final int numberOfChallenges;

  /// Whether the challenge order is randomized each session. Randomization is
  /// what makes a pre-recorded replay attack impractical, so keep this on in
  /// production.
  final bool randomizeOrder;

  /// Per-challenge time budget. If a challenge is not completed in time the
  /// session fails with [LivenessFailureReason.timeout].
  final Duration challengeTimeout;

  /// JPEG quality (1–100) of the returned face image.
  final int imageQuality;

  /// Whether to run the passive anti-spoof model on captured frames. This is
  /// the defence against a face shown on a screen (replay attack), which
  /// active challenges alone cannot fully catch.
  final bool enablePassiveAntiSpoof;

  /// Minimum passive "realness" score (0–1) required to pass. Frames scoring
  /// below this are treated as spoofs.
  final double spoofScoreThreshold;

  /// Which camera to open. Liveness almost always uses the front camera.
  final CameraLensDirection cameraLensDirection;

  Map<String, dynamic> toMap() => {
        'challengePool': challengePool.map((c) => c.wireName).toList(),
        'numberOfChallenges': numberOfChallenges,
        'randomizeOrder': randomizeOrder,
        'challengeTimeoutMs': challengeTimeout.inMilliseconds,
        'imageQuality': imageQuality,
        'enablePassiveAntiSpoof': enablePassiveAntiSpoof,
        'spoofScoreThreshold': spoofScoreThreshold,
        'cameraLensDirection': cameraLensDirection.name,
      };
}
