import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:adbirt_sdk_interface/src/attribution.dart';
import 'package:adbirt_sdk_interface/src/client.dart';

/// In-memory storage standing in for SharedPreferences.
class MemoryStorage implements AdbirtStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

class RecordedRequest {
  RecordedRequest(this.url, this.headers, this.body);
  final Uri url;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

/// A transport that answers with scripted status codes, or throws to simulate
/// being offline.
class ScriptedTransport {
  final List<RecordedRequest> requests = [];
  final List<Object> answers = [];
  int fallbackStatus = 200;

  Future<int> call(Uri url, Map<String, String> headers, String body) async {
    requests.add(RecordedRequest(url, headers, jsonDecode(body) as Map<String, dynamic>));
    if (answers.isEmpty) return fallbackStatus;
    final answer = answers.removeAt(0);
    if (answer is int) return answer;
    throw answer;
  }
}

const clickId = 'adb_0123456789abcdef0123456789abcdef';

void main() {
  late MemoryStorage storage;
  late ScriptedTransport transport;
  late DateTime clock;

  AdbirtClient buildClient({AdbirtConfig? config}) => AdbirtClient(
        config: config ??
            const AdbirtConfig(apiToken: 'adb_pk_test', baseUrl: 'http://localhost:4000/'),
        storage: storage,
        transport: transport.call,
        now: () => clock,
      );

  setUp(() {
    storage = MemoryStorage();
    transport = ScriptedTransport();
    clock = DateTime.utc(2026, 11, 2, 12);
  });

  Future<AdbirtClient> attributedClient() async {
    final client = buildClient();
    await client.recordAttribution(
      parseInstallReferrer('utm_source=adbirt&utm_medium=cpa&adb_clickid=$clickId'),
    );
    return client;
  }

  group('sending', () {
    test('posts to /api/v1/events with the bearer token, trimming a trailing slash', () async {
      final client = await attributedClient();
      expect(await client.logEvent('registration'), isTrue);

      final request = transport.requests.single;
      expect(request.url.toString(), 'http://localhost:4000/api/v1/events');
      expect(request.headers['Authorization'], 'Bearer adb_pk_test');
      expect(request.headers['Content-Type'], 'application/json');
    });

    test('sends the click id, identifier, value, currency, parameters and an event id', () async {
      final client = await attributedClient();
      await client.logEvent('deposit', value: 25.5, currency: 'ngn', parameters: {'method': 'card'});

      final body = transport.requests.single.body;
      expect(body['event_name'], 'deposit');
      expect(body['adb_clickid'], clickId);
      expect(body['adbirt_identifier'], startsWith('adbirt_id_'));
      expect(body['utm_source'], 'adbirt');
      expect(body['utm_medium'], 'cpa');
      expect(body['value'], 25.5);
      expect(body['currency'], 'NGN');
      expect(body['parameters'], {'method': 'card'});
      expect(body['event_id'], matches(RegExp(r'^[a-f0-9]{32}$')));
    });

    test('sends the advertiser transaction id for repeatable events, and none when not given', () async {
      final client = await attributedClient();
      await client.logEvent('transaction', value: 5000, currency: 'NGN', transactionId: ' tx-42 ');
      await client.logDeposit(100, 'NGN', transactionId: 'dep-1');
      await client.logPurchase(100, 'NGN', transactionId: 'order-1');
      await client.logEvent('registration');

      expect(transport.requests[0].body['transaction_id'], 'tx-42');
      expect(transport.requests[1].body['transaction_id'], 'dep-1');
      expect(transport.requests[2].body['transaction_id'], 'order-1');
      expect(transport.requests[3].body.containsKey('transaction_id'), isFalse);
    });

    test('keeps the transaction id on a queued retry', () async {
      final client = await attributedClient();
      transport.answers.add(Exception('offline'));
      await client.logEvent('loan_granted', transactionId: 'loan-7');
      clock = clock.add(const Duration(minutes: 5));
      await client.flush();
      expect(transport.requests[1].body['transaction_id'], 'loan-7');
    });

    test('does not send when the install was not attributed to Adbirt', () async {
      final client = buildClient();
      await client.recordAttribution(parseInstallReferrer('utm_source=google-play'));

      expect(await client.logEvent('registration'), isFalse);
      expect(transport.requests, isEmpty);
      expect(await client.pendingCount(), 0);
    });

    test('sends once a click id arrives another way, such as a deep link', () async {
      final client = buildClient();
      await client.setClickId(clickId);

      expect(await client.logEvent('registration'), isTrue);
      expect(transport.requests.single.body['adb_clickid'], clickId);
    });

    test('rejects an empty event name or a negative value before sending', () async {
      final client = await attributedClient();
      expect(() => client.logEvent(''), throwsArgumentError);
      expect(() => client.logEvent('deposit', value: -1), throwsArgumentError);
    });
  });

  group('helpers', () {
    test('registration, deposit and purchase use stable event names', () async {
      final client = await attributedClient();
      await client.logRegistration(parameters: {'method': 'email'});
      await client.logDeposit(100, 'USD');
      await client.logPurchase(9.99, 'EUR', parameters: {'sku': 'pro'});

      final names = transport.requests.map((r) => r.body['event_name']).toList();
      expect(names, ['registration', 'deposit', 'purchase']);
      expect(transport.requests[1].body['value'], 100);
      expect(transport.requests[2].body['currency'], 'EUR');
      expect(transport.requests[2].body['parameters'], {'sku': 'pro'});
    });
  });

  group('offline queue', () {
    test('keeps an event that could not be sent and delivers it on flush', () async {
      final client = await attributedClient();
      transport.answers.add(Exception('offline'));

      expect(await client.logEvent('registration'), isFalse);
      expect(await client.pendingCount(), 1);

      clock = clock.add(const Duration(minutes: 5));
      expect(await client.flush(), 1);
      expect(await client.pendingCount(), 0);

      // The retry is the same occurrence: same event id, so the server's
      // dedup sees one event, not two.
      expect(transport.requests[0].body['event_id'], transport.requests[1].body['event_id']);
    });

    test('survives a restart: the queue lives in storage', () async {
      final first = await attributedClient();
      transport.answers.add(Exception('offline'));
      await first.logEvent('registration');

      final second = buildClient();
      clock = clock.add(const Duration(minutes: 5));
      expect(await second.flush(), 1);
    });

    test('retries a 5xx and a 429, but drops a 4xx that will never succeed', () async {
      final client = await attributedClient();
      transport.answers.addAll([503, 429, 400]);

      await client.logEvent('a_event');
      await client.logEvent('b_event');
      await client.logEvent('c_event');

      expect(await client.pendingCount(), 2);
    });

    test('backs off: an event is not retried before its next attempt time', () async {
      final client = await attributedClient();
      transport.answers.add(500);
      await client.logEvent('registration');

      expect(await client.flush(), 0);
      expect(transport.requests, hasLength(1));

      clock = clock.add(const Duration(hours: 2));
      expect(await client.flush(), 1);
    });

    test('gives up on an event after the configured number of attempts', () async {
      final client = buildClient(
        config: const AdbirtConfig(apiToken: 'adb_pk_test', maxAttempts: 2),
      );
      await client.setClickId(clickId);
      transport.fallbackStatus = 500;

      await client.logEvent('registration');
      clock = clock.add(const Duration(hours: 2));
      await client.flush();

      expect(await client.pendingCount(), 0);
      expect(transport.requests, hasLength(2));
    });

    test('caps the queue by dropping the oldest events', () async {
      final client = buildClient(
        config: const AdbirtConfig(apiToken: 'adb_pk_test', maxQueueSize: 3),
      );
      await client.setClickId(clickId);
      transport.fallbackStatus = 503;

      for (final name in ['e1', 'e2', 'e3', 'e4', 'e5']) {
        await client.logEvent(name);
      }

      expect(await client.pendingCount(), 3);
      transport.fallbackStatus = 200;
      clock = clock.add(const Duration(hours: 2));
      await client.flush();
      final delivered = transport.requests.skip(5).map((r) => r.body['event_name']).toList();
      expect(delivered, ['e3', 'e4', 'e5']);
    });

    test('does not lose a corrupted queue entry silently or crash on it', () async {
      final client = await attributedClient();
      await storage.setString(AdbirtClient.queueKey, 'not json');

      expect(await client.pendingCount(), 0);
      expect(await client.logEvent('registration'), isTrue);
    });
  });

  group('identifier', () {
    test('is generated once and reused', () async {
      final client = buildClient();
      final first = await client.identifier();
      expect(first, matches(RegExp(r'^adbirt_id_[A-Za-z0-9]{20}$')));
      expect(await buildClient().identifier(), first);
    });
  });

  group('config', () {
    test('validates the token and base URL', () {
      expect(() => const AdbirtConfig(apiToken: ' ').validate(), throwsArgumentError);
      expect(() => const AdbirtConfig(apiToken: 'x', baseUrl: '').validate(), throwsArgumentError);
    });

    test('defaults to the production API', () {
      expect(const AdbirtConfig(apiToken: 'x').eventEndpoint, 'https://api.adbirt.com/api/v1/events');
    });
  });
}
