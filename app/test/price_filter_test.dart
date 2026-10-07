import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test('Names sort all results; amount bounds are inclusive and preserve totals', () {
    final l=Ledger(clock:()=>DateTime(2026,9,28));
    l.ingest(data([
      for (var i=0;i<60;i++) {...payment('$i','2026-09-20',-1000-i,'Food'),'description':'Shop $i'},
      {...payment('a','2026-09-01',-500,'Food'),'description':'alpha'},
      {...payment('z','2026-09-02',500,'Other income'),'description':'Zebra'},
    ]));
    final spent=l.spent;
    l.paymentSort='name_asc';expect(l.visible.first.id,'a');
    l.paymentSort='name_desc';expect(l.visible.first.id,'z');
    l.minimumAmount=500;l.maximumAmount=500;
    expect(l.visible.map((p)=>p.id),['z','a']);
    expect(l.spent,spent);
    l.filter(flow:'expenses');expect(l.visible.single.id,'a');
    l.maximumAmount=null;expect(l.visible.length,61);
    l.minimumAmount=null;l.filter(flow:'all');expect(l.visible.length,62);
    l.dispose();
  });
  test('Amounts parse exactly without floating-point rounding', () {
    expect(parsePrice('12,34'),1234);expect(parsePrice('0.10'),10);
    expect(parsePrice('12.'),1200);expect(parsePrice(''),null);
    for (final text in ['-1','1.234','NaN','1e3']) {
      expect(()=>parsePrice(text),throwsFormatException);
    }
  });
  for (final width in [390.0,1100.0]) {
    testWidgets('Amount inputs validate and clear at $width', (tester) async {
      tester.view.physicalSize=Size(width,1100);tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
      final l=Ledger(clock:()=>DateTime(2026,9,28));
      l.ingest(data([payment('x','2026-09-20',-1234,'Food')]));
      await tester.pumpWidget(MoneyTrackerApp(ledger:l));await tester.pumpAndSettle();
      final minimum=find.widgetWithText(TextFormField,'Min (€)');
      final maximum=find.widgetWithText(TextFormField,'Max (€)');
      await tester.ensureVisible(minimum);await tester.enterText(minimum,'10');await tester.pumpAndSettle();
      await tester.ensureVisible(maximum);await tester.enterText(maximum,'20');await tester.pumpAndSettle();
      expect(l.visible.length,1);
      await tester.enterText(minimum,'30');await tester.pumpAndSettle();
      expect(find.text('Minimum must not exceed maximum.'),findsOneWidget);
      expect(l.minimumAmount,1000);
      await tester.ensureVisible(find.text('Clear amount range'));await tester.tap(find.text('Clear amount range'));await tester.pumpAndSettle();
      expect(l.minimumAmount,null);expect(l.maximumAmount,null);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
