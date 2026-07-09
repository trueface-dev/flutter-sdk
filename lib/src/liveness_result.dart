import 'dart:convert';
import 'dart:typed_data';

import 'liveness_challenge.dart';

/// Why a liveness session did not succeed.
enum LivenessFailureReason {
  /// A challenge was not completed within [LivenessConfig.challengeTimeout].
  timeout,

  /// The passive anti-spoof model flagged the face as fake (photo/screen).
  spoofDetected,

  /// The user or host app cancelled the session.
  cancelled,

  /// The face was lost for too long to continue.
  faceLost,

  /// Camera or permission failure.
  cameraError,

  /// An unexpected native error.
  unknown;

  static LivenessFailureReason fromWire(String value) =>
      LivenessFailureReason.values.firstWhere(
        (r) => r.name == value,
        orElse: () => LivenessFailureReason.unknown,
      );
}

/// The terminal outcome of a liveness session.
class LivenessResult {
  const LivenessResult({
    required this.success,
    this.image,
    this.imageWidth,
    this.imageHeight,
    this.spoofScore,
    this.failureReason,
    this.completedChallenges = const [],
  });

  /// Whether all challenges passed and the frame cleared the anti-spoof check.
  final bool success;

  /// The captured face image as JPEG bytes. Non-null only on [success].
  final Uint8List? image;
  final int? imageWidth;
  final int? imageHeight;

  /// Passive "realness" score in 0–1 for the captured frame (higher = more
  /// likely a real, present face). Null if passive anti-spoof was disabled.
  final double? spoofScore;

  /// Set when [success] is false.
  final LivenessFailureReason? failureReason;

  /// The challenges that were completed before the session ended.
  final List<LivenessChallenge> completedChallenges;

  factory LivenessResult.fromMap(Map<dynamic, dynamic> map) {
    final base64Image = map['imageBase64'] as String?;
    return LivenessResult(
      success: map['success'] as bool,
      image: base64Image != null ? base64Decode(base64Image) : null,
      imageWidth: map['imageWidth'] as int?,
      imageHeight: map['imageHeight'] as int?,
      spoofScore: (map['spoofScore'] as num?)?.toDouble(),
      failureReason: map['failureReason'] != null
          ? LivenessFailureReason.fromWire(map['failureReason'] as String)
          : null,
      completedChallenges: ((map['completed'] as List?) ?? [])
          .map((c) => LivenessChallenge.fromWire(c as String))
          .toList(),
    );
  }

  static LivenessResult cancelled() => const LivenessResult(
        success: false,
        failureReason: LivenessFailureReason.cancelled,
      );
}
