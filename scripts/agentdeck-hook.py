#!/usr/bin/env python3
"""AgentDeck hook bridge: forwards CLI lifecycle events to the app daemon.
Fail-open by design — never blocks or slows the agent CLI."""
import json
import sys
import urllib.request

PORT = 47836

EVENT_MAP = {
    "SessionStart": "session-start",
    "UserPromptSubmit": "prompt-submit",
    "PreToolUse": "tool-use",
    "PostToolUse": "tool-use",
    "Notification": "notification",
    "PermissionRequest": "notification",
    "Stop": "stop",
    "SessionEnd": "session-end",
    "SubagentStop": "tool-use",
}


def main() -> int:
    agent = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    hook = payload.get("hook_event_name", "")
    event = EVENT_MAP.get(hook)
    if not event:
        return 0
    body = {
        "agent": agent,
        "sessionId": payload.get("session_id", "unknown"),
        "event": event,
        "cwd": payload.get("cwd"),
    }
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{PORT}/events",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=0.4).read()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
