# Mac Vault release guide

This guide follows the checked-in build scripts. It intentionally contains no personal signing identity, notarization profile, password, or account data.

## Before a release

1. Run `swift test` from the repository root.
2. Set the release version and build number in the controlled project/build configuration.
3. Review the English manual, localized manuals, and the editor translation audit.
4. Verify the release branch, tag, and milestone policy before publishing an artifact.

## Website DMG pipeline

The scripts live in `scripts/release/`. Their defaults can be overridden with environment variables, including `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, and `BUILD_NUMBER`.

Run the complete pipeline only on a configured signing machine:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

The pipeline composes the existing build, signing, DMG, notarization, and verification scripts. Treat its output as a release candidate until the verification step succeeds.

## Xcode distribution targets

Generate the Xcode project from `XcodeProject/project.yml`, configure the appropriate signing team and capabilities in the approved environment, then archive the relevant target. Do not commit generated credentials, provisioning files, or notarization profiles.

## After a release

1. Create the immutable version tag and permanent release branch according to the release-management policy.
2. Publish the release artifact and checksum.
3. Update the public release registry only after the artifact URL is final.
4. Keep release notes in English unless a reviewed localized release note is supplied.
