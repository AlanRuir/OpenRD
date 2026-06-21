// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;

class VideoControlSnapshot {
  const VideoControlSnapshot({
    required this.ok,
    required this.vehicleOnline,
    required this.videoState,
    required this.serviceActive,
    required this.playUrl,
    required this.lastError,
    required this.leaseExpiresInSec,
  });

  factory VideoControlSnapshot.fromJson(Map<String, dynamic> json) {
    return VideoControlSnapshot(
      ok: json['ok'] == true,
      vehicleOnline: json['vehicle_online'] == true,
      videoState: (json['video_state'] ?? json['state'] ?? 'unknown')
          .toString(),
      serviceActive: json['service_active'] == true,
      playUrl: (json['play_url'] ?? '').toString(),
      lastError: (json['last_error'] ?? json['error'] ?? '').toString(),
      leaseExpiresInSec: _intValue(json['lease_expires_in_sec']),
    );
  }

  final bool ok;
  final bool vehicleOnline;
  final String videoState;
  final bool serviceActive;
  final String playUrl;
  final String lastError;
  final int leaseExpiresInSec;

  bool get running => videoState == 'running' || serviceActive;
  bool get starting => videoState == 'starting';
  bool get stopped => videoState == 'stopped';
  bool get offline => videoState == 'offline' || !vehicleOnline;

  static int _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class VideoControlClient {
  Future<VideoControlSnapshot> status({
    required String baseUrl,
    required String vehicleId,
  }) {
    return _request(baseUrl: baseUrl, vehicleId: vehicleId, action: 'status');
  }

  Future<VideoControlSnapshot> start({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    required int ttlSec,
  }) {
    return _request(
      baseUrl: baseUrl,
      vehicleId: vehicleId,
      action: 'start',
      method: 'POST',
      body: <String, Object>{'viewer_id': viewerId, 'ttl_sec': ttlSec},
    );
  }

  Future<VideoControlSnapshot> renew({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    required int ttlSec,
  }) {
    return _request(
      baseUrl: baseUrl,
      vehicleId: vehicleId,
      action: 'renew',
      method: 'POST',
      body: <String, Object>{'viewer_id': viewerId, 'ttl_sec': ttlSec},
    );
  }

  Future<VideoControlSnapshot> stop({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    bool force = false,
  }) {
    return _request(
      baseUrl: baseUrl,
      vehicleId: vehicleId,
      action: 'stop',
      method: 'POST',
      body: <String, Object>{'viewer_id': viewerId, 'force': force},
    );
  }

  Future<VideoControlSnapshot> _request({
    required String baseUrl,
    required String vehicleId,
    required String action,
    String method = 'GET',
    Map<String, Object>? body,
  }) async {
    final endpoint = _endpoint(baseUrl, vehicleId, action);
    final response = await html.HttpRequest.request(
      endpoint,
      method: method,
      requestHeaders: const <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      sendData: body == null ? null : jsonEncode(body),
    ).timeout(const Duration(seconds: 12));

    final status = response.status ?? 0;
    final raw = response.responseText ?? '';
    final decoded = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('Invalid video control response');
    }

    final snapshot = VideoControlSnapshot.fromJson(decoded);
    if (status < 200 || status >= 300 || !snapshot.ok) {
      final message = snapshot.lastError.isNotEmpty
          ? snapshot.lastError
          : 'Video control HTTP $status';
      throw StateError(message);
    }
    return snapshot;
  }

  String _endpoint(String baseUrl, String vehicleId, String action) {
    final normalizedBase = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$normalizedBase/api/vehicles/$vehicleId/video/$action';
  }
}
