// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'video_stream_metrics.dart';

class OpenRdStreamView extends StatefulWidget {
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
  State<OpenRdStreamView> createState() => _OpenRdStreamViewState();
}

class _OpenRdStreamViewState extends State<OpenRdStreamView> {
  static const String _playerVersion = 'openrd-flv-player-v1';
  static const String _mpegtsCdn =
      'https://cdn.jsdelivr.net/npm/mpegts.js@1.7.3/dist/mpegts.min.js';
  static const String _messageSource = 'openrd-stream-player';
  static final Set<String> _registeredViewTypes = <String>{};
  static final Map<String, _StreamCallbacks> _callbacksByViewType =
      <String, _StreamCallbacks>{};

  late final String _viewType = _buildViewType(widget.url, widget.muted);
  StreamSubscription<html.MessageEvent>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _registerViewType(_viewType, url: widget.url, muted: widget.muted);
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
      onLatency: widget.onLatency,
    );
    _messageSubscription = html.window.onMessage.listen(_handlePlayerMessage);
  }

  @override
  void didUpdateWidget(covariant OpenRdStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
      onLatency: widget.onLatency,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _callbacksByViewType.remove(_viewType);
    super.dispose();
  }

  String _buildViewType(String url, bool muted) {
    final key = '$_playerVersion|$url|$muted';
    final sanitized = key.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final hash = key.hashCode.toUnsigned(32).toRadixString(16);
    return 'openrd_stream_${sanitized}_$hash';
  }

  void _handlePlayerMessage(html.MessageEvent event) {
    final data = event.data;
    if (data is! String) {
      return;
    }

    final Object? parsed;
    try {
      parsed = jsonDecode(data);
    } on FormatException {
      return;
    }

    if (parsed is! Map<String, dynamic>) {
      return;
    }
    if (parsed['source'] != _messageSource || parsed['viewType'] != _viewType) {
      return;
    }

    final callbacks = _callbacksByViewType[_viewType];
    switch (parsed['event']) {
      case 'ready':
        callbacks?.onReady?.call();
      case 'metrics':
        callbacks?.onLatency?.call(
          VideoPlaybackLatencySnapshot.fromJson(parsed),
        );
      case 'error':
        final message = parsed['message'];
        callbacks?.onError?.call(
          message is String && message.isNotEmpty
              ? message
              : 'Video stream failed',
        );
    }
  }

  void _registerViewType(
    String viewType, {
    required String url,
    required bool muted,
  }) {
    if (_registeredViewTypes.contains(viewType)) {
      return;
    }
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..srcdoc = _buildPlayerDocument(
          viewType: viewType,
          url: url,
          muted: muted,
        )
        ..style.border = '0'
        ..style.display = 'block'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'autoplay; fullscreen; picture-in-picture'
        ..setAttribute('scrolling', 'no');

      iframe.onError.listen((_) {
        _callbacksByViewType[viewType]?.onError?.call('Video stream failed');
      });

      return iframe;
    });
  }

  String _buildPlayerDocument({
    required String viewType,
    required String url,
    required bool muted,
  }) {
    final escapedUrl = _escapeJs(url);
    final escapedViewType = _escapeJs(viewType);
    final mutedLiteral = muted ? 'true' : 'false';

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
html, body {
  margin: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  background: #000;
}
body {
  display: flex;
  align-items: center;
  justify-content: center;
}
#video {
  display: block;
  width: min(100vw, calc(100vh * 16 / 9));
  height: auto;
  max-height: 100vh;
  aspect-ratio: 16 / 9;
  background: #000;
}
#message {
  position: fixed;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
  box-sizing: border-box;
  color: white;
  font: 600 14px Arial, sans-serif;
  text-align: center;
  pointer-events: none;
  text-shadow: 0 0 5px black;
}
</style>
<script defer src="$_mpegtsCdn"></script>
</head>
<body>
<!-- $_playerVersion -->
<video id="video" autoplay playsinline disablepictureinpicture disableremoteplayback></video>
<div id="message">Connecting...</div>
<script>
window.addEventListener('load', () => {
  const video = document.getElementById('video');
  const message = document.getElementById('message');
  let player = null;
  let readySent = false;
  let errorSent = false;
  let metricsTimer = null;

  const setMessage = (text) => {
    message.textContent = text;
    message.style.display = text ? 'flex' : 'none';
  };

  const notify = (event, payload = {}) => {
    const body = payload && typeof payload === 'object'
      ? payload
      : { message: String(payload || '') };
    window.parent.postMessage(JSON.stringify({
      source: '$_messageSource',
      viewType: '$escapedViewType',
      event,
      ...body,
    }), '*');
  };

  const notifyReady = () => {
    if (readySent) {
      return;
    }
    readySent = true;
    setMessage('');
    notify('ready');
  };

  const notifyError = (err) => {
    if (errorSent) {
      return;
    }
    errorSent = true;
    const text = err && err.message ? err.message : String(err || 'Video stream failed');
    setMessage(text);
    notify('error', text);
  };

  const stopMetricsTimer = () => {
    if (metricsTimer !== null) {
      window.clearInterval(metricsTimer);
      metricsTimer = null;
    }
  };

  const notifyMetrics = () => {
    if (!player || !video) {
      return;
    }

    const currentTime = Number(video.currentTime || 0);
    const bufferedEnd = video.buffered && video.buffered.length
      ? Number(video.buffered.end(video.buffered.length - 1))
      : null;
    const seekableEnd = video.seekable && video.seekable.length
      ? Number(video.seekable.end(video.seekable.length - 1))
      : null;
    const liveEdge = [bufferedEnd, seekableEnd]
      .filter((value) => Number.isFinite(value))
      .reduce((max, value) => Math.max(max, value), Number.NEGATIVE_INFINITY);
    const bufferLagMs = Number.isFinite(liveEdge)
      ? Math.max(0, Math.round((liveEdge - currentTime) * 1000))
      : null;
    const seekableLagMs = Number.isFinite(seekableEnd)
      ? Math.max(0, Math.round((seekableEnd - currentTime) * 1000))
      : null;

    notify('metrics', {
      state: video.paused ? 'paused' : (video.readyState >= 2 ? 'playing' : 'waiting'),
      buffer_lag_ms: bufferLagMs,
      seekable_lag_ms: seekableLagMs,
      current_time_sec: currentTime,
      buffered_end_sec: bufferedEnd,
      seekable_end_sec: seekableEnd,
      updated_ms: Date.now(),
    });
  };

  const startMetricsTimer = () => {
    if (metricsTimer !== null) {
      return;
    }
    notifyMetrics();
    metricsTimer = window.setInterval(notifyMetrics, 500);
  };

  const destroyPlayer = () => {
    stopMetricsTimer();
    if (player === null) {
      return;
    }
    try {
      player.destroy();
    } catch (_) {
      // Ignore teardown errors from partially initialized players.
    }
    player = null;
  };

  video.muted = $mutedLiteral;
  video.addEventListener('playing', () => {
    notifyReady();
    startMetricsTimer();
  });
  video.addEventListener('pause', stopMetricsTimer);
  video.addEventListener('ended', stopMetricsTimer);
  video.addEventListener('error', () => notifyError(video.error || 'Video element error'));

  try {
    if (!window.mpegts || !mpegts.isSupported()) {
      throw new Error('HTTP-FLV playback is not supported by this browser');
    }

    player = mpegts.createPlayer({
      type: 'flv',
      isLive: true,
      url: '$escapedUrl',
    }, {
      enableWorker: true,
      enableStashBuffer: false,
      stashInitialSize: 128,
      autoCleanupSourceBuffer: true,
      autoCleanupMaxBackwardDuration: 3,
      autoCleanupMinBackwardDuration: 1,
      liveBufferLatencyChasing: true,
      liveBufferLatencyMaxLatency: 1.5,
      liveBufferLatencyMinRemain: 0.3,
    });

    player.on(mpegts.Events.ERROR, (type, detail, info) => {
      const parts = [type, detail].filter(Boolean);
      const suffix = info && info.msg ? ': ' + info.msg : '';
      notifyError((parts.join(' / ') || 'Video stream failed') + suffix);
    });
    player.attachMediaElement(video);
    player.load();
    const playPromise = player.play();
    if (playPromise && typeof playPromise.catch === 'function') {
      playPromise.catch(notifyError);
    }
  } catch (err) {
    notifyError(err);
  }

  window.addEventListener('pagehide', destroyPlayer);
  window.addEventListener('beforeunload', destroyPlayer);
});
</script>
</body>
</html>
''';
  }

  String _escapeJs(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('<', r'\x3C')
        .replaceAll('>', r'\x3E')
        .replaceAll('&', r'\x26');
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(child: HtmlElementView(viewType: _viewType)),
    );
  }
}

class _StreamCallbacks {
  const _StreamCallbacks({this.onReady, this.onError, this.onLatency});

  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
  final ValueChanged<VideoPlaybackLatencySnapshot>? onLatency;
}
