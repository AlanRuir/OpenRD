import 'package:flutter/material.dart';

class OpenRdStreamView extends StatelessWidget {
  const OpenRdStreamView({
    super.key,
    required this.url,
    required this.placeholder,
    this.onReady,
    this.onError,
  });

  final String url;
  final Widget placeholder;
  final VoidCallback? onReady;
  final ValueChanged<String>? onError;

  @override
  Widget build(BuildContext context) {
    return placeholder;
  }
}
