// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class OpenRdStreamView extends StatefulWidget {
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
  State<OpenRdStreamView> createState() => _OpenRdStreamViewState();
}

class _OpenRdStreamViewState extends State<OpenRdStreamView> {
  static final Set<String> _registeredViewTypes = <String>{};
  static final Map<String, _StreamCallbacks> _callbacksByViewType = <String, _StreamCallbacks>{};

  late final String _viewType = _buildViewType(widget.url);

  @override
  void initState() {
    super.initState();
    _registerViewType(_viewType, widget.url);
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
    );
  }

  @override
  void didUpdateWidget(covariant OpenRdStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _callbacksByViewType[_viewType] = _StreamCallbacks(
      onReady: widget.onReady,
      onError: widget.onError,
    );
  }

  @override
  void dispose() {
    _callbacksByViewType.remove(_viewType);
    super.dispose();
  }

  String _buildViewType(String url) {
    final sanitized = url.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final hash = url.hashCode.toUnsigned(32).toRadixString(16);
    return 'openrd_stream_${sanitized}_$hash';
  }

  void _registerViewType(String viewType, String url) {
    if (_registeredViewTypes.contains(viewType)) {
      return;
    }
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = url
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'autoplay; fullscreen; picture-in-picture'
        ..setAttribute('scrolling', 'no');

      iframe.onLoad.listen((_) {
        _callbacksByViewType[viewType]?.onReady?.call();
      });
      iframe.onError.listen((_) {
        _callbacksByViewType[viewType]?.onError?.call('视频流加载失败');
      });

      return iframe;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(
          child: HtmlElementView(viewType: _viewType),
        ),
      ),
    );
  }
}

class _StreamCallbacks {
  const _StreamCallbacks({this.onReady, this.onError});

  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
}
