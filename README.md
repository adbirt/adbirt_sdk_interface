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

TODO: Flutter SDK for adbirt

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
  adbirt_sdk_interface: ^0.0.1
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
  await AdbirtADKInterface.initializeApp('your_api_token');
  
  runApp(MyApp());
}
```

- Event/Transaction tracking
```dart
// Log a custom event with event name and parameters
AdbirtADKInterface.logEvent('apex:transaction', {
  'user_id': '12345', 
  'type': 'cash withdrawal' // can be anything
  'amount': '10,000',
});
```


## Additional information
For more Information, visit [https://adbirt.com/contact](https://adbirt.com/contact) for more information about the Adbirt platform.

