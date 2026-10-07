import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Pixel baselines were rendered on Linux. Other hosts use different font
/// rasterization; layout and interaction assertions still run on every host.
Future<void> expectLinuxGolden(Finder finder, String filename) async {
  if (Platform.isLinux) {
    await expectLater(finder, matchesGoldenFile(filename));
  }
}
