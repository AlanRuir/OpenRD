import 'dart:async';

import 'gamepad_state.dart';

class GamepadInput {
  GamepadInput();

  final StreamController<GamepadSnapshot> _controller =
      StreamController<GamepadSnapshot>.broadcast();
  final GamepadSnapshot _current = GamepadSnapshot.unsupported();

  Stream<GamepadSnapshot> get snapshots => _controller.stream;

  GamepadSnapshot get current => _current;

  void start() {
    if (!_controller.isClosed) {
      _controller.add(_current);
    }
  }

  void dispose() {
    _controller.close();
  }
}
