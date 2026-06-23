class VideoPlaybackLatencySnapshot {
  const VideoPlaybackLatencySnapshot({
    required this.state,
    this.bufferLagMs,
    this.seekableLagMs,
    this.currentTimeSec,
    this.bufferedEndSec,
    this.seekableEndSec,
    this.updatedMs,
    this.error,
  });

  const VideoPlaybackLatencySnapshot.unknown()
    : state = 'unknown',
      bufferLagMs = null,
      seekableLagMs = null,
      currentTimeSec = null,
      bufferedEndSec = null,
      seekableEndSec = null,
      updatedMs = null,
      error = null;

  const VideoPlaybackLatencySnapshot.error(String message)
    : state = 'error',
      bufferLagMs = null,
      seekableLagMs = null,
      currentTimeSec = null,
      bufferedEndSec = null,
      seekableEndSec = null,
      updatedMs = null,
      error = message;

  factory VideoPlaybackLatencySnapshot.fromJson(Map<String, dynamic> json) {
    return VideoPlaybackLatencySnapshot(
      state: (json['state'] ?? 'unknown').toString(),
      bufferLagMs: _intValue(json['buffer_lag_ms']),
      seekableLagMs: _intValue(json['seekable_lag_ms']),
      currentTimeSec: _doubleValue(json['current_time_sec']),
      bufferedEndSec: _doubleValue(json['buffered_end_sec']),
      seekableEndSec: _doubleValue(json['seekable_end_sec']),
      updatedMs: _intValue(json['updated_ms']),
      error: (json['error'] ?? '').toString(),
    );
  }

  final String state;
  final int? bufferLagMs;
  final int? seekableLagMs;
  final double? currentTimeSec;
  final double? bufferedEndSec;
  final double? seekableEndSec;
  final int? updatedMs;
  final String? error;

  bool get hasData => state == 'playing' && latencyMs != null;

  int? get latencyMs {
    if (bufferLagMs != null && seekableLagMs != null) {
      return bufferLagMs! > seekableLagMs! ? bufferLagMs : seekableLagMs;
    }
    return bufferLagMs ?? seekableLagMs;
  }

  String get summaryLabel {
    if (latencyMs != null) {
      return '${latencyMs}ms';
    }
    return stateLabel;
  }

  String get stateLabel {
    switch (state) {
      case 'playing':
        return '播放中';
      case 'waiting':
        return '缓冲中';
      case 'paused':
        return '已暂停';
      case 'ready':
        return '就绪';
      case 'error':
        return '异常';
      case 'unsupported':
        return '不支持';
      default:
        return '未测量';
    }
  }

  String get detailLabel {
    final parts = <String>[
      'state=$state',
      if (bufferLagMs != null) 'buffer=${bufferLagMs}ms',
      if (seekableLagMs != null) 'seekable=${seekableLagMs}ms',
      if (currentTimeSec != null)
        'current=${currentTimeSec!.toStringAsFixed(2)}s',
      if (bufferedEndSec != null)
        'buffered_end=${bufferedEndSec!.toStringAsFixed(2)}s',
      if (seekableEndSec != null)
        'seekable_end=${seekableEndSec!.toStringAsFixed(2)}s',
      if (latencyMs != null) 'latency=${latencyMs}ms',
    ];
    if (error != null && error!.isNotEmpty) {
      parts.add('error=$error');
    }
    return parts.join(' ');
  }

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _doubleValue(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}
