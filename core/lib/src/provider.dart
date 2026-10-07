import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'classification.dart';
import 'journal.dart';

typedef BankApi =
    Future<Map<String, dynamic>> Function(
      String path, [
      Map<String, dynamic>? body,
    ]);
const callbackUrl = 'https://localhost:8443/callback';
String randomToken(int bytes) => base64Url
    .encode(List.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

class Provider {
  final Journal journal;
  final http.Client client;
  final DateTime Function() clock;
  Provider(this.journal, {http.Client? client, DateTime Function()? clock})
    : client = client ?? http.Client(),
      clock = clock ?? DateTime.now;
  bool get configured =>
      (journal.read('credentials.json', {}) as Map)['appId'] is String;
  static void validateCredentials(String id, String pem) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      invalid('Enter the application ID from Enable Banking.');
    }
    try {
      JWT({
        'test': true,
      }).sign(RSAPrivateKey(pem), algorithm: JWTAlgorithm.RS256);
    } catch (_) {
      invalid('Select a valid RSA private key PEM file (PKCS1 or PKCS8).');
    }
  }

  String token(Map credentials) {
    final now = clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final jwt = JWT(
      {
        'iss': 'enablebanking.com',
        'aud': 'api.enablebanking.com',
        'iat': now,
        'exp': now + 600,
      },
      header: {'typ': 'JWT', 'kid': credentials['appId']},
    );
    return jwt.sign(
      RSAPrivateKey(credentials['pem'] as String),
      algorithm: JWTAlgorithm.RS256,
      noIssueAt: true,
    );
  }

  Future<Map<String, dynamic>> call(
    String path, [
    Map<String, dynamic>? body,
    Map<String, dynamic>? credentials,
  ]) async {
    final keys =
        credentials ??
        Map<String, dynamic>.from(journal.read('credentials.json', {}));
    if (keys['appId'] == null || keys['pem'] == null) {
      invalid('Set up your Enable Banking application and private key first.');
    }
    final uri = Uri.parse('https://api.enablebanking.com$path');
    if (uri.host != 'api.enablebanking.com' || uri.scheme != 'https') {
      invalid('Invalid banking endpoint');
    }
    final headers = {
      'Authorization': 'Bearer ${token(keys)}',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.get(uri, headers: headers)
                : client.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 60));
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw StateError(
        'Enable Banking returned an unreadable response (${response.statusCode}).',
      );
    }
    if (response.statusCode >= 400) {
      // Never include signed headers or PEMs in diagnostics.
      final message = decoded is Map
          ? '${decoded['error'] ?? 'Request failed'}: ${decoded['message'] ?? decoded['error_description'] ?? ''}'
          : 'Request failed';
      throw StateError('Enable Banking (${response.statusCode}): $message');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  Future<Map<String, dynamic>> saveCredentials(String id, String pem) async {
    validateCredentials(id, pem);
    final keys = <String, dynamic>{'appId': id, 'pem': pem};
    final application = await call('/application', null, keys);
    if (!(application['redirect_urls'] as List? ?? []).contains(callbackUrl)) {
      invalid(
        'Add $callbackUrl to the redirect URLs in your Enable Banking application, then try again.',
      );
    }
    await journal.write('credentials.json', keys);
    return {
      'configured': true,
      'applicationName': application['name'],
      'message': 'Application and key verified. You can now connect your bank.',
    };
  }

  void close() => client.close();
}
