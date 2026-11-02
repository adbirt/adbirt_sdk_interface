<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/guides/libraries/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-library-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/developing-packages).
-->

Flutter SDK for adbirt

## Features

- Initialize App: Initialize your application with an Adbirt API token.
- Track User Events: Log custom events along with event parameters to the Adbirt platform.
- Android Install Referrer: Automatically capture UTM source and medium values for Android installations.
- iOS Tracking Authorization: Request and manage tracking authorization on iOS devices.

## Getting started
You need the followig ->

flutter:
  sdk: flutter
android_play_install_referrer: ^0.3.0
shared_preferences: ^2.2.2
app_tracking_transparency: ^2.0.4
http: ^1.1.0

## Usage

Add the package to your pubspec.yaml file:
```yaml
dependencies:
  adbirt_sdk_interface: ^0.1.0
```

Then run:
```bash
flutter pub get
```

Here's a quick guide on how to use this package:

- Initialization
```dart
import 'package:adbirt_sdk_interface/adbirt_sdk_interface.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize your app with the Adbirt API token
  // This must be done first for other methods like `logEvent` to work
  await AdbirtADKInterface.initializeApp('adb_pk_your_publishable_token');
  
  runApp(MyApp());
}
```

- Events

Any event name works. Ask Adbirt to set the names you want to pay for as
payable events on your campaign (with a payout per event); other events are
accepted but not billed.

```dart
// Registration, deposit and purchase helpers.
await AdbirtADKInterface.logRegistration();
await AdbirtADKInterface.logDeposit(5000, 'NGN');
await AdbirtADKInterface.logPurchase(9.99, 'USD', parameters: {'sku': 'pro'});

// Any other event, with an optional value.
await AdbirtADKInterface.logValueEvent('subscribe', value: 4.99, currency: 'USD');
await AdbirtADKInterface.logEvent('level_complete', {'level': 3});
```

Each call returns `true` when the server accepted the event. Events that cannot
be sent (offline, server busy) are kept on the device and retried later; call
`AdbirtADKInterface.flush()` when connectivity returns to send them sooner.

- Configuration

```dart
await AdbirtADKInterface.initializeApp(
  'adb_pk_...',
  config: const AdbirtConfig(
    apiToken: 'adb_pk_...',
    baseUrl: 'https://api.adbirt.com', // default
  ),
);
```

Use the **publishable** token (`adb_pk_...`). The secret token (`adb_sk_...`)
is for your server only: it is the only one that can confirm a deposit as
validated, so it must never ship in an app.

- Attribution

On Android the SDK reads the Google Play install referrer, which Adbirt's
click-out fills with `adb_clickid`. iOS has no install referrer: if your app is
opened from an Adbirt link carrying `adb_clickid`, pass it on:

```dart
await AdbirtADKInterface.setClickId(uri.queryParameters['adb_clickid']!);
```

Use this SDK only when you do not use an MMP. With AppsFlyer, Adjust, Branch or
Singular, conversions reach Adbirt through the MMP's postback instead.

## Additional information
For more Information, visit [https://adbirt.com/contact](https://adbirt.com/contact) for more information about the Adbirt platform.

