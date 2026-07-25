import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'control_link.dart';
import 'gamepad_input.dart';
import 'immersive_mode.dart';
import 'video_control.dart';
import 'video_stream.dart';

void main() {
  runApp(const OpenRdApp());
}

class OpenRdApp extends StatelessWidget {
  const OpenRdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OpenRD',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        fontFamily: 'Roboto',
        fontFamilyFallback: const ['sans-serif'],
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        useMaterial3: true,
      ),
      home: const ControlDashboardPage(),
    );
  }
}

enum DriveCommand { forward, backward, left, right, stop }

enum StreamPlaybackState { stopped, loading, ready, error }

const Color _desktopAccent = Color(0xFF0A84FF);
const Color _desktopGreen = Color(0xFF30D158);
const Color _desktopOrange = Color(0xFFFF9F0A);
const Color _desktopRed = Color(0xFFFF453A);
const Color _desktopPanel = Color(0xB812151B);
const Color _desktopStroke = Color(0x29FFFFFF);
const Color _desktopMutedText = Color(0xA6FFFFFF);

ThemeData _desktopTheme(BuildContext context) {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: _desktopAccent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: _desktopAccent,
        secondary: _desktopGreen,
        error: _desktopRed,
        surface: const Color(0xFF111318),
        onSurface: Colors.white,
        onSurfaceVariant: _desktopMutedText,
      );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.black,
    textTheme: base.textTheme.apply(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['sans-serif'],
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    dividerColor: Colors.white.withValues(alpha: 0.10),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.07),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _desktopAccent),
      ),
      isDense: true,
      labelStyle: const TextStyle(color: _desktopMutedText),
      helperStyle: const TextStyle(color: _desktopMutedText),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: _desktopAccent,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
      thumbColor: Colors.white,
      overlayColor: _desktopAccent.withValues(alpha: 0.16),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : Colors.white.withValues(alpha: 0.72),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? _desktopAccent.withValues(alpha: 0.74)
            : Colors.white.withValues(alpha: 0.16),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.white.withValues(alpha: 0.08),
        shape: const CircleBorder(),
      ),
    ),
  );
}

class ControlDashboardPage extends StatefulWidget {
  const ControlDashboardPage({super.key});

  @override
  State<ControlDashboardPage> createState() => _ControlDashboardPageState();
}

