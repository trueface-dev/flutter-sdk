import 'package:flutter/material.dart';
import 'package:liveness_detection/liveness_detection.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liveness Demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LivenessResult? _lastResult;

  Future<void> _startLiveness() async {
    final result = await Navigator.of(context).push<LivenessResult>(
      MaterialPageRoute(builder: (_) => const LivenessScreen()),
    );
    if (result != null) setState(() => _lastResult = result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _lastResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Liveness Detection')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (result != null) ...[
                if (result.success && result.image != null)
                  Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          result.image!,
                          height: 260,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Live face verified ✓',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (result.spoofScore != null)
                        Text(
                          'Realness score: '
                          '${(result.spoofScore! * 100).toStringAsFixed(0)}%',
                        ),
                    ],
                  )
                else
                  Text(
                    'Failed: ${result.failureReason?.name ?? 'unknown'}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 24),
              ],
              FilledButton.icon(
                onPressed: _startLiveness,
                icon: const Icon(Icons.face_retouching_natural),
                label: const Text('Start liveness check'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A dimmed scrim with a transparent oval "hole" that shows the user where to
/// place their face.
class _FaceGuideOverlay extends StatelessWidget {
  const _FaceGuideOverlay();

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.infinite, painter: _FaceGuidePainter());
}

class _FaceGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Oval roughly centered, sized to a comfortable selfie framing.
    final ovalWidth = size.width * 0.72;
    final ovalHeight = ovalWidth * 1.35;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: ovalWidth,
      height: ovalHeight,
    );
    final oval = Path()..addOval(rect);

    // Dim everything outside the oval.
    final scrim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      oval,
    );
    canvas.drawPath(scrim, Paint()..color = Colors.black54);

    // Ring around the oval.
    canvas.drawPath(
      oval,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _FaceGuidePainter oldDelegate) => false;
}

/// Full-screen liveness capture screen driving [LivenessCameraView].
class LivenessScreen extends StatefulWidget {
  const LivenessScreen({super.key});

  @override
  State<LivenessScreen> createState() => _LivenessScreenState();
}

class _LivenessScreenState extends State<LivenessScreen> {
  String _instruction = 'Position your face in the circle';
  int _completed = 0;
  int _total = 0;
  String _debug =
      'waiting for camera frames…'; // TODO: remove after calibration

  void _onEvent(LivenessEvent event) {
    setState(() {
      switch (event) {
        case ChallengeStartedEvent(
          :final challenge,
          :final index,
          :final total,
        ):
          _instruction = challenge.instruction;
          _completed = index;
          _total = total;
        case ChallengeCompletedEvent(:final total):
          _completed += 1;
          _total = total;
          _instruction = 'Great!';
        case LivenessHintEvent(:final hint):
          _instruction = hint.message;
        case FaceLostEvent():
          _instruction = 'Keep your face in view';
        case FaceDetectedEvent():
          _instruction = 'Hold still';
        case UnknownLivenessEvent(:final type, :final raw):
          if (type == 'debug') _debug = raw?['message']?.toString() ?? '';
      }
    });
  }

  void _onResult(LivenessResult result) {
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            LivenessCameraView(
              config: const LivenessConfig(numberOfChallenges: 3),
              onEvent: _onEvent,
              onResult: _onResult,
            ),
            // Dimmed scrim with an oval cut-out to guide face placement.
            const Positioned.fill(
              child: IgnorePointer(child: _FaceGuideOverlay()),
            ),
            Positioned(
              top: 24,
              left: 24,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // TODO: remove after debugging — shows native frame/face counts.
            Positioned(
              top: 70,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                color: Colors.black54,
                child: Text(
                  'debug: $_debug',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 60,
              left: 24,
              right: 24,
              child: Column(
                children: [
                  if (_total > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: LinearProgressIndicator(
                        value: _total == 0 ? 0 : _completed / _total,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  Text(
                    _instruction,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
