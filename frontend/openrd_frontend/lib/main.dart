import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
        useMaterial3: true,
      ),
      home: const ControlDashboardPage(),
    );
  }
}

enum DriveCommand { forward, backward, left, right, stop }

enum StreamProtocol { webrtc }

enum StreamPlaybackState { loading, ready, error }

class ControlDashboardPage extends StatefulWidget {
  const ControlDashboardPage({super.key});

  @override
  State<ControlDashboardPage> createState() => _ControlDashboardPageState();
}

class _ControlDashboardPageState extends State<ControlDashboardPage> {
  DriveCommand _lastCommand = DriveCommand.stop;
  String _connectionState = '未连接';
  final String _targetEndpoint = 'ws://<rk-ip>:8080/control';
  bool _manualMode = true;
  double _steering = 0.0;
  double _throttle = 0.0;
  bool _streamMuted = true;
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
    _gamepadSubscription = _gamepadInput.snapshots.listen(
      _handleGamepadSnapshot,
    );
    _gamepadInput.start();
  }

  @override
  void dispose() {
    _gamepadSubscription?.cancel();
    _gamepadInput.dispose();
    _streamHostController.dispose();
    _streamPathController.dispose();
    super.dispose();
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
    final normalizedX = (delta.dx / radius).clamp(-1.0, 1.0);
    final normalizedY = (delta.dy / radius).clamp(-1.0, 1.0);
    setState(() {
      _steering = normalizedX;
      _throttle = (-normalizedY).clamp(-1.0, 1.0);
      _lastCommand = _commandFromMotion(_steering, _throttle);
    });
  }

  void _stopAll() {
    _sendCommand(DriveCommand.stop);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = _connectionState == '已连接';

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenRD 远程驾驶控制台'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: () {
                  setState(() {
                    _connectionState = isConnected ? '未连接' : '已连接';
                  });
                  _pushEvent(isConnected ? '断开控制端' : '连接控制端');
                },
                icon: Icon(isConnected ? Icons.link_off : Icons.link),
                label: Text(isConnected ? '断开' : '连接'),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wideLayout = constraints.maxWidth >= 1180;
          final twoColumnControls = constraints.maxWidth >= 760;
          final videoSection = _LiveVideoCard(
            theme: theme,
            hostController: _streamHostController,
            pathController: _streamPathController,
            muted: _streamMuted,
            onMutedChanged: (value) {
              setState(() {
                _streamMuted = value;
              });
            },
          );
          final statusPanel = _StatusCard(
            connectionState: _connectionState,
            endpoint: _targetEndpoint,
            lastCommand: _commandLabel(_lastCommand),
            manualMode: _manualMode,
            steering: _steering,
            throttle: _throttle,
            onModeChanged: (value) {
              setState(() {
                _manualMode = value;
              });
              _pushEvent(value ? '切换到手动模式' : '切换到自动预留模式');
            },
          );

          final commandPanel = _CommandGrid(
            onForward: () => _sendCommand(DriveCommand.forward),
            onBackward: () => _sendCommand(DriveCommand.backward),
            onLeft: () => _sendCommand(DriveCommand.left),
            onRight: () => _sendCommand(DriveCommand.right),
            onStop: _stopAll,
          );

          final gamepadPanel = _GamepadCard(snapshot: _gamepadSnapshot);

          final joystickPanel = _JoystickCard(
            steering: _steering,
            throttle: _throttle,
            maxSize: wideLayout ? 220 : 300,
            onChanged: _onJoystickChanged,
            onReleased: _stopAll,
          );

          final controlColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              statusPanel,
              const SizedBox(height: 16),
              gamepadPanel,
              const SizedBox(height: 16),
              commandPanel,
            ],
          );

          final sideControlColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              controlColumn,
              const SizedBox(height: 16),
              joystickPanel,
            ],
          );

          final logPanel = _EventLogCard(eventLog: _eventLog);

          final Widget content;
          if (wideLayout) {
            content = Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 10, child: videoSection),
                    const SizedBox(width: 16),
                    SizedBox(width: 360, child: sideControlColumn),
                  ],
                ),
                const SizedBox(height: 16),
                logPanel,
              ],
            );
          } else {
            content = Column(
              children: [
                videoSection,
                const SizedBox(height: 16),
                twoColumnControls
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: controlColumn),
                          const SizedBox(width: 16),
                          Expanded(flex: 4, child: joystickPanel),
                        ],
                      )
                    : Column(
                        children: [
                          controlColumn,
                          const SizedBox(height: 16),
                          joystickPanel,
                        ],
                      ),
                const SizedBox(height: 16),
                logPanel,
              ],
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1600),
                child: content,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.connectionState,
    required this.endpoint,
    required this.lastCommand,
    required this.manualMode,
    required this.steering,
    required this.throttle,
    required this.onModeChanged,
  });

  final String connectionState;
  final String endpoint;
  final String lastCommand;
  final bool manualMode;
  final double steering;
  final double throttle;
  final ValueChanged<bool> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final connectionColor = connectionState == '已连接'
        ? Colors.green
        : Colors.orange;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sensors, color: connectionColor),
                const SizedBox(width: 8),
                Text('控制状态', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _InfoChip(label: '连接', value: connectionState),
                _InfoChip(label: '目标', value: endpoint),
                _InfoChip(label: '最近指令', value: lastCommand),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: manualMode,
              onChanged: onModeChanged,
              title: const Text('手动驾驶模式'),
              subtitle: const Text('后续这里可以切到自动/半自动模式'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: (throttle + 1.0) / 2.0),
            const SizedBox(height: 8),
            Text(
              '方向：${steering.toStringAsFixed(2)}   油门：${throttle.toStringAsFixed(2)}',
            ),
          ],
        ),
      ),
    );
  }
}