class _ControlDashboardPageState extends State<ControlDashboardPage>
    with WidgetsBindingObserver {
  static const String _defaultStreamHost = '43.139.25.165';
  static const String _defaultStreamPath = 'live/openrd';
  static const String _defaultVideoControlUrl = 'http://43.139.25.165:8790';
  static const String _defaultDriveControlUrl =
      'http://43.139.25.165:8080/openrd-control';
  static const String _videoVehicleId = 'openrd-001';
  static const int _videoLeaseSec = 120;

  DriveCommand _lastCommand = DriveCommand.stop;
  final TextEditingController _controlEndpointController =
      TextEditingController(text: _defaultDriveControlUrl);
  bool _manualMode = true;
  double _steering = 0.0;
  double _throttle = 0.0;
  int _speedLimit = 500;
  bool _streamMuted = true;
  bool _videoPlaybackEnabled = false;
  bool _videoCommandBusy = false;
  int _streamReloadToken = 0;
  StreamPlaybackState _streamState = StreamPlaybackState.stopped;
  String _streamStatusMessage = '视频推流未启动';
  String _videoCloudState = 'unknown';
  String _videoTransport = 'webrtc';
  String _cloudPlayUrl = '';
  String _cloudWhepUrl = '';
  late final String _videoViewerId =
      'openrd-web-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(99999)}';

  late final ControlLink _controlLink = ControlLink(
    endpoint: _controlEndpointController.text.trim(),
  );
  final VideoControlClient _videoControl = VideoControlClient();
  StreamSubscription<ControlLinkSnapshot>? _controlLinkSubscription;
  ControlLinkSnapshot _controlLinkSnapshot = ControlLinkSnapshot.initial(
    _defaultDriveControlUrl,
  );
  Timer? _controlSendTimer;
  Timer? _videoRenewTimer;
  Timer? _videoCloudStatusTimer;
  int _controlSeq = 0;

  final GamepadInput _gamepadInput = GamepadInput();
  StreamSubscription<GamepadSnapshot>? _gamepadSubscription;
  GamepadSnapshot _gamepadSnapshot = GamepadSnapshot.disconnected();
  final TextEditingController _streamHostController = TextEditingController(
    text: _defaultStreamHost,
  );
  final TextEditingController _streamPathController = TextEditingController(
    text: _defaultStreamPath,
  );
  final TextEditingController _videoControlController = TextEditingController(
    text: _defaultVideoControlUrl,
  );
  final List<String> _eventLog = <String>['OpenRD 控制台已启动'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controlLinkSubscription = _controlLink.snapshots.listen(
      _handleControlLinkSnapshot,
    );
    _gamepadSubscription = _gamepadInput.snapshots.listen(
      _handleGamepadSnapshot,
    );
    _gamepadInput.start();
    _controlSendTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _flushControlIfNeeded(),
    );
    _videoCloudStatusTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshVideoCloudStatus()),
    );
    unawaited(_refreshVideoCloudStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlSendTimer?.cancel();
    _videoRenewTimer?.cancel();
    _videoCloudStatusTimer?.cancel();
    _controlLinkSubscription?.cancel();
    _controlLink.dispose();
    _gamepadSubscription?.cancel();
    _gamepadInput.dispose();
    _controlEndpointController.dispose();
    _streamHostController.dispose();
    _streamPathController.dispose();
    _videoControlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopAll();
      _pushEvent('页面失焦：停车');
    }
  }

  String get _streamUrl {
    if (_cloudPlayUrl.isNotEmpty) {
      return _cloudPlayUrl;
    }
    final host = _normalizedHost();
    final pathSegments = _streamPlaybackPathSegments();
    return Uri(
      scheme: 'http',
      host: host,
      port: 8888,
      pathSegments: pathSegments,
    ).toString();
  }

  String get _streamReaderUrl => '';

  String get _streamWhepUrl {
    if (_cloudWhepUrl.isNotEmpty) {
      return _browserPlayableWhepUrl(_cloudWhepUrl);
    }
    final host = _normalizedHost();
    final appAndStream = _streamAppAndName();
    final directUrl = Uri(
      scheme: 'http',
      host: host,
      port: 8888,
      pathSegments: const <String>['index', 'api', 'webrtc'],
      queryParameters: <String, String>{
        'app': appAndStream[0],
        'stream': appAndStream[1],
        'type': 'play',
      },
    ).toString();
    return _browserPlayableWhepUrl(directUrl);
  }

  String _browserPlayableWhepUrl(String url) {
    final parsed = Uri.tryParse(url);
    final base = Uri.base;
    if (parsed == null ||
        base.host.isEmpty ||
        parsed.host != base.host ||
        !parsed.hasPort ||
        parsed.port != 8888 ||
        base.port == 8888 ||
        parsed.path != '/index/api/webrtc') {
      return url;
    }

    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: parsed.path,
      queryParameters: parsed.queryParameters,
    ).toString();
  }

  String get _videoControlUrl {
    final value = _videoControlController.text.trim();
    if (value.isEmpty) {
      return _defaultVideoControlUrl;
    }
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  String _normalizedHost() {
    final host = _streamHostController.text.trim();
    if (host.isEmpty) {
      return _defaultStreamHost;
    }

    return host
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first
        .replaceFirst(RegExp(r':\d+$'), '');
  }

  String _normalizedPath() {
    final path = _streamPathController.text.trim();
    if (path.isEmpty) {
      return _defaultStreamPath;
    }

    return path.startsWith('/') ? path.substring(1) : path;
  }

  List<String> _streamPlaybackPathSegments() {
    final pathSegments = _normalizedPath()
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (pathSegments.isEmpty) {
      return <String>['live', 'openrd.live.flv'];
    }

    final last = pathSegments.last;
    if (last.endsWith('.live.flv')) {
      return pathSegments;
    }

    return <String>[
      ...pathSegments.take(pathSegments.length - 1),
      '$last.live.flv',
    ];
  }

  List<String> _streamAppAndName() {
    final pathSegments = _normalizedPath()
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (pathSegments.isEmpty) {
      return <String>['live', 'openrd'];
    }
    if (pathSegments.length == 1) {
      return <String>[
        'live',
        pathSegments.first.replaceFirst(RegExp(r'\.live\.flv$'), ''),
      ];
    }

    final stream = pathSegments
        .skip(1)
        .join('/')
        .replaceFirst(RegExp(r'\.live\.flv$'), '');
    return <String>[pathSegments.first, stream.isEmpty ? 'openrd' : stream];
  }

  void _cacheVideoSnapshot(VideoControlSnapshot snapshot) {
    _videoCloudState = snapshot.videoState;
    _videoTransport = snapshot.transport.isNotEmpty
        ? snapshot.transport
        : (snapshot.mode.isNotEmpty ? snapshot.mode : _videoTransport);
    final playUrl = snapshot.playUrl.trim();
    if (playUrl.isNotEmpty) {
      _cloudPlayUrl = playUrl;
    }
    final whepUrl = snapshot.whepUrl.trim();
    if (whepUrl.isNotEmpty) {
      _cloudWhepUrl = whepUrl;
    }
  }

  void _pushEvent(String message) {
    setState(() {
      _eventLog.insert(
        0,
        '[${DateTime.now().toIso8601String().substring(11, 19)}] $message',
      );
      if (_eventLog.length > 12) {
        _eventLog.removeLast();
      }
    });
  }

  void _handleControlLinkSnapshot(ControlLinkSnapshot snapshot) {
    final wasConnected = _controlLinkSnapshot.isConnected;
    setState(() {
      _controlLinkSnapshot = snapshot;
    });
    if (!wasConnected && snapshot.isConnected) {
      _queueControlSend(immediate: true);
    }
  }

  void _sendCommand(DriveCommand command) {
    setState(() {
      _lastCommand = command;
      switch (command) {
        case DriveCommand.forward:
          _throttle = 1.0;
          break;
        case DriveCommand.backward:
          _throttle = -1.0;
          break;
        case DriveCommand.left:
          _steering = -1.0;
          break;
        case DriveCommand.right:
          _steering = 1.0;
          break;
        case DriveCommand.stop:
          _steering = 0.0;
          _throttle = 0.0;
          break;
      }
    });
    _queueControlSend(immediate: command == DriveCommand.stop);
    _pushEvent('发送指令：${_commandLabel(command)}');
  }

  void _handleGamepadSnapshot(GamepadSnapshot snapshot) {
    final previous = _gamepadSnapshot;
    final connected = snapshot.connected;
    final applyDrive = connected && _manualMode;
    final stopPressed =
        connected && snapshot.stopPressed && !previous.stopPressed;
    final returnedToNeutral = previous.hasDriveInput && !snapshot.hasDriveInput;
    var nextSteering = _steering;
    var nextThrottle = _throttle;
    var nextCommand = _lastCommand;

    if (applyDrive) {
      if (snapshot.stopPressed) {
        nextSteering = 0.0;
        nextThrottle = 0.0;
        nextCommand = DriveCommand.stop;
      } else {
        nextSteering = snapshot.driveSteering;
        nextThrottle = snapshot.driveThrottle;
        nextCommand = _commandFromMotion(nextSteering, nextThrottle);
      }
    }

    setState(() {
      _gamepadSnapshot = snapshot;
      if (applyDrive) {
        _steering = nextSteering;
        _throttle = nextThrottle;
        _lastCommand = nextCommand;
      }
    });

    if (applyDrive) {
      _queueControlSend(immediate: snapshot.stopPressed);
    }

    if (!previous.connected && connected) {
      _pushEvent('手柄已连接：${snapshot.shortName}');
    } else if (previous.connected && !connected) {
      _pushEvent('手柄已断开');
    }

    if (stopPressed) {
      _pushEvent('手柄停止键触发');
    } else if (applyDrive && returnedToNeutral) {
      _pushEvent('手柄回中：停止');
    }
  }

  void _onJoystickChanged(Offset delta, double radius) {
    final normalizedX = ((delta.dx / radius).clamp(-1.0, 1.0)).toDouble();
    final normalizedY = ((delta.dy / radius).clamp(-1.0, 1.0)).toDouble();
    setState(() {
      _steering = normalizedX;
      _throttle = (-normalizedY).clamp(-1.0, 1.0);
      _lastCommand = _commandFromMotion(_steering, _throttle);
    });
    _queueControlSend();
  }

  void _onMobileDriveChanged(double steering, double throttle) {
    setState(() {
      _manualMode = true;
      _steering = steering.clamp(-1.0, 1.0).toDouble();
      _throttle = throttle.clamp(-1.0, 1.0).toDouble();
      _lastCommand = _commandFromMotion(_steering, _throttle);
    });
    _queueControlSend();
  }

  void _setMobileSpeedLimit(int value) {
    setState(() {
      _speedLimit = value.clamp(100, 500).toInt();
    });
    _queueControlSend();
    _pushEvent('手机端速度上限：$_speedLimit');
  }

  Future<void> _enterImmersiveMode() async {
    final ok = await requestImmersiveMode();
    _pushEvent(ok ? '已请求浏览器全屏' : '当前浏览器不支持网页全屏，请添加到主屏幕');
  }

  void _stopAll() {
    _sendCommand(DriveCommand.stop);
  }

  void _toggleControlLink() {
    if (_controlLinkSnapshot.isConnected ||
        _controlLinkSnapshot.state == ControlLinkState.connecting) {
      _controlLink.disconnect();
      _pushEvent('断开控制链路');
      return;
    }

    final endpoint = _controlEndpointController.text.trim();
    if (endpoint.isEmpty) {
      _pushEvent('控制链路地址为空');
      return;
    }

    _controlLink.connect(endpoint);
    _pushEvent('连接控制链路：$endpoint');
  }

  void _handleStreamConfigChanged() {
    setState(() {
      _cloudPlayUrl = '';
      _cloudWhepUrl = '';
      _streamReloadToken += 1;
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = '正在刷新视频地址';
    });
  }

  void _retryStream() {
    if (!_videoPlaybackEnabled && !_videoCommandBusy) {
      unawaited(_startVideoPush());
      return;
    }
    setState(() {
      _streamReloadToken += 1;
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = '正在手动重连视频流';
    });
    _pushEvent('重连视频流');
  }

  Future<void> _startVideoPush() async {
    if (_videoCommandBusy) {
      return;
    }

    setState(() {
      _videoCommandBusy = true;
      _videoPlaybackEnabled = false;
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = '正在请求云端启动视频推流';
    });
    _pushEvent('请求启动云端视频');

    try {
      final snapshot = await _videoControl.start(
        baseUrl: _videoControlUrl,
        vehicleId: _videoVehicleId,
        viewerId: _videoViewerId,
        ttlSec: _videoLeaseSec,
      );
      if (mounted) {
        setState(() {
          _cacheVideoSnapshot(snapshot);
        });
      }
      final running = await _waitForVideoRunning();
      if (!running) {
        throw StateError('视频推流启动超时');
      }
      _startVideoRenewTimer();
      if (!mounted) {
        return;
      }
      setState(() {
        _videoPlaybackEnabled = true;
        _streamReloadToken += 1;
        _streamState = StreamPlaybackState.loading;
        _streamStatusMessage = '正在打开云端视频流';
      });
      _pushEvent('云端视频推流已启动');
    } catch (error) {
      _videoRenewTimer?.cancel();
      if (!mounted) {
        return;
      }
      setState(() {
        _videoPlaybackEnabled = false;
        _streamState = StreamPlaybackState.error;
        _streamStatusMessage = error.toString();
      });
      _pushEvent('启动视频失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _videoCommandBusy = false;
        });
      }
    }
  }

  Future<void> _stopVideoPush() async {
    if (_videoCommandBusy) {
      return;
    }

    _videoRenewTimer?.cancel();
    setState(() {
      _videoCommandBusy = true;
      _videoPlaybackEnabled = false;
      _streamState = StreamPlaybackState.stopped;
      _streamStatusMessage = '正在停止视频推流';
    });
    _pushEvent('请求停止云端视频');

    try {
      await _videoControl.stop(
        baseUrl: _videoControlUrl,
        vehicleId: _videoVehicleId,
        viewerId: _videoViewerId,
      );
      await _refreshVideoCloudStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _streamState = StreamPlaybackState.stopped;
        _streamStatusMessage = '视频推流已停止';
      });
      _pushEvent('云端视频推流已停止');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _streamState = StreamPlaybackState.error;
        _streamStatusMessage = error.toString();
      });
      _pushEvent('停止视频失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _videoCommandBusy = false;
        });
      }
    }
  }

  Future<bool> _waitForVideoRunning() async {
    for (var attempt = 0; attempt < 25; attempt += 1) {
      final snapshot = await _videoControl.status(
        baseUrl: _videoControlUrl,
        vehicleId: _videoVehicleId,
      );
      if (!mounted) {
        return false;
      }
      setState(() {
        _cacheVideoSnapshot(snapshot);
        _streamStatusMessage = snapshot.running
            ? '视频推流已运行'
            : '等待车端启动视频推流：${snapshot.videoState}';
      });
      if (snapshot.running) {
        return true;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return false;
  }

  void _startVideoRenewTimer() {
    _videoRenewTimer?.cancel();
    _videoRenewTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_renewVideoLease());
    });
  }

  Future<void> _renewVideoLease() async {
    try {
      final snapshot = await _videoControl.renew(
        baseUrl: _videoControlUrl,
        vehicleId: _videoVehicleId,
        viewerId: _videoViewerId,
        ttlSec: _videoLeaseSec,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cacheVideoSnapshot(snapshot);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _streamStatusMessage = '视频续约失败：$error';
      });
      _pushEvent('视频续约失败：$error');
    }
  }

  Future<void> _refreshVideoCloudStatus() async {
    try {
      final snapshot = await _videoControl.status(
        baseUrl: _videoControlUrl,
        vehicleId: _videoVehicleId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cacheVideoSnapshot(snapshot);
        if (!_videoPlaybackEnabled &&
            !_videoCommandBusy &&
            _streamState != StreamPlaybackState.error) {
          _streamState = snapshot.running
              ? StreamPlaybackState.stopped
              : StreamPlaybackState.stopped;
          _streamStatusMessage = snapshot.running
              ? '视频推流正在运行，点击播放可接入'
              : '视频推流未启动';
        }
      });
    } catch (_) {
      if (!mounted || _videoPlaybackEnabled || _videoCommandBusy) {
        return;
      }
      setState(() {
        _videoCloudState = 'offline';
      });
    }
  }

  void _handleStreamReady() {
    if (!mounted) {
      return;
    }

    setState(() {
      _streamState = StreamPlaybackState.ready;
      _streamStatusMessage = '';
    });
  }

  void _handleStreamError(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _streamState = StreamPlaybackState.error;
      _streamStatusMessage = message;
    });
  }

  void _queueControlSend({bool immediate = false}) {
    if (immediate) {
      _flushControlIfNeeded(force: true);
    }
  }

  void _flushControlIfNeeded({bool force = false}) {
    final stop = _steering.abs() < 0.01 && _throttle.abs() < 0.01;
    if (!_controlLinkSnapshot.isConnected) {
      if (force) {
        _pushEvent('控制链路未连接，指令未发送');
      }
      return;
    }

    _controlSeq += 1;
    final message = DriveControlMessage(
      seq: _controlSeq,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      steering: _steering,
      throttle: _throttle,
      speedLimit: _speedLimit,
      stop: stop,
      source: _gamepadSnapshot.connected ? 'gamepad' : 'ui',
    );
    final sent = _controlLink.send(message);
    if (!sent && force) {
      _pushEvent('控制链路未连接，指令未发送');
    }
  }

  DriveCommand _commandFromMotion(double steering, double throttle) {
    if (steering.abs() < 0.05 && throttle.abs() < 0.05) {
      return DriveCommand.stop;
    }
    return throttle.abs() >= steering.abs()
        ? (throttle > 0 ? DriveCommand.forward : DriveCommand.backward)
        : (steering > 0 ? DriveCommand.right : DriveCommand.left);
  }

  String _commandLabel(DriveCommand command) {
    switch (command) {
      case DriveCommand.forward:
        return '前进';
      case DriveCommand.backward:
        return '后退';
      case DriveCommand.left:
        return '左转';
      case DriveCommand.right:
        return '右转';
      case DriveCommand.stop:
        return '停止';
    }
  }

  String _streamLabel() {
    switch (_streamState) {
      case StreamPlaybackState.stopped:
        return '未启动';
      case StreamPlaybackState.loading:
        return '加载中';
      case StreamPlaybackState.ready:
        return '已打开';
      case StreamPlaybackState.error:
        return '异常';
    }
  }

  Color _streamColor() {
    switch (_streamState) {
      case StreamPlaybackState.stopped:
        return const Color(0xFF607D8B);
      case StreamPlaybackState.loading:
        return const Color(0xFF1565C0);
      case StreamPlaybackState.ready:
        return const Color(0xFF2E7D32);
      case StreamPlaybackState.error:
        return const Color(0xFFC62828);
    }
  }

  IconData _streamIcon() {
    switch (_streamState) {
      case StreamPlaybackState.stopped:
        return Icons.videocam_off;
      case StreamPlaybackState.loading:
        return Icons.sync;
      case StreamPlaybackState.ready:
        return Icons.check_circle;
      case StreamPlaybackState.error:
        return Icons.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          final wideLayout = constraints.maxWidth >= 1180;
          final mobileDriveLayout =
              media.size.shortestSide < 600 || constraints.maxWidth < 720;
          final streamUrl = _streamUrl;
          final streamReaderUrl = _streamReaderUrl;
          final streamWhepUrl = _streamWhepUrl;
          if (mobileDriveLayout) {
            return _MobileDriveView(
              connectionState: _controlLinkSnapshot.stateLabel,
              controlActive:
                  _controlLinkSnapshot.isConnected ||
                  _controlLinkSnapshot.state == ControlLinkState.connecting,
              streamState: _streamLabel(),
              battery: _controlLinkSnapshot.battery,
              steering: _steering,
              throttle: _throttle,
              speedLimit: _speedLimit,
              lastCommand: _commandLabel(_lastCommand),
              endpoint: _controlLinkSnapshot.endpoint,
              streamUrl: streamUrl,
              streamReaderUrl: streamReaderUrl,
              streamWhepUrl: streamWhepUrl,
              streamViewKey: ValueKey(
                'mobile#$streamUrl#$streamWhepUrl#$_streamMuted#$_streamReloadToken#$_videoPlaybackEnabled',
              ),
              muted: _streamMuted,
              videoStatusMessage: _streamStatusMessage,
              playbackEnabled: _videoPlaybackEnabled,
              onToggleConnection: _toggleControlLink,
              onStop: _stopAll,
              onDriveChanged: _onMobileDriveChanged,
              onDriveReleased: _stopAll,
              onSpeedLimitSelected: _setMobileSpeedLimit,
              onEnterImmersive: _enterImmersiveMode,
              onReady: _handleStreamReady,
              onError: _handleStreamError,
            );
          }
          final statusBar = _DashboardStatusBar(
            connectionState: _controlLinkSnapshot.stateLabel,
            controlActive:
                _controlLinkSnapshot.isConnected ||
                _controlLinkSnapshot.state == ControlLinkState.connecting,
            streamState: _streamLabel(),
            streamColor: _streamColor(),
            gamepadState: _gamepadSnapshot.connected ? '已连接' : '未连接',
            gamepadConnected: _gamepadSnapshot.connected,
            battery: _controlLinkSnapshot.battery,
            manualMode: _manualMode,
            lastCommand: _commandLabel(_lastCommand),
            onToggleConnection: _toggleControlLink,
            onStop: _stopAll,
          );
          final videoPanel = _LiveVideoPanel(
            streamUrl: streamUrl,
            streamReaderUrl: streamReaderUrl,
            streamWhepUrl: streamWhepUrl,
            playbackEnabled: _videoPlaybackEnabled,
            videoBusy: _videoCommandBusy,
            videoCloudState: _videoCloudState,
            muted: _streamMuted,
            streamViewKey: ValueKey(
              '$streamUrl#$streamWhepUrl#$_streamMuted#$_streamReloadToken#$_videoPlaybackEnabled',
            ),
            streamState: _streamLabel(),
            streamStatusMessage: _streamStatusMessage,
            streamColor: _streamColor(),
            streamIcon: _streamIcon(),
            fillAvailable: wideLayout,
            onRetry: _retryStream,
            onStartVideo: _startVideoPush,
            onStopVideo: _stopVideoPush,
            onReady: _handleStreamReady,
            onError: _handleStreamError,
          );
          final drivePanel = _DriveControlPanel(
            endpoint: _controlLinkSnapshot.endpoint,
            controlSnapshot: _controlLinkSnapshot,
            manualMode: _manualMode,
            steering: _steering,
            throttle: _throttle,
            speedLimit: _speedLimit,
            battery: _controlLinkSnapshot.battery,
            lastCommand: _commandLabel(_lastCommand),
            gamepadSnapshot: _gamepadSnapshot,
            onModeChanged: (value) {
              setState(() {
                _manualMode = value;
              });
              _pushEvent(value ? '切换到手动模式' : '切换到自动预留模式');
            },
            onSpeedLimitChanged: (value) {
              setState(() {
                _speedLimit = value.round().clamp(100, 1000).toInt();
              });
              _queueControlSend();
            },
            onForward: () => _sendCommand(DriveCommand.forward),
            onBackward: () => _sendCommand(DriveCommand.backward),
            onLeft: () => _sendCommand(DriveCommand.left),
            onRight: () => _sendCommand(DriveCommand.right),
            onStop: _stopAll,
            onJoystickChanged: _onJoystickChanged,
            onJoystickReleased: _stopAll,
          );
          final debugPanel = _DebugPanel(
            eventLog: _eventLog,
            controlEndpointController: _controlEndpointController,
            controlSnapshot: _controlLinkSnapshot,
            hostController: _streamHostController,
            pathController: _streamPathController,
            videoControlController: _videoControlController,
            muted: _streamMuted,
            streamUrl: streamUrl,
            streamWhepUrl: streamWhepUrl,
            streamStatus: _streamLabel(),
            videoCloudState: _videoCloudState,
            videoTransport: _videoTransport,
            onMutedChanged: (value) {
              setState(() {
                _streamMuted = value;
              });
            },
            onStreamConfigChanged: _handleStreamConfigChanged,
          );

          return SafeArea(
            child: _DesktopDriveView(
              wideLayout: wideLayout,
              statusBar: statusBar,
              videoPanel: videoPanel,
              drivePanel: drivePanel,
              debugPanel: debugPanel,
            ),
          );
        },
      ),
    );
  }
}

