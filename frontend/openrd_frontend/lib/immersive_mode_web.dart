// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<bool> requestImmersiveMode() async {
  final element = html.document.documentElement;
  if (element == null) {
    return false;
  }

  try {
    await element.requestFullscreen();
    return true;
  } catch (_) {
    return false;
  }
}
