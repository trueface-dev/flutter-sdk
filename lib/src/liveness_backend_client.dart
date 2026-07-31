import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:encrypt/encrypt.dart' as enc;

import 'liveness_challenge.dart';

/// Session config returned by the backend `start` call: the server-issued
/// ordered challenge sequence plus capture parameters.
class SessionStart {
  SessionStart({
    required this.challenges,
    required this.videoMaxDurationMs,
    required this.challengeTimeoutMs,
  });

  final List<LivenessChallenge> challenges;
  final int videoMaxDurationMs;
  final int challengeTimeoutMs;
}

/// Presigned upload targets for the image and video.
class UploadTargets {
  UploadTargets({
    required this.imageKey,
    required this.imagePutUrl,
    required this.imageContentType,
    required this.videoKey,
    required this.videoPutUrl,
    required this.videoContentType,
  });

  final String imageKey;
  final String imagePutUrl;
  final String imageContentType;
  final String videoKey;
  final String videoPutUrl;
  final String videoContentType;
}

/// Thin HTTP client for the hosted-verification backend. All route/field names
/// live here so they can be adjusted without touching the rest of the SDK.
class LivenessBackendClient {
  LivenessBackendClient({
    required this.baseUrl,
    required this.publicKey,
    required this.verificationId,
    required this.clientSecret,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String publicKey;
  final String verificationId;
  final String clientSecret;
  final http.Client _client;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'x-public-key': publicKey,
    'x-client-secret': clientSecret,
  };

  Uri _u(String path) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}$path');

  String get _session => '/v1/sessions/$verificationId';

  Future<SessionStart> startSession() async {
    final res = await _client.post(_u('$_session/start'), headers: _headers);
    _ensureOk(res, 'start');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final challenges = (body['challenges'] as List)
        .map((c) => LivenessChallenge.fromWire(c as String))
        .toList();
    final capture = (body['capture'] as Map?) ?? const {};
    return SessionStart(
      challenges: challenges,
      videoMaxDurationMs:
          (capture['videoMaxDurationMs'] as num?)?.toInt() ?? 3000,
      challengeTimeoutMs:
          (capture['challengeTimeoutMs'] as num?)?.toInt() ?? 12000,
    );
  }

  Future<UploadTargets> requestUploadUrls() async {
    final res = await _client.post(
      _u('$_session/upload-urls'),
      headers: _headers,
    );
    _ensureOk(res, 'upload-urls');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final image = body['image'] as Map<String, dynamic>;
    final video = body['video'] as Map<String, dynamic>;
    return UploadTargets(
      imageKey: image['key'] as String,
      imagePutUrl: image['url'] as String,
      imageContentType: image['contentType'] as String? ?? 'image/jpeg',
      videoKey: video['key'] as String,
      videoPutUrl: video['url'] as String,
      videoContentType: video['contentType'] as String? ?? 'video/mp4',
    );
  }

  /// Uploads bytes to a presigned S3 PUT URL.
  Future<void> uploadFile(
    String putUrl,
    List<int> bytes,
    String contentType,
  ) async {
    final res = await _client.put(
      Uri.parse(putUrl),
      headers: {'content-type': contentType},
      body: bytes,
    );
    if (res.statusCode >= 300) {
      throw LivenessBackendException('upload failed (${res.statusCode})');
    }
  }

  Future<void> notifyComplete({
    required UploadTargets targets,
    required List<LivenessChallenge> completedChallenges,
    double? onDeviceSpoofScore,
  }) async {
    final payload = <String, dynamic>{
      'imageKey': targets.imageKey,
      'videoKey': targets.videoKey,
      'completedChallenges': completedChallenges
          .map((c) => c.wireName)
          .toList(),
      'clientSecret': clientSecret,
      'deviceOs': Platform.operatingSystem,
      'deviceModel': Platform.operatingSystemVersion,
    };
    if (onDeviceSpoofScore != null) {
      payload['onDeviceSpoofScore'] = onDeviceSpoofScore;
    }

    final key = enc.Key.fromUtf8(clientSecret.padRight(32).substring(0, 32));
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(jsonEncode(payload), iv: iv);

    final requestBody = <String, dynamic>{
      'encryptedData': encrypted.base64,
      'iv': iv.base64,
    };

    final res = await _client.post(
      _u('$_session/complete'),
      headers: _headers,
      body: jsonEncode(requestBody),
    );
    _ensureOk(res, 'complete');
  }

  /// Returns the current backend status string (e.g. `processing`, `approved`).
  Future<String> fetchStatus() async {
    final res = await _client.get(_u('$_session/status'), headers: _headers);
    _ensureOk(res, 'status');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['status'] as String;
  }

  void close() => _client.close();

  void _ensureOk(http.Response res, String op) {
    if (res.statusCode >= 300) {
      throw LivenessBackendException(
        '$op failed (${res.statusCode}): ${res.body}',
      );
    }
  }
}

class LivenessBackendException implements Exception {
  LivenessBackendException(this.message);
  final String message;
  @override
  String toString() => 'LivenessBackendException: $message';
}