class _DesktopDriveView extends StatelessWidget {
  const _DesktopDriveView({
    required this.wideLayout,
    required this.statusBar,
    required this.videoPanel,
    required this.drivePanel,
    required this.debugPanel,
  });

  final bool wideLayout;
  final Widget statusBar;
  final Widget videoPanel;
  final Widget drivePanel;
  final Widget debugPanel;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _desktopTheme(context),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050507), Color(0xFF101218), Color(0xFF050507)],
            stops: [0.0, 0.48, 1.0],
          ),
        ),
        child: wideLayout ? _buildWide() : _buildNarrow(),
      ),
    );
  }

  Widget _buildWide() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            children: [
              statusBar,
              const SizedBox(height: 18),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 7, child: videoPanel),
                    const SizedBox(width: 18),
                    SizedBox(
                      width: 372,
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            drivePanel,
                            const SizedBox(height: 14),
                            debugPanel,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNarrow() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              statusBar,
              const SizedBox(height: 14),
              videoPanel,
              const SizedBox(height: 14),
              drivePanel,
              const SizedBox(height: 14),
              debugPanel,
            ],
          ),
        ),
      ),
    );
  }
}

const double _mobileTouchCalibrationYOffset = -10.0;

class _MobileDriveView extends StatelessWidget {
  const _MobileDriveView({
    required this.connectionState,
    required this.controlActive,
    required this.streamState,
    required this.battery,
    required this.steering,
    required this.throttle,
    required this.speedLimit,
    required this.lastCommand,
    required this.endpoint,
    required this.streamUrl,
    required this.streamReaderUrl,
    required this.streamWhepUrl,
    required this.streamViewKey,
    required this.muted,
    required this.videoStatusMessage,
    required this.playbackEnabled,
    required this.onToggleConnection,
    required this.onStop,
    required this.onDriveChanged,
    required this.onDriveReleased,
    required this.onSpeedLimitSelected,
    required this.onEnterImmersive,
    required this.onReady,
    required this.onError,
  });

