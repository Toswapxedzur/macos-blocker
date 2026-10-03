# Adamancia Vault Privacy Policy

Last updated: October 3, 2026

Adamancia Vault is a focus and blocking app. This policy describes the macOS app release.

## Summary

Adamancia Vault is designed to keep blocking rules and usage state local to your Mac by default. The app does not sell personal data, does not display ads, and does not share personal data with data brokers.

## Data Stored Locally

The app may store the following local data on your Mac:

- Blocking groups, schedules, timers, freeze/snooze state, and app settings.
- Local web editor storage mirrored from the bundled web interface.
- Local bridge/link state when you connect the macOS app to browser extensions.
- App enforcement policy files used by the macOS blocking engine.
- App Group container data when an App Store build or extension build uses an App Group.

Known local paths are documented in `RELEASE.md` and in the uninstaller script.

## Official dictionaries and creator contributions

Vault checks for official term and creator dictionary updates at startup. You choose when to download updates. Creator lookup defaults to a 10,000-entry cache with adjustable capacity; a cache miss sends the public, platform-scoped creator ID to our server. Full-download creator lookup is local. Dictionary downloads and lookups do not require your own AI API key. User-written and user AI-generated definitions remain local and take priority over official definitions. Optional web/AI research uses its separate provider settings.

Help improve the creator dictionary is ON by default. On first launch, a screen explains the feature and lets you disable it before any contribution is sent. You can turn it off at any time in Classifier → Knowledge. When enabled, the app samples missing public creator IDs and their displayed public subscriber/follower counts (which may be rounded); missing counts are sent as unknown. It sends no term names, titles, browsing history, personal definitions, API keys or persistent user/device identifiers. Submissions are deduplicated locally, sampled one in four IDs per day, and capped at 50 per day. Turning it off cancels pending contribution requests and stops future submissions; it does not recall requests already received.

The server retains candidate creator IDs, public counts and last-seen timestamps for seven days after the latest submission. An in-memory, temporary address hash limits abuse and expires hourly; the contribution database stores no IP addresses. Hosting and network providers necessarily process requests. These candidate submissions help prioritize the project-maintained public dictionary; they are distinct from routine cache-miss lookup. Official descriptions are maintained separately and may remain published in future versions.

## Network Use

The app may open a local network listener for its web-app bridge so browser extensions can connect to the Mac app. The app may also make network requests if a bundled feature needs to communicate with Adamancia services, for example optional account or sync-related features.

## Analytics and Ads

The macOS app does not include third-party advertising SDKs. It should not send analytics unless a feature explicitly says it is using an online service.

## Optional Accounts and Sync

If account or sync features are enabled in a release, those features may send the minimum data needed to provide that feature, such as account identity and sync payloads. Downloads and local blocking must not require an account.

## Permissions

Depending on channel and enabled features, Adamancia Vault may ask macOS for permissions such as Accessibility, network access, login item registration, or App Group access. These permissions are used to provide blocking, app launch, bridge, and persistence features.

## Uninstalling

The DMG includes `uninstall.command`. It asks for confirmation, quits the app if running, unregisters the app's login item when possible, removes `/Applications/AdamanciaVault.app`, and optionally removes only known files created by this app.

## Contact

For privacy questions, open an issue in the public GitHub repository or use the contact channel published on the Adamancia Vault website.
