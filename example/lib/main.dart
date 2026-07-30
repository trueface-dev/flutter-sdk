import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:trueface_liveness/trueface_liveness.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liveness Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
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
  bool _useHostedApi = true;
  bool _isLoading = false;
  String? _errorMessage;

  late final _backendUrlController = TextEditingController(
    text:'https://e66b-102-88-167-64.ngrok-free.app',// Platform.isAndroid ? 'http://10.0.2.2:3000' : 'http://localhost:3000',
  );
  final _publicKeyController = TextEditingController(
    text: 'pk_test_SFJdgYdzDh84SO2jKDwL6qTxQINZCOI6',
  );
  final _secretKeyController = TextEditingController(
    text: 'sk_test_FrrvGbScsWuxCsPc_BrRCFlRNXmb4Yfi',
  );
  late final _webhookUrlController = TextEditingController(
    text:'https://e66b-102-88-167-64.ngrok-free.app',// Platform.isAndroid ? 'http://10.0.2.2:5050/webhook' : 'http://localhost:5050/webhook',
  );
  final _userIdentifierController = TextEditingController(
    text: 'user_demo_123',
  );
  final _matchImageUrlController = TextEditingController();
  
  int _challengeCount = 3;

  @override
  void dispose() {
    _backendUrlController.dispose();
    _publicKeyController.dispose();
    _secretKeyController.dispose();
    _webhookUrlController.dispose();
    _userIdentifierController.dispose();
    _matchImageUrlController.dispose();
    super.dispose();
  }

  Future<void> _startLiveness() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      LivenessConfig config;

      if (_useHostedApi) {
        // Step 1: Create verification session dynamically
        final backendUrl = _backendUrlController.text.trim();
        final secretKey = _secretKeyController.text.trim();
        final publicKey = _publicKeyController.text.trim();
        final webhookUrl = _webhookUrlController.text.trim();
        final userIdentifier = _userIdentifierController.text.trim();
        final matchImageUrl = _matchImageUrlController.text.trim();

        if (backendUrl.isEmpty || secretKey.isEmpty || publicKey.isEmpty) {
          throw Exception('Backend URL, Secret Key, and Publishable Key are required for Hosted Mode.');
        }

        final sessionData = await _createVerificationSession(
          backendUrl: backendUrl,
          secretKey: secretKey,
          webhookUrl: webhookUrl,
          challengeCount: _challengeCount,
          userIdentifier: userIdentifier,
          matchImageUrl: matchImageUrl,
        );

        config = LivenessConfig(
          backendBaseUrl: backendUrl,
          publicKey: publicKey,
          verificationId: sessionData['id']!,
          clientSecret: sessionData['clientSecret']!,
          recordVideo: true,
        );
      } else {
        // Local on-device mode
        config = LivenessConfig(numberOfChallenges: _challengeCount);
      }

      setState(() => _isLoading = false);

      if (!mounted) return;

      final result = await Navigator.of(context).push<LivenessResult>(
        MaterialPageRoute(builder: (_) => LivenessScreen(config: config)),
      );

      if (result != null) {
        setState(() => _lastResult = result);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<Map<String, String>> _createVerificationSession({
    required String backendUrl,
    required String secretKey,
    required String webhookUrl,
    required int challengeCount,
    required String userIdentifier,
    required String matchImageUrl,
  }) async {
    final cleanUrl = backendUrl.replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$cleanUrl/v1/verifications');

    final response = await http.post(
      uri,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $secretKey',
      },
      body: jsonEncode({
        if (webhookUrl.isNotEmpty) 'webhookUrl': webhookUrl,
        if (userIdentifier.isNotEmpty) 'userIdentifier': userIdentifier,
        if (matchImageUrl.isNotEmpty) 'matchImageUrl': matchImageUrl,
        'challengeCount': challengeCount,
      }),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode >= 300) {
      throw Exception('Server error (${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return {
      'id': data['id'] as String,
      'clientSecret': data['clientSecret'] as String,
    };
  }

  @override
  Widget build(BuildContext context) {
    final result = _lastResult;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Liveness SDK Demo'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Mode selector
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.phonelink_setup),
                      label: Text('Local Mode'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.cloud),
                      label: Text('Hosted API Mode'),
                    ),
                  ],
                  selected: {_useHostedApi},
                  onSelectionChanged: (set) {
                    setState(() {
                      _useHostedApi = set.first;
                    });
                  },
                ),
                const SizedBox(height: 20),

                // Settings card
                Card(
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Configuration Settings',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                        const SizedBox(height: 16),
                        if (_useHostedApi) ...[
                          TextFormField(
                            controller: _backendUrlController,
                            decoration: const InputDecoration(
                              labelText: 'Backend base URL',
                              prefixIcon: Icon(Icons.link),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _publicKeyController,
                            decoration: const InputDecoration(
                              labelText: 'Publishable Key',
                              prefixIcon: Icon(Icons.vpn_key),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _secretKeyController,
                            decoration: const InputDecoration(
                              labelText: 'Merchant Secret Key',
                              prefixIcon: Icon(Icons.security),
                              border: OutlineInputBorder(),
                            ),
                            obscureText: true,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _webhookUrlController,
                            decoration: const InputDecoration(
                              labelText: 'Webhook URL',
                              prefixIcon: Icon(Icons.webhook),
                              border: OutlineInputBorder(),
                              helperText: 'Triggers when verification completes',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _userIdentifierController,
                            decoration: const InputDecoration(
                              labelText: 'User Identifier',
                              prefixIcon: Icon(Icons.person),
                              border: OutlineInputBorder(),
                              helperText: 'Unique ID to identify this user',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _matchImageUrlController,
                            decoration: const InputDecoration(
                              labelText: 'Match Image URL (AWS Rekognition)',
                              prefixIcon: Icon(Icons.compare),
                              border: OutlineInputBorder(),
                              helperText: 'Optional reference image URL to match face against',
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        DropdownButtonFormField<int>(
                          value: _challengeCount,
                          decoration: const InputDecoration(
                            labelText: 'Number of active challenges',
                            prefixIcon: Icon(Icons.psychology),
                            border: OutlineInputBorder(),
                          ),
                          items: List.generate(5, (index) => index + 1)
                              .map(
                                (c) => DropdownMenuItem(
                                  value: c,
                                  child: Text('$c challenge${c > 1 ? 's' : ''}'),
                                ),
                              )
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _challengeCount = val);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Error message
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Action button
                FilledButton.icon(
                  onPressed: _isLoading ? null : _startLiveness,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.face_retouching_natural),
                  label: Text(_useHostedApi
                      ? 'Create Session & Start Check'
                      : 'Start Local Liveness Check'),
                ),
                const SizedBox(height: 24),

                // Last result display
                if (result != null) ...[
                  Card(
                    color: result.success
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: result.success ? Colors.green : Colors.red,
                        width: 1,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                result.success
                                    ? Icons.check_circle
                                    : Icons.cancel,
                                color: result.success ? Colors.green : Colors.red,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                result.success
                                    ? 'Liveness Completed ✓'
                                    : 'Liveness Failed ✗',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: result.success ? Colors.green.shade900 : Colors.red.shade900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (result.success && result.image != null) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.memory(
                                result.image!,
                                height: 200,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          _buildDetailRow('Verification Status', result.verificationStatus?.name ?? 'n/a'),
                          if (result.spoofScore != null)
                            _buildDetailRow('Realness Score', '${(result.spoofScore! * 100).toStringAsFixed(1)}%'),
                          if (result.failureReason != null)
                            _buildDetailRow('Failure Reason', result.failureReason!.name),
                          if (result.imageUrl != null)
                            _buildDetailRow('Image Key', result.imageUrl!),
                          if (result.videoUrl != null)
                            _buildDetailRow('Video Key', result.videoUrl!),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black45,
                child: const Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Creating verification session...'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
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
  const LivenessScreen({super.key, required this.config});

  final LivenessConfig config;

  @override
  State<LivenessScreen> createState() => _LivenessScreenState();
}

class _LivenessScreenState extends State<LivenessScreen> {
  String _instruction = 'Position your face in the circle';
  int _completed = 0;
  int _total = 0;
  String _debug =
      'waiting for camera frames…'; // TODO: remove after calibration
  bool _verifying = false;

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
        case LivenessUploadingEvent(:final progress):
          _verifying = true;
          _instruction = progress == null
              ? 'Uploading…'
              : 'Uploading… ${(progress * 100).toStringAsFixed(0)}%';
        case LivenessVerifyingEvent():
          _verifying = true;
          _instruction = 'Verifying your identity…';
        case LivenessUploadFailedEvent(:final message):
          _instruction = 'Upload failed: $message';
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
              config: widget.config,
              onEvent: _onEvent,
              onResult: _onResult,
            ),
            // Dimmed scrim with an oval cut-out to guide face placement.
            const Positioned.fill(
              child: IgnorePointer(child: _FaceGuideOverlay()),
            ),
            // Backend verifying overlay.
            if (_verifying)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.7),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.white),
                        const SizedBox(height: 16),
                        Text(
                          _instruction,
                          style: const TextStyle(color: Colors.white, fontSize: 18),
                        ),
                      ],
                    ),
                  ),
                ),
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
