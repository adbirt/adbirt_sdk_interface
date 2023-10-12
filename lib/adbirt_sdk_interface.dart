library adbirt_sdk_interface;

import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:android_play_install_referrer/android_play_install_referrer.dart';
import 'dart:core';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';

import 'package:flutter/foundation.dart';

abstract class AdbirtADKInterface {
  static String apiURL = 'https://adbirt.com/api/v1/partners/log-event';

  static Future<void> initializeApp(String apiToken) async {
    SharedPreferences sharedPrefs = await SharedPreferences.getInstance();

    sharedPrefs.setString('adbirt_api_token', apiToken);

    if (Platform.isAndroid) {
      var installReferrerInfo =
          await AdbirtADKInterface._getReferrerDetailsAndroid();

      var existingUtmource = sharedPrefs.getString('utmsource');

      if (existingUtmource == null || existingUtmource.isEmpty) {
        if (installReferrerInfo != null) {
          var utmSource = installReferrerInfo['utmSource'];
          var utmMedium = installReferrerInfo['utmMedium'];

          await sharedPrefs.setString('utm_source', utmSource ?? '');
          await sharedPrefs.setString('utm_medium', utmMedium ?? '');

          if (utmSource == 'adbirt') {
            await sharedPrefs.setBool('is_adbirt', true);
          }
        }
      }
    } else if (Platform.isIOS) {
      await AdbirtADKInterface._getReferrerDetailsIOS();
    }

    var adbirtIdentifier = sharedPrefs.getString('adbirt_identifier');

    if (adbirtIdentifier == null || adbirtIdentifier.isEmpty) {
      adbirtIdentifier = AdbirtADKInterface._geterateUniqueIdentifyer();

      await sharedPrefs.setString('adbirt_identifier', adbirtIdentifier);
    }
  }

  //

  static Future<Map<String, String>?> _getReferrerDetailsAndroid() async {
    try {
      ReferrerDetails referrerDetails =
          await AndroidPlayInstallReferrer.installReferrer;
      // Decode the URL-encoded installReferrer string
      String decodedReferrer =
          Uri.decodeFull(referrerDetails.installReferrer ?? '');

      // Parse the decoded string as a URI
      Uri referrerUri = Uri.parse('?$decodedReferrer');

      // Extract the utm_source and utm_medium fields
      String utmSource = referrerUri.queryParameters['utm_source']!;
      String utmMedium = referrerUri.queryParameters['utm_medium']!;

      debugPrint('utm_source: $utmSource');
      debugPrint('utm_medium: $utmMedium');

      return {
        'utm_source': utmSource,
        'utm_medium': utmMedium,
      };
    } catch (e) {
      debugPrint('Failed to get referrer details: $e');

      return null;
    }
  }

  //

  static Future<void> _getReferrerDetailsIOS() async {
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status == TrackingStatus.notDetermined) {
        await AppTrackingTransparency.requestTrackingAuthorization();
      }

      //
    } catch (e) {
      debugPrint('Failed to get referrer details: $e');
    }
  }

  //

  static Future<void> logEvent(
    String eventName,
    Map<String, dynamic> parameters,
  ) async {
    SharedPreferences sharedPrefs = await SharedPreferences.getInstance();

    String? adbirtApiToken = sharedPrefs.getString('adbirt_api_token');

    if (adbirtApiToken == null || adbirtApiToken.isEmpty) {
      debugPrint('Adbirt API token not set!!!');
    }

    String jsonParameters = jsonEncode(parameters);

    String encodedPayload = Uri.encodeQueryComponent(jsonParameters);

    await http.post(
      Uri.parse(AdbirtADKInterface.apiURL),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'Authorization': 'Bearer $adbirtApiToken',
      },
      body: encodedPayload,
    );
  }

  //

  // static Future<bool> _trackCurrentScreen(String screenName) async {
  //   // TODO: implement this

  //   return false;
  // }

  static String _geterateUniqueIdentifyer() {
    int length = 20;

    const chars =
        'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';

    final rnd = Random();

    return 'adbirt_id_${String.fromCharCodes(Iterable.generate(
      length,
      (_) => chars.codeUnitAt(rnd.nextInt(chars.length)),
    ))}';
  }
}
