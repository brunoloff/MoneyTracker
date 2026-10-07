import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/preferences_page.dart';
import 'widget_test.dart' show data;

void main() {
  testWidgets('Undo history limit validates and saves unlimited', (tester) async {
    final snapshot=data([]);
    var saves=0;
    final l=Ledger(client:MockClient((request) async {
      if (request.method=='POST') {
        saves++;
        expect(jsonDecode(request.body),{'undoLimit':0});
        snapshot['preferences']={'undoLimit':0};
        return http.Response('{}',200);
      }
      return http.Response(jsonEncode(snapshot),200);
    }));
    l.ingest(snapshot);
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:PreferencesPage(ledger:l)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo history'));
    await tester.pumpAndSettle();
    final field=find.widgetWithText(TextFormField,'Undo steps to keep');
    await tester.enterText(field,'-1');
    await tester.tap(find.text('Save undo history settings'));
    await tester.pumpAndSettle();
    expect(saves,0);
    await tester.enterText(field,'0');
    await tester.tap(find.text('Save undo history settings'));
    await tester.pumpAndSettle();
    expect(saves,1);expect(l.undoLimit,0);
    expect(find.text('Undo history limit saved.'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());l.dispose();
  });
}
