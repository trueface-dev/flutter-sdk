import 'dart:async';
import 'dart:io';

import 'liveness_backend_client.dart';
import 'liveness_config.dart';
import 'liveness_event.dart';
import 'liveness_result.dart';

/// Drives the post-liveness backend flow: upload the captured image + video,
/// tell the backend to run the digital-spoof check, and poll for the verdict.
///
/// Returns an enriched [LivenessResult] carrying the backend
/// [VerificationStatus]. Never throws — network problems resolve to a failed
/// result with a [LivenessUploadFailedEvent] emitted first.
class LivenessVerificationOrchestrator {
  LivenessVerificationOrchestrator({
    required this.config,
    required this.onEvent,
    LivenessBackendClient? client,
  }) : _client = client ??
            LivenessBackendClient(
              baseUrl: config.backendBaseUrl!,
              publicKey: config.publicKey!,
              verificationId: config.verificationId!,
              clientSecret: config.clientSecret!,
            );

  final LivenessConfig config;
  final void Function(LivenessEvent event) onEvent;
  final LivenessBackendClient _client;

  static const _pollInterval = Duration(seconds: 2);
  static const _deadline = Duration(seconds: 60);

  bool _cancelled = false;

  Future<LivenessResult> run(LivenessResult nativeResult) async {
    try {
      onEvent(const LivenessUploadingEvent(progress: 0));
      final targets = await _client.requestUploadUrls();

      final image = nativeResult.image;
      if (image != null) {
        await _client.uploadFile(
            targets.imagePutUrl, image, targets.imageContentType);
      }
      onEvent(const LivenessUploadingEvent(progress: 0.5));

      final videoPath = nativeResult.videoPath;
      if (videoPath != null && File(videoPath).existsSync()) {
        final bytes = await File(videoPath).readAsBytes();
        await _client.uploadFile(
            targets.videoPutUrl, bytes, targets.videoContentType);
      }
      onEvent(const LivenessUploadingEvent(progress: 1.0));
      if (_cancelled) return _failed(nativeResult);

      await _client.notifyComplete(
        targets: targets,
        completedChallenges: nativeResult.completedChallenges,
        onDeviceSpoofScore: nativeResult.spoofScore,
      );

      await _deleteTemp(videoPath);

      onEvent(const LivenessVerifyingEvent());
      final status = await _pollForVerdict();
      return nativeResult.copyWith(
        success: status == VerificationStatus.approved,
        verificationStatus: status,
      );
    } catch (e) {
      onEvent(LivenessUploadFailedEvent(e.toString()));
      return _failed(nativeResult);
    } finally {
      _client.close();
    }
  }

  Future<VerificationStatus> _pollForVerdict() async {
    final start = DateTime.now();
    while (!_cancelled && DateTime.now().difference(start) < _deadline) {
      final status = VerificationStatus.fromWire(await _client.fetchStatus());
      if (status == VerificationStatus.approved ||
          status == VerificationStatus.rejected ||
          status == VerificationStatus.failed) {
        return status;
      }
      await Future<void>.delayed(_pollInterval);
    }
    // Timed out / cancelled — treat as pending; the webhook still delivers.
    return VerificationStatus.pending;
  }

  LivenessResult _failed(LivenessResult native) => native.copyWith(
        success: false,
        verificationStatus: VerificationStatus.failed,
        failureReason: LivenessFailureReason.unknown,
      );

  Future<void> _deleteTemp(String? path) async {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // best-effort cleanup
    }
  }

  void cancel() {
    _cancelled = true;
    _client.close();
  }
}
