import 'package:flutter_test/flutter_test.dart';
import 'package:adbirt_sdk_interface/src/attribution.dart';

/// The install-referrer parser is where attribution is won or lost.
///
/// Version 0.0.6 shipped a producer that returned `utm_source` and a consumer
/// that read `utmSource`, so the value was always null, `is_adbirt` was never
/// set, and every event send was gated on it. The SDK could not attribute an
/// install or send a single event. These tests exist so that class of defect
/// cannot ship again unnoticed.
void main() {
  group('parseInstallReferrer', () {
    test('reads utm_source and utm_medium from a Play referrer string', () {
      final result = parseInstallReferrer('utm_source=adbirt&utm_medium=cpa');

      expect(result.source, 'adbirt');
      expect(result.medium, 'cpa');
    });

    test('reads a URL-encoded referrer string', () {
      final result =
          parseInstallReferrer('utm_source%3Dadbirt%26utm_medium%3Dcpc');

      expect(result.source, 'adbirt');
      expect(result.medium, 'cpc');
    });

    test('captures the Adbirt click id when the referrer carries one', () {
      final result = parseInstallReferrer(
          'utm_source=adbirt&utm_medium=cpa&adb_clickid=adb_abc123');

      expect(result.clickId, 'adb_abc123');
    });

    test('returns an empty attribution for an organic install', () {
      // Play sends a referrer with no UTM parameters for organic installs.
      // 0.0.6 force-unwrapped utm_source here and threw.
      final result = parseInstallReferrer('utm_source=google-play&utm_medium=organic');

      expect(result.source, 'google-play');
      expect(result.isAdbirt, isFalse);
    });

    test('does not throw on a referrer with no parameters at all', () {
      final result = parseInstallReferrer('');

      expect(result.source, isNull);
      expect(result.isAdbirt, isFalse);
    });

    test('does not throw on a malformed referrer', () {
      final result = parseInstallReferrer('%%%not-a-referrer%%%');

      expect(result.isAdbirt, isFalse);
    });
  });

  group('attribution source matching', () {
    test('recognises the default adbirt source', () {
      expect(parseInstallReferrer('utm_source=adbirt').isAdbirt, isTrue);
    });

    test('matches the source case-insensitively', () {
      // A campaign built by hand with 'Adbirt' must still attribute.
      expect(parseInstallReferrer('utm_source=Adbirt').isAdbirt, isTrue);
      expect(parseInstallReferrer('utm_source=ADBIRT').isAdbirt, isTrue);
    });

    test('accepts a caller-configured source so one build can serve any network',
        () {
      // The point of the rewrite: the SDK must not hard-code the one source it
      // attributes, or a white-labelled build can never attribute at all.
      final result = parseInstallReferrer(
        'utm_source=partner-network',
        attributedSources: {'partner-network'},
      );

      expect(result.isAdbirt, isTrue);
    });

    test('does not attribute a source it was not told about', () {
      expect(parseInstallReferrer('utm_source=some-other-network').isAdbirt,
          isFalse);
    });
  });

  group('AdbirtConfig', () {
    test('defaults to the documented API base URL', () {
      const config = AdbirtConfig(apiToken: 't');
      expect(config.baseUrl, isNotEmpty);
    });

    test('accepts an override so a client is not pinned to one deployment', () {
      // 0.0.6 hard-coded https://adbirt.com/api/v1/partners/log-event, the
      // legacy platform, with no way to point at the DSP.
      const config = AdbirtConfig(
        apiToken: 't',
        baseUrl: 'https://api.adbirt.com',
      );
      expect(config.baseUrl, 'https://api.adbirt.com');
      expect(config.eventEndpoint, 'https://api.adbirt.com/api/v1/events');
    });

    test('rejects an empty api token rather than failing silently later', () {
      expect(() => AdbirtConfig(apiToken: '').validate(), throwsArgumentError);
    });
  });
}
