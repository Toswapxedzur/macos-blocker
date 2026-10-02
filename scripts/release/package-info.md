# Release scripts

- `build_app.sh`: builds the release Mac app and bundles resources, classifier runtime and native host.
- `sign_app.sh`: signs the release, optionally embedding an authorized production App Group profile for Safari pairing.
- `create_dmg.sh`: assembles and signs the installer disk image.
- `notarize_dmg.sh`: submits/staples the disk image through Apple's notarization service.
- `verify_release.sh`: verifies release signatures and installer metadata.
- `full_release_dmg.sh`: runs the complete release pipeline.
