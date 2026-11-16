# MiniGauge for iPhone

Live engine data from the MiniGauge cluster (R53 Mini Cooper S, ESP32-S3) over Bluetooth:
dashboard, every BMW-mode value, the gauge's own dials, trouble codes and fault memory,
dyno, trip logs, and a Live Activity for the Lock Screen, the Dynamic Island and **CarPlay** (iOS 26+).

The gauge streams over Bluetooth **in K-line mode** (firmware v5.2 or later). It advertises as
`MiniGauge`; the app finds it by itself and reconnects whenever the gauge powers up, also in the background.

## Screens
- **Dash**: RPM, gear, speed, boost with a 60 s trace, S/C ratio, ignition per cylinder (knock), slip, fuel, duty, temps, battery.
- **Engine**: every value, grouped (air, fuel, ignition, drive, temperatures, link).
- **Gauges**: the gauge's own slots as dials, with its names, ranges and warning zones.
- **Car**: trouble codes; the gauge's read-only jobs (identify, fault memory with descriptions, steering pump, DSC search, address sweep).
- **More**: Dyno (record a pull from the phone, power and torque curve, 30-70 times), trip logs (CSV, 5 rows/s, share or Files app), raw blocks, K-line log, Lock Screen & CarPlay values, settings.

## Live Activity / CarPlay
Starts by itself when the gauge connects with the app open (iOS only allows starting one from the
foreground), then keeps updating about once a second from the background. Pick up to four values in
More → Lock Screen & CarPlay. On iOS 26+ CarPlay shows it on the dashboard; no CarPlay entitlement is needed.

## Install from Windows (Sideloadly)
1. Download **MiniGauge.ipa** (the `builds` branch of this repo, or the latest Actions run's artifact).
2. Install **iTunes** (the apple.com version, not the Microsoft Store one) and **Sideloadly** (sideloadly.io).
3. Plug in the iPhone, trust the computer. In Sideloadly drop in the .ipa, enter your Apple ID, Start.
4. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID.
   Also Settings → Privacy & Security → Developer Mode → on (iOS asks to restart).
5. Free Apple IDs sign for **7 days**: re-run Sideloadly weekly (its auto-refresh can do it over Wi-Fi).
   A paid developer account removes that limit (and allows TestFlight).

## Build
Every push to `main` builds on a GitHub Mac (`.github/workflows/ios.yml`): unit tests in the simulator,
screenshots on demo data, an unsigned `.ipa`. On a Mac: `brew install xcodegen && xcodegen generate`, open
`MiniGauge.xcodeproj`, pick your team, run.

## Protocol
`MiniGauge/Model/Protocol.swift` mirrors `phone_proto.h` in the firmware: one GATT service, LIVE notify
(ENGINE ~10/s, GAUGES ~4/s, STATUS ~1/s, little-endian binary), CMD write (ASCII commands), TEXT notify
(chunked replies, first line = the command). The unit tests decode frames produced by the firmware's own encoder.
