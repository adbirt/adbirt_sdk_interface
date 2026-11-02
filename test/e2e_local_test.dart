// Drives a locally running Adbirt backend through the real HTTP layer.
// Skipped unless ADBIRT_E2E_BASE_URL is set; see the backend's
// main-backend/docs/sdk-events.md for the full local run. Never point it at
// production: it creates billable conversions.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:adbirt_sdk_interface/src/attribution.dart';
import 'package:adbirt_sdk_interface/src/client.dart';

class MemoryStorage implements AdbirtStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

Future<int> httpTransport(Uri url, Map<String, String> headers, String body) async {
  final response = await http.post(url, headers: headers, body: body);
  stdout.writeln('  POST $url -> ${response.statusCode} ${response.body}');
  return response.statusCode;
}

void main() {
  final baseUrl = Platform.environment['ADBIRT_E2E_BASE_URL'];
  final token = Platform.environment['ADBIRT_E2E_TOKEN'] ?? '';
  final referrer = Platform.environment['ADBIRT_E2E_REFERRER'];

  test('install, registration, a replay and a deposit reach the local backend', () async {
    final client = AdbirtClient(
      config: AdbirtConfig(apiToken: token, baseUrl: baseUrl!),
      storage: MemoryStorage(),
      transport: httpTransport,
    );
    await client.recordAttribution(parseInstallReferrer(referrer));

    expect(await client.logEvent(AdbirtEvents.install, parameters: {'platform': 'android'}), isTrue);
    expect(await client.logRegistration(parameters: {'method': 'email'}), isTrue);
    // A replay (as an offline retry would be) is accepted by HTTP and
    // deduplicated by the server; the database check shows it billed once.
    expect(await client.logRegistration(), isTrue);
    expect(await client.logDeposit(5000, 'NGN'), isTrue);
    expect(await client.pendingCount(), 0);
  }, skip: baseUrl == null ? 'set ADBIRT_E2E_BASE_URL to run against a local backend' : false);
}
