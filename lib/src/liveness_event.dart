import 'liveness_challenge.dart';

/// A non-terminal event emitted during a liveness session. Use these to drive
/// UI (instructions, progress, hints). The session outcome is delivered
/// separately as a [LivenessResult], not as an event.
sealed class LivenessEvent {
  const LivenessEvent();

  /// Parses an event map coming from the native side.
  factory LivenessEvent.fromMap(Map<dynamic, dynamic> map) {
    final type = map['type'] as String;
    return switch (type) {
      'faceDetected' => const FaceDetectedEvent(),
      'faceLost' => const FaceLostEvent(),
      'challengeStarted' => ChallengeStartedEvent(
        challenge: LivenessChallenge.fromWire(map['challenge'] as String),
        index: map['index'] as int,
        total: map['total'] as int,
      ),
      'challengeCompleted' => ChallengeCompletedEvent(
        challenge: LivenessChallenge.fromWire(map['challenge'] as String),
        index: map['index'] as int,
        total: map['total'] as int,
      ),
      'hint' => LivenessHintEvent(
        hint: LivenessHint.fromWire(map['code'] as String),
      ),
      'uploading' => LivenessUploadingEvent(
        progress: (map['progress'] as num?)?.toDouble(),
      ),
      'verifying' => const LivenessVerifyingEvent(),
      'uploadFailed' => LivenessUploadFailedEvent(
        map['message'] as String? ?? 'Upload failed',
      ),
      _ => UnknownLivenessEvent(type, map),
    };
  }
}

/// Emitted (by the Dart layer, not native) while uploading the captured media
/// to the verification backend. [progress] is 0..1 across image+video, or null.
class LivenessUploadingEvent extends LivenessEvent {
  const LivenessUploadingEvent({this.progress});
  final double? progress;
}

/// Emitted while polling the backend for the digital-spoof verdict.
class LivenessVerifyingEvent extends LivenessEvent {
  const LivenessVerifyingEvent();
}

/// Emitted when uploading to / polling the backend failed (network/timeout).
class LivenessUploadFailedEvent extends LivenessEvent {
  const LivenessUploadFailedEvent(this.message);
  final String message;
}

/// A live face entered the frame and tracking has started.
class FaceDetectedEvent extends LivenessEvent {
  const FaceDetectedEvent();
}

/// The tracked face left the frame; the current challenge is paused.
class FaceLostEvent extends LivenessEvent {
  const FaceLostEvent();
}

/// A new challenge has begun. [index] is 0-based, [total] is the session
/// length.
class ChallengeStartedEvent extends LivenessEvent {
  const ChallengeStartedEvent({
    required this.challenge,
    required this.index,
    required this.total,
  });
  final LivenessChallenge challenge;
  final int index;
  final int total;
}

/// A challenge was satisfied.
class ChallengeCompletedEvent extends LivenessEvent {
  const ChallengeCompletedEvent({
    required this.challenge,
    required this.index,
    required this.total,
  });
  final LivenessChallenge challenge;
  final int index;
  final int total;
}

/// Guidance for the user to correct their positioning/environment.
enum LivenessHint {
  moveCloser,
  moveBack,
  centerFace,
  holdStill,
  faceTooDark,
  multipleFaces,
  lookStraight;

  static LivenessHint fromWire(String value) =>
      LivenessHint.values.firstWhere((h) => h.name == value);

  String get message => switch (this) {
    LivenessHint.moveCloser => 'Move a little closer',
    LivenessHint.moveBack => 'Move a little back',
    LivenessHint.centerFace => 'Center your face in the frame',
    LivenessHint.holdStill => 'Hold still',
    LivenessHint.faceTooDark => 'Find better lighting',
    LivenessHint.multipleFaces => 'Only one face should be visible',
    LivenessHint.lookStraight => 'Look straight at the camera',
  };
}

/// A positioning/environment hint for the user.
class LivenessHintEvent extends LivenessEvent {
  const LivenessHintEvent({required this.hint});
  final LivenessHint hint;
}

/// An event type not recognized by this version of the plugin. Also used to
/// carry diagnostic `debug` events (see [raw]).
class UnknownLivenessEvent extends LivenessEvent {
  const UnknownLivenessEvent(this.type, [this.raw]);
  final String type;

  /// The full event map, when available (used by `debug` diagnostics).
  final Map<dynamic, dynamic>? raw;
}
