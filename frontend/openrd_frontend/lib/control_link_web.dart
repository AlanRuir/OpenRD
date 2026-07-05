// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

enum ControlLinkState { disconnected, connecting, connected, error }

enum _ControlTransport { none, websocket, httpDriver, cloudDrive }

class DriverBatterySnapshot {
  const DriverBatterySnapshot({
    required this.available,
    required this.profile,
    required this.voltageV,
    required this.ageMs,
  });

  const DriverBatterySnapshot.unknown()
    : available = false,
      profile = '12V_3S',
      voltageV = 0.0,
      ageMs = 0;

  final bool available;
  final String profile;
  final double voltageV;
  final int ageMs;
}

class DriveControlMessage {
  const DriveControlMessage({
    required this.seq,
    required this.timestampMs,
    required this.steering,
    required this.throttle,
    required this.speedLimit,
    required this.stop,
    required this.source,
  });

  final int seq;
  final int timestampMs;
  final double steering;
  final double throttle;
  final int speedLimit;
  final bool stop;
  final String source;

  Map<String, Object> toJson() {
    return <String, Object>{
      'type': stop ? 'stop' : 'drive',
      'seq': seq,
      'timestamp_ms': timestampMs,
      'steering': _round3(steering),
      'throttle': _round3(throttle),
      'speed_limit': speedLimit.clamp(0, 1000),
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
    this.battery = const DriverBatterySnapshot.unknown(),
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
      battery: const DriverBatterySnapshot.unknown(),
    );
  }

  final ControlLinkState state;
  final String endpoint;
  final String lastError;
  final int sentCount;
  final int receivedCount;
  final DriveControlMessage? lastSent;
  final String lastReceived;
  final DriverBatterySnapshot battery;

  bool get isConnected => state == ControlLinkState.connected;

  ControlLinkSnapshot withBattery(DriverBatterySnapshot value) {
    return ControlLinkSnapshot(
      state: state,
      endpoint: endpoint,
      lastError: lastError,
      sentCount: sentCount,
      receivedCount: receivedCount,
      lastSent: lastSent,
      lastReceived: lastReceived,
      battery: value,
    );
  }

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

  static const String _vehicleId = 'openrd-001';

  final StreamController<ControlLinkSnapshot> _controller =
      StreamController<ControlLinkSnapshot>.broadcast();
  html.WebSocket? _socket;
  _ControlTransport _transport = _ControlTransport.none;
  String _httpDriverEndpoint = '';
  String _cloudDriveEndpoint = '';
  int _httpInFlight = 0;
  int _cloudInFlight = 0;
  Timer? _httpStatusTimer;
  Timer? _cloudStatusTimer;
  DateTime? _lastReadVolRequestAt;
  ControlLinkSnapshot _snapshot;
  int _sentCount = 0;
  int _receivedCount = 0;

  Stream<ControlLinkSnapshot> get snapshots => _controller.stream;

  ControlLinkSnapshot get current => _snapshot;

  void connect(String endpoint) {
    final normalizedEndpoint = _normalizeEndpoint(endpoint);
    disconnect(emit: false);
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.connecting,
        endpoint: normalizedEndpoint,
        lastError: '',
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );

    if (_isHttpEndpoint(normalizedEndpoint)) {
      _connectHttpEndpoint(normalizedEndpoint);
      return;
    }

    if (!_isWebSocketEndpoint(normalizedEndpoint)) {
      _update(
        ControlLinkSnapshot(
          state: ControlLinkState.error,
          endpoint: normalizedEndpoint,
          lastError: '控制地址需要以 ws://、wss://、http:// 或 https:// 开头',
          sentCount: _sentCount,
          receivedCount: _receivedCount,
          lastSent: _snapshot.lastSent,
          lastReceived: _snapshot.lastReceived,
        ),
      );
      return;
    }

    _transport = _ControlTransport.websocket;

