#!/bin/bash
# End-to-end smoke test for the Refinery menu-bar app.
#
# Verifies the non-UI core of the hotkey pipeline without a real endpoint:
# reads the frontmost app's selection via the Accessibility API, runs the
# preset prompt construction, talks to a local mock OpenAI-compatible server,
# and writes the polished result to the clipboard.
#
# Usage: ./Scripts/e2e-smoke.sh [preset-name] [custom-prompt]
set -euo pipefail

PRESET="${1:-polish}"
CUSTOM="${2:-}"
PORT=18765
MOCK_BODY='{"choices":[{"message":{"role":"assistant","content":"MOCK POLISHED OUTPUT"}}]}'

echo "== starting mock endpoint =="
python3 - "$PORT" "$MOCK_BODY" <<'PY' &
import sys, http.server, json
port = int(sys.argv[1]); body = sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = self.rfile.read(n)
        print(f"MOCK SERVER got {self.path}", flush=True)
        print(f"MOCK SERVER body: {req.decode()[:600]}", flush=True)
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null" EXIT
sleep 1

echo "== launching Refinery in e2e mode =="
BIN=.build/debug/Refinery
E2E_BASE_URL="http://127.0.0.1:$PORT/v1" \
E2E_MODEL="mock-model" \
E2E_PRESET="$PRESET" \
E2E_CUSTOM_PROMPT="$CUSTOM" \
E2E_INPUT="this is a smal test of refinery" \
E2E_DUMMY_KEY="dummy-key-for-tests" \
E2E_TIMEOUT=5 \
"$BIN" 2>&1
