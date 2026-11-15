#!/usr/bin/env python3
"""
QuickVibeHost Codex Hook — PermissionRequest 短窗口回传(REQ-021 路径②)。

只注册 PermissionRequest 一个事件:把 payload 转发给 QuickVibeHost 的
/tmp/vibepanel-codex.sock。server 按设备是否可用下发 10/60 秒窗口；窗口内
等待 Mac UI / 设备端的 Allow/Deny，超时则不作决定、交回 Codex 原生审批。

任何失败(socket 不在 / 未收到窗口 / 超时 / 无响应)→ 静默 exit 0 = fail-open,
Codex 回退自家审批提示,不阻塞用户。
(wire 格式 2026-07-10 于 codex-cli 0.143/0.144 实测:allow 放行 / deny 拒绝均生效)
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/vibepanel-codex.sock"
SERVER_ACK_TIMEOUT_SECONDS = 2
MAX_REMOTE_WINDOW_SECONDS = 60
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


def recv_json_line(sock):
    """读取一条 newline 分隔 JSON，避免 ack 与最终判决粘包。"""
    chunks = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        chunks.append(chunk)
        data = b"".join(chunks)
        if b"\n" not in data:
            continue
        try:
            return json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    event = data.get("hook_event_name")

    if event == "UserPromptSubmit":
        prompt = data.get("prompt")
        payload = {
            "hook_schema": HOOK_SCHEMA,
            "event": "UserPromptSubmit",
            "hook_event_name": event,
            "session_id": data.get("session_id", ""),
            "turn_id": data.get("turn_id", ""),
            "cwd": data.get("cwd", ""),
            "transcript_path": data.get("transcript_path"),
            "pid": os.getppid(),
            **terminal_context(),
        }
        if isinstance(prompt, str) and prompt:
            payload["prompt"] = prompt
        else:
            payload["payload_keys"] = list(data.keys())
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(PROMPT_TIMEOUT_SECONDS)
            sock.connect(SOCKET_PATH)
            sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            sock.close()
        except (socket.error, OSError):
            pass
        sys.exit(0)

    if event != "PermissionRequest":
        sys.exit(0)

    payload = {
        "hook_schema": HOOK_SCHEMA,
        "event": "PermissionRequest",
        "hook_event_name": event,
        "session_id": data.get("session_id", ""),
        "turn_id": data.get("turn_id", ""),
        "cwd": data.get("cwd", ""),
        "transcript_path": data.get("transcript_path", ""),
        "tool_name": data.get("tool_name", ""),
        "tool_input": data.get("tool_input", {}),
        "pid": os.getppid(),
        **terminal_context(),
    }

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(SERVER_ACK_TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        first = recv_json_line(sock)
        # 未收到 server 确认时立即回退原生审批，不能重现旧版 590 秒阻塞。
        if not isinstance(first, dict):
            sys.exit(0)
        if first.get("kind") == "pending":
            wait_seconds = first.get("wait_seconds")
            if not isinstance(wait_seconds, int) or not 1 <= wait_seconds <= MAX_REMOTE_WINDOW_SECONDS:
                sys.exit(0)
            sock.settimeout(wait_seconds)
            reply = recv_json_line(sock)
        else:
            # 判决极快到达时兼容直接回复。
            reply = first
        sock.close()
    except (socket.error, OSError):
        sys.exit(0)

    if not reply:
        sys.exit(0)

    decision = reply.get("decision")
    if decision == "allow":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }))
    elif decision == "deny":
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": reply.get("reason") or "Denied by user via QuickVibeHost",
                },
            }
        }))
    # 其他(ask/未知)→ 不输出,codex 走自家提示
    sys.exit(0)


if __name__ == "__main__":
    main()