  final String connectionState;
  final bool controlActive;
  final String streamState;
  final DriverBatterySnapshot battery;
  final double steering;
  final double throttle;
  final int speedLimit;
  final String lastCommand;
  final String endpoint;
  final String streamUrl;
  final String streamReaderUrl;
  final String streamWhepUrl;
  final Key streamViewKey;
  final bool muted;
  final String videoStatusMessage;
  final bool playbackEnabled;
  final VoidCallback onToggleConnection;
  final VoidCallback onStop;
  final void Function(double steering, double throttle) onDriveChanged;
  final VoidCallback onDriveReleased;
  final ValueChanged<int> onSpeedLimitSelected;
  final VoidCallback onEnterImmersive;
  final VoidCallback onReady;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final edge = isLandscape ? 14.0 : 10.0;
    final viewSize = MediaQuery.sizeOf(context);
    final padSize = isLandscape
        ? math.min(160.0, math.max(132.0, viewSize.height * 0.40))
        : 190.0;
    final actionWidth = isLandscape ? 150.0 : 150.0;
    final readoutLeft = isLandscape ? edge + padSize + 34 : edge;
    final readoutRight = isLandscape ? edge + actionWidth + 34 : edge;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: playbackEnabled
              ? OpenRdStreamView(
                  key: streamViewKey,
                  url: streamUrl,
                  readerUrl: streamReaderUrl,
                  whepUrl: streamWhepUrl,
                  muted: muted,
                  onReady: onReady,
                  onError: onError,
                  placeholder: _MobileVideoPlaceholder(
                    playbackEnabled: playbackEnabled,
                    message: videoStatusMessage,
                  ),
                )
              : Align(
                  alignment: const Alignment(0.18, -0.02),
                  child: _MobileVideoPlaceholder(
                    playbackEnabled: playbackEnabled,
                    message: videoStatusMessage,
                  ),
                ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.58),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.42),
              ],
              stops: const [0.0, 0.42, 1.0],
            ),
          ),
        ),
        Positioned(
          left: edge,
          right: edge,
          top: edge,
          height: isLandscape ? 60 : null,
          child: _MobileStatusStrip(
            connectionState: connectionState,
            controlActive: controlActive,
            streamState: streamState,
            battery: battery,
            speedLimit: speedLimit,
            lastCommand: lastCommand,
            onEnterImmersive: onEnterImmersive,
          ),
        ),
        Positioned(
          left: edge,
          bottom: edge + 20,
          width: padSize,
          height: padSize,
          child: _MobileDrivePad(
            steering: steering,
            throttle: throttle,
            onChanged: onDriveChanged,
            onReleased: onDriveReleased,
          ),
        ),
        Positioned(
          right: edge,
          top: isLandscape ? edge + 76 : null,
          bottom: edge,
          width: actionWidth,
          height: isLandscape ? null : 204,
          child: _MobileActionRail(
            controlActive: controlActive,
            speedLimit: speedLimit,
            onStop: onStop,
            onSpeedLimitSelected: onSpeedLimitSelected,
          ),
        ),
        Positioned(
          left: readoutLeft,
          right: readoutRight,
          bottom: edge + 2,
          child: _MobileBottomReadout(
            steering: steering,
            throttle: throttle,
            endpoint: endpoint,
          ),
        ),
        Positioned(
          left: isLandscape ? readoutLeft : edge,
          bottom: isLandscape ? edge + 24 : edge + 228,
          width: isLandscape ? 220 : 190,
          height: 96,
          child: _MobileConnectButton(
            controlActive: controlActive,
            onPressed: onToggleConnection,
          ),
        ),
      ],
    );
  }
}

