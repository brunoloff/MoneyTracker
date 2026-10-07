import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const appVersion = '1.0.1+2';
const buildRevision = String.fromEnvironment(
  'MONEYTRACKER_BUILD_REVISION',
  defaultValue: 'local build',
);

// An allowlist: never collect errors, file paths, accounts or authorization URLs.
String testingBuildInfo() =>
    'MoneyTracker $appVersion\nBuild: $buildRevision\n'
    'Platform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}\n';

String credentialStoreGuidance(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows =>
    'MoneyTracker could not access the Windows credential store. '
        'Restart the app under your usual Windows user account and retry. '
        'If this continues, open Testing help and report the problem. '
        'Keep your existing app data and original PEM key.',
  _ =>
    'MoneyTracker could not unlock the system credential store. '
        'Unlock your desktop keyring (GNOME Keyring or KDE Wallet), then retry. '
        'Keep your existing app data and original PEM key.',
};

Future<void> showTestingHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 568),
    title: const Text('Testing help'),
    scrollable: true,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(testingBuildInfo()),
        const SizedBox(height: 16),
        const Text(
          'For your first test:\n'
          '1. Set up your own Enable Banking application and key.\n'
          '2. Connect your bank, then run Sync.\n'
          '3. Check a few payments against your bank.\n'
          '4. Try a category, a rule and Undo.\n'
          '5. Close and reopen the app; check that your data remains.',
        ),
        const SizedBox(height: 16),
        const Text(
          'For feedback, copy the build info and describe what you clicked, '
          'what you expected and what happened. The copied info contains '
          'only the app version, build and platform.\n\n'
          'Keep keys, account details and browser callback URLs private. '
          'Crop or blur financial details in screenshots.',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: testingBuildInfo()));
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Build info copied.')));
          }
        },
        child: const Text('Copy build info'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
