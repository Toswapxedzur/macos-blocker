# Mac Vault

Mac Vault is the native macOS member of the Vault product family. It combines a Swift policy engine, a WebView editor, native application inventory and enforcement adapters, Custom-rule support, and a local web-app bridge hub.

The current code is the source of truth. The English in-app reference is [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md).

## What is implemented

- Default groups for selected macOS applications and Custom groups for advanced policy rules.
- Immediate, allowance, and countdown blocking modes.
- Schedules, freeze modes, snooze flows, import/export, and persistent group state.
- Application inventory, device-control permission state, native enforcement adapters, and a floating status surface.
- A controlled JavaScript policy runtime with logging and syntax checking.
- A loopback WebSocket bridge hub for explicitly linked compatible groups.
- A WebView editor with the same core group model as the Vault product family.

## Development

Run the Swift package tests:

```bash
swift test
```

The package includes core policy, schedule, custom-rule, bridge, import, and macOS-control tests.

## Xcode project

The optional Xcode project is generated from [XcodeProject/project.yml](XcodeProject/project.yml):

```bash
cd XcodeProject
./generate.sh
```

Read [XcodeProject/README.md](XcodeProject/README.md) before configuring signing or distribution targets.

## Documentation policy

English documents remain canonical. The editor UI has complete locale catalogs, translated manuals live beside `WebAssets/manual/en.md`, and translated copies of the remaining maintained documents are under `i18n-docs/<locale>/`.

Legal terms and privacy notices remain separate legal documents; this README does not replace them.
