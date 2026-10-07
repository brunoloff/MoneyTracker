import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'ledger.dart';

class BankConnection extends StatefulWidget {
  final Ledger ledger;
  const BankConnection({super.key, required this.ledger});
  @override
  State<BankConnection> createState() => _BankConnectionState();
}

class _BankConnectionState extends State<BankConnection> {
  final callback = TextEditingController();
  final country = TextEditingController(text: 'PT');
  Timer? poll;
  String? attempt;
  bool checking = false;
  List<Map<String, dynamic>> banks = [];
  String? bank, url, error;
  bool busy = false;
  @override
  void dispose() {
    country.dispose();
    callback.dispose();
    poll?.cancel();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadBanks() => run(() async {
    final result = await widget.ledger.post('/api/connections/banks', {
      'country': country.text.trim().toUpperCase(),
    });
    if (mounted) {
      setState(() {
        banks = (result['banks'] as List).cast<Map<String, dynamic>>();
        banks.sort(
          (a, b) => (a['name'] as String).compareTo(b['name'] as String),
        );
        bank = null;
      });
    }
  });

  Future<void> start() => run(() async {
    final selected = banks.firstWhere((b) => b['name'] == bank);
    final result = await widget.ledger.post('/api/connections/start', selected);
    if (mounted) {
      setState(() {
        url = result['url'] as String;
        attempt = result['attempt'] as String;
      });
      poll?.cancel();
      poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => checkConnection(),
      );
    }
  });

  Future<void> checkConnection() async {
    if (!mounted || checking || attempt == null) return;
    checking = true;
    final currentAttempt = attempt;
    try {
      final result = await widget.ledger.post('/api/connections/status', {
        'attempt': attempt,
      });
      if (!mounted || currentAttempt != attempt) return;
      if (result['status'] == 'complete') {
        poll?.cancel();
        await widget.ledger.load();
        if (mounted) Navigator.pop(context, result['message'] as String);
      } else if (result['status'] == 'error') {
        poll?.cancel();
        setState(() => error = result['message'] as String);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Waiting to reconnect to MoneyTracker…');
      }
    } finally {
      checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect or renew a bank'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (url == null) ...[
              const Text(
                'Choose your bank, then authorize account access on its website. We request up to 90 days of access, subject to the bank’s limit.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: country,
                      enabled: !busy,
                      maxLength: 2,
                      decoration: const InputDecoration(
                        labelText: 'Country',
                        counterText: '',
                        helperText: 'PT, ES, …',
                      ),
                      onChanged: (_) => setState(() {
                        banks = [];
                        bank = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : loadBanks,
                      child: const Text('Find banks'),
                    ),
                  ),
                ],
              ),
              if (banks.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey(banks),
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bank'),
                  items: banks
                      .map(
                        (b) => DropdownMenuItem<String>(
                          value: b['name'],
                          child: Text(
                            b['name'],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: busy ? null : (v) => setState(() => bank = v),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy || bank == null ? null : start,
                  child: const Text('Create authorization link'),
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'For this personal Enable Banking application, first link the account in its control panel. Existing transactions and account assignments are kept.',
              ),
            ] else ...[
              const Text(
                '1. Open the authorization page and select the accounts you want to connect.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          if (!await launchUrl(
                            Uri.parse(url!),
                            mode: LaunchMode.externalApplication,
                            webOnlyWindowName: '_blank',
                          )) {
                            throw Exception(
                              'Could not open the browser. Use Copy link instead.',
                            );
                          }
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open bank authorization'),
              ),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: url!)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy link'),
              ),
              const SizedBox(height: 12),
              const Text(
                'After approval, you will return to MoneyTracker and this connection will update automatically. If your browser shows a certificate warning for localhost, accept the local MoneyTracker certificate to continue.',
              ),
              const SizedBox(height: 12),
              const Text('Waiting for bank authorization…'),
              const SizedBox(height: 12),
              ExpansionTile(
                title: const Text('Finish with the callback URL'),
                children: [
                  const Text(
                    'If the browser cannot complete the local callback, copy its final localhost URL here.',
                  ),
                  TextField(
                    controller: callback,
                    decoration: const InputDecoration(
                      labelText: 'Final callback URL',
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final result = await widget.ledger.post(
                              '/api/connections/finish',
                              {'callback': callback.text.trim()},
                            );
                            await widget.ledger.load();
                            if (context.mounted) {
                              Navigator.pop(
                                context,
                                result['message'] as String,
                              );
                            }
                          }),
                    child: const Text('Finish authorization'),
                  ),
                ],
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        poll?.cancel();
                        setState(() {
                          url = null;
                          attempt = null;
                          error = null;
                        });
                      },
                child: const Text('Start again'),
              ),
            ],
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
