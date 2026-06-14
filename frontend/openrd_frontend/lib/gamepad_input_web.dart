import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'gamepad_state.dart';

@JS('navigator')
external _BrowserNavigator get _navigator;

extension type _BrowserNavigator(JSObject _) implements JSObject {
  external JSArray<_BrowserGamepad?> getGamepads();
}

extension type _BrowserGamepad(JSObject _) implements JSObject {
  external JSArray<JSNumber>? get axes;
  external JSArray<_BrowserGamepadButton>? get buttons;
  external JSBoolean? get connected;
  external JSString? get id;
  external JSNumber? get index;
}

extension type _BrowserGamepadButton(JSObject _) implements JSObject {
  external JSBoolean? get pressed;
  external JSNumber? get value;
}

class GamepadInput {
  GamepadInput();

  final StreamController<GamepadSnapshot> _controller =
      StreamController<GamepadSnapshot>.broadcast();
  Timer? _pollTimer;
  GamepadSnapshot _current = GamepadSnapshot.disconnected();

  Stream<GamepadSnapshot> get snapshots => _controller.stream;

  GamepadSnapshot get current => _current;

  void start() {
    if (_pollTimer != null) {
      return;
    }

    _poll(force: true);
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _poll(),
    );
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _controller.close();
  }

  void _poll({bool force = false}) {
    final next = _readSnapshot();
    if (!force && next == _current) {
      return;
    }

    _current = next;
    if (!_controller.isClosed) {
      _controller.add(next);
    }
  }

  GamepadSnapshot _readSnapshot() {
    final JSArray<_BrowserGamepad?> gamepads;
    try {
      gamepads = _navigator.getGamepads();
    } catch (_) {
      return GamepadSnapshot.unsupported();
    }

    for (var i = 0; i < gamepads.length; i += 1) {
      final gamepad = gamepads[i];
      if (gamepad == null || _readBool(gamepad.connected, true) == false) {
        continue;
      }

      return GamepadSnapshot(
        supported: true,
        connected: true,
        index: _readInt(gamepad.index, i),
        id: _gamepadId(gamepad.id, i),
        axes: _readAxes(gamepad),
        buttons: _readButtons(gamepad),
      );
    }

    return GamepadSnapshot.disconnected();
  }

  List<double> _readAxes(_BrowserGamepad gamepad) {
    final axes = gamepad.axes;
    if (axes == null || axes.length == 0) {
      return const <double>[];
    }

    final length = math.min(axes.length, 8);
    return List<double>.generate(length, (index) {
      return quantizeGamepadValue(_readDouble(axes[index], 0.0));
    });
  }

  List<GamepadButtonSnapshot> _readButtons(_BrowserGamepad gamepad) {
    final buttons = gamepad.buttons;
    if (buttons == null || buttons.length == 0) {
      return const <GamepadButtonSnapshot>[];
    }

    final length = math.min(buttons.length, 24);
    return List<GamepadButtonSnapshot>.generate(length, (index) {
      final button = buttons[index];

      return GamepadButtonSnapshot(
        pressed: _readBool(button.pressed, false),
        value: _readDouble(button.value, 0.0).clamp(0.0, 1.0),
      );
    });
  }

  bool _readBool(JSBoolean? value, bool fallback) {
    if (value == null) {
      return fallback;
    }
    return value.toDart;
  }

  int _readInt(JSNumber? value, int fallback) {
    if (value == null) {
      return fallback;
    }
    try {
      return value.toDartInt;
    } catch (_) {
      return value.toDartDouble.round();
    }
  }

  double _readDouble(JSNumber? value, double fallback) {
    if (value == null) {
      return fallback;
    }
    return value.toDartDouble;
  }

  String _gamepadId(JSString? value, int fallbackIndex) {
    final id = value?.toDart.trim();
    if (id == null || id.isEmpty) {
      return 'Gamepad #$fallbackIndex';
    }
    return id;
  }
}
