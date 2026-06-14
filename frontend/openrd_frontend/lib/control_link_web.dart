// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

enum ControlLinkState { disconnected, connecting, connected, error }

class DriveControlMessage {
  const DriveControlMessage({
    required this.seq,
    required this.timestampMs,
    required this.steering,
    required this.throttle,
    required this.stop,
    required this.source,
  });

  final int seq;
  final int timestampMs;
  final double steering;
  final double throttle;
  final bool stop;
  final String source;

  Map<String, Object> toJson() {
    return <String, Object>{
      'type': stop ? 'stop' : 'drive',
      'seq': seq,
      'timestamp_ms': timestampMs,
      'steering': _round3(steering),
      'throttle': _round3(throttle),
      'stop': stop,
      'source': source,
    };
  }

  String encode() {
    return jsonEncode(toJson());
  }

  static double _round3(double value) {
    return (value.clamp(-1.0, 1.0) * 1000).roundToDouble() / 1000.0;
  }
}

class ControlLinkSnapshot {
  const ControlLinkSnapshot({
    required this.state,
    required this.endpoint,
    required this.lastError,
    required this.sentCount,
    required this.receivedCount,
    required this.lastSent,
    required this.lastReceived,
  });

  factory ControlLinkSnapshot.initial(String endpoint) {
    return ControlLinkSnapshot(
      state: ControlLinkState.disconnected,
      endpoint: endpoint,
      lastError: '',
      sentCount: 0,
      receivedCount: 0,
      lastSent: null,
      lastReceived: '',
    );
  }

  final ControlLinkState state;
  final String endpoint;
  final String lastError;
  final int sentCount;
  final int receivedCount;
  final DriveControlMessage? lastSent;
  final String lastReceived;

  bool get isConnected => state == ControlLinkState.connected;

  String get stateLabel {
    switch (state) {
      case ControlLinkState.disconnected:
        return '未连接';
      case ControlLinkState.connecting:
        return '连接中';
      case ControlLinkState.connected:
        return '已连接';
      case ControlLinkState.error:
        return '异常';
    }
  }
}

class ControlLink {
  ControlLink({required String endpoint})
    : _snapshot = ControlLinkSnapshot.initial(endpoint);

  final StreamController<ControlLinkSnapshot> _controller =
      StreamController<ControlLinkSnapshot>.broadcast();
  html.WebSocket? _socket;
  ControlLinkSnapshot _snapshot;
  int _sentCount = 0;
  int _receivedCount = 0;

  Stream<ControlLinkSnapshot> get snapshots => _controller.stream;

  ControlLinkSnapshot get current => _snapshot;

  void connect(String endpoint) {
    disconnect(emit: false);
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.connecting,
        endpoint: endpoint,
        lastError: '',
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );

    try {
      final socket = html.WebSocket(endpoint);
      _socket = socket;

      socket.onOpen.listen((_) {
        if (!identical(_socket, socket)) {
          return;
        }
        _update(
          ControlLinkSnapshot(
            state: ControlLinkState.connected,
            endpoint: endpoint,
            lastError: '',
            sentCount: _sentCount,
            receivedCount: _receivedCount,
            lastSent: _snapshot.lastSent,
            lastReceived: _snapshot.lastReceived,
          ),
        );
      });

      socket.onMessage.listen((event) {
        if (!identical(_socket, socket)) {
          return;
        }
        _receivedCount += 1;
        _update(
          ControlLinkSnapshot(
            state: _snapshot.state,
            endpoint: endpoint,
            lastError: _snapshot.lastError,
            sentCount: _sentCount,
            receivedCount: _receivedCount,
            lastSent: _snapshot.lastSent,
            lastReceived: event.data?.toString() ?? '',
          ),
        );
      });

      socket.onError.listen((_) {
        if (!identical(_socket, socket)) {
          return;
        }
        _update(
          ControlLinkSnapshot(
            state: ControlLinkState.error,
            endpoint: endpoint,
            lastError: 'WebSocket 连接异常',
            sentCount: _sentCount,
            receivedCount: _receivedCount,
            lastSent: _snapshot.lastSent,
            lastReceived: _snapshot.lastReceived,
          ),
        );
      });

      socket.onClose.listen((event) {
        if (!identical(_socket, socket)) {
          return;
        }
        _socket = null;
        final closeReason = event.reason ?? '';
        final lastError = closeReason.isNotEmpty
            ? closeReason
            : _snapshot.lastError;
        final state = _snapshot.state == ControlLinkState.error
            ? ControlLinkState.error
            : ControlLinkState.disconnected;
        _update(
          ControlLinkSnapshot(
            state: state,
            endpoint: endpoint,
            lastError: lastError,
            sentCount: _sentCount,
            receivedCount: _receivedCount,
            lastSent: _snapshot.lastSent,
            lastReceived: _snapshot.lastReceived,
          ),
        );
      });
    } catch (error) {
      _update(
        ControlLinkSnapshot(
          state: ControlLinkState.error,
          endpoint: endpoint,
          lastError: error.toString(),
          sentCount: _sentCount,
          receivedCount: _receivedCount,
          lastSent: _snapshot.lastSent,
          lastReceived: _snapshot.lastReceived,
        ),
      );
    }
  }

  void disconnect({bool emit = true}) {
    final socket = _socket;
    _socket = null;
    socket?.close();
    if (!emit) {
      return;
    }

    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.disconnected,
        endpoint: _snapshot.endpoint,
        lastError: '',
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );
  }

  bool send(DriveControlMessage message) {
    final socket = _socket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      return false;
    }

    socket.send(message.encode());
    _sentCount += 1;
    _update(
      ControlLinkSnapshot(
        state: _snapshot.state,
        endpoint: _snapshot.endpoint,
        lastError: _snapshot.lastError,
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: message,
        lastReceived: _snapshot.lastReceived,
      ),
    );
    return true;
  }

  void dispose() {
    disconnect(emit: false);
    _controller.close();
  }

  void _update(ControlLinkSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_controller.isClosed) {
      _controller.add(snapshot);
    }
  }
}
