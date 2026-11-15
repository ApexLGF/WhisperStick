#!/usr/bin/env python3
"""Bridge WorkBuddy approval hooks to QuickVibeHost.

Any transport failure or explicit handoff emits no decision, so WorkBuddy falls
back to its native approval UI. The script never silently allows an operation.
"""
import json
import os
import socket
import sys
from datetime import datetime, timezone

SOCKET_PATH = os.environ.get(
    "QUICKVIBEHOST_WORKBUDDY_APPROVAL_SOCKET",
    "/tmp/quickvibehost-workbuddy.sock",
)
ACK_TIMEOUT_SECONDS = 2
MAX_WAIT_SECONDS = 110
HOOK_SCHEMA = 1
SUPPORTED_EVENTS = {"PreToolUse", "PermissionRequest"}


def log_diagnostic(event, **fields):
    """Write bounded, content-free diagnostics when the plugin opts in."""
    path = os.environ.get("QUICKVIBEHOST_WORKBUDDY_APPROVAL_LOG")
    if not path:
        return
    record = {
        "time": datetime.now(timezone.utc).isoformat(),
        "event": event,
        **fields,
    }
    try:
        expanded = os.path.expanduser(path)
        os.makedirs(os.path.dirname(expanded), mode=0o700, exist_ok=True)
        if os.path.exists(expanded) and os.path.getsize(expanded) >= 512 * 1024:
            rotated = expanded + ".1"
            try:
                os.replace(expanded, rotated)
            except OSError:
                pass
        with open(expanded, "a", encoding="utf-8") as output:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def recv_json_line(sock):
    data = bytearray()
    while len(data) < 65536:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data.extend(chunk)
        if b"\n" in data:
            try:
                return json.loads(bytes(data).split(b"\n", 1)[0].decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return None
    return None


def emit_decision(reply, hook_event_name):
    decision = reply.get("decision") if isinstance(reply, dict) else None
    if decision not in ("allow", "deny"):
        return
    value = {"behavior": decision}
    if decision == "deny":
        value["message"] = reply.get("reason") or "Denied by user via QuickVibeHost"
    reason = reply.get("reason") or (
        "Denied by user via QuickVibeHost" if decision == "deny"
        else "Allowed by user via QuickVibeHost"
    )
    output = {
        "decision": "approve" if decision == "allow" else "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": hook_event_name,
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
            "decision": value,
        }
    }
    print(json.dumps(output))
    log_diagnostic("decision", hook_event_name=hook_event_name, decision=decision)


def main():
    try:
        source = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return
    hook_event_name = source.get("hook_event_name")
    if hook_event_name not in SUPPORTED_EVENTS:
        return
    tool_use_id = source.get("tool_use_id") or source.get("call_id")
    if not source.get("session_id") or not tool_use_id:
        return
    log_diagnostic(
        "invoked",
        hook_event_name=hook_event_name,
        tool_name=source.get("tool_name", ""),
    )
    payload = {
        "hook_schema": HOOK_SCHEMA,
        "hook_event_name": hook_event_name,
        "session_id": source.get("session_id"),
        "transcript_path": source.get("transcript_path"),
        "tool_use_id": tool_use_id,
        "call_id": source.get("call_id"),
        "tool_name": source.get("tool_name", ""),
        "tool_input": source.get("tool_input", {}),
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(ACK_TIMEOUT_SECONDS)
            client.connect(SOCKET_PATH)
            client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            acknowledgement = recv_json_line(client)
            if not isinstance(acknowledgement, dict):
                return
            wait_seconds = acknowledgement.get("wait_seconds")
            if acknowledgement.get("kind") != "pending" or not isinstance(wait_seconds, int):
                return
            if not 1 <= wait_seconds <= MAX_WAIT_SECONDS:
                return
            client.settimeout(wait_seconds + 2)
            emit_decision(recv_json_line(client), hook_event_name)
    except (OSError, socket.timeout) as error:
        log_diagnostic("fallback", reason=type(error).__name__)
        return


if __name__ == "__main__":
    main()
