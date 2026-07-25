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
  static const String _playerVersion = 'openrd-webrtc-player-v1';
  static const String _mpegtsCdn =
      'https://cdn.jsdelivr.net/npm/mpegts.js@1.7.3/dist/mpegts.min.js';
  static const String _messageSource = 'openrd-stream-player';
  static final Set<String> _registeredViewTypes = <String>{};
  static final Map<String, _StreamCallbacks> _callbacksByViewType =
      <String, _StreamCallbacks>{};

  late final String _viewType = _buildViewType(
    widget.url,
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
      url: widget.url,
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

  String _buildViewType(
    String url,
    String readerUrl,
    String whepUrl,
    bool muted,
  ) {
    final key = '$_playerVersion|$url|$readerUrl|$whepUrl|$muted';
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
          message is String && message.isNotEmpty
              ? message
              : 'Video stream failed',
        );
    }
  }

  void _registerViewType(
    String viewType, {
    required String url,
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
          url: url,
          whepUrl: whepUrl,
          muted: muted,
        )
        ..style.border = '0'
        ..style.display = 'block'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.pointerEvents = 'none'
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
    required String whepUrl,
    required bool muted,
  }) {
    if (whepUrl.trim().isNotEmpty) {
      return _buildWhepPlayerDocument(
        viewType: viewType,
        whepUrl: whepUrl.trim(),
        muted: muted,
      );
    }
    return _buildFlvPlayerDocument(viewType: viewType, url: url, muted: muted);
  }

  String _buildWhepPlayerDocument({
    required String viewType,
    required String whepUrl,
    required bool muted,
  }) {
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
${_playerCss()}
</style>
</head>
<body>
<!-- $_playerVersion WHEP -->
<video id="video" autoplay playsinline disablepictureinpicture disableremoteplayback></video>
<div id="message">Connecting WebRTC...</div>
<script>
window.addEventListener('load', async () => {
  const video = document.getElementById('video');
  const message = document.getElementById('message');
  let pc = null;
  let remoteStream = null;
  let readySent = false;
  let errorSent = false;

  const setMessage = (text) => {
    message.textContent = text;
    message.style.display = text ? 'flex' : 'none';
  };

  const notify = (event, text = '') => {
    window.parent.postMessage(JSON.stringify({
      source: '$_messageSource',
      viewType: '$escapedViewType',
      event,
      message: text,
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

  const destroyPlayer = () => {
    if (pc === null) {
      return;
    }
    try {
      pc.getSenders().forEach((sender) => sender.track && sender.track.stop());
      pc.getReceivers().forEach((receiver) => receiver.track && receiver.track.stop());
      pc.close();
    } catch (_) {
      // Ignore teardown errors from partially initialized WebRTC sessions.
    }
    pc = null;
    video.srcObject = null;
  };

  const waitForIceGathering = () => new Promise((resolve) => {
    const currentPc = pc;
    if (!currentPc || currentPc.iceGatheringState === 'complete') {
      resolve();
      return;
    }
    const onStateChange = () => {
      if (currentPc.iceGatheringState === 'complete') {
        window.clearTimeout(timeout);
        currentPc.removeEventListener('icegatheringstatechange', onStateChange);
        resolve();
      }
    };
    const timeout = window.setTimeout(() => {
      currentPc.removeEventListener('icegatheringstatechange', onStateChange);
      resolve();
    }, 1600);
    currentPc.addEventListener('icegatheringstatechange', onStateChange);
  });

  const parseAnswerSdp = (contentType, text) => {
    const trimmed = text.trim();
    if (contentType.includes('application/json') || trimmed.startsWith('{')) {
      const parsed = JSON.parse(trimmed);
      if (Object.prototype.hasOwnProperty.call(parsed, 'code') && Number(parsed.code) !== 0) {
        throw new Error(parsed.msg || parsed.error || 'WHEP rejected offer');
      }
      return parsed.sdp || parsed.answer || '';
    }
    return text;
  };

  video.muted = $mutedLiteral;
  video.addEventListener('playing', notifyReady, { once: true });
  video.addEventListener('error', () => notifyError(video.error || 'Video element error'));

  try {
    if (!window.RTCPeerConnection) {
      throw new Error('WebRTC is not supported by this browser');
    }

    pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });
    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.ontrack = (event) => {
      if (remoteStream === null) {
        remoteStream = new MediaStream();
        video.srcObject = remoteStream;
      }
      remoteStream.addTrack(event.track);
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed') {
        notifyError('WebRTC connection failed');
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed') {
        notifyError('WebRTC ICE failed');
      }
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await waitForIceGathering();

    const localDescription = pc.localDescription || offer;
    let contentType = 'application/sdp';
    try {
      const endpoint = new URL('$escapedWhepUrl', window.location.href);
      let endpointPath = endpoint.pathname;
      while (endpointPath.endsWith('/')) {
        endpointPath = endpointPath.slice(0, -1);
      }
      if (endpointPath === '/index/api/webrtc') {
        contentType = 'text/plain;charset=utf-8';
      }
    } catch (_) {
      // Keep the standard WHEP content type when URL parsing is unavailable.
    }
    const response = await fetch('$escapedWhepUrl', {
      method: 'POST',
      headers: {
        'Content-Type': contentType,
        'Accept': 'application/sdp, application/json',
      },
      body: localDescription.sdp,
    });
    const responseText = await response.text();
    if (!response.ok) {
      const detail = responseText ? ': ' + responseText.slice(0, 180) : '';
      throw new Error('WHEP HTTP ' + response.status + detail);
    }

    const answerSdp = parseAnswerSdp(response.headers.get('content-type') || '', responseText);
    if (!answerSdp) {
      throw new Error('WHEP answer SDP is empty');
    }
    await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });

    const playPromise = video.play();
    if (playPromise && typeof playPromise.catch === 'function') {
      playPromise.catch(notifyError);
    }
  } catch (err) {
    notifyError(err);
    destroyPlayer();
  }

  window.addEventListener('pagehide', destroyPlayer);
  window.addEventListener('beforeunload', destroyPlayer);
});
</script>
</body>
</html>
''';
  }

  String _buildFlvPlayerDocument({
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
${_playerCss()}
</style>
<script defer src="$_mpegtsCdn"></script>
</head>
<body>
<!-- $_playerVersion HTTP-FLV fallback -->
<video id="video" autoplay playsinline disablepictureinpicture disableremoteplayback></video>
<div id="message">Connecting HTTP-FLV...</div>
<script>
window.addEventListener('load', () => {
  const video = document.getElementById('video');
  const message = document.getElementById('message');
  let player = null;
  let readySent = false;
  let errorSent = false;

  const setMessage = (text) => {
    message.textContent = text;
    message.style.display = text ? 'flex' : 'none';
  };

  const notify = (event, text = '') => {
    window.parent.postMessage(JSON.stringify({
      source: '$_messageSource',
      viewType: '$escapedViewType',
      event,
      message: text,
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

  const destroyPlayer = () => {
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
  video.addEventListener('playing', notifyReady, { once: true });
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

  String _playerCss() {
    return '''
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
  const _StreamCallbacks({this.onReady, this.onError});

  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
}
