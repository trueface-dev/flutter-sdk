# Liveness native contract

This is the cross-platform method-channel contract both native platforms
implement so the shared Dart code works unchanged. (The Dart layer is no longer
frozen — the hosted-verification work added networking + video config.)

## Platform view

- Register a `PlatformViewFactory` for view type: **`com.trueface/trueface_liveness_view`**.
- Creation params arrive as a `StandardMessageCodec` **Map** with keys:
  - `challengePool`: `List<String>` — pool of challenge wire-names to draw from.
  - `numberOfChallenges`: `int`.
  - `randomizeOrder`: `bool`.
  - `challengeTimeoutMs`: `int` — per-challenge timeout.
  - `imageQuality`: `int` (1–100) — JPEG quality of the returned image.
  - `enablePassiveAntiSpoof`: `bool`.
  - `spoofScoreThreshold`: `double` (0–1) — min realness score to pass.
  - `cameraLensDirection`: `String` — `"front"` or `"back"`.
  - `recordVideo`: `bool` — record a face-present clip during challenges.
  - `videoMaxDurationMs`: `int` — cap on the recorded clip (~3000).
- The view owns the camera. The session **starts automatically** when the view
  is created.
- When `recordVideo` is true, record only frames where a face is present, front
  camera, no audio, capped at `videoMaxDurationMs`; on success include the local
  file path as `videoPath` in the result map (success is NOT gated on the video).

## Per-view MethodChannel

Name: **`com.trueface/trueface_liveness_<viewId>`** where `<viewId>` is the integer id
the platform view factory receives for this instance.

### Dart → native (you handle these)
- `cancel` — abort; then emit a terminal cancelled result.
- `restart` — restart the challenge sequence from the beginning.

### native → Dart (you call `channel.invokeMethod(...)` on the platform/main thread)
- `onEvent` with argument = **event map** (below). Fire-and-forget.
- `onResult` with argument = **result map** (below). Emit **exactly once**.

## Challenge wire-names
`blink`, `smile`, `turnLeft`, `turnRight`, `nod`
(`turnLeft`/`turnRight` are from the **user's** perspective; the front camera
preview is mirrored, so calibrate the head-Euler-Y sign accordingly.)

## Event maps
- `{ "type": "faceDetected" }`
- `{ "type": "faceLost" }`
- `{ "type": "challengeStarted", "challenge": <wire>, "index": <int0based>, "total": <int> }`
- `{ "type": "challengeCompleted", "challenge": <wire>, "index": <int0based>, "total": <int> }`
- `{ "type": "hint", "code": <hint> }` where `<hint>` is one of:
  `moveCloser`, `moveBack`, `centerFace`, `holdStill`, `faceTooDark`,
  `multipleFaces`, `lookStraight`.

## Result map
```
{
  "success": <bool>,
  "imageBase64": <String?>,   // JPEG bytes, base64, present only on success
  "imageWidth": <int?>,
  "imageHeight": <int?>,
  "spoofScore": <double?>,    // 0..1 realness; null if passive disabled
  "failureReason": <String?>, // present only when success == false
  "completed": <List<String>>,// completed challenge wire-names
  "videoPath": <String?>      // recorded clip path, when recordVideo && success
}
```
`failureReason` ∈ `timeout`, `spoofDetected`, `cancelled`, `faceLost`,
`cameraError`, `unknown`.

## Detection logic (both platforms, keep behaviour identical)

Use **Google ML Kit Face Detection** with: accurate mode, classification
enabled (smile + eyes-open probabilities), landmarks enabled, tracking enabled.

Gating before/between challenges (emit `hint` events, do not advance until OK):
- exactly one face → else `multipleFaces`
- face box wide enough (≈25–60% of frame width) → `moveCloser` / `moveBack`
- face centered → `centerFace`
- adequate luminance → `faceTooDark`
- roughly frontal at rest (|eulerY| and |eulerX| small) → `lookStraight`

Challenge satisfaction:
- **blink**: both eye-open probs drop below 0.35 then both rise above 0.7.
- **smile**: smiling prob > 0.7.
- **turnLeft / turnRight**: |headEulerAngleY| exceeds ≈25° in the correct
  (mirror-corrected) direction, then returns toward center.
- **nod**: headEulerAngleX goes below ≈-15° (down) then back up.

Emit `challengeStarted` when a challenge begins, `challengeCompleted` when
satisfied, then move to the next. If a challenge exceeds `challengeTimeoutMs`,
finish with `failureReason: "timeout"`.

## Anti-spoofing (the key requirement — beat a photo/screen held to the camera)

1. **Primary**: the randomly ordered active-challenge sequence (already above)
   defeats printed photos and generic pre-recorded video.
2. **Passive** (`enablePassiveAntiSpoof == true`): compute a realness
   `spoofScore` in 0..1 and reject (`failureReason: "spoofDetected"`) if it is
   below `spoofScoreThreshold`. Implement a **pluggable `AntiSpoofDetector`**:
   - Default heuristic (must compile & run without extra model files):
     **depth-from-motion / parallax.** During the head-turn challenges, track
     nose-tip vs. ear/cheek landmark displacement. A real 3-D head produces
     *differential* (parallax) motion between near and far landmarks; a flat
     photo or screen produces near-uniform affine motion. Also fold in a
     high-frequency/moiré texture check on the face crop and reject frames with
     no inter-frame micro-motion. Map these cues to 0..1.
   - Leave a clearly documented slot to drop in a TFLite silent-face
     anti-spoof model (e.g. MiniVision) under assets for production-grade
     scoring; if such a model is present, use it in preference to the heuristic.

## Capture
On all challenges passed **and** anti-spoof cleared: grab a full-resolution
frame, crop generously around the face bounding box, encode JPEG at
`imageQuality`, base64-encode into `imageBase64` with `imageWidth`/`imageHeight`,
and emit the success result.
