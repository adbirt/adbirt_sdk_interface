/// Attribution parsing and configuration for the Adbirt SDK.
///
/// This is deliberately pure: no plugins, no I/O, no platform channels. The
/// defect that made version 0.0.6 inert — a producer returning `utm_source`
/// and a consumer reading `utmSource` — was invisible precisely because the
/// logic was tangled with `SharedPreferences` and the install-referrer plugin
/// and so was never unit tested.
library;

/// The default install source Adbirt tags its own campaign links with.
const String kDefaultAttributedSource = 'adbirt';

/// What an install referrer told us about where the install came from.
class AdbirtAttribution {
  const AdbirtAttribution({
    this.source,
    this.medium,
    this.clickId,
    this.campaignId,
    required this.isAdbirt,
  });

  /// `utm_source`, verbatim.
  final String? source;

  /// `utm_medium`, verbatim. Typically the pricing model: cpa, cpc, cpm.
  final String? medium;

  /// The Adbirt click id, when the campaign link carried one. This is what
  /// ties an install back to the click that caused it.
  final String? clickId;

  final String? campaignId;

  /// Whether this install should be attributed to a configured source.
  final bool isAdbirt;

  static const AdbirtAttribution none = AdbirtAttribution(isAdbirt: false);

  Map<String, dynamic> toJson() => {
        if (source != null) 'utm_source': source,
        if (medium != null) 'utm_medium': medium,
        if (clickId != null) 'adb_clickid': clickId,
        if (campaignId != null) 'adb_campaignid': campaignId,
      };
}

/// Parse a Google Play install referrer string into attribution data.
///
/// Accepts both the raw form (`utm_source=adbirt&utm_medium=cpa`) and the
/// URL-encoded form Play sometimes delivers. Never throws: an organic install,
/// an empty referrer and a malformed referrer are all ordinary inputs that must
/// return "not attributed" rather than blow up in the host app's startup path.
///
/// [attributedSources] lets one build serve any network. Version 0.0.6 compared
/// against the literal 'adbirt', so a white-labelled build could never
/// attribute anything.
AdbirtAttribution parseInstallReferrer(
  String? referrer, {
  Set<String> attributedSources = const {kDefaultAttributedSource},
}) {
  if (referrer == null || referrer.trim().isEmpty) {
    return AdbirtAttribution.none;
  }

  try {
    var decoded = referrer;
    // A referrer that arrives percent-encoded contains no literal '=' until it
    // is decoded. Decoding twice is harmless; not decoding loses everything.
    if (!decoded.contains('=') || decoded.contains('%3D')) {
      decoded = Uri.decodeFull(decoded);
    }

    final params = Uri.splitQueryString(decoded);

    final source = _nullIfEmpty(params['utm_source']);
    final normalizedTargets =
        attributedSources.map((s) => s.toLowerCase()).toSet();

    return AdbirtAttribution(
      source: source,
      medium: _nullIfEmpty(params['utm_medium']),
      clickId: _nullIfEmpty(params['adb_clickid'] ?? params['clickid']),
      campaignId: _nullIfEmpty(params['adb_campaignid'] ?? params['utm_campaign']),
      isAdbirt:
          source != null && normalizedTargets.contains(source.toLowerCase()),
    );
  } catch (_) {
    // A malformed referrer is not worth crashing an app's first launch over.
    return AdbirtAttribution.none;
  }
}

String? _nullIfEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// SDK configuration.
///
/// The endpoint is configurable. Version 0.0.6 hard-coded
/// `https://adbirt.com/api/v1/partners/log-event` — the legacy platform — so an
/// integrator had no way to point the SDK at the DSP, or at a staging
/// environment, or at anything else.
class AdbirtConfig {
  const AdbirtConfig({
    required this.apiToken,
    this.baseUrl = defaultBaseUrl,
    this.attributedSources = const {kDefaultAttributedSource},
  });

  static const String defaultBaseUrl = 'https://api.adbirt.com';

  final String apiToken;
  final String baseUrl;

  /// Install sources this build should attribute. Configurable so one SDK can
  /// serve many networks rather than only Adbirt's own campaigns.
  final Set<String> attributedSources;

  String get eventEndpoint => '$baseUrl/api/v1/events';

  /// Fail loudly at initialization rather than silently dropping every event.
  /// Version 0.0.6 used `assert`, which is a no-op in release builds, so a
  /// missing token produced no error and no data in production.
  void validate() {
    if (apiToken.trim().isEmpty) {
      throw ArgumentError.value(
        apiToken,
        'apiToken',
        'Adbirt API token must not be empty',
      );
    }
    if (baseUrl.trim().isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'baseUrl must not be empty');
    }
  }
}
