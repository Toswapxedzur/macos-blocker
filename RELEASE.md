# Mac Vault release guide

This guide follows the checked-in build scripts. It intentionally contains no personal signing identity, notarization profile, password, or account data.

## Before a release

1. Run `swift test` from the repository root.
2. Set the release version and build number in the controlled project/build configuration.
3. Review the English manual, localized manuals, and the editor translation audit.
4. Verify the release branch, tag, and milestone policy before publishing an artifact.

## Website DMG pipeline

Current distribution is direct website download, with an **alpha** designation.
The supported Mac target is **macOS 13.3+**. Published artifacts and version tags
remain immutable; select a new version/build before publishing this candidate.

The scripts live in `scripts/release/`. Their defaults can be overridden with environment variables, including `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, and `BUILD_NUMBER`.

`build_app.sh` builds one explicit architecture (`VAULT_BUILD_ARCH=arm64` or
`x86_64`, defaulting to the build host), resolving all app/resource/helper paths
through SwiftPM. It first prepares a pinned source runtime in
`release/runtime-<architecture>/install`; `VAULT_RUNTIME_WORK` changes that
staging root. A previously built runtime may be selected with
`VAULT_LLAMA_PREFIX`, but its pinned source receipt, hashes, architecture and
Mach-O minimum OS are checked before use. Headers and libraries use the same
prefix. Homebrew binaries are not accepted for release packaging.

The runtime retains Accelerate BLAS and OpenMP; Apple silicon also retains
embedded Metal shaders targeting 13.3. The bundled notices include the exact
source references and build receipt. Source/build checks do not establish native
13.3 acceptance: verify the final artifact on the supported OS and hardware.
All tests run on mini1; it currently runs 14.2.1, so 13.3 acceptance is still open.

Production signing requires `MAC_VAULT_APP_PROVISIONING_PROFILE` authorizing the
production Mac bundle identifier, team, signing certificate and shared App Group.
It refuses a missing profile rather than shipping a Mac/Safari pair that cannot
authenticate. Development profiles do not satisfy this requirement.

Run the complete pipeline only on a configured signing machine:

```bash
VERSION=<version> BUILD_NUMBER=<build> scripts/release/full_release_dmg.sh
```

The pipeline composes the existing build, signing, DMG, notarization, and verification scripts. Treat its output as a release candidate until the verification step succeeds.

## Xcode project

`XcodeProject/project.yml` retains the historical sandboxed target. It is not the
selected website distribution pipeline. Use the SwiftPM DMG pipeline above for
the full Mac Vault product. Do not commit generated credentials, provisioning
files, or notarization profiles.

## After a release

1. Create the immutable version tag and permanent release branch according to the release-management policy.
2. Publish the release artifact and checksum.
3. Update the public release registry only after the artifact URL is final.
4. Keep release notes in English unless a reviewed localized release note is supplied.
