enum VideoHealthState { unknown, checking, online, offline }

class VideoHealthSnapshot {
  const VideoHealthSnapshot({
    required this.state,
    required this.checkedAt,
    required this.message,
  });

  final VideoHealthState state;
  final DateTime? checkedAt;
  final String message;
}

Future<VideoHealthSnapshot> checkVideoHealth(String url) async {
  return VideoHealthSnapshot(
    state: VideoHealthState.unknown,
    checkedAt: DateTime.now(),
    message: '当前平台不支持网页健康检查',
  );
}