class _GamepadCard extends StatelessWidget {
  const _GamepadCard({required this.snapshot});

  final GamepadSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = !snapshot.supported
        ? Colors.red
        : snapshot.connected
        ? Colors.green
        : Colors.orange;
    final pressedButtons = snapshot.pressedButtonLabels;
    final buttonText = pressedButtons.isEmpty ? '无' : pressedButtons.join(' ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gamepad, color: statusColor),
                const SizedBox(width: 8),
                Text('手柄输入', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _InfoChip(label: '状态', value: _statusLabel(snapshot)),
                _InfoChip(label: '设备', value: snapshot.shortName),
                _InfoChip(label: '按键', value: buttonText),
              ],
            ),
            const SizedBox(height: 12),
            _AxisMeter(
              label: '方向',
              value: snapshot.connected ? snapshot.driveSteering : 0.0,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 8),
            _AxisMeter(
              label: '油门',
              value: snapshot.connected ? snapshot.driveThrottle : 0.0,
              color: Colors.green,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ValueChip(label: 'LX', value: _axisValue(0)),
                _ValueChip(label: 'LY', value: _axisValue(1)),
                _ValueChip(label: 'RX', value: _axisValue(2)),
                _ValueChip(label: 'RY', value: _axisValue(3)),
                _ValueChip(label: 'LT', value: snapshot.buttonValue(6)),
                _ValueChip(label: 'RT', value: snapshot.buttonValue(7)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _axisValue(int index) {
    if (!snapshot.connected || index >= snapshot.axes.length) {
      return 0.0;
    }
    return snapshot.axes[index];
  }

  String _statusLabel(GamepadSnapshot snapshot) {
    if (!snapshot.supported) {
      return '不支持';
    }
    return snapshot.connected ? '已连接' : '未连接';
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

class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Text(label, style: Theme.of(context).textTheme.labelSmall),
      label: Text(value.toStringAsFixed(2)),
    );
  }
}

class _CommandGrid extends StatelessWidget {
  const _CommandGrid({
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
        height: 64,
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('基础控制', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: const SizedBox()),
                Expanded(
                  child: button(
                    icon: Icons.keyboard_arrow_up,
                    label: '前进',
                    onPressed: onForward,
                  ),
                ),
                Expanded(child: const SizedBox()),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: button(
                    icon: Icons.keyboard_arrow_left,
                    label: '左转',
                    onPressed: onLeft,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: button(
                    icon: Icons.stop_circle_outlined,
                    label: '停止',
                    onPressed: onStop,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: button(
                    icon: Icons.keyboard_arrow_right,
                    label: '右转',
                    onPressed: onRight,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: const SizedBox()),
                Expanded(
                  child: button(
                    icon: Icons.keyboard_arrow_down,
                    label: '后退',
                    onPressed: onBackward,
                  ),
                ),
                Expanded(child: const SizedBox()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _JoystickCard extends StatefulWidget {
  const _JoystickCard({
    required this.steering,
    required this.throttle,
    required this.maxSize,
    required this.onChanged,
    required this.onReleased,
  });

  final double steering;
  final double throttle;
  final double maxSize;
  final void Function(Offset delta, double radius) onChanged;
  final VoidCallback onReleased;

  @override
  State<_JoystickCard> createState() => _JoystickCardState();
}

class _JoystickCardState extends State<_JoystickCard> {
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('方向盘', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
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
                      final distance = raw.distance;
                      final clamped = distance > radius
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
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.blueGrey.shade50,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.blueGrey.shade200,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _JoystickPainter(
                                knobOffset: _delta,
                                dragging: _dragging,
                              ),
                            ),
                          ),
                          Center(
                            child: Container(
                              width: 86,
                              height: 86,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    blurRadius: 16,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: const Icon(Icons.tune, size: 36),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              '手势拖动方向盘可控制方向与油门，松手自动停。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
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
    final knobRadius = dragging ? 26.0 : 22.0;
    final paint = Paint()
      ..color = const Color(0xFF1565C0).withValues(alpha: 0.92);

    canvas.drawCircle(center + knobOffset, knobRadius, paint);
    canvas.drawCircle(
      center + knobOffset,
      knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.8),
    );

    final axisPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.blueGrey.withValues(alpha: 0.22);

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
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset ||
        oldDelegate.dragging != dragging;
  }
}

class _EventLogCard extends StatelessWidget {
  const _EventLogCard({required this.eventLog});

  final List<String> eventLog;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('事件日志', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: ListView.separated(
                itemCount: eventLog.length,
                itemBuilder: (context, index) {
                  return Text(
                    eventLog[index],
                    style: Theme.of(context).textTheme.bodyMedium,
                  );
                },
                separatorBuilder: (context, index) => const SizedBox(height: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveVideoCard extends StatefulWidget {
  const _LiveVideoCard({
    required this.theme,
    required this.hostController,
    required this.pathController,
    required this.muted,
    required this.onMutedChanged,
  });

  final ThemeData theme;
  final TextEditingController hostController;
  final TextEditingController pathController;
  final bool muted;
  final ValueChanged<bool> onMutedChanged;

  @override
  State<_LiveVideoCard> createState() => _LiveVideoCardState();
}

class _LiveVideoCardState extends State<_LiveVideoCard> {
  StreamPlaybackState _streamState = StreamPlaybackState.loading;
  String _streamStatusMessage = '正在加载视频流';

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _LiveVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  String _normalizedHost() {
    final host = widget.hostController.text.trim();
    if (host.isEmpty) {
      return '192.168.100.108';
    }

    return host.replaceFirst(RegExp(r'^https?://'), '');
  }

  String _normalizedPath() {
    final path = widget.pathController.text.trim();
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

  void _markLoading(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _streamState = StreamPlaybackState.loading;
      _streamStatusMessage = message;
    });
  }

  void _handleStreamReady() {
    if (!mounted) {
      return;
    }

    setState(() {
      _streamState = StreamPlaybackState.ready;
      _streamStatusMessage = '播放器页面已打开，视频帧由 MediaMTX WebRTC 接入';
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

  String _protocolDescription() {
    return 'WebRTC 低延迟主链路，前端不再探测 HLS 播放列表。';
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

  Color _streamColor(ThemeData theme) {
    switch (_streamState) {
      case StreamPlaybackState.loading:
        return theme.colorScheme.primary;
      case StreamPlaybackState.ready:
        return Colors.green;
      case StreamPlaybackState.error:
        return Colors.red;
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
    final theme = widget.theme;
    final streamUrl = _streamUrl;
    final statusColor = _streamColor(theme);
    final statusValue = _streamLabel();
    final statusMessage = _streamStatusMessage;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final streamControls = Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 170,
                  child: TextField(
                    controller: widget.hostController,
                    decoration: const InputDecoration(
                      labelText: 'RK IP',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _markLoading('正在刷新视频地址'),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: widget.pathController,
                    decoration: const InputDecoration(
                      labelText: 'Path',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _markLoading('正在刷新视频地址'),
                  ),
                ),
                const Chip(
                  avatar: Icon(Icons.wifi_tethering, size: 18),
                  label: Text('WebRTC 低延迟'),
                ),
                FilterChip(
                  label: const Text('静音'),
                  selected: widget.muted,
                  onSelected: widget.onMutedChanged,
                ),
              ],
            );
            final stageMaxWidth = constraints.maxWidth
                .clamp(320.0, 860.0)
                .toDouble();
            final stageMaxHeight = constraints.maxWidth >= 1280
                ? 420.0
                : constraints.maxWidth >= 960
                ? 380.0
                : 300.0;
            final stageWidth = math
                .min(stageMaxWidth, stageMaxHeight * 16 / 9)
                .toDouble();
            final stageHeight = stageWidth * 9 / 16;

            final header = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.videocam, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('实时视频', style: theme.textTheme.titleLarge),
                    const SizedBox(width: 12),
                    Text(
                      'WebRTC',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(_protocolDescription(), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _InfoChip(label: '视频', value: statusValue),
                    Chip(
                      avatar: Icon(_streamIcon(), color: statusColor, size: 18),
                      label: Text(
                        '播放器：$statusValue',
                        style: theme.textTheme.labelLarge,
                      ),
                      backgroundColor: statusColor.withValues(alpha: 0.08),
                      side: BorderSide(
                        color: statusColor.withValues(alpha: 0.3),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _markLoading('正在手动重连视频流'),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  statusMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                constraints.maxWidth >= 1040
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: header),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: math.min(430.0, constraints.maxWidth * 0.38),
                            child: Align(
                              alignment: Alignment.topRight,
                              child: streamControls,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          header,
                          const SizedBox(height: 12),
                          streamControls,
                        ],
                      ),
                const SizedBox(height: 12),
                Center(
                  child: SizedBox(
                    width: stageWidth,
                    height: stageHeight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: OpenRdStreamView(
                        key: ValueKey(streamUrl),
                        url: streamUrl,
                        onReady: _handleStreamReady,
                        onError: _handleStreamError,
                        placeholder: _StreamFallback(
                          theme: theme,
                          url: streamUrl,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StreamFallback extends StatelessWidget {
  const _StreamFallback({required this.theme, required this.url});

  final ThemeData theme;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Center(
        child: Text(
          '视频预览加载中\n$url',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Text(label, style: Theme.of(context).textTheme.labelSmall),
      label: Text(value, overflow: TextOverflow.ellipsis),
    );
  }
}
