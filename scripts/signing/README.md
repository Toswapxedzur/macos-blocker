# Mac Vault App Group signing

Safari Vault and Mac Vault remain separate apps. Their authenticated Safari
bootstrap uses the shared group `group.com.adamancia.vault` in production and
`group.com.adamancia.vault.development` in development. Apple signing must
explicitly authorize that shared container for each participating app.

Select a Mac app profile with `MAC_VAULT_APP_PROVISIONING_PROFILE`. Development
launching uses the existing stable Developer ID selected by
`MAC_VAULT_SIGNING_IDENTITY`; release signing uses `SIGNING_IDENTITY`. The
profile must authorize the actual Mac app bundle identifier, the matching
shared group, and the same developer team used for Safari Vault and its native
extension. The helper validates expiration, bundle authorization, group, and
team before replacing a development wrapper or embedding anything in a
release. It embeds `Contents/embedded.provisionprofile` and generates only
App Group/application/team entitlements. It does not sandbox Mac Vault.

The outer app receives restricted entitlements after existing leaf signing;
native hosts, resource bundles and framework libraries do not inherit the
Mac app's profile. Post-sign verification checks the developer team, the
profile's authorization of the actual signing certificate, and
entitlements. Absent an explicitly selected profile, current ordinary Mac
signing remains available and reports Safari pairing unavailable.

Run on mini1:

```sh
python3 scripts/signing/test-vault-app-group.py
python3 scripts/development/test-vault-delivery.py
```

The metadata and launcher tests use disposable account-free fixtures. They
prove profile rejection and wrapper/controller contracts, not Apple signature
acceptance or live App Group access. The actual Safari connection still needs
Apple-authorized profiles, matching installed signing identities, and owner
enablement in Safari.

Apple documents [App Group configuration](https://developer.apple.com/documentation/Xcode/configuring-app-groups)
and the [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).
