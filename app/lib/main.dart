import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'app_zoom.dart';
import 'ledger.dart';
import 'dashboard.dart';
import 'dart:convert';
import 'platform/runtime.dart';
import 'setup_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MoneyTrackerApp());
}

class MoneyTrackerApp extends StatefulWidget {
  final Ledger? ledger;
  const MoneyTrackerApp({super.key, this.ledger});
  @override
  State<MoneyTrackerApp> createState() => _MoneyTrackerAppState();
}

class _MoneyTrackerAppState extends State<MoneyTrackerApp> {
  Ledger? ledger;
  AppRuntime? runtime;
  bool setupNeeded = false;
  String? startupError;
  @override
  void initState() {
    super.initState();
    if (widget.ledger != null) {
      ledger = widget.ledger;
    } else {
      start();
    }
  }

  Future<void> start() async {
    setState(() => startupError = null);
    AppRuntime? opened;
    try {
      opened = await createRuntime();
      final local = Ledger(client: opened.client, desktop: opened.desktop);
      bool setup = false;
      if (opened.desktop) {
        final response = await local.client.get(
          local.uri('/api/setup'),
          headers: local.headers,
        );
        if (response.statusCode != 200) {
          throw Exception(jsonDecode(response.body)['error']);
        }
        final data = jsonDecode(response.body) as Map;
        setup = data['configured'] != true;
      }
      await local.load();
      if (!mounted) {
        local.dispose();
        return;
      }
      setState(() {
        runtime = opened;
        ledger = local;
        setupNeeded = setup;
      });
    } catch (e) {
      await opened?.close();
      if (mounted) {
        setState(
          () => startupError = e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  @override
  void dispose() {
    ledger?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MoneyTracker',
    debugShowCheckedModeBanner: false,
    theme: moneyTrackerTheme(),
    // Browsers already provide their own Ctrl+wheel page zoom.
    builder: (context, child) => AppZoom(enabled: !kIsWeb, child: child!),
    home: ledger == null
        ? Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'MoneyTracker',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (startupError == null)
                        const CircularProgressIndicator()
                      else ...[
                        Text(startupError!),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: start,
                          child: const Text('Retry'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          )
        : setupNeeded
        ? SetupPage(
            ledger: ledger!,
            onFinished: () => setState(() => setupNeeded = false),
          )
        : Dashboard(ledger: ledger!),
  );
}

ThemeData moneyTrackerTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: Colors.white,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff008f84),
    surface: Colors.white,
  ),
  fontFamily: 'MoneySans',
  textTheme: ThemeData.light().textTheme.apply(
    fontFamily: 'MoneySans',
    bodyColor: const Color(0xff12213e),
    displayColor: const Color(0xff12213e),
  ),
  dividerColor: const Color(0xffe5eaf0),
  inputDecorationTheme: InputDecorationTheme(
    isDense: true,
    filled: true,
    fillColor: const Color(0xfff8fafc),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: Color(0xffe1e7ee)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: Color(0xffe1e7ee)),
    ),
  ),
);
