# Twiddl

A focused, privacy-first chromatic tuner for iPhone. Twiddl listens through the microphone, estimates the fundamental pitch on-device, and shows the nearest chromatic note with its deviation in cents.

Learn more at [twiddl.app](https://twiddl.app).

## MVP

- Live chromatic pitch detection from A0 through C8
- Zero-tap listening when the app opens or returns to the foreground
- Keeps the display awake while actively listening
- Recovers from calls, Siri, media-service resets, and microphone route changes
- Large note and octave display
- ±50-cent tuning gauge with flat/sharp guidance
- Adjustable concert pitch from A4 = 430–450 Hz
- No accounts, ads, analytics, tracking, or app-initiated network requests
- Microphone audio is processed only on the device
- In-app privacy details and troubleshooting

## Run it

1. Install the full version of Xcode from the Mac App Store.
2. Open `TwiddlTuner.xcodeproj`.
3. For device signing, copy `Config/Signing.xcconfig.example` to
   `Config/Signing.xcconfig` and replace `YOUR_TEAM_ID` with your Apple
   Developer Team ID. This local file is ignored by Git.
4. Change the bundle identifier if Xcode says it is already in use.
5. Run on a physical iPhone. The Simulator is useful for layout, but real microphone tuning should be tested on a device.

The tuning engine has platform-independent checks. They work with the command-line tools alone:

```sh
swift run TuningCoreChecks
```

After installing full Xcode, run the XCTest suite with:

```sh
swift test
```

## Privacy

Twiddl has no account system, advertising, analytics, tracking, or app-initiated
network requests. Microphone audio is analyzed in memory on the device and is
never recorded, saved, or uploaded. The app requires no API keys or other
runtime secrets.

## Copyright

Copyright © 2026 Luis Diego Hernandez. All rights reserved.

The source is published for transparency. No permission is granted to copy,
modify, or redistribute it. The Twiddl name, icon, screenshots, and visual
identity are not licensed for reuse.
