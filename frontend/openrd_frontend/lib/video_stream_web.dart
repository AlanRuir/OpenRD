// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

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
  });

  final String url;
  final String readerUrl;
  final String whepUrl;
  final bool muted;
  final Widget placeholder;
  final VoidCallback? onReady;
  final ValueChanged<String>? onError;

  @override
  State<OpenRdStreamView> createState() => _OpenRdStreamViewState();
}

class _OpenRdStreamViewState extends State<OpenRdStreamView> {
  static const String _playerVersion = 'openrd-player-16x9-v3';
  static const String _messageSource = 'openrd-stream-player';
  static final Set<String> _registeredViewTypes = <String>{};
  static final Map<String, _StreamCallbacks> _callbacksByViewType =
      <String, _StreamCallbacks>{};

  late final String _viewType = _buildViewType(
    widget.readerUrl,
    widget.whepUrl,
    widget.muted,
  );
  StreamSubscription<html.MessageEvent>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _registerViewType(
      _viewType,
      readerUrl: widget.readerUrl,
      whepUrl: widget.whepUrl,
      muted: widget.muted,
    );
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
    );
    _messageSubscription = html.window.onMessage.listen(_handlePlayerMessage);
  }

  @override
  void didUpdateWidget(covariant OpenRdStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _callbacksByViewType.remove(_viewType);
    super.dispose();
  }

  String _buildViewType(String readerUrl, String whepUrl, bool muted) {
    final key = '$_playerVersion|$readerUrl|$whepUrl|$muted';
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
      case 'error':
        final message = parsed['message'];
        callbacks?.onError?.call(
          message is String && message.isNotEmpty ? message : '视频流加载失败',
        );
    }
  }

  void _registerViewType(
    String viewType, {
    required String readerUrl,
    required String whepUrl,
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
          readerUrl: readerUrl,
          whepUrl: whepUrl,
          muted: muted,
        )
        ..style.border = '0'
        ..style.display = 'block'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'autoplay; fullscreen; picture-in-picture'
        ..setAttribute('scrolling', 'no');

      iframe.onError.listen((_) {
        _callbacksByViewType[viewType]?.onError?.call('视频流加载失败');
      });

      return iframe;
    });
  }

  String _buildPlayerDocument({
    required String viewType,
    required String readerUrl,
    required String whepUrl,
    required bool muted,
  }) {
    final escapedReaderUrl = _escapeHtml(readerUrl);
    final escapedWhepUrl = _escapeJs(whepUrl);
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
<script defer src="$escapedReaderUrl"></script>
</head>
<body>
<!-- $_playerVersion -->
<video id="video" autoplay playsinline disablepictureinpicture disableremoteplayback></video>
<div id="message">Connecting...</div>
<script>
window.addEventListener('load', () => {
  const video = document.getElementById('video');
  const message = document.getElementById('message');
  let reader = null;
  let readySent = false;

  const setMessage = (text) => {
    message.textContent = text;
    message.style.display = text ? 'flex' : 'none';
  };

  const notify = (event, message = '') => {
    window.parent.postMessage(JSON.stringify({
      source: '$_messageSource',
      viewType: '$escapedViewType',
      event,
      message,
    }), '*');
  };

  const notifyReady = () => {
    if (readySent) {
      return;
    }
    readySent = true;
    notify('ready');
  };

  const notifyError = (err) => {
    const text = err && err.message ? err.message : String(err || 'Video stream failed');
    setMessage(text);
    notify('error', text);
  };

  video.muted = $mutedLiteral;
  video.addEventListener('playing', notifyReady, { once: true });

  try {
    reader = new MediaMTXWebRTCReader({
      url: '$escapedWhepUrl',
      onError: notifyError,
      onTrack: (evt) => {
        setMessage('');
        video.srcObject = evt.streams[0];
        notifyReady();
      },
      onDataChannel: (evt) => {
        evt.channel.binaryType = 'arraybuffer';
      },
    });
  } catch (err) {
    notifyError(err);
  }

  window.addEventListener('beforeunload', () => {
    if (reader !== null) {
      reader.close();
    }
  });
});
</script>
</body>
</html>
''';
  }

  String _escapeHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _escapeJs(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
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
  const _StreamCallbacks({this.onReady, this.onError});

  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
}
