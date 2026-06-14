import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'control_link.dart';
import 'gamepad_input.dart';
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

enum StreamPlaybackState { loading, ready, error }

class ControlDashboardPage extends StatefulWidget {
  const ControlDashboardPage({super.key});

  @override
  State<ControlDashboardPage> createState() => _ControlDashboardPageState();
}

class _ControlDashboardPageState extends State<ControlDashboardPage> {
  DriveCommand _lastCommand = DriveCommand.stop;
  final TextEditingController _controlEndpointController =
      TextEditingController(text: 'ws://127.0.0.1:8080/control');
  bool _manualMode = true;
  double _steering = 0.0;
  double _throttle = 0.0;
  bool _streamMuted = true;
  int _streamReloadToken = 0;
  StreamPlaybackState _streamState = StreamPlaybackState.loading;
  String _streamStatusMessage = '正在加载视频流';

  late final ControlLink _controlLink = ControlLink(
    endpoint: _controlEndpointController.text.trim(),
  );
  StreamSubscription<ControlLinkSnapshot>? _controlLinkSubscription;
  ControlLinkSnapshot _controlLinkSnapshot = ControlLinkSnapshot.initial(
    'ws://127.0.0.1:8080/control',
  );
  Timer? _controlSendTimer;
  int _controlSeq = 0;

