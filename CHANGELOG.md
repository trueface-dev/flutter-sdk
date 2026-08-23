## 0.3.0

* **Dynamic Luminance & Gating Checks**: Integrated dynamic camera frame luminance (luma) calculation to detect low-light/dark room environments as well as excessive glare/overexposure, preventing challenges from running until lighting conditions are optimal.
* **Native SDK Upgrades**: Upgraded underlying native dependencies to `dev.trueface:trueface-liveness:0.3.0` on Android and `v0.3.0` on iOS.
* **Video Encoding & Buffer Pipeline**: Realigned native Android and iOS media recording pipelines with clean surface encoding and synchronized frame acquisition.
* **Human-Friendly Gating & Challenge Hints**: Updated challenge and positioning hint prompts for natural user instructions.

## 0.2.9

* **Attentive-Only Video Recording**: Refactored the native recording sessions on both iOS and Android to only begin capturing/storing video frames once the user has become attentive and the first liveness challenge has officially started.
* **Native Dependency Upgrade**: Upgraded native underlying `TrueFaceLiveness` dependencies to version `v0.2.9` on iOS and `0.2.8` on Android.

## 0.2.8

* **Open-Eyes Upload Enforcement**: Implemented logic to ensure that the uploaded face frame has the user's eyes open (alert check). The system now tracks and scores the frame with the widest open eyes as a baseline fallback instead of blindly uploading the final frame of the camera feed (which could catch the user mid-blink or looking away).
* **Native Dependency Upgrade**: Upgraded native underlying `TrueFaceLiveness` dependencies to version `v0.2.8` on iOS and updated build configurations on Android.

## 0.2.7

* **iOS Framework Fix**: Updated the underlying `TrueFaceLiveness` iOS framework dependency to `v0.2.7`, which restores the missing `Info.plist` inside `TrueFaceLiveness.framework` to prevent compiler and bundling errors on iOS devices and simulators.
* **SPM & CocoaPods Target Alignment**: Refactored the internal podspec and SwiftPM `Package.swift` targets to download and resolve `v0.2.7` of the public iOS binary distribution.

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
