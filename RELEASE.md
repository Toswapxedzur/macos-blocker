# Mac Vault release guide

This guide follows the checked-in build scripts. It intentionally contains no personal signing identity, notarization profile, password, or account data.

## Before a release

1. Run the relevant Swift, web UI, localization and packaging checks on the selected test Mac.
2. Set the release version and build number in `XcodeProject/project.yml`.
3. Review the English manual, localized manuals, and the editor translation audit.
4. Verify the release branch, tag, and milestone policy before publishing an artifact.

## Website DMG pipeline

Current distribution is direct website download, with an **alpha** designation.
The supported Mac target is **macOS 13.3+**. Published artifacts and version tags
remain immutable. The next private candidate uses version **2.2.8 (12)**; it is
not a public release until separately authorized and verified.

The scripts live in `scripts/release/`. Their defaults can be overridden with environment variables, including `APP_NAME`, `BUNDLE_ID`, `TEAM_ID`, `SIGNING_IDENTITY`, `NOTARY_PROFILE`, `VERSION`, and `BUILD_NUMBER`.

`build_app.sh` builds one explicit architecture (`VAULT_BUILD_ARCH=arm64` or
`x86_64`, defaulting to the build host), resolving all app, resource and native
messaging helper paths through SwiftPM. Local model libraries are retired from
the production package; `verify-macos-runtime.py` rejects them. A successful
build does not establish native macOS 13.3 acceptance: verify the final artifact
on supported OS and hardware. This candidate's test host is Mini2.

Production signing requires `MAC_VAULT_APP_PROVISIONING_PROFILE` authorizing the
production Mac bundle identifier, team, signing certificate and shared App Group.
It refuses a missing profile rather than shipping a Mac/Safari pair that cannot
authenticate. Development profiles do not satisfy this requirement.

On a configured signing machine, build, sign and notarize using distinct private
`BUILD_DIR` and `DIST_DIR` paths outside the public website artifacts:

```bash
scripts/release/build_app.sh
scripts/release/sign_app.sh
scripts/release/create_dmg.sh
scripts/release/notarize_dmg.sh
```

The scripts derive the version/build from `project.yml`; set `BUILD_DIR`,
`DIST_DIR`, `DMG_NAME`, `MAC_VAULT_APP_PROVISIONING_PROFILE` and `NOTARY_PROFILE`
for the selected private build. Transfer the exact final stapled DMG to Mini2,
then run `verify_release.sh` and installed-runtime acceptance there. Record the
source commit, checksum, signature, notarization result and test evidence.
`full_release_dmg.sh` runs verification on its build machine, so do not use it
when that machine is not the selected test host.

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
