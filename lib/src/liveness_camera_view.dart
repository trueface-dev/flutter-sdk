import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'liveness_config.dart';
import 'liveness_event.dart';
import 'liveness_result.dart';

/// The native camera preview that runs the full liveness flow.
///
/// The widget hosts a platform view (CameraX `PreviewView` on Android,
/// `AVCaptureVideoPreviewLayer` on iOS). All camera access, face tracking,
/// the challenge state machine and the anti-spoof checks run natively; this
/// widget only forwards configuration down and surfaces
/// [LivenessEvent]s / the terminal [LivenessResult] back up.
///
/// The session starts automatically once the view is created. Call
/// [LivenessController.cancel] (via [onControllerReady]) to abort early.
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

const String _viewType = 'com.liveness/liveness_view';

class _LivenessCameraViewState extends State<LivenessCameraView> {
  MethodChannel? _channel;
  LivenessController? _controller;
  bool _resultDelivered = false;

  @override
  Widget build(BuildContext context) {
    final creationParams = widget.config.toMap();
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
            final controller = PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: _viewType,
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams,
              creationParamsCodec: codec,
              onFocus: () => params.onFocusChanged(true),
            )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
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
    final channel = MethodChannel('com.liveness/liveness_$id');
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
        widget.onResult(
          LivenessResult.fromMap((call.arguments as Map).cast()),
        );
    }
    return null;
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _controller?._detach();
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
  Future<void> restart() =>
      _channel?.invokeMethod('restart') ?? Future.value();

  void _detach() => _channel = null;
}

class _UnsupportedPlatform extends StatelessWidget {
  const _UnsupportedPlatform();
  @override
  Widget build(BuildContext context) => const Center(
        child: Text('Liveness is only supported on Android and iOS'),
      );
}