    try {
      final socket = html.WebSocket(normalizedEndpoint);
      _socket = socket;

      socket.onOpen.listen((_) {
        if (!identical(_socket, socket)) {
          return;
        }
        _update(
          ControlLinkSnapshot(
            state: ControlLinkState.connected,
            endpoint: normalizedEndpoint,
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
            endpoint: normalizedEndpoint,
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
            endpoint: normalizedEndpoint,
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
            endpoint: normalizedEndpoint,
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
          endpoint: normalizedEndpoint,
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
    _transport = _ControlTransport.none;
    _httpDriverEndpoint = '';
    _cloudDriveEndpoint = '';
    _httpInFlight = 0;
    _cloudInFlight = 0;
    _httpStatusTimer?.cancel();
    _httpStatusTimer = null;
    _cloudStatusTimer?.cancel();
    _cloudStatusTimer = null;
    _lastReadVolRequestAt = null;
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
    if (_transport == _ControlTransport.cloudDrive) {
      return _sendCloudDrive(message);
    }

    if (_transport == _ControlTransport.httpDriver) {
      return _sendHttpDriver(message);
    }

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

  void _connectHttpEndpoint(String endpoint) {
    (() async {
      final handledAsCloud = await _tryConnectCloudDrive(endpoint);
      if (!handledAsCloud &&
          _transport != _ControlTransport.cloudDrive &&
          _cloudDriveEndpoint.isEmpty) {
        _connectHttpDriver(endpoint);
      }
    })();
  }

  Future<bool> _tryConnectCloudDrive(String endpoint) async {
    try {
      final response = await html.HttpRequest.request(
        _cloudDriveUri(endpoint, 'status').toString(),
        method: 'GET',
        requestHeaders: const <String, String>{'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 3));

      if (_transport != _ControlTransport.none) {
        return true;
      }

      final raw = response.responseText ?? '';
      if (!_isOkStatus(response.status ?? 0)) {
        return _looksLikeCloudEndpoint(endpoint)
            ? _markCloudConnectError(endpoint, '云端控制 HTTP ${response.status}')
            : false;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          (!decoded.containsKey('drive_agent_online') &&
              !decoded.containsKey('drive_state'))) {
        return false;
      }

      if (decoded['drive_agent_online'] != true) {
        return _markCloudConnectError(endpoint, '云端底盘 agent 离线');
      }

      _transport = _ControlTransport.cloudDrive;
      _cloudDriveEndpoint = endpoint;
      _receivedCount += 1;
      _update(
        ControlLinkSnapshot(
          state: ControlLinkState.connected,
          endpoint: endpoint,
          lastError: '',
          sentCount: _sentCount,
          receivedCount: _receivedCount,
          lastSent: _snapshot.lastSent,
          lastReceived: raw,
          battery: _batteryFromCloudStatus(decoded, _snapshot.battery),
        ),
      );
      _startCloudStatusPolling(endpoint);
      return true;
    } catch (error) {
      if (_looksLikeCloudEndpoint(endpoint)) {
        return _markCloudConnectError(endpoint, error.toString());
      }
      return false;
    }
  }

  bool _markCloudConnectError(String endpoint, String error) {
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.error,
        endpoint: endpoint,
        lastError: error,
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
        battery: _snapshot.battery,
      ),
    );
    return true;
  }

  void _connectHttpDriver(String endpoint) {
    _transport = _ControlTransport.httpDriver;
    _httpDriverEndpoint = endpoint;

    (() async {
      try {
        final response = await html.HttpRequest.request(
          _driverUri(endpoint, '/status').toString(),
          method: 'GET',
          requestHeaders: const <String, String>{'Accept': 'application/json'},
        );
        if (_transport != _ControlTransport.httpDriver ||
            _httpDriverEndpoint != endpoint) {
          return;
        }

        final raw = response.responseText ?? '';
        if (!_isOkStatus(response.status ?? 0)) {
          _markHttpError(endpoint, 'OpenRD-Driver HTTP ${response.status}');
          return;
        }

        final decoded = jsonDecode(raw);
        if (decoded is! Map || decoded['device'] != 'OpenRD-Driver') {
          _markHttpError(endpoint, '目标不是 OpenRD-Driver');
          return;
        }

        _receivedCount += 1;
        _update(
          ControlLinkSnapshot(
            state: ControlLinkState.connected,
            endpoint: endpoint,
            lastError: '',
            sentCount: _sentCount,
            receivedCount: _receivedCount,
            lastSent: _snapshot.lastSent,
            lastReceived: raw,
            battery: _batteryFromStatus(decoded, _snapshot.battery),
          ),
        );
        _startHttpStatusPolling(endpoint);
        unawaited(_requestBatteryVoltage(endpoint));
      } catch (error) {
        if (_transport == _ControlTransport.httpDriver &&
            _httpDriverEndpoint == endpoint) {
          _markHttpError(endpoint, error.toString());
        }
      }
    })();
  }

  bool _sendHttpDriver(DriveControlMessage message) {
    if (_snapshot.state != ControlLinkState.connected ||
        _httpDriverEndpoint.isEmpty) {
      return false;
    }
    if (_httpInFlight > 0 && !message.stop) {
      return true;
    }

    final endpoint = _httpDriverEndpoint;
    final motors = _driverMotorValues(message);
    final body = Uri(
      queryParameters: <String, String>{
        'm1': motors[0].toString(),
        'm2': motors[1].toString(),
        'm3': motors[2].toString(),
        'm4': motors[3].toString(),
      },
    ).query;

    _sentCount += 1;
    _httpInFlight += 1;
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

    (() async {
      try {
        final response = await html.HttpRequest.request(
          _driverUri(endpoint, '/control').toString(),
          method: 'POST',
          requestHeaders: const <String, String>{
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          sendData: body,
        );
        if (_transport != _ControlTransport.httpDriver ||
            _httpDriverEndpoint != endpoint) {
          return;
        }

        final raw = response.responseText ?? '';
        _receivedCount += 1;
        if (!_isOkStatus(response.status ?? 0)) {
          _update(
            ControlLinkSnapshot(
              state: ControlLinkState.error,
              endpoint: endpoint,
              lastError: 'OpenRD-Driver HTTP ${response.status}',
              sentCount: _sentCount,
              receivedCount: _receivedCount,
              lastSent: _snapshot.lastSent,
              lastReceived: raw,
            ),
          );
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
            lastReceived: raw,
          ),
        );
      } catch (error) {
        if (_transport == _ControlTransport.httpDriver &&
            _httpDriverEndpoint == endpoint) {
          _markHttpError(endpoint, error.toString());
        }
      } finally {
        _httpInFlight = math.max(0, _httpInFlight - 1);
      }
    })();

    return true;
  }

  bool _sendCloudDrive(DriveControlMessage message) {
    if (_snapshot.state != ControlLinkState.connected ||
        _cloudDriveEndpoint.isEmpty) {
      return false;
    }
    if (_cloudInFlight > 0 && !message.stop) {
      return true;
    }

    final endpoint = _cloudDriveEndpoint;
    _sentCount += 1;
    _cloudInFlight += 1;
    _update(
      ControlLinkSnapshot(
        state: _snapshot.state,
        endpoint: _snapshot.endpoint,
        lastError: _snapshot.lastError,
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: message,
        lastReceived: _snapshot.lastReceived,
        battery: _snapshot.battery,
      ),
    );

    (() async {
      try {
        final response = await html.HttpRequest.request(
          _cloudDriveUri(endpoint, 'command').toString(),
          method: 'POST',
          requestHeaders: const <String, String>{
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          sendData: message.encode(),
        ).timeout(const Duration(seconds: 3));

        if (_transport != _ControlTransport.cloudDrive ||
            _cloudDriveEndpoint != endpoint) {
          return;
        }

        final raw = response.responseText ?? '';
        _receivedCount += 1;
        final decoded = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
        if (!_isOkStatus(response.status ?? 0) ||
            decoded is! Map ||
            decoded['ok'] != true) {
          final error = decoded is Map
              ? (decoded['last_error'] ?? decoded['error'] ?? '').toString()
              : '';
          _update(
            ControlLinkSnapshot(
              state: ControlLinkState.error,
              endpoint: endpoint,
              lastError: error.isNotEmpty
                  ? error
                  : '云端控制 HTTP ${response.status}',
              sentCount: _sentCount,
              receivedCount: _receivedCount,
              lastSent: _snapshot.lastSent,
              lastReceived: raw,
              battery: _snapshot.battery,
            ),
          );
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
            lastReceived: raw,
            battery: _batteryFromCloudStatus(decoded, _snapshot.battery),
          ),
        );
      } catch (error) {
        if (_transport == _ControlTransport.cloudDrive &&
            _cloudDriveEndpoint == endpoint) {
          _markCloudError(endpoint, error.toString());
        }
      } finally {
        _cloudInFlight = math.max(0, _cloudInFlight - 1);
      }
    })();

    return true;
  }

  void _startCloudStatusPolling(String endpoint) {
    _cloudStatusTimer?.cancel();
    _cloudStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_transport != _ControlTransport.cloudDrive ||
          _cloudDriveEndpoint != endpoint) {
        return;
      }
      unawaited(_refreshCloudDriveStatus(endpoint));
    });
  }

  Future<void> _refreshCloudDriveStatus(String endpoint) async {
    try {
      final response = await html.HttpRequest.request(
        _cloudDriveUri(endpoint, 'status').toString(),
        method: 'GET',
        requestHeaders: const <String, String>{'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 3));

      if (_transport != _ControlTransport.cloudDrive ||
          _cloudDriveEndpoint != endpoint) {
        return;
      }

      final raw = response.responseText ?? '';
      if (!_isOkStatus(response.status ?? 0)) {
        _markCloudError(endpoint, '云端控制 HTTP ${response.status}');
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _markCloudError(endpoint, '云端控制状态格式异常');
        return;
      }

      _receivedCount += 1;
      _update(
        ControlLinkSnapshot(
          state: decoded['drive_agent_online'] == true
              ? ControlLinkState.connected
              : ControlLinkState.error,
          endpoint: endpoint,
          lastError: decoded['drive_agent_online'] == true
              ? ''
              : '云端底盘 agent 离线',
          sentCount: _sentCount,
          receivedCount: _receivedCount,
          lastSent: _snapshot.lastSent,
          lastReceived: raw,
          battery: _batteryFromCloudStatus(decoded, _snapshot.battery),
        ),
      );
    } catch (error) {
      if (_transport == _ControlTransport.cloudDrive &&
          _cloudDriveEndpoint == endpoint) {
        _markCloudError(endpoint, error.toString());
      }
    }
  }

  void _startHttpStatusPolling(String endpoint) {
    _httpStatusTimer?.cancel();
    _httpStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_transport != _ControlTransport.httpDriver ||
          _httpDriverEndpoint != endpoint) {
        return;
      }
      unawaited(_refreshHttpDriverStatus(endpoint));

      final lastRead = _lastReadVolRequestAt;
      if (lastRead == null ||
          DateTime.now().difference(lastRead) >= const Duration(seconds: 30)) {
        unawaited(_requestBatteryVoltage(endpoint));
      }
    });
  }

  Future<void> _refreshHttpDriverStatus(String endpoint) async {
    try {
      final response = await html.HttpRequest.request(
        _driverUri(endpoint, '/status').toString(),
        method: 'GET',
        requestHeaders: const <String, String>{'Accept': 'application/json'},
      );
      if (_transport != _ControlTransport.httpDriver ||
          _httpDriverEndpoint != endpoint) {
        return;
      }

      final raw = response.responseText ?? '';
      if (!_isOkStatus(response.status ?? 0)) {
        _markHttpError(endpoint, 'OpenRD-Driver HTTP ${response.status}');
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['device'] != 'OpenRD-Driver') {
        _markHttpError(endpoint, '目标不是 OpenRD-Driver');
        return;
      }

      _receivedCount += 1;
      _update(
        ControlLinkSnapshot(
          state: ControlLinkState.connected,
          endpoint: endpoint,
          lastError: '',
          sentCount: _sentCount,
          receivedCount: _receivedCount,
          lastSent: _snapshot.lastSent,
          lastReceived: raw,
          battery: _batteryFromStatus(decoded, _snapshot.battery),
        ),
      );
    } catch (error) {
      if (_transport == _ControlTransport.httpDriver &&
          _httpDriverEndpoint == endpoint) {
        _markHttpError(endpoint, error.toString());
      }
    }
  }

  Future<void> _requestBatteryVoltage(String endpoint) async {
    _lastReadVolRequestAt = DateTime.now();
    try {
      await html.HttpRequest.request(
        _driverUri(endpoint, '/read_vol').toString(),
        method: 'POST',
        requestHeaders: const <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        sendData: '',
      );
    } catch (_) {
      // Status polling will surface connection problems. A missed voltage
      // request should not interrupt live driving.
    }
  }

  void dispose() {
    disconnect(emit: false);
    _controller.close();
  }

  void _update(ControlLinkSnapshot snapshot) {
    final next = !snapshot.battery.available && _snapshot.battery.available
        ? snapshot.withBattery(_snapshot.battery)
        : snapshot;
    _snapshot = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  void _markHttpError(String endpoint, String error) {
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.error,
        endpoint: endpoint,
        lastError: error,
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
      ),
    );
  }

