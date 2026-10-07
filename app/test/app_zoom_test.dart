import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/app_zoom.dart';

const probe = Key('zoom-probe');

Future<void> scroll(
  WidgetTester tester,
  double delta, {
  bool control = true,
  LogicalKeyboardKey controlKey = LogicalKeyboardKey.controlLeft,
  Offset? position,
}) async {
  if (control) await tester.sendKeyDownEvent(controlKey);
  await tester.sendEventToBinding(
    PointerScrollEvent(
      kind: PointerDeviceKind.mouse,
      position: position ?? const Offset(400, 300),
      scrollDelta: Offset(0, delta),
    ),
  );
  await tester.pump();
  if (control) await tester.sendKeyUpEvent(controlKey);
}

Widget app({required Widget home, bool enabled = true}) => MaterialApp(
  builder: (context, child) => AppZoom(enabled: enabled, child: child!),
  home: home,
);

Widget sizeProbe() => const SizedBox(key: probe, width: 100, height: 40);

void main() {
  testWidgets('Ctrl+wheel scales geometry and responsive layout together', (
    tester,
  ) async {
    Size? logicalSize;
    double? layoutWidth;
    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              logicalSize = MediaQuery.sizeOf(context);
              layoutWidth = constraints.maxWidth;
              return Center(child: sizeProbe());
            },
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byKey(probe)).width, 100);
    await scroll(tester, -120);
    expect(tester.getRect(find.byKey(probe)).width, closeTo(110, 0.001));
    expect(logicalSize!.width, closeTo(800 / 1.1, 0.001));
    expect(layoutWidth, closeTo(logicalSize!.width, 0.001));
    await scroll(tester, 120, controlKey: LogicalKeyboardKey.controlRight);
    expect(tester.getRect(find.byKey(probe)).width, closeTo(100, 0.001));
    expect(logicalSize, const Size(800, 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+wheel over a scrollable zooms without scrolling', (
    tester,
  ) async {
    final controller = ScrollController(initialScrollOffset: 300);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [sizeProbe(), const SizedBox(height: 3000)],
            ),
          ),
        ),
      ),
    );
    await scroll(
      tester,
      -120,
      position: tester.getCenter(find.byType(SingleChildScrollView)),
    );
    expect(controller.offset, 300);
    expect(tester.getRect(find.byKey(probe)).width, closeTo(110, 0.001));
    await scroll(
      tester,
      120,
      control: false,
      position: tester.getCenter(find.byType(SingleChildScrollView)),
    );
    expect(controller.offset, greaterThan(300));
    expect(tester.getRect(find.byKey(probe)).width, closeTo(110, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Zoom is bounded and Ctrl+0 resets it', (tester) async {
    await tester.pumpWidget(
      app(
        home: Scaffold(body: Center(child: sizeProbe())),
      ),
    );
    for (var i = 0; i < 25; i++) {
      await scroll(tester, -120);
    }
    expect(tester.getRect(find.byKey(probe)).width, closeTo(200, 0.001));
    for (var i = 0; i < 25; i++) {
      await scroll(tester, 120);
    }
    expect(tester.getRect(find.byKey(probe)).width, closeTo(50, 0.001));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.getRect(find.byKey(probe)).width, closeTo(100, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Zoomed controls and dialog overlays remain clickable', (
    tester,
  ) async {
    var clicked = false;
    await tester.pumpWidget(
      app(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Zoomed dialog'),
                    content: sizeProbe(),
                    actions: [
                      TextButton(
                        onPressed: () {
                          clicked = true;
                          Navigator.pop(context);
                        },
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await scroll(tester, -120);
    }
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Zoomed dialog'), findsOneWidget);
    final before = tester.getRect(find.text('Zoomed dialog')).width;
    await scroll(
      tester,
      120,
      position: tester.getCenter(find.byType(AlertDialog)),
    );
    expect(tester.getRect(find.text('Zoomed dialog')).width, lessThan(before));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(clicked, isTrue);
    expect(find.text('Zoomed dialog'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Disabled zoom leaves browser wheel handling unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        enabled: false,
        home: Scaffold(body: Center(child: sizeProbe())),
      ),
    );
    await scroll(tester, -120);
    expect(tester.getRect(find.byKey(probe)).width, 100);
    await tester.pumpWidget(const SizedBox());
    await scroll(tester, -120);
    expect(tester.takeException(), isNull);
  });
}
