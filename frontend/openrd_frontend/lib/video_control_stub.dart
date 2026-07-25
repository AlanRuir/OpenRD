class VideoControlSnapshot {
  const VideoControlSnapshot({
    required this.ok,
    required this.vehicleOnline,
    required this.videoState,
    required this.serviceActive,
    required this.mode,
    required this.transport,
    required this.playUrl,
    required this.whipUrl,
    required this.whepUrl,
    required this.lastError,
    required this.leaseExpiresInSec,
  });

  final bool ok;
  final bool vehicleOnline;
  final String videoState;
  final bool serviceActive;
  final String mode;
  final String transport;
  final String playUrl;
  final String whipUrl;
  final String whepUrl;
  final String lastError;
  final int leaseExpiresInSec;

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
      mode: '',
      transport: '',
      playUrl: '',
      whipUrl: '',
      whepUrl: '',
      lastError: 'Video cloud control is only implemented for Web',
      leaseExpiresInSec: 0,
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