  final GamepadInput _gamepadInput = GamepadInput();
  StreamSubscription<GamepadSnapshot>? _gamepadSubscription;
  GamepadSnapshot _gamepadSnapshot = GamepadSnapshot.disconnected();
  final TextEditingController _streamHostController = TextEditingController(
    text: '192.168.100.108',
  );
  final TextEditingController _streamPathController = TextEditingController(
    text: 'live',
  );
  final List<String> _eventLog = <String>['OpenRD 控制台已启动'];

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _controlSendTimer?.cancel();
    _controlLinkSubscription?.cancel();
    _controlLink.dispose();
    _gamepadSubscription?.cancel();
    _gamepadInput.dispose();
    _controlEndpointController.dispose();
    _streamHostController.dispose();
    _streamPathController.dispose();
    super.dispose();
  }

  String get _streamUrl {
    final host = _normalizedHost();
    final pathSegments = _pathSegments();
    return Uri(
      scheme: 'http',
      host: host,
      port: 8889,
      pathSegments: <String>[...pathSegments, ''],
    ).toString();
  }

  String get _streamReaderUrl {
    final host = _normalizedHost();
    final pathSegments = _pathSegments();
    return Uri(
      scheme: 'http',
      host: host,
      port: 8889,
      pathSegments: <String>[...pathSegments, 'reader.js'],
    ).toString();
  }

  String get _streamWhepUrl {
    final host = _normalizedHost();
    final pathSegments = _pathSegments();
    return Uri(
      scheme: 'http',
      host: host,
      port: 8889,
      pathSegments: <String>[...pathSegments, 'whep'],
    ).toString();
  }

  String _normalizedHost() {
    final host = _streamHostController.text.trim();
    if (host.isEmpty) {
      return '192.168.100.108';
    }

    return host.replaceFirst(RegExp(r'^https?://'), '');
  }

  String _normalizedPath() {
    final path = _streamPathController.text.trim();
    if (path.isEmpty) {
      return 'live';
    }

    return path.startsWith('/') ? path.substring(1) : path;
  }

  List<String> _pathSegments() {
    return _normalizedPath()
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
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

  void _markStreamLoading(String message) {
    setState(() {
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = message;
    });
  }

  void _retryStream() {
    setState(() {
      _streamReloadToken += 1;
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = '正在手动重连视频流';
    });
    _pushEvent('重连视频流');
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
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wideLayout = constraints.maxWidth >= 1180;
            final streamUrl = _streamUrl;
            final streamReaderUrl = _streamReaderUrl;
            final streamWhepUrl = _streamWhepUrl;
            final statusBar = _DashboardStatusBar(
              connectionState: _controlLinkSnapshot.stateLabel,
              controlActive:
                  _controlLinkSnapshot.isConnected ||
                  _controlLinkSnapshot.state == ControlLinkState.connecting,
              streamState: _streamLabel(),
              streamColor: _streamColor(),
              gamepadState: _gamepadSnapshot.connected ? '已连接' : '未连接',
              gamepadConnected: _gamepadSnapshot.connected,
              manualMode: _manualMode,
              lastCommand: _commandLabel(_lastCommand),
              onToggleConnection: _toggleControlLink,
              onStop: _stopAll,
            );
            final videoPanel = _LiveVideoPanel(
              streamUrl: streamUrl,
              streamReaderUrl: streamReaderUrl,
              streamWhepUrl: streamWhepUrl,
              muted: _streamMuted,
              streamViewKey: ValueKey(
                '$streamUrl#$_streamMuted#$_streamReloadToken',
              ),
              streamState: _streamLabel(),
              streamStatusMessage: _streamStatusMessage,
              streamColor: _streamColor(),
              streamIcon: _streamIcon(),
              fillAvailable: wideLayout,
              onRetry: _retryStream,
              onReady: _handleStreamReady,
              onError: _handleStreamError,
            );
            final drivePanel = _DriveControlPanel(
              endpoint: _controlLinkSnapshot.endpoint,
              controlSnapshot: _controlLinkSnapshot,
              manualMode: _manualMode,
              steering: _steering,
              throttle: _throttle,
              lastCommand: _commandLabel(_lastCommand),
              gamepadSnapshot: _gamepadSnapshot,
              onModeChanged: (value) {
                setState(() {
                  _manualMode = value;
                });
                _pushEvent(value ? '切换到手动模式' : '切换到自动预留模式');
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
              muted: _streamMuted,
              streamUrl: streamUrl,
              streamStatus: _streamLabel(),
              onMutedChanged: (value) {
                setState(() {
                  _streamMuted = value;
                });
              },
              onStreamConfigChanged: () => _markStreamLoading('正在刷新视频地址'),
            );

            if (wideLayout) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: statusBar,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: videoPanel),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 380,
                            child: SingleChildScrollView(child: drivePanel),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(padding: const EdgeInsets.all(12), child: debugPanel),
                ],
              );
            }

            return SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  statusBar,
                  const SizedBox(height: 12),
                  videoPanel,
                  const SizedBox(height: 12),
                  drivePanel,
                  const SizedBox(height: 12),
                  debugPanel,
                ],
              ),
            );
          },
        ),
      ),
    );
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
  final bool manualMode;
  final String lastCommand;
  final VoidCallback onToggleConnection;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final title = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.route, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'OpenRD 远程驾驶控制台',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            );
            final pills = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusPill(
                  icon: controlActive ? Icons.link : Icons.link_off,
                  label: '车端',
                  value: connectionState,
                  color: controlActive
                      ? const Color(0xFF2E7D32)
                      : Colors.orange,
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
                  color: gamepadConnected
                      ? const Color(0xFF2E7D32)
                      : Colors.orange,
                ),
                _StatusPill(
                  icon: Icons.tune,
                  label: '输入',
                  value: manualMode ? '手动' : '自动预留',
                  color: const Color(0xFF1565C0),
                ),
                _StatusPill(
                  icon: Icons.near_me,
                  label: '指令',
                  value: lastCommand,
                  color: const Color(0xFF455A64),
                ),
              ],
            );
            final actions = Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onToggleConnection,
                  icon: Icon(controlActive ? Icons.link_off : Icons.link),
                  label: Text(controlActive ? '断开' : '连接'),
                ),
                FilledButton.icon(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('急停'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFC62828),
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            );

            if (constraints.maxWidth >= 980) {
              return Row(
                children: [
                  title,
                  const SizedBox(width: 16),
                  Expanded(child: pills),
                  const SizedBox(width: 12),
                  actions,
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: 10),
                pills,
                const SizedBox(height: 10),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LiveVideoPanel extends StatelessWidget {
  const _LiveVideoPanel({
    required this.streamUrl,
    required this.streamReaderUrl,
    required this.streamWhepUrl,
    required this.muted,
    required this.streamViewKey,
    required this.streamState,
    required this.streamStatusMessage,
    required this.streamColor,
    required this.streamIcon,
    required this.fillAvailable,
    required this.onRetry,
    required this.onReady,
    required this.onError,
  });

  final String streamUrl;
  final String streamReaderUrl;
  final String streamWhepUrl;
  final bool muted;
  final Key streamViewKey;
  final String streamState;
  final String streamStatusMessage;
  final Color streamColor;
  final IconData streamIcon;
  final bool fillAvailable;
  final VoidCallback onRetry;
  final VoidCallback onReady;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frame = _VideoFrame(
      streamUrl: streamUrl,
      streamReaderUrl: streamReaderUrl,
      streamWhepUrl: streamWhepUrl,
      muted: muted,
      streamViewKey: streamViewKey,
      onReady: onReady,
      onError: onError,
    );

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.videocam, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('实时视频', style: theme.textTheme.titleMedium),
                const SizedBox(width: 10),
                _InlineState(
                  icon: streamIcon,
                  value: streamState,
                  color: streamColor,
                ),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  tooltip: '重连视频',
                ),
              ],
            ),
            if (streamStatusMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                streamStatusMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            fillAvailable
                ? Expanded(
                    child: Center(
                      child: AspectRatio(aspectRatio: 16 / 9, child: frame),
                    ),
                  )
                : AspectRatio(aspectRatio: 16 / 9, child: frame),
          ],
        ),
      ),
    );
  }
}

