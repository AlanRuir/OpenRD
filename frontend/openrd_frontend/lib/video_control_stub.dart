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

  final bool ok;
  final bool vehicleOnline;
  final String videoState;
  final bool serviceActive;
  final String playUrl;
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
      playUrl: '',
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
