import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'liveness_backend_client.dart';
import 'liveness_challenge.dart';
import 'liveness_config.dart';
import 'liveness_event.dart';
import 'liveness_result.dart';
import 'liveness_verification_orchestrator.dart';

/// The native camera preview that runs the full liveness flow.
///
/// The widget hosts a platform view (CameraX `PreviewView` on Android,
/// `AVCaptureVideoPreviewLayer` on iOS). All camera access, face tracking,
/// the challenge state machine and the anti-spoof checks run natively; this
/// widget forwards configuration down and surfaces [LivenessEvent]s / the
/// terminal [LivenessResult] back up.
///
/// When [LivenessConfig.hasBackend] is true the widget first fetches the
/// server-issued challenge sequence, records a video, then (on local success)
/// uploads the media and polls the backend for the digital-spoof verdict before
/// delivering the final result.
class LivenessCameraView extends StatefulWidget {
  const LivenessCameraView({
    super.key,
    this.config = const LivenessConfig(),
    required this.onResult,
    this.onEvent,
    this.onControllerReady,
  });

  final LivenessConfig config;

  /// Called exactly once when the session reaches a terminal state.
  final void Function(LivenessResult result) onResult;

  /// Called for every intermediate event (instructions, hints, progress).
  final void Function(LivenessEvent event)? onEvent;

  /// Gives the host a controller to drive the session (e.g. cancel/restart).
  final void Function(LivenessController controller)? onControllerReady;

  @override
  State<LivenessCameraView> createState() => _LivenessCameraViewState();
}

const String _viewType = 'com.trueface/trueface_liveness_view';

class _LivenessCameraViewState extends State<LivenessCameraView> {
  MethodChannel? _channel;
  LivenessController? _controller;
  LivenessVerificationOrchestrator? _orchestrator;
  bool _resultDelivered = false;

  // Backend session state.
  bool _sessionReady = false;
  List<LivenessChallenge>? _challenges;
  int _videoMaxMs = 3000;

  @override
  void initState() {
    super.initState();
    if (widget.config.hasBackend) {
      _initSession();
    } else {
      _sessionReady = true;
    }
  }

  Future<void> _initSession() async {
    final client = LivenessBackendClient(
      baseUrl: widget.config.backendBaseUrl!,
      publicKey: widget.config.publicKey!,
      verificationId: widget.config.verificationId!,
      clientSecret: widget.config.clientSecret!,
    );
    try {
      final session = await client.startSession();
      if (!mounted) return;
      setState(() {
        _challenges = session.challenges;
        _videoMaxMs = session.videoMaxDurationMs;
        _sessionReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      _deliver(
        LivenessResult(
          success: false,
          failureReason: LivenessFailureReason.unknown,
          verificationStatus: VerificationStatus.failed,
        ),
      );
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> get _creationParams => widget.config.hasBackend
      ? widget.config.toMap(
          challengesOverride: _challenges,
          recordVideoOverride: true,
          videoMaxDurationMsOverride: _videoMaxMs,
        )
      : widget.config.toMap();

  @override
  Widget build(BuildContext context) {
    if (!_sessionReady) {
      return const ColoredBox(
        color: Color(0xFF000000),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final creationParams = _creationParams;
    const codec = StandardMessageCodec();

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return PlatformViewLink(
          viewType: _viewType,
          surfaceFactory: (context, controller) => AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          ),
          onCreatePlatformView: (params) {
            final controller =
                PlatformViewsService.initSurfaceAndroidView(
                    id: params.id,
                    viewType: _viewType,
                    layoutDirection: TextDirection.ltr,
                    creationParams: creationParams,
                    creationParamsCodec: codec,
                    onFocus: () => params.onFocusChanged(true),
                  )
                  ..addOnPlatformViewCreatedListener(
                    params.onPlatformViewCreated,
                  )
                  ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
                  ..create();
            return controller;
          },
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: _viewType,
          creationParams: creationParams,
          creationParamsCodec: codec,
          onPlatformViewCreated: _onPlatformViewCreated,
        );
      default:
        return const _UnsupportedPlatform();
    }
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('com.trueface/trueface_liveness_$id');
    channel.setMethodCallHandler(_handleNativeCall);
    _channel = channel;
    _controller = LivenessController._(channel);
    widget.onControllerReady?.call(_controller!);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onEvent':
        widget.onEvent?.call(
          LivenessEvent.fromMap((call.arguments as Map).cast()),
        );
      case 'onResult':
        if (_resultDelivered) return;
        _resultDelivered = true;
        final native = LivenessResult.fromMap((call.arguments as Map).cast());
        // Hosted verification: on local success, upload + poll for the verdict.
        if (widget.config.hasBackend && native.success) {
          _orchestrator = LivenessVerificationOrchestrator(
            config: widget.config,
            onEvent: (e) => widget.onEvent?.call(e),
          );
          final finalResult = await _orchestrator!.run(native);
          if (mounted) widget.onResult(finalResult);
        } else {
          widget.onResult(native);
        }
    }
    return null;
  }

  void _deliver(LivenessResult result) {
    if (_resultDelivered) return;
    _resultDelivered = true;
    widget.onResult(result);
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _controller?._detach();
    _orchestrator?.cancel();
    super.dispose();
  }
}

/// Drives an in-progress liveness session from the host app.
class LivenessController {
  LivenessController._(this._channel);
  MethodChannel? _channel;

  /// Aborts the session. The view will still deliver a final cancelled
  /// [LivenessResult] through [LivenessCameraView.onResult].
  Future<void> cancel() => _channel?.invokeMethod('cancel') ?? Future.value();

  /// Restarts the challenge sequence from the beginning.
  Future<void> restart() => _channel?.invokeMethod('restart') ?? Future.value();

  void _detach() => _channel = null;
}

class _UnsupportedPlatform extends StatelessWidget {
  const _UnsupportedPlatform();
  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Liveness is only supported on Android and iOS'),
  );
}
