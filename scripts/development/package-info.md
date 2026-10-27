# Development scripts

- `migrate_state_once.sh`: existing bounded development-state reconciliation.
- `vault-delivery.py`: shared integration, mini1 verification and laptop delivery controller; explicit pinned history reconciliation preserves original evidence and guards subsequent rewritten ancestry. The explicit owner-approved metadata recovery preserves both object histories and original receipts before a normal merge; it never resets integration or carries old verification.
- `launch-mac-vault-build.sh`: signing/build/exec implementation used by the controller; optional authorized App Group profile wraps the executable for Safari pairing. Mini1 can use it locally without laptop Git configuration.
- `test-vault-delivery.py`: disposable Git/process regression fixtures; run on mini1.
- `test-history-reconciliation.py`: disposable Git/local-remote fixtures for exact adoption, preservation, partial-state refusal, bootstrap restrictions and subsequent delivery guards; run on mini1.
- `README.md`: required delivery workflow and commands.
- `test-metadata-recovery.py`: disposable Git fixtures for exact approved metadata aliases, preservation, preflight drift/tampering and mandatory fresh verification/push; run on the selected test host.
