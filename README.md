# MacFan

MacFan is a standalone macOS Menu Bar mini app for observing Mac thermals and controlling fan behavior without depending on external tools such as `mactop`.

## Features

- Menu Bar mini app built with SwiftUI `MenuBarExtra`.
- Fan control modes:
  - Auto: let macOS control fan behavior.
  - Custom RPM: user-selected fixed fan target.
  - Full Blast: maximum fan speed.
  - Fan Curve: saved temperature-to-RPM curves.
- Temperature-Safe System:
  - Enabled by default.
  - 90 °C threshold by default.
  - Overrides unsafe custom settings using either Full Blast or Auto failsafe behavior.
- Fan curve templates:
  - Quiet
  - Regular
  - Aggressive
  - Unlimited user-created custom curves persisted locally.
- Sensor dashboard:
  - Good names for known temperature probes.
  - Now, Average 15s, and historic high temperature.
  - CPU name, CPU core count, and GPU core count where macOS exposes the data.
- Fan curves can be driven by one selected thermal source:
  - Hottest CPU core.
  - Average CPU core temperature.
  - Average GPU temperature.

## Building

On macOS 13 or newer with Xcode command line tools installed:

```bash
swift build
swift run MacFan
```

Fan writes use Apple's private SMC interface and may require elevated privileges or helper-tool hardening for distribution. The app is structured so the UI, safety model, sensor collection, and SMC fan backend are separate and can later be moved behind a privileged helper if needed.
