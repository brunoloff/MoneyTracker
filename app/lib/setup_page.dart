import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'bank_connection.dart';
import 'ledger.dart';
import 'testing_help.dart';

const bankingCallback = 'https://localhost:8443/callback';

class SetupPage extends StatefulWidget {
  final Ledger ledger;
  final VoidCallback onFinished;
  final Future<XFile?> Function()? pickKey;
  final Future<String?> Function()? pickDirectory;
  const SetupPage({
    super.key,
    required this.ledger,
    required this.onFinished,
    this.pickKey,
    this.pickDirectory,
  });
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final appId = TextEditingController();
  String? pem, keyName, message, error;
  bool busy = false, configured = false, hasData = false;
  @override
  void initState() {
    super.initState();
    status();
  }

  @override
  void dispose() {
    appId.dispose();
    pem = null;
    super.dispose();
  }

  Future<void> status() async {
    try {
      final response = await widget.ledger.client.get(
        widget.ledger.uri('/api/setup'),
        headers: widget.ledger.headers,
      );
      final data = jsonDecode(response.body) as Map;
      if (mounted) {
        setState(() {
          configured = data['configured'] == true;
          hasData = data['hasData'] == true;
        });
      }
    } catch (_) {
      /* The action below reports service failures with context. */
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(String url) async {
    try {
      if (!await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        throw Exception('Could not open the browser.');
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> chooseKey() => run(() async {
    final file =
        await (widget.pickKey?.call() ??
            openFile(
              acceptedTypeGroups: [
                const XTypeGroup(label: 'RSA private key', extensions: ['pem']),
              ],
            ));
    if (file == null) return;
    if (await file.length() > 1024 * 1024) {
      throw Exception('Choose a PEM key file smaller than 1 MB.');
    }
    final value = await file.readAsString();
    if (!value.contains('PRIVATE KEY')) {
      throw Exception(
        'Choose the private key PEM, rather than the public certificate.',
      );
    }
    if (mounted) {
      setState(() {
        pem = value;
        keyName = file.name;
        if (appId.text.isEmpty) {
          appId.text = file.name.replaceFirst(
            RegExp(r'\.pem$', caseSensitive: false),
            '',
          );
        }
      });
    }
  });
  Future<void> verify() => run(() async {
    if (pem == null) throw Exception('Select your private key file first.');
    final result = await widget.ledger.post('/api/setup/credentials', {
      'appId': appId.text.trim(),
      'pem': pem,
    });
    if (mounted) {
      setState(() {
        configured = true;
        pem = null;
        message = result['message'] as String?;
      });
    }
  });
  Future<void> importExisting() => run(() async {
    final path =
        await (widget.pickDirectory?.call() ??
            getDirectoryPath(confirmButtonText: 'Select old .private folder'));
    if (path == null) return;
    final result = await widget.ledger.post('/api/setup/import', {
      'path': path,
    });
    await widget.ledger.load();
    await status();
    if (mounted) {
      setState(
        () => message =
            '${result['transactions']} payments, ${result['accounts']} accounts and ${result['undoSteps']} undo steps copied. Your original data has been kept.',
      );
    }
  });
  Future<void> connect() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => BankConnection(ledger: widget.ledger),
    );
    if (result != null && mounted) setState(() => message = result);
  }

  Widget step(int number, String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$number. $title',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Set up MoneyTracker'),
      actions: [
        IconButton(
          tooltip: 'Testing help',
          onPressed: () => showTestingHelp(context),
          icon: const Icon(Icons.help_outline),
        ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Your accounts, your keys',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Each person uses their own Enable Banking application and private key. Payments stay on this computer. Setup does not download transactions until you choose Sync.',
            ),
            const SizedBox(height: 20),
            if (!hasData)
              step(0, 'Already using MoneyTracker?', [
                const Text(
                  'Close the old MoneyTracker service, then select its .private folder. We copy payments, labels, rules, account settings and undo history into this app. The old installation is kept unchanged.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : importExisting,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Import existing MoneyTracker data'),
                ),
              ]),
            step(1, 'Create your Enable Banking application', [
              const Text(
                'Sign in with your email address. Register a production application for your own accounts. Choose “Generate in the browser” and export the private key, then save the downloaded PEM file and application ID.',
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => open('https://enablebanking.com/sign-in/'),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open Enable Banking'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => open(
                            'https://enablebanking.com/docs/api/reference/#certificate-upload-and-application-registration',
                          ),
                    child: const Text('Registration instructions'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text('Add this redirect URL to the application:'),
              const SizedBox(height: 8),
              SelectableText(bankingCallback),
              TextButton.icon(
                onPressed: () => Clipboard.setData(
                  const ClipboardData(text: bankingCallback),
                ),
                icon: const Icon(Icons.copy),
                label: const Text('Copy redirect URL'),
              ),
            ]),
            step(2, 'Link your own bank accounts', [
              const Text(
                'In the Enable Banking control panel, choose “Activate by linking accounts”. Link every account you want to use. This enables restricted access to those accounts. Each friend or family member does this in their own Enable Banking account.',
              ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => open(
                        'https://enablebanking.com/docs/api/linked-accounts/',
                      ),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Account linking instructions'),
              ),
            ]),
            step(
              3,
              configured
                  ? 'Application verified — change keys if needed'
                  : 'Add your application and key',
              [
                TextField(
                  key: const ValueKey('setup-app-id'),
                  controller: appId,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Application ID',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : chooseKey,
                  icon: const Icon(Icons.key),
                  label: Text(keyName ?? 'Select private key PEM'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'MoneyTracker encrypts the imported key and bank sessions. The encryption key is saved in your system credential store. Keep your original PEM file as a backup; do not share it with the app bundle.',
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy || pem == null ? null : verify,
                  child: const Text('Verify and save keys'),
                ),
              ],
            ),
            if (configured)
              step(4, 'Connect your bank', [
                const Text(
                  'Authorize the accounts you linked, then open Sync to download their payments. You can repeat this for other banks or PayPal.',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : connect,
                  icon: const Icon(Icons.account_balance),
                  label: const Text('Connect a bank'),
                ),
              ]),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message!, key: const ValueKey('setup-message')),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : widget.onFinished,
                child: Text(
                  configured
                      ? 'Continue to MoneyTracker'
                      : 'Use without a bank connection',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