class _VideoFrame extends StatelessWidget {
  const _VideoFrame({
    required this.streamUrl,
    required this.streamReaderUrl,
    required this.streamWhepUrl,
    required this.muted,
    required this.streamViewKey,
    required this.onReady,
    required this.onError,
  });

  final String streamUrl;
  final String streamReaderUrl;
  final String streamWhepUrl;
  final bool muted;
  final Key streamViewKey;
  final VoidCallback onReady;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.black,
        child: OpenRdStreamView(
          key: streamViewKey,
          url: streamUrl,
          readerUrl: streamReaderUrl,
          whepUrl: streamWhepUrl,
          muted: muted,
          onReady: onReady,
          onError: onError,
          placeholder: _StreamFallback(url: streamUrl),
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
    required this.lastCommand,
    required this.gamepadSnapshot,
    required this.onModeChanged,
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
  final String lastCommand;
  final GamepadSnapshot gamepadSnapshot;
  final ValueChanged<bool> onModeChanged;
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

    return _SurfacePanel(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('驾驶控制', style: theme.textTheme.titleMedium),
                const Spacer(),
                Switch.adaptive(value: manualMode, onChanged: onModeChanged),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SmallInfo(label: '目标', value: endpoint),
                _SmallInfo(label: '链路', value: controlSnapshot.stateLabel),
                _SmallInfo(label: '最近', value: lastCommand),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('急停'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: const Color(0xFFC62828),
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 14),
            _AxisMeter(
              label: '方向',
              value: steering,
              color: const Color(0xFF1565C0),
            ),
            const SizedBox(height: 8),
            _AxisMeter(
              label: '油门',
              value: throttle,
              color: const Color(0xFF2E7D32),
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _GamepadSummary(snapshot: gamepadSnapshot),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _BackupControls(
              onForward: onForward,
              onBackward: onBackward,
              onLeft: onLeft,
              onRight: onRight,
              onStop: onStop,
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _JoystickPad(
              maxSize: 220,
              onChanged: onJoystickChanged,
              onReleased: onJoystickReleased,
            ),
          ],
        ),
      ),
    );
  }
}

class _GamepadSummary extends StatelessWidget {
  const _GamepadSummary({required this.snapshot});

  final GamepadSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = !snapshot.supported
        ? const Color(0xFFC62828)
        : snapshot.connected
        ? const Color(0xFF2E7D32)
        : Colors.orange;
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
          style: color == null
              ? null
              : FilledButton.styleFrom(foregroundColor: color),
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
                color: const Color(0xFFC62828),
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
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              foregroundColor: _holding
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : null,
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
    final basePaint = Paint()..color = const Color(0xFFECEFF1);
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFB0BEC5);
    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = const Color(0xFF90A4AE);
    final knobPaint = Paint()..color = const Color(0xFF1565C0);
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
    required this.muted,
    required this.streamUrl,
    required this.streamStatus,
    required this.onMutedChanged,
    required this.onStreamConfigChanged,
  });

  final List<String> eventLog;
  final TextEditingController controlEndpointController;
  final ControlLinkSnapshot controlSnapshot;
  final TextEditingController hostController;
  final TextEditingController pathController;
  final bool muted;
  final String streamUrl;
  final String streamStatus;
  final ValueChanged<bool> onMutedChanged;
  final VoidCallback onStreamConfigChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _SurfacePanel(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text('调试', style: theme.textTheme.titleSmall),
        subtitle: Text(
          '$streamStatus  ·  $streamUrl',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
                  decoration: const InputDecoration(labelText: 'WebSocket'),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFC62828),
                ),
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
                  decoration: const InputDecoration(labelText: 'RK IP'),
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
              FilterChip(
                label: const Text('静音'),
                selected: muted,
                onSelected: onMutedChanged,
              ),
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
          child: Text(label, style: theme.textTheme.labelLarge),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: normalized,
              minHeight: 10,
              color: color,
              backgroundColor: color.withValues(alpha: 0.14),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 52,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: theme.textTheme.labelLarge,
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.labelSmall),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
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
    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFE0E5EA)),
      ),
      child: child,
    );
  }
}

class _StreamFallback extends StatelessWidget {
  const _StreamFallback({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Text(
          '视频预览加载中\n$url',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      ),
    );
  }
}
