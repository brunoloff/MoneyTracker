import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Scales the entire native app, including the navigator and its overlays.
class AppZoom extends StatefulWidget {
  final Widget child;
  final bool enabled;

  const AppZoom({super.key, required this.child, this.enabled = true});

  @override
  State<AppZoom> createState() => _AppZoomState();
}

class _AppZoomState extends State<AppZoom> {
  double scale = 1;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (!widget.enabled ||
        event is! KeyDownEvent ||
        !HardwareKeyboard.instance.isControlPressed ||
        (event.logicalKey != LogicalKeyboardKey.digit0 &&
            event.logicalKey != LogicalKeyboardKey.numpad0)) {
      return false;
    }
    if (scale != 1) setState(() => scale = 1);
    return true;
  }

  void _onScroll(PointerScrollEvent event) {
    if (!HardwareKeyboard.instance.isControlPressed ||
        event.scrollDelta.dy == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (signal) {
      // Claim even events at a zoom limit so Ctrl+wheel never also scrolls.
      signal.respond(allowPlatformDefault: false);
      final step = event.scrollDelta.dy < 0 ? 1 : -1;
      final next = ((scale * 10).round() + step).clamp(5, 20) / 10;
      if (next != scale) setState(() => scale = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return _ScrollSignalCapture(
      onScroll: _onScroll,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          final logicalSize = viewport / scale;
          final media = MediaQuery.of(context);
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: logicalSize.width,
              maxWidth: logicalSize.width,
              minHeight: logicalSize.height,
              maxHeight: logicalSize.height,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                child: MediaQuery(
                  data: media.copyWith(
                    size: logicalSize,
                    padding: media.padding / scale,
                    viewPadding: media.viewPadding / scale,
                    viewInsets: media.viewInsets / scale,
                    systemGestureInsets: media.systemGestureInsets / scale,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ScrollSignalCapture extends SingleChildRenderObjectWidget {
  final void Function(PointerScrollEvent) onScroll;

  const _ScrollSignalCapture({required this.onScroll, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderScrollSignalCapture(onScroll);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderScrollSignalCapture renderObject,
  ) {
    renderObject.onScroll = onScroll;
  }
}

class _RenderScrollSignalCapture extends RenderProxyBox {
  void Function(PointerScrollEvent) onScroll;

  _RenderScrollSignalCapture(this.onScroll);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    // Register before descendants: an ordinary ancestor Listener loses the
    // pointer signal to a scrollable underneath the mouse. Other pointer
    // events still reach the child normally, with its transformed coordinates.
    result.add(BoxHitTestEntry(this, position));
    hitTestChildren(result, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerScrollEvent) onScroll(event);
  }
}
