# trueface_liveness

A Flutter plugin for **camera-based face liveness detection**. The user is asked
to complete a short, **randomly ordered sequence of active challenges** (blink,
smile, turn head, nod) while a **passive anti-spoof** check runs in parallel.
On success the plugin returns the **captured face image**.

Native ML runs on-device with Google ML Kit Face Detection on Android and Apple
Vision on iOS. No network calls are made and no images leave the device.

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
| iOS | 15.0 | AVFoundation + Apple Vision |

## Installation

Add the plugin to your Flutter application:

```yaml
dependencies:
  trueface_liveness: ^0.2.6
```

Flutter 3.44 and later resolves the iOS implementation with Swift Package
Manager. The plugin depends on the public
[`trueface-dev/ios-artifact`](https://github.com/trueface-dev/ios-artifact)
package from version `0.2.6`, which distributes the native SDK as a binary
XCFramework. CocoaPods remains supported for Flutter projects that have not yet
migrated to Swift Package Manager.

## Permissions

- **Android**: `CAMERA` (requested at runtime).
- **iOS**: add `NSCameraUsageDescription` to your `Info.plist`.

## Usage

```dart
import 'package:trueface_liveness/trueface_liveness.dart';

// Show the full-screen camera view; it starts the session automatically.
LivenessCameraView(
  config: const LivenessConfig(
    numberOfChallenges: 3,
    enablePassiveAntiSpoof: true,
    spoofScoreThreshold: 0.6,
    // Hosted verification configuration:
    backendBaseUrl: 'https://api.trueface.dev',
    publicKey: 'pk_test_...',
    verificationId: 'ca93f062-7c46-43b1-be08-5136fc02e83b',
    clientSecret: 'vs_4f4PZPic2lkqlY8UEgFcQHLdrMdaY3VM',
  ),
  onEvent: (event) {
    // Drive your UI: instructions, hints, progress, uploading state
    switch (event) {
      case ChallengeStartedEvent(:final challenge):
        print(challenge.instruction);
      case LivenessUploadingEvent(:final progress):
        print('Uploading: ${(progress ?? 0) * 100}%');
      case LivenessVerifyingEvent():
        print('Verifying identity...');
      default:
        break;
    }
  },
  onResult: (result) {
    if (result.success) {
      final jpeg = result.image!;   // Uint8List — the captured face
      print('Liveness approved: ${result.verificationStatus}');
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
ring, hint badges, and error retries.

## Customizing UI Colors

Pass a custom `TrueFaceColors` instance into `LivenessConfig` to style native iOS and Android UI elements:

```dart
LivenessCameraView(
  config: const LivenessConfig(
    colors: TrueFaceColors(
      primaryColor: Color(0xFF10B981),        // Action buttons & active accents
      backgroundColor: Color(0xFFF0FDF4),     // Main view & card items background
      cardBackgroundColor: Colors.white,      // Sheet background
      textColor: Color(0xFF064E3B),           // Primary header & title text
      subtitleColor: Color(0xFF047857),       // Subtitle & secondary body text
      promptBackgroundColor: Colors.white,    // Challenge prompt pill background
      promptTextColor: Color(0xFF064E3B),     // Challenge prompt text color
      promptBorderColor: Color(0xFFA7F3D0),   // Prompt pill border color
      ovalBorderColor: Color(0xFF10B981),     // Oval target border color
      overlayScrimColor: Color(0x80F0FDF4),   // Camera overlay translucent scrim
    ),
  ),
  onResult: (result) {
    // Handle result
  },
);
```

## Configuration

`LivenessConfig` options:

| Property | Type | Default | Description |
|---|---|---|---|
| `challengePool` | `List<LivenessChallenge>` | `values` | Available challenge pool (blink, smile, turnLeft, turnRight, nod). |
| `numberOfChallenges` | `int` | `3` | Number of challenges presented to the user. |
| `randomizeOrder` | `bool` | `true` | Randomize challenge sequence per session. |
| `challengeTimeout` | `Duration` | `12s` | Time budget per challenge. |
| `imageQuality` | `int` | `90` | JPEG compression quality (1–100) of captured still. |
| `enablePassiveAntiSpoof` | `bool` | `true` | Enable passive motion/texture anti-spoof checks. |
| `spoofScoreThreshold` | `double` | `0.6` | Minimum realness score threshold (0.0 – 1.0). |
| `cameraLensDirection` | `CameraLensDirection` | `front` | Front or back camera selection. |
| `backendBaseUrl` | `String?` | `'https://api.trueface.dev'` | Base URL of hosted verification backend. |
| `publicKey` | `String?` | `null` | Merchant publishable key (`pk_...`). |
| `verificationId` | `String?` | `null` | Session ID returned from server session creation. |
| `clientSecret` | `String?` | `null` | Client secret (`vs_...`) returned alongside verification ID. |
| `recordVideo` | `bool` | `false` | Enable video recording during challenges (auto-enabled for backend). |
| `showInstructions` | `bool?` | `null` | Controls pre-session instruction card visibility. |
| `colors` | `TrueFaceColors` | `TrueFaceColors()` | Full color theme override for native views. |