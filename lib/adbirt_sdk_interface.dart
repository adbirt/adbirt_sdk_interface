library adbirt_sdk_interface;

import 'dart:io';

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'src/attribution.dart';
import 'src/client.dart';

export 'src/attribution.dart'
    show AdbirtConfig, AdbirtAttribution, parseInstallReferrer, kDefaultAttributedSource;
export 'src/client.dart' show AdbirtClient, AdbirtEvents, AdbirtStorage, AdbirtTransport;

/// Adbirt SDK.
///
/// Use this only when the advertiser has no mobile measurement partner. Where
/// the advertiser already runs AppsFlyer, Adjust, Branch or Singular, install
/// and conversion attribution reaches Adbirt through that MMP's server-to-server
/// postback and this SDK is not part of the integration.
///
/// Events go to `POST {baseUrl}/api/v1/events` with the campaign's
/// publishable token (`adb_pk_...`). The secret token (`adb_sk_...`) belongs
/// on the advertiser's server and must never be put in an app.
///
/// Events that cannot be delivered are queued on the device and retried with
/// backoff, on the next event, on the next launch and on [flush].
abstract class AdbirtADKInterface {
  static AdbirtClient? _client;

  static const _kReferrerRead = 'adbirt_referrer_read';

  /// Initialize the SDK.
  ///
  /// Backwards compatible with `initializeApp('token')`. Pass [config] instead
  /// to point the SDK at another deployment or to attribute a source other
  /// than `adbirt`.
  static Future<void> initializeApp(
    String apiToken, {
    AdbirtConfig? config,
  }) async {
    final resolved = config ?? AdbirtConfig(apiToken: apiToken);
    resolved.validate();

    final prefs = await SharedPreferences.getInstance();
    final client = AdbirtClient(
      config: resolved,
      storage: _SharedPreferencesStorage(prefs),
      transport: _httpTransport,
    );
    _client = client;

    // The identifier exists before the install event that carries it.
    await client.identifier();

    final alreadyRead = prefs.getBool(_kReferrerRead) ?? false;

    if (Platform.isAndroid && !alreadyRead) {
      await _readAndroidReferrer(client, resolved);
    } else if (Platform.isIOS) {
      await _requestIosTrackingAuthorization();
    }

    if (!alreadyRead) {
      await prefs.setBool(_kReferrerRead, true);
      await client.logEvent(AdbirtEvents.install, parameters: {
        'platform': Platform.isAndroid ? 'android' : 'ios',
      });
    }

    await client.flush();
  }

  /// Read the Play install referrer once and store what it said.
  static Future<void> _readAndroidReferrer(AdbirtClient client, AdbirtConfig config) async {
    try {
      final details = await AndroidPlayInstallReferrer.installReferrer;
      await client.recordAttribution(parseInstallReferrer(
        details.installReferrer,
        attributedSources: config.attributedSources,
      ));
    } catch (e) {
      // An install referrer is unavailable on non-Play installs and on some
      // devices. That is normal and must not break the host app's startup.
      debugPrint('Adbirt: install referrer unavailable ($e)');
    }
  }

  /// iOS has no install-referrer equivalent.
  ///
  /// Attribution on iOS needs a click id delivered another way (a deep link
  /// carrying `adb_clickid`, passed to [setClickId]), SKAdNetwork or an MMP.
  /// This only requests ATT so a host app that wants IDFA can.
  static Future<void> _requestIosTrackingAuthorization() async {
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status == TrackingStatus.notDetermined) {
        await AppTrackingTransparency.requestTrackingAuthorization();
      }
    } catch (e) {
      debugPrint('Adbirt: ATT unavailable ($e)');
    }
  }

  static AdbirtClient? _ready() {
    final client = _client;
    if (client == null) debugPrint('Adbirt: not initialized - call initializeApp first');
    return client;
  }

  /// Log an event with any name.
  ///
  /// Returns true when the server accepted it now; false when it was queued
  /// for retry or not sent (install not attributed to Adbirt). Configure the
  /// name as a payable event on the campaign to be billed for it.
  static Future<bool> logEvent(
    String eventName, [
    Map<String, dynamic> parameters = const {},
  ]) async {
    final client = _ready();
    if (client == null) return false;
    return client.logEvent(
      eventName,
      parameters: parameters,
      value: _amount(parameters['value']),
      currency: parameters['currency']?.toString(),
    );
  }

  /// Log an event with a value, e.g. `logValueEvent('subscribe', value: 4.99, currency: 'USD')`.
  static Future<bool> logValueEvent(
    String eventName, {
    num? value,
    String? currency,
    Map<String, dynamic> parameters = const {},
  }) async =>
      await _ready()?.logEvent(eventName, value: value, currency: currency, parameters: parameters) ?? false;

  static Future<bool> logRegistration({Map<String, dynamic> parameters = const {}}) async =>
      await _ready()?.logRegistration(parameters: parameters) ?? false;

  static Future<bool> logDeposit(num value, String currency, {Map<String, dynamic> parameters = const {}}) async =>
      await _ready()?.logDeposit(value, currency, parameters: parameters) ?? false;

  static Future<bool> logPurchase(num value, String currency, {Map<String, dynamic> parameters = const {}}) async =>
      await _ready()?.logPurchase(value, currency, parameters: parameters) ?? false;

  /// Attribute this install to a click id from a deep link (`adb_clickid`).
  static Future<void> setClickId(String clickId) async => _ready()?.setClickId(clickId);

  /// Retry queued events now, e.g. when connectivity returns.
  static Future<int> flush() async => await _ready()?.flush() ?? 0;

  /// The Adbirt click id for this install, when there is one.
  static Future<String?> clickId() async =>
      (await SharedPreferences.getInstance()).getString(AdbirtClient.clickIdKey);

  static num? _amount(Object? raw) {
    if (raw is num) return raw >= 0 && raw.isFinite ? raw : null;
    if (raw is String) {
      final parsed = num.tryParse(raw);
      return parsed != null && parsed >= 0 && parsed.isFinite ? parsed : null;
    }
    return null;
  }
}

class _SharedPreferencesStorage implements AdbirtStorage {
  _SharedPreferencesStorage(this.prefs);
  final SharedPreferences prefs;

  @override
  Future<String?> getString(String key) async {
    // Earlier versions stored the attribution flag as a bool.
    final value = prefs.get(key);
    return value?.toString();
  }

  @override
  Future<void> setString(String key, String value) => prefs.setString(key, value);

  @override
  Future<void> remove(String key) => prefs.remove(key);
}

Future<int> _httpTransport(Uri url, Map<String, String> headers, String body) async {
  final response = await http.post(url, headers: headers, body: body).timeout(const Duration(seconds: 15));
  return response.statusCode;
}
