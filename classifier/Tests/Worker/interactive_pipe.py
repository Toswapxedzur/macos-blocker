"""mini1 integration fixture: reply to small frames before the host closes stdin."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


def verify(executable):
    with tempfile.TemporaryDirectory(prefix="vault-interactive-worker-") as directory:
        environment = dict(os.environ, VAULT_DATA_ROOT=directory,
                           VAULT_ENVIRONMENT="development",
                           ADAMANCIA_VAULT_ENVIRONMENT="development")
        with open(Path(directory) / "stderr.log", "wb") as errors:
            process = subprocess.Popen([executable, "--testing-directory", directory],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, env=environment)
            messages = queue.Queue()

            def receive():
                for raw in process.stdout:
                    try:
                        messages.put(json.loads(raw))
                    except Exception as error:
                        messages.put(error)
                messages.put(EOFError("Worker stdout closed"))

            threading.Thread(target=receive, daemon=True).start()

            def matching(predicate):
                deadline = time.monotonic() + 30
                while True:
                    message = messages.get(timeout=max(0, deadline - time.monotonic()))
                    if isinstance(message, Exception):
                        raise message
                    if predicate(message):
                        return message

            try:
                assert matching(lambda value: value.get("event") == "ready")["protocol"] == 1
                for identifier, operation, data in [
                    ("snapshot", "snapshot", {}),
                    ("utf8", "action", {"action": "createClassifierType", "data": {
                        "name": "Fixture 中文", "platformIDs": ["youtube"]}}),
                ]:
                    frame = {"id": identifier, "operation": operation, "data": data}
                    process.stdin.write(json.dumps(frame, ensure_ascii=False).encode("utf-8") + b"\n")
                    process.stdin.flush()
                    reply = matching(lambda value: value.get("id") == identifier)
                    assert reply["ok"], reply
                    if identifier == "utf8":
                        groups = reply["value"]["snapshot"]["assets"]["classifierTypes"]
                        assert any(group["name"] == "Fixture 中文" for group in groups)
                process.stdin.close()
                assert process.wait(timeout=10) == 0
                print("PASS: interactive small-frame replies, UTF-8 and graceful EOF")
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()


if __name__ == "__main__":
    verify(str(Path(sys.argv[1]).resolve()))
