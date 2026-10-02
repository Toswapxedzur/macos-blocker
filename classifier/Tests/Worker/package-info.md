# Worker process fixtures

- `interactive_pipe.py` — mini1 integration check against the actual worker
  executable. Sends small JSON frames and awaits each response before closing
  stdin, checks UTF-8 and verifies graceful EOF. Uses only Python's standard
  library and an isolated temporary support directory.
- `package-info.md` — this direct-content map.
- `download_fixture.py` — one-request loopback HTTP server for the actual
  URLSession model download and HTTP failure regression tests on Mac and Windows.
  Uses Python's standard library; `VAULT_TEST_PYTHON` can select its interpreter.

The Windows bundle test in `windowsBlocker/scripts/classifier-worker/` additionally
verifies relocation, app-local dependencies, DPAPI persistence and scene callbacks.
