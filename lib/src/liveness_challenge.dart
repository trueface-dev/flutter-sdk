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

  /// Nod / tilt the head down then up (head Euler X angle).
  nod;

  /// The wire value sent across the method channel to the native side.
  String get wireName => name;

  static LivenessChallenge fromWire(String value) =>
      LivenessChallenge.values.firstWhere((c) => c.wireName == value);

  /// A human-readable instruction to show the user for this challenge.
  String get instruction => switch (this) {
        LivenessChallenge.blink => 'Blink your eyes',
        LivenessChallenge.smile => 'Smile',
        LivenessChallenge.turnLeft => 'Slowly turn your head left',
        LivenessChallenge.turnRight => 'Slowly turn your head right',
        LivenessChallenge.nod => 'Nod your head',
      };
}
