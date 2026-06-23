class VideoLatencySnapshot {
  const VideoLatencySnapshot({
    required this.state,
    this.currentMs,
    this.avgMs,
    this.p50Ms,
    this.p95Ms,
    this.frameSeq,
    this.updatedMs,
    this.error,
  });

  const VideoLatencySnapshot.unknown()
    : state = 'unknown',
      currentMs = null,
      avgMs = null,
      p50Ms = null,
      p95Ms = null,
      frameSeq = null,
      updatedMs = null,
      error = null;

  final String state;
  final int? currentMs;
  final int? avgMs;
  final int? p50Ms;
  final int? p95Ms;
  final int? frameSeq;
  final int? updatedMs;
  final String? error;

  bool get hasData => state == 'ok' && currentMs != null;
  String get summaryLabel => hasData ? '${currentMs}ms' : '未接入';
  String get detailLabel => summaryLabel;
}

class VideoControlSnapshot {
  const VideoControlSnapshot({
    required this.ok,
    required this.vehicleOnline,
    required this.videoState,
    required this.serviceActive,
    required this.playUrl,
    required this.lastError,
    required this.leaseExpiresInSec,
    required this.videoLatency,
  });

  final bool ok;
  final bool vehicleOnline;
  final String videoState;
  final bool serviceActive;
  final String playUrl;
  final String lastError;
  final int leaseExpiresInSec;
  final VideoLatencySnapshot videoLatency;

  bool get running => videoState == 'running' || serviceActive;
}

class VideoControlClient {
  Future<VideoControlSnapshot> status({
    required String baseUrl,
    required String vehicleId,
  }) async {
    return const VideoControlSnapshot(
      ok: false,
      vehicleOnline: false,
      videoState: 'unsupported',
      serviceActive: false,
      playUrl: '',
      lastError: 'Video cloud control is only implemented for Web',
      leaseExpiresInSec: 0,
      videoLatency: VideoLatencySnapshot.unknown(),
    );
  }

  Future<VideoControlSnapshot> start({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    required int ttlSec,
  }) => status(baseUrl: baseUrl, vehicleId: vehicleId);

  Future<VideoControlSnapshot> renew({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    required int ttlSec,
  }) => status(baseUrl: baseUrl, vehicleId: vehicleId);

  Future<VideoControlSnapshot> stop({
    required String baseUrl,
    required String vehicleId,
    required String viewerId,
    bool force = false,
  }) => status(baseUrl: baseUrl, vehicleId: vehicleId);
}
