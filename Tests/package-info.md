# Mac Vault tests

- `ActivityTimeBins.test.js`: isolated script regression.
- `MacBlockerAppFeatureTests/`: native contract test sources.
- `MacBlockerCoreTests/`: native contract test sources.
- `MacBlockerMacControlTests/`: native contract test sources.
- `NativeEditorShim.test.js`: isolated script regression.
- `RuleLogShim.test.js`: isolated script regression.
- `WebUI/`: native contract test sources.

`MacBlockerAppFeatureTests/ManagedRuleTimeChecks.swift` shares native timer/hub/persistence checks between XCTest and a disposable CLI probe on hosts without XCTest. `ManagedRuleTimeTests.swift` registers them with XCTest. These checks do not start a listener or a GUI app.
