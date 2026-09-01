library adbirt_sdk_interface;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'src/attribution.dart';

export 'src/attribution.dart'
    show AdbirtConfig, AdbirtAttribution, parseInstallReferrer, kDefaultAttributedSource;

/// Adbirt SDK.
///
/// Use this only when the advertiser has no mobile measurement partner. Where
/// the advertiser already runs AppsFlyer, Adjust, Branch or Singular, install
/// and conversion attribution reaches Adbirt through that MMP's server-to-server
/// postback and this SDK is not part of the integration.
///
/// ## What changed from 0.0.6
///
/// 0.0.6 could not attribute an install or send any event. `_getReferrerDetails`
/// returned a map keyed `utm_source`/`utm_medium` while the caller read
/// `utmSource`/`utmMedium`, so both were always null, the `is_adbirt` flag was
/// never set, and every send was gated on that flag. A second, independent bug
/// gated the install event on an identifier that was generated afterwards.
/// Both are fixed and covered by tests in `test/attribution_test.dart`.
abstract class AdbirtADKInterface {
  static AdbirtConfig? _config;

  static const _kApiToken = 'adbirt_api_token';
  static const _kIdentifier = 'adbirt_identifier';
  static const _kAttributed = 'is_adbirt';
  static const _kSource = 'utm_source';
  static const _kMedium = 'utm_medium';
  static const _kClickId = 'adb_clickid';
  static const _kReferrerRead = 'adbirt_referrer_read';

  /// Initialize the SDK.
  ///
  /// Backwards compatible with `initializeApp('token')`. Pass [config] instead
  /// to point the SDK at a specific deployment or to attribute a source other
  /// than `adbirt`.
  static Future<void> initializeApp(
    String apiToken, {
    AdbirtConfig? config,
  }) async {
    final resolved = config ?? AdbirtConfig(apiToken: apiToken);
    resolved.validate();
    _config = resolved;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApiToken, resolved.apiToken);

    // Generate the device identifier FIRST. In 0.0.6 this ran after the install
    // event, and the install event required a non-empty identifier - so on the
    // one launch where an install matters, it was always empty.
    var identifier = prefs.getString(_kIdentifier);
    if (identifier == null || identifier.isEmpty) {
      identifier = _generateIdentifier();
      await prefs.setString(_kIdentifier, identifier);
    }

    if (Platform.isAndroid) {
      await _readAndroidReferrer(prefs, resolved);
    } else if (Platform.isIOS) {
      await _requestIosTrackingAuthorization();
    }

    final attributed = prefs.getBool(_kAttributed) ?? false;
    final alreadyReported = prefs.getBool(_kReferrerRead) ?? false;

    if (attributed && !alreadyReported) {
      await logEvent('app_install', {
        'platform': Platform.isAndroid ? 'android' : 'ios',
      });
      await prefs.setBool(_kReferrerRead, true);
    }
  }

  /// Read the Play install referrer once and store what it said.
  static Future<void> _readAndroidReferrer(
    SharedPreferences prefs,
    AdbirtConfig config,
  ) async {
    if (prefs.getBool(_kReferrerRead) == true) return;

    try {
      final details = await AndroidPlayInstallReferrer.installReferrer;
      final attribution = parseInstallReferrer(
        details.installReferrer,
        attributedSources: config.attributedSources,
      );

      if (attribution.source != null) {
        await prefs.setString(_kSource, attribution.source!);
      }
      if (attribution.medium != null) {
        await prefs.setString(_kMedium, attribution.medium!);
      }
      if (attribution.clickId != null) {
        await prefs.setString(_kClickId, attribution.clickId!);
      }
      await prefs.setBool(_kAttributed, attribution.isAdbirt);
    } catch (e) {
      // An install referrer is unavailable on non-Play installs and on some
      // devices. That is normal and must not break the host app's startup.
      debugPrint('Adbirt: install referrer unavailable ($e)');
    }
  }

  /// iOS has no install-referrer equivalent.
  ///
  /// Attribution on iOS requires either SKAdNetwork or an MMP. This method
  /// requests ATT so a host app that wants IDFA can, and does nothing else.
  /// It is not iOS attribution and must not be described as such.
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

  /// Log an event.
  ///
  /// Returns true when the event was accepted by the server. 0.0.6 returned
  /// void and swallowed the response, so an integrator had no way to know
  /// whether anything worked - and nothing did.
  static Future<bool> logEvent(
    String eventName,
    Map<String, dynamic> parameters,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final config = _config ??
        AdbirtConfig(apiToken: prefs.getString(_kApiToken) ?? '');

    if (config.apiToken.isEmpty) {
      debugPrint('Adbirt: not initialized - call initializeApp first');
      return false;
    }

    // Only report events for installs this SDK is configured to attribute.
    if (!(prefs.getBool(_kAttributed) ?? false)) return false;

    try {
      final response = await http.post(
        Uri.parse(config.eventEndpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiToken}',
        },
        body: jsonEncode({
          'event_name': eventName,
          'adbirt_identifier': prefs.getString(_kIdentifier),
          'adb_clickid': prefs.getString(_kClickId),
          'utm_source': prefs.getString(_kSource),
          'utm_medium': prefs.getString(_kMedium),
          'parameters': parameters,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) return true;

      debugPrint('Adbirt: event rejected (${response.statusCode})');
      return false;
    } catch (e) {
      debugPrint('Adbirt: event send failed ($e)');
      return false;
    }
  }

  /// The Adbirt click id for this install, when there is one.
  static Future<String?> clickId() async =>
      (await SharedPreferences.getInstance()).getString(_kClickId);

  static String _generateIdentifier() {
    const chars =
        'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
    final rnd = Random.secure();
    final body = String.fromCharCodes(
      Iterable.generate(20, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))),
    );
    return 'adbirt_id_$body';
  }
}
