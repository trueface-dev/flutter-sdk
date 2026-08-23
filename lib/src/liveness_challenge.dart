/// The set of active challenges the user can be asked to perform.
///
/// Active challenges are the primary defence against presentation attacks:
/// a printed photo or a generic pre-recorded video cannot perform a
/// *randomly ordered* sequence of these actions on demand.
enum LivenessChallenge {
  /// Blink both eyes (eye-open probability drops then rises).
  blink,

  /// Smile (ML Kit smiling probability crosses a threshold).
  smile,

  /// Turn the head to the user's left (negative head Euler Y angle).
  turnLeft,

  /// Turn the head to the user's right (positive head Euler Y angle).
  turnRight,

  /// Open the mouth wide (mouth-aspect ratio crosses a threshold).
  ///
  /// The hosted backend draws this from its challenge pool, so it arrives on the
  /// wire for roughly three in five hosted sessions.
  openMouth,

  /// Nod / tilt the head down then up (head Euler X angle).
  ///
  /// Local mode only — the hosted backend does not issue this, because Apple
  /// Vision cannot detect it reliably on iOS.
  nod,

  /// A challenge this version of the SDK does not recognise.
  ///
  /// Reaching this means the server issued something newer than the client. It
  /// exists so an unknown wire value degrades to a generic prompt instead of
  /// throwing out of [LivenessEvent.fromMap].
  unknown;

  /// The challenges that may actually be requested — every member except
  /// [unknown], which exists only as a parse fallback and must never be sent to
  /// the native side as something to perform.
  static const List<LivenessChallenge> selectable = [
    LivenessChallenge.blink,
    LivenessChallenge.smile,
    LivenessChallenge.turnLeft,
    LivenessChallenge.turnRight,
    LivenessChallenge.openMouth,
    LivenessChallenge.nod,
  ];

  /// The wire value sent across the method channel to the native side.
  String get wireName => name;

  static LivenessChallenge fromWire(String value) =>
      LivenessChallenge.values.firstWhere(
        (c) => c.wireName == value,
        orElse: () => LivenessChallenge.unknown,
      );

  /// A human-readable instruction to show the user for this challenge.
  String get instruction => switch (this) {
    LivenessChallenge.blink => 'Blink your eyes',
    LivenessChallenge.smile => 'Smile',
    LivenessChallenge.turnLeft => 'Slowly turn your head left',
    LivenessChallenge.turnRight => 'Slowly turn your head right',
    LivenessChallenge.openMouth => 'Open your mouth wide',
    LivenessChallenge.nod => 'Nod your head',
    LivenessChallenge.unknown => 'Follow the on-screen instructions',
  };
}
