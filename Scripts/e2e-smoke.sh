#!/bin/bash
# End-to-end smoke test for the Refinery menu-bar app.
#
# Verifies the non-UI core of the polish pipeline without a real endpoint:
# preset prompt construction, the request/parse path against a local mock
# OpenAI-compatible server, and writing the polished result to the clipboard.
# The accessibility-selection read is not exercised (input comes from
# E2E_INPUT).
#
# Usage: ./Scripts/e2e-smoke.sh [preset-name] [custom-prompt]
set -euo pipefail

PRESET="${1:-polish}"
CUSTOM="${2:-}"
PORT=18765
MOCK_BODY='{"choices":[{"message":{"role":"assistant","content":"MOCK POLISHED OUTPUT"}}]}'

echo "== starting mock endpoint =="
python3 - "$PORT" "$MOCK_BODY" "$PRESET" "$CUSTOM" <<'PY' &
import sys, http.server, json
port = int(sys.argv[1]); body = sys.argv[2].encode()
expected_preset = sys.argv[3]; custom = sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = self.rfile.read(n)
        errors = []
        try:
            payload = json.loads(req)
        except Exception as error:
            payload = {}
            errors.append(f"invalid JSON: {error}")
        if self.path != "/v1/chat/completions": errors.append(f"wrong path: {self.path}")
        if self.headers.get("Authorization") != "Bearer dummy-key-for-tests": errors.append("wrong authorization")
        if payload.get("model") != "mock-model": errors.append("wrong model")
        messages = payload.get("messages", [])
        if len(messages) != 2 or messages[-1].get("content") != "this is a smal test of refinery": errors.append("wrong input")
        system = messages[0].get("content", "") if messages else ""
        expected = {
            "polish": "fix grammar",
            "concise": "Make the text concise",
            "formal": "formal, professional register",
            "friendlyEmail": "friendly email",
            "languageAware": "Danish or English",
            "customOneOff": f"Instruction: {custom}",
        }.get(expected_preset)
        if not expected or expected not in system: errors.append("wrong preset prompt")
        if errors:
            failure = json.dumps({"errors": errors}).encode()
            self.send_response(400); self.send_header("Content-Length", str(len(failure)))
            self.end_headers(); self.wfile.write(failure); return
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null" EXIT
sleep 1

echo "== launching Refinery e2e harness =="
E2E_BASE_URL="http://127.0.0.1:$PORT/v1" \
E2E_MODEL="mock-model" \
E2E_PRESET="$PRESET" \
E2E_CUSTOM_PROMPT="$CUSTOM" \
E2E_INPUT="this is a smal test of refinery" \
E2E_DUMMY_KEY="dummy-key-for-tests" \
E2E_TIMEOUT=5 \
swift run RefineryE2E 2>&1
