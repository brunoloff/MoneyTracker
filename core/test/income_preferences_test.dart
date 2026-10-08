import 'dart:io';
import 'package:test/test.dart';
import 'package:money_tracker_core/money_tracker_core.dart';

void main() {
  test(
    'income preferences survive restart and invalid updates preserve them',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'income-preferences-',
      );
      var service = MoneyTrackerService(directory.path);
      try {
        final saved = await service.request('POST', '/api/preferences', {
          'incomeMode': 'average',
          'incomeAverageMonths': 6,
        });
        expect(saved.status, 200);
        for (final invalid in [
          {'incomeMode': 'unknown'},
          {'incomeAverageMonths': 0},
          {'incomeAverageMonths': 25},
          {'incomeAverageMonths': 2.5},
        ]) {
          expect(
            (await service.request('POST', '/api/preferences', invalid)).status,
            400,
          );
        }
        await service.close();
        service = MoneyTrackerService(directory.path);
        final prefs = service.store.read('preferences.json', {}) as Map;
        expect(prefs['incomeMode'], 'average');
        expect(prefs['incomeAverageMonths'], 6);
        await service.request('POST', '/api/preferences', {'periodCount': 2});
        expect(
          service.store.read('preferences.json', {})['incomeMode'],
          'average',
        );
      } finally {
        await service.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
