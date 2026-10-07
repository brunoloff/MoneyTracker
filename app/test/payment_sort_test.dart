import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/ledger.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test('Sort covers all matches before display limit and preserves totals', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(
      data([
        for (var i = 0; i < 60; i++)
          payment('$i', '2026-09-20', -100 - i, 'Food'),
        payment('largest', '2026-09-01', -100000, 'Food'),
        payment('income', '2026-09-02', 200000, 'Salary'),
        payment('outside', '2026-08-01', -900000, 'Food'),
      ]),
    );
    expect(l.visible.take(40).any((p) => p.id == 'largest'), false);
    final spent = l.spent;
    final passes = l.summaryPasses;
    l.paymentSort = 'amount_desc';
    expect(l.visible.first.id, 'income');
    l.filter(flow: 'expenses');
    expect(l.visible.first.id, 'largest');
    expect(l.visible.length, 61);
    l.paymentSort = 'amount_asc';
    expect(l.visible.first.amount, -100);
    l.paymentSort = 'date_asc';
    expect(l.visible.first.id, 'largest');
    l.paymentSort = 'date_desc';
    expect(l.visible.last.id, 'largest');
    expect(l.spent, spent);
    expect(l.summaryPasses, passes);
    l.dispose();
  });
}