  void _markCloudError(String endpoint, String error) {
    _update(
      ControlLinkSnapshot(
        state: ControlLinkState.error,
        endpoint: endpoint,
        lastError: error,
        sentCount: _sentCount,
        receivedCount: _receivedCount,
        lastSent: _snapshot.lastSent,
        lastReceived: _snapshot.lastReceived,
        battery: _snapshot.battery,
      ),
    );
  }

  Uri _driverUri(String endpoint, String path) {
    final uri = Uri.parse(endpoint);
    return uri.replace(path: path, queryParameters: const <String, String>{});
  }

  Uri _cloudDriveUri(String endpoint, String action) {
    final uri = Uri.parse(endpoint);
    final baseSegments = uri.pathSegments.where((part) => part.isNotEmpty);
    return uri.replace(
      pathSegments: <String>[
        ...baseSegments,
        'api',
        'vehicles',
        _vehicleId,
        'drive',
        action,
      ],
      queryParameters: const <String, String>{},
      fragment: '',
    );
  }

  bool _looksLikeCloudEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null) {
      return false;
    }
    if (uri.path.contains('/openrd-control') ||
        uri.path.contains('/api/vehicles/')) {
      return true;
    }
    if (uri.port == 8790) {
      return true;
    }
    return uri.host == '43.139.25.165';
  }

  DriverBatterySnapshot _batteryFromStatus(
    Map<dynamic, dynamic> status,
    DriverBatterySnapshot fallback,
  ) {
    final profile =
        status['battery_profile']?.toString() ??
        (fallback.profile.isNotEmpty ? fallback.profile : '12V_3S');
    var voltage = _readDouble(status['battery_voltage_v']);
    final ageMs = _readInt(status['battery_age_ms']);

    if (voltage <= 0.0) {
      voltage = _batteryVoltageFromRx(status['last_motor_rx']?.toString());
    }

    if (voltage <= 0.0) {
      return fallback;
    }

    return DriverBatterySnapshot(
      available: true,
      profile: profile,
      voltageV: voltage,
      ageMs: ageMs,
    );
  }

  DriverBatterySnapshot _batteryFromCloudStatus(
    Map<dynamic, dynamic> status,
    DriverBatterySnapshot fallback,
  ) {
    final profile =
        status['battery_profile']?.toString() ??
        (fallback.profile.isNotEmpty ? fallback.profile : '12V_3S');
    final voltage = _readDouble(status['battery_voltage_v']);
    final ageMs = _readInt(status['battery_age_ms']);
    if (voltage <= 0.0) {
      return fallback;
    }
    return DriverBatterySnapshot(
      available: true,
      profile: profile,
      voltageV: voltage,
      ageMs: ageMs,
    );
  }

  double _batteryVoltageFromRx(String? raw) {
    if (raw == null || raw.isEmpty) {
      return 0.0;
    }
    final match = RegExp(
      r'Battery:([0-9.]+)V',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) {
      return 0.0;
    }
    return double.tryParse(match.group(1) ?? '') ?? 0.0;
  }

  double _readDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  int _readInt(Object? value) {
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  List<int> _driverMotorValues(DriveControlMessage message) {
    final speed = message.speedLimit.clamp(0, 1000).toDouble();
    if (message.stop || speed <= 0) {
      return const <int>[0, 0, 0, 0];
    }

    var left =
        (message.throttle.clamp(-1.0, 1.0) + message.steering.clamp(-1.0, 1.0))
            .toDouble();
    var right =
        (message.throttle.clamp(-1.0, 1.0) - message.steering.clamp(-1.0, 1.0))
            .toDouble();
    final scale = math.max(1.0, math.max(left.abs(), right.abs()));
    left /= scale;
    right /= scale;

    int motor(double value) {
      return (value * speed).round().clamp(-1000, 1000).toInt();
    }

    return <int>[motor(left), motor(left), motor(right), motor(right)];
  }

  bool _isOkStatus(int status) {
    return status >= 200 && status < 300;
  }

  bool _isHttpEndpoint(String endpoint) {
    final scheme = Uri.tryParse(endpoint)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  bool _isWebSocketEndpoint(String endpoint) {
    final scheme = Uri.tryParse(endpoint)?.scheme.toLowerCase();
    return scheme == 'ws' || scheme == 'wss';
  }

  String _normalizeEndpoint(String endpoint) {
    final value = endpoint.trim();
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(value)) {
      return value;
    }
    return 'http://$value';
  }
}
