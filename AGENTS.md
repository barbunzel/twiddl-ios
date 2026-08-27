# Twiddl iOS repository guidance

Twiddl is a focused, free, privacy-first chromatic tuner.

## Product and engineering rules

- Keep launch-to-listening immediate: no account, onboarding, ad, paywall,
  analytics, tracking, upload, or required network request.
- Microphone audio stays in memory on device and is never recorded or sent.
- Preserve automatic listening, interruption recovery, pause/resume, and the
  screen-awake behavior.
- Pitch-engine changes require matching fixtures and an explicit parity check
  with the Android implementation.
- Verify pitch work with `swift test`, `swift run TuningCoreChecks`, and a
  physical iPhone; synthetic tests do not replace real microphone testing.
- Do not commit, tag, push, upload builds, or change release metadata unless the
  request explicitly includes it.
- Never inspect or commit signing files, certificates, provisioning profiles,
  account credentials, recordings, or generated build output.
