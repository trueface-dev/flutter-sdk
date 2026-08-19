## 0.2.6

* **Custom Color Themes**: Added `TrueFaceColors` for configuring UI colors (`primaryColor`, `backgroundColor`, `textColor`, `accentColor`, `cardBackgroundColor`) natively on both iOS and Android.
* **Upload Progress & Events**: Exposed `LivenessUploadingEvent` (0–100% upload progress) and `LivenessVerifyingEvent` in `LivenessEvent.fromMap` for real-time loading UI overlays.
* **Video Quality & Bitrate Optimization**: Optimized video recording resolution to SD (480p) and capped bitrate to 500 kbps, significantly reducing uploaded MP4 file sizes (~300–400 KB) and accelerating uploads.
* **SDK Version Alignment**: Updated underlying native dependencies to `dev.trueface:trueface-liveness:0.2.6` on Android and `0.2.6` on iOS.

## 0.1.0

* Initial release of the TrueFace Flutter liveness SDK.
* Add configurable randomized blink, smile, turn, and nod challenges.
* Add passive anti-spoof scoring and captured-face image results.
* Support hosted verification sessions with encrypted media uploads.
* Support Android with CameraX and ML Kit Face Detection.
* Support iOS 15 and later with AVFoundation and Apple Vision.
* Add Swift Package Manager support while retaining CocoaPods compatibility.
* Distribute the native iOS SDK through the public `ios-artifact` package.
