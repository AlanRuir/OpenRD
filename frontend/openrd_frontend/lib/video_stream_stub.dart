import 'package:flutter/material.dart';

import 'video_stream_metrics.dart';

class OpenRdStreamView extends StatelessWidget {
  const OpenRdStreamView({
    super.key,
    required this.url,
    required this.readerUrl,
    required this.whepUrl,
    required this.muted,
    required this.placeholder,
    this.onReady,
    this.onError,
    this.onLatency,
  });

  final String url;
  final String readerUrl;
  final String whepUrl;
  final bool muted;
  final Widget placeholder;
  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
  final ValueChanged<VideoPlaybackLatencySnapshot>? onLatency;

  @override
  Widget build(BuildContext context) {
    return placeholder;
  }
}
