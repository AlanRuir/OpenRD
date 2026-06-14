import 'dart:async';

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
      'steering': steering,
      'throttle': throttle,
      'stop': stop,
      'source': source,
    };
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
  ControlLinkSnapshot _snapshot;

  Stream<ControlLinkSnapshot> get snapshots => _controller.stream;

  ControlLinkSnapshot get current => _snapshot;

  void connect(String endpoint) {
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.error,
        endpoint: endpoint,
        lastError: '当前平台不支持 WebSocket 控制链路',
        sentCount: _snapshot.sentCount,
        receivedCount: _snapshot.receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );
  }

  void disconnect() {
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.disconnected,
        endpoint: _snapshot.endpoint,
        lastError: '',
        sentCount: _snapshot.sentCount,
        receivedCount: _snapshot.receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );
  }

  bool send(DriveControlMessage message) {
    _update(
      ControlLinkSnapshot(
        state: _snapshot.state,
        endpoint: _snapshot.endpoint,
        lastError: _snapshot.lastError,
        sentCount: _snapshot.sentCount,
        receivedCount: _snapshot.receivedCount,
        lastSent: message,
        lastReceived: _snapshot.lastReceived,
      ),
    );
    return false;
  }

  void dispose() {
    _controller.close();
  }

  void _update(ControlLinkSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_controller.isClosed) {
      _controller.add(snapshot);
    }
  }
}