class _MobileVideoPlaceholder extends StatelessWidget {
  const _MobileVideoPlaceholder({
    required this.playbackEnabled,
    required this.message,
  });

  final bool playbackEnabled;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          playbackEnabled ? Icons.videocam : Icons.videocam_off,
          color: Colors.white.withValues(alpha: 0.38),
          size: 42,
        ),
        const SizedBox(height: 10),
        Text(
          playbackEnabled ? '视频画面' : '视频黑屏占位',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.72),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 360,
          child: Text(
            message.isNotEmpty ? message : 'iOS FLV 暂不支持，先保留驾驶 HUD',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.46),
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileStatusStrip extends StatelessWidget {
  const _MobileStatusStrip({
    required this.connectionState,
    required this.controlActive,
    required this.streamState,
    required this.battery,
    required this.speedLimit,
    required this.lastCommand,
    required this.onEnterImmersive,
  });

  final String connectionState;
  final bool controlActive;
  final String streamState;
  final DriverBatterySnapshot battery;
  final int speedLimit;
  final String lastCommand;
  final VoidCallback onEnterImmersive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _MobileStatusChip(
                    icon: controlActive ? Icons.link : Icons.link_off,
                    label: connectionState,
                    color: controlActive
                        ? const Color(0xFF66BB6A)
                        : const Color(0xFFFFB74D),
                  ),
                  const SizedBox(width: 6),
                  _MobileStatusChip(
                    icon: Icons.videocam,
                    label: streamState,
                    color: const Color(0xFF607D8B),
                  ),
                  const SizedBox(width: 6),
                  _MobileStatusChip(
                    icon: Icons.battery_full,
                    label: battery.available
                        ? '${battery.voltageV.toStringAsFixed(1)}V'
                        : '--.-V',
                    color: battery.available
                        ? const Color(0xFF66BB6A)
                        : const Color(0xFFFFB74D),
                  ),
                  const SizedBox(width: 6),
                  _MobileStatusChip(
                    icon: Icons.speed,
                    label: '$speedLimit',
                    color: const Color(0xFF64B5F6),
                  ),
                  const SizedBox(width: 6),
                  _MobileStatusChip(
                    icon: Icons.near_me,
                    label: lastCommand,
                    color: const Color(0xFFB0BEC5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            height: 40,
            child: IconButton.filledTonal(
              onPressed: onEnterImmersive,
              icon: const Icon(Icons.fullscreen),
              tooltip: '进入沉浸模式',
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileStatusChip extends StatelessWidget {
  const _MobileStatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileConnectButton extends StatelessWidget {
  const _MobileConnectButton({
    required this.controlActive,
    required this.onPressed,
  });

  final bool controlActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Center(
        child: SizedBox(
          width: 156,
          height: 48,
          child: IgnorePointer(
            child: FilledButton.icon(
              onPressed: onPressed,
              icon: Icon(controlActive ? Icons.link_off : Icons.link),
              label: Text(controlActive ? '断开' : '连接'),
              style: FilledButton.styleFrom(
                backgroundColor: controlActive
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFF1565C0),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileBottomReadout extends StatelessWidget {
  const _MobileBottomReadout({
    required this.steering,
    required this.throttle,
    required this.endpoint,
  });

  final double steering;
  final double throttle;
  final String endpoint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '方向 ${steering.toStringAsFixed(2)}   油门 ${throttle.toStringAsFixed(2)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              endpoint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileActionRail extends StatelessWidget {
  const _MobileActionRail({
    required this.controlActive,
    required this.speedLimit,
    required this.onStop,
    required this.onSpeedLimitSelected,
  });

  final bool controlActive;
  final int speedLimit;
  final VoidCallback onStop;
  final ValueChanged<int> onSpeedLimitSelected;

  @override
  Widget build(BuildContext context) {
    final speeds = <int>[200, 300, 500];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: _HudButton(
            label: 'STOP',
            icon: Icons.stop_circle,
            color: const Color(0xFFD32F2F),
            onPressed: onStop,
            compact: true,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _HudButton(
            label: 'ESTOP',
            icon: Icons.emergency,
            color: const Color(0xFF7F1D1D),
            onPressed: onStop,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.32),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final speed in speeds)
                ChoiceChip(
                  label: Text('$speed'),
                  selected: speedLimit == speed,
                  onSelected: (_) => onSpeedLimitSelected(speed),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          controlActive ? '触控区松手即停' : '连接后可驾驶',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}

class _HudButton extends StatelessWidget {
  const _HudButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.86),
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 18 : 28),
            if (!compact) const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: compact ? 14 : 26,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileDrivePad extends StatefulWidget {
  const _MobileDrivePad({
    required this.steering,
    required this.throttle,
    required this.onChanged,
    required this.onReleased,
  });

  final double steering;
  final double throttle;
  final void Function(double steering, double throttle) onChanged;
  final VoidCallback onReleased;

  @override
  State<_MobileDrivePad> createState() => _MobileDrivePadState();
}

class _MobileDrivePadState extends State<_MobileDrivePad> {
  int? _pointer;
  Offset _knob = Offset.zero;

  void _handlePointer(Offset localPosition, Size size) {
    final adjustedPosition =
        localPosition + const Offset(0, _mobileTouchCalibrationYOffset);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(36.0, math.min(size.width, size.height) / 2 - 14);
    final raw = adjustedPosition - center;
    final clamped = raw.distance > radius
        ? Offset.fromDirection(raw.direction, radius)
        : raw;
    final steering = (clamped.dx / radius).clamp(-1.0, 1.0).toDouble();
    final throttle = (-clamped.dy / radius).clamp(-1.0, 1.0).toDouble();

    setState(() {
      _knob = clamped;
    });
    widget.onChanged(_applyDeadzone(steering), _applyDeadzone(throttle));
  }

  double _applyDeadzone(double value) {
    if (value.abs() < 0.08) {
      return 0.0;
    }
    return value;
  }

  void _release() {
    if (_pointer == null && _knob == Offset.zero) {
      return;
    }
    setState(() {
      _pointer = null;
      _knob = Offset.zero;
    });
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointer != null) {
              return;
            }
            _pointer = event.pointer;
            _handlePointer(event.localPosition, size);
          },
          onPointerMove: (event) {
            if (_pointer != event.pointer) {
              return;
            }
            _handlePointer(event.localPosition, size);
          },
          onPointerUp: (event) {
            if (_pointer == event.pointer) {
              _release();
            }
          },
          onPointerCancel: (event) {
            if (_pointer == event.pointer) {
              _release();
            }
          },
          child: CustomPaint(
            painter: _MobileDrivePadPainter(knobOffset: _knob),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

class _MobileDrivePadPainter extends CustomPainter {
  _MobileDrivePadPainter({required this.knobOffset});

  final Offset knobOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(36.0, math.min(size.width, size.height) / 2 - 14);
    final glassPaint = Paint()..color = Colors.black.withValues(alpha: 0.26);
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.18);
    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.18);
    final activePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF64B5F6).withValues(alpha: 0.82);
    final knobPaint = Paint()
      ..color = const Color(0xFF64B5F6).withValues(alpha: 0.88);

    canvas.drawCircle(center, radius, glassPaint);
    canvas.drawCircle(center, radius, borderPaint);
    canvas.drawCircle(center, radius * 0.52, borderPaint);
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      axisPaint,
    );
    canvas.drawLine(center, center + knobOffset, activePaint);
    canvas.drawCircle(center + knobOffset, 20, knobPaint);
    canvas.drawCircle(
      center + knobOffset,
      20,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(covariant _MobileDrivePadPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset;
  }
}

class _DashboardStatusBar extends StatelessWidget {
  const _DashboardStatusBar({
    required this.connectionState,
    required this.controlActive,
    required this.streamState,
    required this.streamColor,
    required this.gamepadState,
    required this.gamepadConnected,
    required this.battery,
    required this.manualMode,
    required this.lastCommand,
    required this.onToggleConnection,
    required this.onStop,
  });

  final String connectionState;
  final bool controlActive;
  final String streamState;
  final Color streamColor;
  final String gamepadState;
  final bool gamepadConnected;
  final DriverBatterySnapshot battery;
  final bool manualMode;
  final String lastCommand;
  final VoidCallback onToggleConnection;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final title = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.navigation, size: 18),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'OpenRD Drive',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                    Text(
                      '远程驾驶舱',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: _desktopMutedText,
                      ),
                    ),
                  ],
                ),
              ],
            );
            final pills = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  icon: controlActive ? Icons.link : Icons.link_off,
                  label: '底盘',
                  value: connectionState,
                  color: controlActive ? _desktopGreen : _desktopOrange,
                ),
                _StatusPill(
                  icon: Icons.videocam,
                  label: '视频',
                  value: streamState,
                  color: streamColor,
                ),
                _StatusPill(
                  icon: Icons.gamepad,
                  label: '手柄',
                  value: gamepadState,
                  color: gamepadConnected ? _desktopGreen : _desktopOrange,
                ),
                _StatusPill(
                  icon: _batteryIcon(battery),
                  label: '电池',
                  value: _batterySummary(battery),
                  color: _batteryColor(battery),
                ),
                _StatusPill(
                  icon: Icons.tune,
                  label: '输入',
                  value: manualMode ? '手动' : '自动预留',
                  color: _desktopAccent,
                ),
                _StatusPill(
                  icon: Icons.near_me,
                  label: '指令',
                  value: lastCommand,
                  color: Colors.white70,
                ),
              ],
            );
            final actions = Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onToggleConnection,
                  icon: Icon(controlActive ? Icons.link_off : Icons.link),
                  label: Text(controlActive ? '断开' : '连接'),
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                FilledButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('紧急停止'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _desktopRed,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            );

            if (constraints.maxWidth >= 980) {
              return Row(
                children: [
                  title,
                  const SizedBox(width: 18),
                  Expanded(child: pills),
                  const SizedBox(width: 14),
                  actions,
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: 12),
                pills,
                const SizedBox(height: 12),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }

  String _batterySummary(DriverBatterySnapshot battery) {
    if (!battery.available) {
      return '未读取';
    }
    return '${battery.voltageV.toStringAsFixed(1)}V · ${_batteryPercent(battery).round()}%';
  }

  IconData _batteryIcon(DriverBatterySnapshot battery) {
    if (!battery.available) {
      return Icons.battery_unknown;
    }
    final percent = _batteryPercent(battery);
    if (percent >= 70) {
      return Icons.battery_full;
    }
    if (percent >= 35) {
      return Icons.battery_5_bar;
    }
    if (percent >= 15) {
      return Icons.battery_2_bar;
    }
    return Icons.battery_alert;
  }

  Color _batteryColor(DriverBatterySnapshot battery) {
    if (!battery.available) {
      return _desktopOrange;
    }
    if (battery.voltageV < 9.6) {
      return _desktopRed;
    }
    if (battery.voltageV < 10.2) {
      return _desktopOrange;
    }
    if (battery.voltageV < 10.8) {
      return const Color(0xFFFFD60A);
    }
    return _desktopGreen;
  }

  double _batteryPercent(DriverBatterySnapshot battery) {
    return (((battery.voltageV - 8.1) / (12.6 - 8.1)) * 100).clamp(0.0, 100.0);
  }
}

class _LiveVideoPanel extends StatelessWidget {
  const _LiveVideoPanel({
    required this.streamUrl,
    required this.streamReaderUrl,
    required this.streamWhepUrl,
    required this.playbackEnabled,
    required this.videoBusy,
    required this.videoCloudState,
    required this.muted,
    required this.streamViewKey,
    required this.streamState,
    required this.streamStatusMessage,
    required this.streamColor,
    required this.streamIcon,
    required this.fillAvailable,
    required this.onRetry,
    required this.onStartVideo,
    required this.onStopVideo,
    required this.onReady,
    required this.onError,
  });

  final String streamUrl;
  final String streamReaderUrl;
  final String streamWhepUrl;
  final bool playbackEnabled;
  final bool videoBusy;
  final String videoCloudState;
  final bool muted;
  final Key streamViewKey;
  final String streamState;
  final String streamStatusMessage;
  final Color streamColor;
  final IconData streamIcon;
  final bool fillAvailable;
  final VoidCallback onRetry;
  final VoidCallback onStartVideo;
  final VoidCallback onStopVideo;
  final VoidCallback onReady;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _VideoFrame(
      streamUrl: streamUrl,
      streamReaderUrl: streamReaderUrl,
      streamWhepUrl: streamWhepUrl,
      playbackEnabled: playbackEnabled,
      muted: muted,
      streamViewKey: streamViewKey,
      onReady: onReady,
      onError: onError,
    );

    final videoSurface = ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: frame),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.48),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.40),
                    ],
                    stops: const [0.0, 0.38, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            top: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LiveBadge(active: playbackEnabled),
                const SizedBox(width: 8),
                _InlineState(
                  icon: streamIcon,
                  value: streamState,
                  color: streamColor,
                ),
                const SizedBox(width: 8),
                _InlineState(
                  icon: Icons.cloud,
                  value: videoCloudState,
                  color: streamColor,
                ),
              ],
            ),
          ),
          Positioned(
            right: 14,
            top: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: videoBusy || playbackEnabled ? null : onStartVideo,
                  icon: const Icon(Icons.play_arrow),
                  tooltip: '启动视频推流',
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: videoBusy || !playbackEnabled ? null : onStopVideo,
                  icon: const Icon(Icons.stop),
                  tooltip: '停止视频推流',
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  tooltip: '重连视频',
                ),
              ],
            ),
          ),
          if (streamStatusMessage.isNotEmpty)
            Positioned(
              left: 18,
              right: 18,
              bottom: 16,
              child: Text(
                streamStatusMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.76),
                ),
              ),
            ),
        ],
      ),
    );

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
              child: Row(
                children: [
                  Text(
                    '实时视频',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    muted ? '静音预览' : '音频开启',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: _desktopMutedText,
                    ),
                  ),
                ],
              ),
            ),
            fillAvailable
                ? Expanded(child: videoSurface)
                : AspectRatio(aspectRatio: 16 / 9, child: videoSurface),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? _desktopRed : Colors.white70;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            active ? 'LIVE' : 'STANDBY',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoFrame extends StatelessWidget {
  const _VideoFrame({
    required this.streamUrl,
    required this.streamReaderUrl,
    required this.streamWhepUrl,
    required this.playbackEnabled,
    required this.muted,
    required this.streamViewKey,
    required this.onReady,
    required this.onError,
  });

  final String streamUrl;
  final String streamReaderUrl;
  final String streamWhepUrl;
  final bool playbackEnabled;
  final bool muted;
  final Key streamViewKey;
  final VoidCallback onReady;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: Colors.black,
        child: playbackEnabled
            ? OpenRdStreamView(
                key: streamViewKey,
                url: streamUrl,
                readerUrl: streamReaderUrl,
                whepUrl: streamWhepUrl,
                muted: muted,
                onReady: onReady,
                onError: onError,
                placeholder: _StreamFallback(
                  url: streamWhepUrl.isNotEmpty ? streamWhepUrl : streamUrl,
                ),
              )
            : _StreamFallback(
                url: streamWhepUrl.isNotEmpty ? streamWhepUrl : streamUrl,
                message: '视频推流未启动',
              ),
      ),
    );
  }
}

