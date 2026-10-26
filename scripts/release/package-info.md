# Release scripts

- `build_app.sh`: builds the release Mac app and bundles resources and native host.
- `verify-macos-runtime.py`: checks the app architecture, minimum OS and self-contained dependencies; rejects retired llama/ggml/OpenMP libraries.
- `test-packaging.py`: Mini2 fixtures with actual Mach-O executables; verify cloud-only packaging, retired-runtime refusal, SwiftPM output selection and Safari-safe uninstall.
- `sign_app.sh`: requires and embeds an authorized production App Group profile for Safari pairing before release signing.
- `create_dmg.sh`: assembles and signs the installer disk image.
- `notarize_dmg.sh`: submits/staples the disk image through Apple's notarization service.
- `verify_release.sh`: verifies release signatures and installer metadata.
- `full_release_dmg.sh`: runs the complete release pipeline.

- `version.py`: reads the one canonical native version/build in `XcodeProject/project.yml`; every package script derives its defaults from it. Explicit historical VERSION/BUILD_NUMBER overrides remain supported.
