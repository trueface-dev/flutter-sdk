import 'liveness_challenge.dart';
import 'liveness_colors.dart';

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
    this.backendBaseUrl = 'https://api.trueface.dev',
    this.publicKey,
    this.verificationId,
    this.clientSecret,
    this.recordVideo = false,
    this.videoMaxDurationMs = 3000,
    this.showInstructions,
    this.colors = const TrueFaceColors(),
  }) : assert(numberOfChallenges > 0),
       assert(imageQuality >= 1 && imageQuality <= 100),
       assert(spoofScoreThreshold >= 0 && spoofScoreThreshold <= 1),
       assert(videoMaxDurationMs > 0);

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

  // --- Hosted-verification fields (Dart-only; not sent over the channel) ---

  /// Base URL of the liveness verification backend. When set (with
  /// [publicKey], [verificationId] and [clientSecret]) the SDK fetches the
  /// challenge sequence from the backend, records a video, uploads the media
  /// and polls for the verdict.
  final String? backendBaseUrl;

  /// Merchant publishable key (`pk_...`) used for session calls.
  final String? publicKey;

  /// The verification id returned by the merchant's server when it initiated
  /// the verification.
  final String? verificationId;

  /// The per-verification client secret returned alongside [verificationId].
  final String? clientSecret;

  /// Whether to record a short video during the challenges (uploaded to the
  /// backend for the digital-spoof check). Forced on when a backend is set.
  final bool recordVideo;

  /// Maximum recorded video duration in milliseconds.
  final int videoMaxDurationMs;

  /// Optional override to control whether pre-session instructions screen is shown.
  final bool? showInstructions;

  /// Customizable colors for the liveness UI elements.
  final TrueFaceColors colors;

  /// Whether a full hosted-verification session is configured.
  bool get hasBackend =>
      backendBaseUrl != null &&
      publicKey != null &&
      verificationId != null &&
      clientSecret != null;

  /// Builds the platform-view creation params. When [challengesOverride] is
  /// provided (the server-issued sequence) it replaces the local pool and
  /// randomization is disabled so the exact order is honored.
  Map<String, dynamic> toMap({
    List<LivenessChallenge>? challengesOverride,
    bool? recordVideoOverride,
    int? videoMaxDurationMsOverride,
  }) {
    final challenges = challengesOverride ?? challengePool;
    return {
      'challengePool': challenges.map((c) => c.wireName).toList(),
      'numberOfChallenges': challengesOverride != null
          ? challenges.length
          : numberOfChallenges,
      'randomizeOrder': challengesOverride != null ? false : randomizeOrder,
      'challengeTimeoutMs': challengeTimeout.inMilliseconds,
      'imageQuality': imageQuality,
      'enablePassiveAntiSpoof': enablePassiveAntiSpoof,
      'spoofScoreThreshold': spoofScoreThreshold,
      'cameraLensDirection': cameraLensDirection.name,
      'recordVideo': recordVideoOverride ?? recordVideo,
      'videoMaxDurationMs': videoMaxDurationMsOverride ?? videoMaxDurationMs,
      'showInstructions': showInstructions,
      'backendBaseUrl': backendBaseUrl,
      'publicKey': publicKey,
      'verificationId': verificationId,
      'clientSecret': clientSecret,
      'colors': colors.toMap(),
    };
  }
}
