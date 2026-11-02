## 0.1.1

* `transactionId` on `logEvent`, `logValueEvent`, `logDeposit` and `logPurchase`
  (and `transaction_id` in the parameters of the static `logEvent`): your own id
  for one occurrence. Campaigns can charge an event every time it happens (each
  transaction, each loan); each distinct id is charged once. The SDK's own
  `event_id` stays a retry key and is never used for that.

## 0.1.0

* Events go to `POST {baseUrl}/api/v1/events`, which the Adbirt backend now
  serves, authenticated with the campaign's publishable token (`adb_pk_...`).
* Free-form events with an optional value and currency:
  `logValueEvent(name, value:, currency:, parameters:)`; `logEvent(name, params)`
  still works and reads `value`/`currency` from the parameters.
* Helpers: `logRegistration`, `logDeposit`, `logPurchase`.
* Offline queue: undelivered events are stored on the device and retried with
  exponential backoff (30 s doubling to 1 h, 10 attempts, 100 events max), on
  the next event, the next launch and `flush()`. Each event keeps its id across
  retries; the server counts one conversion per click and event name.
* `setClickId` attributes an install from a deep link carrying `adb_clickid`
  (the only route on iOS, which has no install referrer).
* The send, queue and retry logic is a pure-Dart `AdbirtClient` with injected
  storage and HTTP, covered by `test/client_test.dart`.
* Fixes from the unreleased work after 0.0.6: install referrer key mismatch
  that made attribution impossible, install event gated on an identifier
  created after it, hard-coded legacy endpoint and source.

## 0.0.6

* Record the number of android app installs.

## 0.0.5

* Update documentation, and prevent accidental triggers.

## 0.0.1

* Initial release.
