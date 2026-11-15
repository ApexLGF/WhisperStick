#!/usr/bin/env python3
"""
VibeEverything Hook — sends Claude Code session state to QuickVibeHost via Unix socket.
For PermissionRequest: waits for user decision (Allow/Deny from Stick S3 or Mac UI).
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/vibepanel-claude.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
PROMPT_TIMEOUT_SECONDS = 0.5
HOOK_SCHEMA = 2


TERMINAL_APP_ALIASES = {
    "apple_terminal": "Terminal",
    "iterm.app": "iTerm",
    "iterm": "iTerm",
    "warp": "Warp",
    "warpterminal": "Warp",
    "vscode": "VS Code",
    "ghostty": "Ghostty",
    "wezterm": "WezTerm",
    "kitty": "kitty",
    "cmux": "cmux",
}


def terminal_context(env=None):
    """Capture stable routing identifiers inherited from the host terminal."""
    env = os.environ if env is None else env
    raw_app = env.get("TERM_PROGRAM", "").strip()
    app = TERMINAL_APP_ALIASES.get(raw_app.lower(), raw_app or None)
    session_id = (
        env.get("ITERM_SESSION_ID")
        or env.get("TERM_SESSION_ID")
        or env.get("CMUX_SURFACE_ID")
        or env.get("KITTY_WINDOW_ID")
        or env.get("WARP_SESSION_ID")
        or env.get("WARP_TAB_ID")
    )
    pane_id = env.get("WARP_PANE_UUID") or env.get("WARP_PANE_ID")
    result = {}
    if app:
        result["terminal_app"] = app
    if session_id:
        result["terminal_session_id"] = session_id
    if pane_id:
        result["terminal_pane_id"] = pane_id
    if env.get("TMUX_PANE"):
        result["tmux_target"] = env["TMUX_PANE"]
    return result


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess
    ppid = os.getppid()
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True, text=True, timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            if tty.startswith("/dev/"):
                tty = tty[len("/dev/"):]
            return tty
    except Exception:
        pass
    for fd in [sys.stdin, sys.stdout]:
        try:
            name = os.ttyname(fd.fileno())
            if name.startswith("/dev/"):
                name = name[len("/dev/"):]
            return name
        except (OSError, AttributeError):
            pass
    return None


def send_event(state):
    """Send event to QuickVibeHost, return response if permission request."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS if state.get("status") == "waiting_for_approval" else PROMPT_TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    claude_pid = os.getppid()
    tty = get_tty()

    state = {
        "hook_schema": HOOK_SCHEMA,
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
        "transcript_path": data.get("transcript_path"),
        "permission_mode": data.get("permission_mode", "default"),
        "agent_id": data.get("agent_id"),
        "agent_type": data.get("agent_type"),
        **terminal_context(),
    }

    if event == "UserPromptSubmit":
        state["status"] = "processing"
        state["prompt"] = data.get("prompt")

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PermissionRequest":
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

        # Debug: dump all keys in PermissionRequest data
        import datetime
        with open(os.path.expanduser("~/Documents/Projects/VibeEverything/hook-debug.log"), "a") as f:
            f.write(f"\n[{datetime.datetime.now().isoformat()}] PermissionRequest keys: {list(data.keys())}\n")
            f.write(f"  tool_use_id={data.get('tool_use_id')}\n")
            f.write(f"  tool_name={data.get('tool_name')}\n")
            for k in data.keys():
                if k not in ('tool_input',):
                    f.write(f"  {k}={data.get(k)}\n")

        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                decision_obj = {"behavior": "allow"}
                # REQ-022:always_allow 时 Mac 侧回包带 updatedPermissions
                # (destination=session 会话级规则),原样透传给 Claude Code
                updated_permissions = response.get("updatedPermissions")
                if updated_permissions:
                    decision_obj["updatedPermissions"] = updated_permissions
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": decision_obj,
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via VibeEverything",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" → let Claude Code show its normal prompt
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # REQ-022 后续批:turn 因 API 错误结束 → Mac 标 error → 设备 SDS_BLOCKED 响 TASK_ERROR。
        # 非阻塞:send_event 对非审批事件 sendall 即关,与其它状态事件同模式。
        # 实测 payload(CLI 2.1.81):error=机器可读短码(如 invalid_request),
        # last_assistant_message=展示用文本。
        state["status"] = "turn_error"
        state["error"] = data.get("error")
        state["message"] = data.get("last_assistant_message")

    elif event == "PostToolUseFailure":
        # REQ-022 后续批:单工具失败,模型常自愈 → Mac 侧仅 per-session 计数,不进状态不响铃
        state["status"] = "tool_error"
        state["tool"] = data.get("tool_name")
        state["error"] = data.get("error")
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "SessionStart":
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        state["status"] = "compacting"

    else:
        state["status"] = "unknown"

    send_event(state)


if __name__ == "__main__":
    main()
