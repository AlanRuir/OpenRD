class GamepadButtonSnapshot {
  const GamepadButtonSnapshot({required this.pressed, required this.value});

  final bool pressed;
  final double value;
}

class GamepadSnapshot {
  const GamepadSnapshot({
    required this.supported,
    required this.connected,
    required this.index,
    required this.id,
    required this.axes,
    required this.buttons,
  });

  factory GamepadSnapshot.unsupported() {
    return const GamepadSnapshot(
      supported: false,
      connected: false,
      index: -1,
      id: '',
      axes: <double>[],
      buttons: <GamepadButtonSnapshot>[],
    );
  }

  factory GamepadSnapshot.disconnected() {
    return const GamepadSnapshot(
      supported: true,
      connected: false,
      index: -1,
      id: '',
      axes: <double>[],
      buttons: <GamepadButtonSnapshot>[],
    );
  }

  static const List<String> buttonLabels = <String>[
    'A',
    'B',
    'X',
    'Y',
    'LB',
    'RB',
    'LT',
    'RT',
    'Back',
    'Start',
    'L3',
    'R3',
    'Up',
    'Down',
    'Left',
    'Right',
    'Home',
  ];

  final bool supported;
  final bool connected;
  final int index;
  final String id;
  final List<double> axes;
  final List<GamepadButtonSnapshot> buttons;

  String get displayName {
    if (!supported) {
      return '不支持';
    }
    if (!connected) {
      return '未连接';
    }
    if (id.trim().isEmpty) {
      return 'Gamepad #$index';
    }
    return id.trim();
  }

  String get shortName {
    final name = displayName;
    if (name.length <= 40) {
      return name;
    }
    return '${name.substring(0, 37)}...';
  }

  double axis(int index, {double deadzone = 0.12}) {
    if (index < 0 || index >= axes.length) {
      return 0.0;
    }
    return _applyDeadzone(axes[index], deadzone);
  }

  bool buttonPressed(int index) {
    if (index < 0 || index >= buttons.length) {
      return false;
    }
    return buttons[index].pressed || buttons[index].value >= 0.55;
  }

  double buttonValue(int index) {
    if (index < 0 || index >= buttons.length) {
      return 0.0;
    }
    return buttons[index].value.clamp(0.0, 1.0);
  }

  double get analogSteering => axis(0);

  double get analogThrottle => -axis(1);

  double get triggerThrottle {
    final reverse = buttonValue(6);
    final forward = buttonValue(7);
    final value = forward - reverse;
    return value.abs() < 0.01 ? 0.0 : value.clamp(-1.0, 1.0);
  }

  double get digitalSteering {
    if (buttonPressed(14)) {
      return -1.0;
    }
    if (buttonPressed(15)) {
      return 1.0;
    }
    return 0.0;
  }

  double get digitalThrottle {
    if (buttonPressed(12)) {
      return 1.0;
    }
    if (buttonPressed(13)) {
      return -1.0;
    }
    return 0.0;
  }

  double get driveSteering {
    final digital = digitalSteering;
    return digital != 0.0 ? digital : analogSteering;
  }

  double get driveThrottle {
    final digital = digitalThrottle;
    if (digital != 0.0) {
      return digital;
    }
    if (triggerThrottle != 0.0) {
      return triggerThrottle;
    }
    return analogThrottle;
  }

  bool get stopPressed => buttonPressed(0) || buttonPressed(1);

  bool get hasDriveInput {
    return driveSteering.abs() >= 0.01 || driveThrottle.abs() >= 0.01;
  }

  List<String> get pressedButtonLabels {
    final labels = <String>[];
    for (var i = 0; i < buttons.length; i += 1) {
      if (!buttonPressed(i)) {
        continue;
      }
      labels.add(i < buttonLabels.length ? buttonLabels[i] : 'B$i');
    }
    return labels;
  }

  static double _applyDeadzone(double value, double deadzone) {
    final clamped = value.clamp(-1.0, 1.0);
    final magnitude = clamped.abs();
    if (magnitude < deadzone) {
      return 0.0;
    }

    final scaled = ((magnitude - deadzone) / (1.0 - deadzone)).clamp(0.0, 1.0);
    return clamped.sign * scaled;
  }

  @override
  bool operator ==(Object other) {
    return other is GamepadSnapshot &&
        other.supported == supported &&
        other.connected == connected &&
        other.index == index &&
        other.id == id &&
        _doubleListsEqual(other.axes, axes) &&
        _buttonListsEqual(other.buttons, buttons);
  }

  @override
  int get hashCode {
    return Object.hash(
      supported,
      connected,
      index,
      id,
      Object.hashAll(axes),
      Object.hashAll(
        buttons.map((button) => Object.hash(button.pressed, button.value)),
      ),
    );
  }

  static bool _doubleListsEqual(List<double> left, List<double> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i += 1) {
      if ((left[i] - right[i]).abs() > 0.0001) {
        return false;
      }
    }
    return true;
  }

  static bool _buttonListsEqual(
    List<GamepadButtonSnapshot> left,
    List<GamepadButtonSnapshot> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i += 1) {
      if (left[i].pressed != right[i].pressed ||
          (left[i].value - right[i].value).abs() > 0.0001) {
        return false;
      }
    }
    return true;
  }
}

double quantizeGamepadValue(double value) {
  final clamped = value.clamp(-1.0, 1.0);
  return (clamped * 1000).roundToDouble() / 1000.0;
}
