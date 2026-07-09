// Basic Flutter integration test for the liveness plugin.
//
// A full end-to-end liveness run needs a real camera and a human performing
// challenges, so it can't be asserted in a headless integration test. This
// smoke test verifies the plugin's public API and that the platform view
// mounts without throwing.
//
// https://flutter.dev/to/integration-testing

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:liveness_detection/liveness_detection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('config serializes to the native contract', () {
    final map = const LivenessConfig(numberOfChallenges: 2).toMap();
    expect(map['numberOfChallenges'], 2);
    expect(map['enablePassiveAntiSpoof'], true);
    expect(map['cameraLensDirection'], 'front');
    expect(map['challengePool'], contains('blink'));
  });

  test('result parses a native success map', () {
    final result = LivenessResult.fromMap({
      'success': true,
      'imageWidth': 480,
      'imageHeight': 640,
      'spoofScore': 0.9,
      'completed': ['blink', 'smile'],
    });
    expect(result.success, true);
    expect(result.completedChallenges.length, 2);
    expect(result.spoofScore, 0.9);
  });

  testWidgets('LivenessCameraView mounts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LivenessCameraView(
          config: const LivenessConfig(),
          onResult: (_) {},
        ),
      ),
    );
    expect(find.byType(LivenessCameraView), findsOneWidget);
  });
}