class _DriveControlPanel extends StatelessWidget {
  const _DriveControlPanel({
    required this.endpoint,
    required this.controlSnapshot,
    required this.manualMode,
    required this.steering,
    required this.throttle,
    required this.speedLimit,
    required this.battery,
    required this.lastCommand,
    required this.gamepadSnapshot,
    required this.onModeChanged,
    required this.onSpeedLimitChanged,
    required this.onForward,
    required this.onBackward,
    required this.onLeft,
    required this.onRight,
    required this.onStop,
    required this.onJoystickChanged,
    required this.onJoystickReleased,
  });

  final String endpoint;
  final ControlLinkSnapshot controlSnapshot;
  final bool manualMode;
  final double steering;
  final double throttle;
  final int speedLimit;
  final DriverBatterySnapshot battery;
  final String lastCommand;
  final GamepadSnapshot gamepadSnapshot;
  final ValueChanged<bool> onModeChanged;
  final ValueChanged<double> onSpeedLimitChanged;
  final VoidCallback onForward;
  final VoidCallback onBackward;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onStop;
  final void Function(Offset delta, double radius) onJoystickChanged;
  final VoidCallback onJoystickReleased;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = controlSnapshot.isConnected;

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: (connected ? _desktopGreen : _desktopOrange)
                        .withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    connected ? Icons.link : Icons.link_off,
                    size: 18,
                    color: connected ? _desktopGreen : _desktopOrange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '控制',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        manualMode ? '手动驾驶' : '自动预留',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _desktopMutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: manualMode, onChanged: onModeChanged),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SmallInfo(label: '目标', value: endpoint),
                _SmallInfo(label: '链路', value: controlSnapshot.stateLabel),
                _SmallInfo(label: '最近', value: lastCommand),
                _SmallInfo(label: '上限', value: '$speedLimit'),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('紧急停止'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: _desktopRed,
                foregroundColor: Colors.white,
                textStyle: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 18),
            _AxisMeter(label: '方向', value: steering, color: _desktopAccent),
            const SizedBox(height: 10),
            _AxisMeter(label: '油门', value: throttle, color: _desktopGreen),
            const SizedBox(height: 16),
            _SpeedLimitSlider(
              value: speedLimit,
              onChanged: onSpeedLimitChanged,
            ),
            const SizedBox(height: 16),
            _BatteryStatusCard(snapshot: battery),
            const SizedBox(height: 16),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.10)),
            const SizedBox(height: 16),
            _GamepadSummary(snapshot: gamepadSnapshot),
            const SizedBox(height: 16),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.10)),
            const SizedBox(height: 16),
            _BackupControls(
              onForward: onForward,
              onBackward: onBackward,
              onLeft: onLeft,
              onRight: onRight,
              onStop: onStop,
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.10)),
            const SizedBox(height: 16),
            _JoystickPad(
              maxSize: 196,
              onChanged: onJoystickChanged,
              onReleased: onJoystickReleased,
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedLimitSlider extends StatelessWidget {
  const _SpeedLimitSlider({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('速度上限', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              '$value',
              style: theme.textTheme.titleSmall?.copyWith(
                color: _desktopAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: 100,
          max: 1000,
          divisions: 9,
          label: '$value',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _BatteryStatusCard extends StatelessWidget {
  const _BatteryStatusCard({required this.snapshot});

  final DriverBatterySnapshot snapshot;

  static const double _fullVoltage = 12.6;
  static const double _cutoffVoltage = 8.1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = snapshot.available;
    final percent = available ? _percent(snapshot.voltageV) : 0.0;
    final color = _statusColor(snapshot);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_icon(snapshot), color: color),
                const SizedBox(width: 8),
                Text('电池', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  available
                      ? '${snapshot.voltageV.toStringAsFixed(1)}V'
                      : '--.-V',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: percent / 100.0,
                minHeight: 9,
                color: color,
                backgroundColor: color.withValues(alpha: 0.16),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  available ? '${percent.round()}%' : '等待读取',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                Text(
                  _stateText(snapshot),
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static double _percent(double voltage) {
    return (((voltage - _cutoffVoltage) / (_fullVoltage - _cutoffVoltage)) *
            100)
        .clamp(0.0, 100.0);
  }

  static String _stateText(DriverBatterySnapshot snapshot) {
    if (!snapshot.available) {
      return '连接后自动刷新';
    }
    if (snapshot.voltageV < 9.6) {
      return '建议停止';
    }
    if (snapshot.voltageV < 10.2) {
      return '建议限速';
    }
    if (snapshot.voltageV < 10.8) {
      return '低电提醒';
    }
    return '电量正常';
  }

  static Color _statusColor(DriverBatterySnapshot snapshot) {
    if (!snapshot.available) {
      return _desktopOrange;
    }
    if (snapshot.voltageV < 9.6) {
      return _desktopRed;
    }
    if (snapshot.voltageV < 10.2) {
      return _desktopOrange;
    }
    if (snapshot.voltageV < 10.8) {
      return const Color(0xFFFFD60A);
    }
    return _desktopGreen;
  }

  static IconData _icon(DriverBatterySnapshot snapshot) {
    if (!snapshot.available) {
      return Icons.battery_unknown;
    }
    final percent = _percent(snapshot.voltageV);
    if (percent >= 70) {
      return Icons.battery_full;
    }
    if (percent >= 35) {
      return Icons.battery_5_bar;
    }
    if (percent >= 15) {
      return Icons.battery_2_bar;
    }
    return Icons.battery_alert;
  }
}

class _GamepadSummary extends StatelessWidget {
  const _GamepadSummary({required this.snapshot});

  final GamepadSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = !snapshot.supported
        ? _desktopRed
        : snapshot.connected
        ? _desktopGreen
        : _desktopOrange;
    final pressedButtons = snapshot.pressedButtonLabels;
    final buttonText = pressedButtons.isEmpty ? '无' : pressedButtons.join(' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.gamepad, color: statusColor),
            const SizedBox(width: 8),
            Text('手柄输入', style: theme.textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SmallInfo(label: '状态', value: _statusLabel(snapshot)),
            _SmallInfo(label: '设备', value: snapshot.shortName),
            _SmallInfo(label: '按键', value: buttonText),
          ],
        ),
      ],
    );
  }

  String _statusLabel(GamepadSnapshot snapshot) {
    if (!snapshot.supported) {
      return '不支持';
    }
    return snapshot.connected ? '已连接' : '未连接';
  }
}

class _BackupControls extends StatelessWidget {
  const _BackupControls({
    required this.onForward,
    required this.onBackward,
    required this.onLeft,
    required this.onRight,
    required this.onStop,
  });

  final VoidCallback onForward;
  final VoidCallback onBackward;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    Widget button({
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
      Color? color,
    }) {
      return SizedBox(
        height: 46,
        child: FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
          style: FilledButton.styleFrom(
            foregroundColor: color ?? Colors.white,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
          ),
        ),
      );
    }

    Widget holdButton({
      required IconData icon,
      required String label,
      required VoidCallback onHoldStart,
    }) {
      return _HoldDriveButton(
        icon: icon,
        label: label,
        onHoldStart: onHoldStart,
        onHoldEnd: onStop,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('备用控制', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            Expanded(
              child: holdButton(
                icon: Icons.keyboard_arrow_up,
                label: '前进',
                onHoldStart: onForward,
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: holdButton(
                icon: Icons.keyboard_arrow_left,
                label: '左转',
                onHoldStart: onLeft,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: button(
                icon: Icons.stop_circle_outlined,
                label: '停止',
                onPressed: onStop,
                color: _desktopRed,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: holdButton(
                icon: Icons.keyboard_arrow_right,
                label: '右转',
                onHoldStart: onRight,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            Expanded(
              child: holdButton(
                icon: Icons.keyboard_arrow_down,
                label: '后退',
                onHoldStart: onBackward,
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ],
    );
  }
}

class _HoldDriveButton extends StatefulWidget {
  const _HoldDriveButton({
    required this.icon,
    required this.label,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final IconData icon;
  final String label;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<_HoldDriveButton> createState() => _HoldDriveButtonState();
}

class _HoldDriveButtonState extends State<_HoldDriveButton> {
  bool _holding = false;

  void _startHold() {
    if (_holding) {
      return;
    }
    setState(() {
      _holding = true;
    });
    widget.onHoldStart();
  }

  void _endHold() {
    if (!_holding) {
      return;
    }
    setState(() {
      _holding = false;
    });
    widget.onHoldEnd();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _startHold(),
      onPointerUp: (_) => _endHold(),
      onPointerCancel: (_) => _endHold(),
      onPointerPanZoomStart: (_) => _startHold(),
      onPointerPanZoomEnd: (_) => _endHold(),
      child: MouseRegion(
        onExit: (_) => _endHold(),
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          height: 46,
          child: FilledButton.tonalIcon(
            onPressed: () {},
            icon: Icon(widget.icon),
            label: Text(widget.label),
            style: FilledButton.styleFrom(
              backgroundColor: _holding
                  ? _desktopAccent.withValues(alpha: 0.26)
                  : Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _JoystickPad extends StatefulWidget {
  const _JoystickPad({
    required this.maxSize,
    required this.onChanged,
    required this.onReleased,
  });

  final double maxSize;
  final void Function(Offset delta, double radius) onChanged;
  final VoidCallback onReleased;

  @override
  State<_JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<_JoystickPad> {
  Offset _delta = Offset.zero;
  bool _dragging = false;

  void _reset() {
    setState(() {
      _delta = Offset.zero;
      _dragging = false;
    });
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('触屏输入', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, widget.maxSize);
            return Center(
              child: GestureDetector(
                onPanStart: (_) => setState(() => _dragging = true),
                onPanUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final local = box.globalToLocal(details.globalPosition);
                  final localCenter = Offset(
                    box.size.width / 2,
                    box.size.height / 2,
                  );
                  final radius = size / 2 - 12;
                  final raw = local - localCenter;
                  final clamped = raw.distance > radius
                      ? Offset.fromDirection(raw.direction, radius)
                      : raw;
                  setState(() => _delta = clamped);
                  widget.onChanged(clamped, radius);
                },
                onPanEnd: (_) => _reset(),
                onPanCancel: _reset,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(
                    painter: _JoystickPainter(
                      knobOffset: _delta,
                      dragging: _dragging,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({required this.knobOffset, required this.dragging});

  final Offset knobOffset;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    final basePaint = Paint()..color = Colors.white.withValues(alpha: 0.055);
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: dragging ? 0.30 : 0.18);
    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.20);
    final knobPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_desktopAccent, Color(0xFF66D4FF)],
      ).createShader(Rect.fromCircle(center: center + knobOffset, radius: 28));
    final knobRadius = dragging ? 24.0 : 21.0;

    canvas.drawCircle(center, radius, basePaint);
    canvas.drawCircle(center, radius, borderPaint);
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      axisPaint,
    );
    canvas.drawCircle(center + knobOffset, knobRadius, knobPaint);
    canvas.drawCircle(
      center + knobOffset,
      knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset ||
        oldDelegate.dragging != dragging;
  }
}

class _DebugPanel extends StatelessWidget {
  const _DebugPanel({
    required this.eventLog,
    required this.controlEndpointController,
    required this.controlSnapshot,
    required this.hostController,
    required this.pathController,
    required this.videoControlController,
    required this.muted,
    required this.streamUrl,
    required this.streamWhepUrl,
    required this.streamStatus,
    required this.videoCloudState,
    required this.videoTransport,
    required this.onMutedChanged,
    required this.onStreamConfigChanged,
  });

  final List<String> eventLog;
  final TextEditingController controlEndpointController;
  final ControlLinkSnapshot controlSnapshot;
  final TextEditingController hostController;
  final TextEditingController pathController;
  final TextEditingController videoControlController;
  final bool muted;
  final String streamUrl;
  final String streamWhepUrl;
  final String streamStatus;
  final String videoCloudState;
  final String videoTransport;
  final ValueChanged<bool> onMutedChanged;
  final VoidCallback onStreamConfigChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SurfacePanel(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white54,
        title: Text(
          '系统检查器',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          '$streamStatus · $videoTransport · $streamWhepUrl',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: _desktopMutedText),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('控制链路', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  controller: controlEndpointController,
                  decoration: const InputDecoration(
                    labelText: '控制地址',
                    helperText: 'OpenRD-Driver HTTP 或 WebSocket',
                  ),
                ),
              ),
              _SmallInfo(label: '状态', value: controlSnapshot.stateLabel),
              _SmallInfo(label: '发送', value: '${controlSnapshot.sentCount}'),
              _SmallInfo(
                label: '接收',
                value: '${controlSnapshot.receivedCount}',
              ),
            ],
          ),
          if (controlSnapshot.lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                controlSnapshot.lastError,
                style: theme.textTheme.bodySmall?.copyWith(color: _desktopRed),
              ),
            ),
          ],
          if (controlSnapshot.lastSent != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'last tx: ${controlSnapshot.lastSent!.toJson()}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          if (controlSnapshot.lastReceived.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'last rx: ${controlSnapshot.lastReceived}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('视频配置', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: TextField(
                  controller: hostController,
                  decoration: const InputDecoration(labelText: 'ZLM Host'),
                  onChanged: (_) => onStreamConfigChanged(),
                ),
              ),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: pathController,
                  decoration: const InputDecoration(labelText: 'Path'),
                  onChanged: (_) => onStreamConfigChanged(),
                ),
              ),
              SizedBox(
                width: 250,
                child: TextField(
                  controller: videoControlController,
                  decoration: const InputDecoration(labelText: 'Cloud API'),
                ),
              ),
              FilterChip(
                label: const Text('静音'),
                selected: muted,
                onSelected: onMutedChanged,
              ),
              _SmallInfo(label: '云端', value: videoCloudState),
              _SmallInfo(label: '传输', value: videoTransport),
              _SmallInfo(label: 'FLV', value: streamUrl),
              _SmallInfo(label: 'WHEP', value: streamWhepUrl),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('事件日志', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: eventLog.length,
              itemBuilder: (context, index) {
                return Text(eventLog[index], style: theme.textTheme.bodySmall);
              },
              separatorBuilder: (context, index) => const SizedBox(height: 6),
            ),
          ),
        ],
      ),
    );
  }
}

class _AxisMeter extends StatelessWidget {
  const _AxisMeter({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final normalized = ((value.clamp(-1.0, 1.0) + 1.0) / 2.0).toDouble();
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: _desktopMutedText,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: normalized,
              minHeight: 8,
              color: color,
              backgroundColor: Colors.white.withValues(alpha: 0.10),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 52,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: theme.textTheme.labelLarge?.copyWith(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 36, maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.26)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: _desktopMutedText,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineState extends StatelessWidget {
  const _InlineState({
    required this.icon,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        border: Border.all(color: color.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 15),
          const SizedBox(width: 5),
          Text(
            value,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallInfo extends StatelessWidget {
  const _SmallInfo({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 32, maxWidth: 330),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.065),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: _desktopMutedText,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Material(
          color: _desktopPanel,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: _desktopStroke),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _StreamFallback extends StatelessWidget {
  const _StreamFallback({required this.url, this.message = '视频预览加载中'});

  final String url;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off_outlined,
              size: 44,
              color: Colors.white.withValues(alpha: 0.42),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.78),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              url,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.46),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
