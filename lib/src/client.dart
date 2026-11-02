/// The event client behind the Adbirt SDK.
///
/// Pure Dart: storage and HTTP are injected, so the whole send, queue and
/// retry path runs under `flutter test` without a device, plugins or network.
/// `AdbirtADKInterface` wires it to SharedPreferences and `package:http`.
library;

import 'dart:convert';
import 'dart:math';

import 'attribution.dart';

/// Key-value storage that survives app restarts (SharedPreferences in apps).
abstract class AdbirtStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// Sends one request and returns the HTTP status. Throws when offline.
typedef AdbirtTransport = Future<int> Function(
  Uri url,
  Map<String, String> headers,
  String body,
);

/// Event names the helpers use. Configure these as payable events on the
/// campaign to be billed for them.
class AdbirtEvents {
  static const install = 'app_install';
  static const registration = 'registration';
  static const deposit = 'deposit';
  static const purchase = 'purchase';
}

class AdbirtClient {
  AdbirtClient({
    required this.config,
    required this.storage,
    required this.transport,
    DateTime Function()? now,
    Random? random,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final AdbirtConfig config;
  final AdbirtStorage storage;
  final AdbirtTransport transport;
  final DateTime Function() _now;
  final Random _random;

  static const identifierKey = 'adbirt_identifier';
  static const attributedKey = 'is_adbirt';
  static const sourceKey = 'utm_source';
  static const mediumKey = 'utm_medium';
  static const clickIdKey = 'adb_clickid';
  static const queueKey = 'adbirt_event_queue';

  static const _firstRetryDelay = Duration(seconds: 30);
  static const _maxRetryDelay = Duration(hours: 1);

  Future<int>? _flushInProgress;

  /// Store what the install referrer said about this install.
  Future<void> recordAttribution(AdbirtAttribution attribution) async {
    if (attribution.source != null) await storage.setString(sourceKey, attribution.source!);
    if (attribution.medium != null) await storage.setString(mediumKey, attribution.medium!);
    if (attribution.clickId != null) await storage.setString(clickIdKey, attribution.clickId!);
    await storage.setString(attributedKey, attribution.isAdbirt ? 'true' : 'false');
  }

  /// Attribute this install to a click id that arrived some other way, for
  /// example an `adb_clickid` parameter on a deep link that opened the app.
  /// This is the only attribution route on iOS, which has no install referrer.
  Future<void> setClickId(String clickId) async {
    final trimmed = clickId.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(clickId, 'clickId', 'must not be empty');
    await storage.setString(clickIdKey, trimmed);
    await storage.setString(attributedKey, 'true');
  }

  Future<String?> clickId() => storage.getString(clickIdKey);

  /// The install's random identifier, created on first use. The server
  /// stores only a hash of it.
  Future<String> identifier() async {
    final existing = await storage.getString(identifierKey);
    if (existing != null && existing.isNotEmpty) return existing;
    const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
    final body = String.fromCharCodes(
      Iterable.generate(20, (_) => chars.codeUnitAt(_random.nextInt(chars.length))),
    );
    final created = 'adbirt_id_$body';
    await storage.setString(identifierKey, created);
    return created;
  }

  Future<bool> _isAttributed() async =>
      (await storage.getString(attributedKey)) == 'true' &&
      ((await storage.getString(clickIdKey)) ?? '').isNotEmpty;

  /// Report an event.
  ///
  /// Returns true when the server accepted it now. An event that could not
  /// be delivered (offline, server error, rate limited) is queued and retried
  /// by later calls and by [flush]; it keeps its event id, so a retry is never
  /// counted twice. Nothing is sent for an install Adbirt did not bring.
  ///
  /// [transactionId] is your own id for this occurrence (an order, a
  /// transaction, a loan). Send it for events a campaign pays for every time:
  /// each distinct id is charged once, and the same id sent again is not.
  Future<bool> logEvent(
    String eventName, {
    Map<String, dynamic> parameters = const {},
    num? value,
    String? currency,
    String? transactionId,
  }) async {
    if (eventName.trim().isEmpty) {
      throw ArgumentError.value(eventName, 'eventName', 'must not be empty');
    }
    if (value != null && (value.isNaN || value.isInfinite || value < 0)) {
      throw ArgumentError.value(value, 'value', 'must be a non-negative number');
    }

    if (!await _isAttributed()) return false;

    final event = <String, dynamic>{
      'event_name': eventName.trim(),
      'event_id': _eventId(),
      if (transactionId != null && transactionId.trim().isNotEmpty)
        'transaction_id': transactionId.trim(),
      if (value != null) 'value': value,
      if (currency != null && currency.trim().isNotEmpty)
        'currency': currency.trim().toUpperCase(),
      if (parameters.isNotEmpty) 'parameters': parameters,
      'attempts': 0,
    };

    final outcome = await _deliver(event);
    if (outcome == _Outcome.retry) await _enqueue(event);

    await flush();
    return outcome == _Outcome.delivered;
  }

  Future<bool> logRegistration({Map<String, dynamic> parameters = const {}}) =>
      logEvent(AdbirtEvents.registration, parameters: parameters);

  Future<bool> logDeposit(num value, String currency,
          {Map<String, dynamic> parameters = const {}, String? transactionId}) =>
      logEvent(AdbirtEvents.deposit,
          value: value, currency: currency, parameters: parameters, transactionId: transactionId);

  Future<bool> logPurchase(num value, String currency,
          {Map<String, dynamic> parameters = const {}, String? transactionId}) =>
      logEvent(AdbirtEvents.purchase,
          value: value, currency: currency, parameters: parameters, transactionId: transactionId);

  /// Events waiting for retry.
  Future<int> pendingCount() async => (await _readQueue()).length;

  /// Retry every queued event that is due. Returns how many were delivered.
  Future<int> flush() {
    return _flushInProgress ??= _flushDue().whenComplete(() => _flushInProgress = null);
  }

  Future<int> _flushDue() async {
    final queue = await _readQueue();
    if (queue.isEmpty) return 0;

    final now = _now().millisecondsSinceEpoch;
    final remaining = <Map<String, dynamic>>[];
    var delivered = 0;

    for (final event in queue) {
      final dueAt = (event['next_attempt_at'] as num?)?.toInt() ?? 0;
      if (dueAt > now) {
        remaining.add(event);
        continue;
      }
      final outcome = await _deliver(event);
      if (outcome == _Outcome.delivered) delivered += 1;
      if (outcome == _Outcome.retry && _scheduleRetry(event)) remaining.add(event);
    }

    await _writeQueue(remaining);
    return delivered;
  }

  Future<_Outcome> _deliver(Map<String, dynamic> event) async {
    event['attempts'] = ((event['attempts'] as num?)?.toInt() ?? 0) + 1;

    final body = <String, dynamic>{
      'event_name': event['event_name'],
      'event_id': event['event_id'],
      if (event['transaction_id'] != null) 'transaction_id': event['transaction_id'],
      'adbirt_identifier': await identifier(),
      'adb_clickid': await storage.getString(clickIdKey),
      'utm_source': await storage.getString(sourceKey),
      'utm_medium': await storage.getString(mediumKey),
      if (event['value'] != null) 'value': event['value'],
      if (event['currency'] != null) 'currency': event['currency'],
      'parameters': event['parameters'] ?? const <String, dynamic>{},
    };

    try {
      final status = await transport(
        Uri.parse(config.eventEndpoint),
        {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiToken}',
        },
        jsonEncode(body),
      );
      if (status >= 200 && status < 300) return _Outcome.delivered;
      // 429 and 5xx are transient. Any other 4xx (bad token, bad payload)
      // will fail the same way every time, so retrying only wastes battery.
      if (status == 429 || status >= 500) return _Outcome.retry;
      return _Outcome.dropped;
    } catch (_) {
      return _Outcome.retry;
    }
  }

  /// Set the next attempt time. False when the event is out of attempts.
  bool _scheduleRetry(Map<String, dynamic> event) {
    final attempts = (event['attempts'] as num).toInt();
    if (attempts >= config.maxAttempts) return false;
    final delay = _firstRetryDelay * pow(2, attempts - 1).toInt();
    final capped = delay > _maxRetryDelay ? _maxRetryDelay : delay;
    event['next_attempt_at'] = _now().add(capped).millisecondsSinceEpoch;
    return true;
  }

  Future<void> _enqueue(Map<String, dynamic> event) async {
    if (!_scheduleRetry(event)) return;
    final queue = await _readQueue()..add(event);
    while (queue.length > config.maxQueueSize) {
      queue.removeAt(0);
    }
    await _writeQueue(queue);
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    final raw = await storage.getString(queueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map((entry) => Map<String, dynamic>.from(entry)).toList();
    } catch (_) {
      // A corrupted queue is discarded rather than allowed to block every
      // future event, or to crash the host app.
      await storage.remove(queueKey);
      return [];
    }
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> queue) async {
    if (queue.isEmpty) {
      await storage.remove(queueKey);
    } else {
      await storage.setString(queueKey, jsonEncode(queue));
    }
  }

  String _eventId() =>
      List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

enum _Outcome { delivered, retry, dropped }
