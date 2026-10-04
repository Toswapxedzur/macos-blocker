# Release scripts

- `build_app.sh`: builds the release Mac app and bundles resources, classifier runtime and native host.
- `build-macos-runtime.py` and `runtime-sources.json`: pin and checksum llama.cpp with its matching ggml and OpenMP source; build each architecture for macOS 13.3 with Accelerate and OpenMP, plus Metal on Apple silicon.
- `verify-macos-runtime.py`: rejects modified source-runtime inventories, wrong architectures, newer minimum OS requirements, external app dependencies and missing notices.
- `test-packaging.py`: mini1 fixtures with actual Mach-O libraries; verify stock Bash bundling, prefix-independent execution, refusal guards, SwiftPM output selection and Safari-safe uninstall.
- `sign_app.sh`: requires and embeds an authorized production App Group profile for Safari pairing before release signing.
- `create_dmg.sh`: assembles and signs the installer disk image.
- `notarize_dmg.sh`: submits/staples the disk image through Apple's notarization service.
- `verify_release.sh`: verifies release signatures and installer metadata.
- `full_release_dmg.sh`: runs the complete release pipeline.

- `version.py`: reads the one canonical native version/build in `XcodeProject/project.yml`; every package script derives its defaults from it. Explicit historical VERSION/BUILD_NUMBER overrides remain supported.
