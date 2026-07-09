# liveness_detection

A Flutter plugin for **camera-based face liveness detection**. The user is asked
to complete a short, **randomly ordered sequence of active challenges** (blink,
smile, turn head, nod) while a **passive anti-spoof** check runs in parallel.
On success the plugin returns the **captured face image**.

Native ML runs on-device with Google ML Kit Face Detection — no network calls,
no images leave the device.

## Anti-spoofing

Presentation attacks are handled in two layers:

1. **Active, randomized challenges** — a printed photo or a generic
   pre-recorded/replayed video cannot perform an unpredictable, freshly ordered
   sequence of actions on demand. Order and selection are randomized per
   session.
2. **Passive anti-spoof** — a depth-from-motion (parallax) heuristic plus a
   texture/micro-motion check produce a *realness* score. A flat face shown on a
   **screen** or **paper held to the camera** moves as a rigid 2-D plane and
   fails the parallax test. The score must clear
   `LivenessConfig.spoofScoreThreshold` or the session fails with
   `LivenessFailureReason.spoofDetected`. There is a documented slot to drop in a
   TFLite/CoreML silent-face anti-spoof model for production-grade scoring.

> No liveness system is 100% spoof-proof. For high-assurance use cases, add a
> dedicated anti-spoof model in the provided extension point and tune the
> threshold for your risk profile.

## Platforms

| | Min version | Engine |
|---|---|---|
| Android | API 24 | CameraX + ML Kit Face Detection |
| iOS | 15.0 | AVFoundation + ML Kit Face Detection |

## Permissions

- **Android**: `CAMERA` (requested at runtime).
- **iOS**: add `NSCameraUsageDescription` to your `Info.plist`.

## Usage

```dart
import 'package:liveness_detection/liveness_detection.dart';

// Show the full-screen camera view; it starts the session automatically.
LivenessCameraView(
  config: const LivenessConfig(
    numberOfChallenges: 3,
    enablePassiveAntiSpoof: true,
    spoofScoreThreshold: 0.6,
  ),
  onEvent: (event) {
    // Drive your UI: instructions, hints, progress.
    if (event is ChallengeStartedEvent) {
      print(event.challenge.instruction);
    }
  },
  onResult: (result) {
    if (result.success) {
      final jpeg = result.image!;   // Uint8List — the captured face
      // upload / display / verify jpeg
    } else {
      print('Failed: ${result.failureReason}');
    }
  },
);
```

Cancel or restart programmatically via the controller:

```dart
LivenessCameraView(
  config: const LivenessConfig(),
  onControllerReady: (c) => _controller = c,
  onResult: (r) {},
);
// later:
_controller.cancel();
```

See [`example/`](example/) for a complete screen with instructions, a progress
bar, and the result preview.

## Configuration

`LivenessConfig` fields: `challengePool`, `numberOfChallenges`,
`randomizeOrder`, `challengeTimeout`, `imageQuality`, `enablePassiveAntiSpoof`,
`spoofScoreThreshold`, `cameraLensDirection`.
