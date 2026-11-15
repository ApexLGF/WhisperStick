#!/usr/bin/env python3
"""vibepty — PTY wrapper exposing a Unix socket for external stdin injection.

Problem it solves:
    macOS 14+ 封禁了 TIOCSTI ioctl，write(2) 到 slave tty 只是"屏幕输出"不是
    stdin。要把字符像"用户键盘敲入"那样送进 claude 的 stdin，只能从 PTY master
    写入——但 master fd 通常只有终端 App (iTerm2/Ghostty/…) 持有。
    vibepty 把自己做成 PTY master：用户跑 `vibepty claude` 而不是 `claude`，
    vibepty 自己 relay master↔terminal；同时监听一个 unix socket，收到
    `{"inject":"text"}` 就 write 到 master，claude 立刻读到 stdin。

Usage:
    vibepty claude                            # wrap claude
    vibepty claude --mcp-config ./cfg.json    # 透传额外 argv

    # 从外部注入：
    printf '{"inject":"hello\\n"}\\n' | nc -U /tmp/vibepty-<child_pid>.sock

Socket protocol:
    请求：每条消息一行 JSON，`\\n` 终止。
        {"inject": "<utf8 text>"}   — write 到 master
        {"ping": true}              — 回 {"ok":true}
    响应：一行 JSON，{"ok":true} 或 {"error":"..."}

Lifecycle:
    - child exit → vibepty exit → socket 文件清理
    - SIGWINCH 透传（窗口 resize）
    - Ctrl+C 在 raw mode 下以字节 0x03 送 master → line discipline 给 child SIGINT
    - 外部 SIGTERM / SIGINT：handler 置标志 → 主循环感知 → finally 带超时收尾
      （graceful 等 → SIGTERM → SIGKILL 升级，总预算 ~5s，末尾 unlink socket）

Argv contract:
    vibepty **不消费任何自有 flag**；`sys.argv[1:]` 原样 exec 给子进程。
    `vibepty claude --resume <id>` → claude 收到 `['claude', '--resume', '<id>']`。
    未来若要加 vibepty 自有 flag，约定用 `--` 分隔：
        vibepty --vibepty-log debug -- claude --resume <id>
    （期 1 不实现。这里固定契约给上层调用方参考。）
"""

import os
import sys
import pty
import tty
import termios
import select
import signal
import json
import socket
import threading
import fcntl
import struct
import errno
import time
import uuid


SOCK_PATH_FMT = "/tmp/vibepty-{pid}.sock"
# REQ-019: sidecar 注册文件 — Mac App 用它把「vibepty child pid」与
# agent 会话对上号(codex rollout 无 pid,靠 cwd+启动时间匹配)。
SIDECAR_PATH_FMT = "/tmp/vibepty-{pid}.json"


class LineBuffer:
    def __init__(self):
        self.line = ""
        self.cursor = 0
        self.line_id = 1
        self.spans = []
        self.unsafe = False
        self.unsafe_reason = None

    def is_empty(self):
        return self.line == ""

    def inject(self, text, asr_span=False):
        span_id = None
        if asr_span and text:
            span_id = str(uuid.uuid4())
            start = self.cursor
            self.apply_text(text)
        else:
            self.apply_user_bytes(text.encode("utf-8"))
        if span_id is not None:
            self.spans.append({
                "id": span_id,
                "text": text,
                "start": start,
                "end": start + len(text),
            })
        return span_id

    def apply_user_bytes(self, data):
        text = data.decode("utf-8", errors="ignore")
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                consumed = self._apply_escape(text[i:])
                i += max(consumed, 1)
                continue
            if ch in ("\r", "\n"):
                self._enter()
            elif ch == "\x03":
                self._enter()
            elif ch == "\x7f":
                self._backspace()
            elif ch == "\x15":
                self._delete_range(0, self.cursor)
                self.cursor = 0
            elif ch == "\x17":
                self._delete_previous_word()
            elif ch == "\x01":
                self.cursor = 0
            elif ch == "\x05":
                self.cursor = len(self.line)
            elif ord(ch) >= 0x20:
                self.apply_text(ch)
            i += 1

    def apply_text(self, text):
        for ch in text:
            if ch in ("\r", "\n"):
                self._enter()
            elif ch == "\x7f":
                self._backspace()
            elif ord(ch) >= 0x20:
                self._insert(ch)

    def snapshot(self):
        if self.unsafe:
            reply = {"ok": False, "error": "unsafe line state"}
            if self.unsafe_reason:
                reply["unsafeReason"] = self.unsafe_reason
            return reply
        return {
            "ok": True,
            "line": self.line,
            "lineId": self.line_id,
            "asrSpans": [s.copy() for s in self.spans if s["text"] and s["start"] < s["end"]],
        }

    def _mark_unsafe(self, reason, text=""):
        self.unsafe = True
        if text:
            sample = text[:24].encode("utf-8", errors="backslashreplace").hex()
            self.unsafe_reason = f"{reason} hex={sample}"
        else:
            self.unsafe_reason = reason

    def _apply_escape(self, text):
        if text.startswith("\x1b[200~") or text.startswith("\x1b[201~"):
            return 6
        if text.startswith("\x1b[D"):
            self.cursor = max(0, self.cursor - 1)
            return 3
        if text.startswith("\x1b[C"):
            self.cursor = min(len(self.line), self.cursor + 1)
            return 3
        if text.startswith("\x1b[H"):
            self.cursor = 0
            return 3
        if text.startswith("\x1b[F"):
            self.cursor = len(self.line)
            return 3
        if text.startswith("\x1b[3~"):
            self._delete_forward()
            return 4
        if text.startswith("\x1b[A") or text.startswith("\x1b[B"):
            return 3
        if text.startswith("\x1b[I") or text.startswith("\x1b[O"):
            return 3
        if text.startswith("\x1b[Z"):
            self._mark_unsafe("shift-tab", text)
            return 3
        if text.startswith("\x1bOD"):
            self.cursor = max(0, self.cursor - 1)
            return 3
        if text.startswith("\x1bOC"):
            self.cursor = min(len(self.line), self.cursor + 1)
            return 3
        if text.startswith("\x1bOH"):
            self.cursor = 0
            return 3
        if text.startswith("\x1bOF"):
            self.cursor = len(self.line)
            return 3
        if text.startswith("\x1bOA") or text.startswith("\x1bOB"):
            return 3
        if text.startswith("\x1b]"):
            bel = text.find("\x07", 2)
            st = text.find("\x1b\\", 2)
            candidates = [idx + (1 if idx == bel else 2) for idx in (bel, st) if idx != -1]
            return min(candidates) if candidates else len(text)
        # Terminal/app control replies (bracketed-paste mode, cursor reports,
        # focus events) also arrive on stdin. They are not user line edits; do
        # not poison an otherwise empty prompt.
        if text.startswith("\x1b["):
            tail = text[2:]
            for offset, ch in enumerate(tail):
                if "@" <= ch <= "~":
                    consumed = offset + 3
                    prefix = tail[:offset]
                    if ch == "A" or ch == "B":
                        return consumed
                    if ch == "D":
                        if self._is_modified_word_arrow(prefix):
                            self._move_previous_word()
                        else:
                            self.cursor = max(0, self.cursor - 1)
                        return consumed
                    if ch == "C":
                        if self._is_modified_word_arrow(prefix):
                            self._move_next_word()
                        else:
                            self.cursor = min(len(self.line), self.cursor + 1)
                        return consumed
                    if ch == "H":
                        self.cursor = 0
                        return consumed
                    if ch == "F":
                        self.cursor = len(self.line)
                        return consumed
                    if ch == "~":
                        if prefix == "3":
                            self._delete_forward()
                        elif prefix not in ("200", "201"):
                            self._mark_unsafe("unsupported-csi", text[:consumed])
                        return consumed
                    if ch in "IORnu":
                        return consumed
                    if ch == "y" and prefix.endswith("$"):
                        return consumed
                    self._mark_unsafe("unsupported-csi", text[:consumed])
                    return consumed
        self._mark_unsafe("unsupported-escape", text)
        return 1

    def _is_modified_word_arrow(self, prefix):
        if ":" in prefix:
            return False
        parts = prefix.split(";")
        return len(parts) >= 2 and parts[-1] in ("3", "5")

    def _is_word_char(self, ch):
        return ch.isalnum() or ch == "_"

    def _move_previous_word(self):
        i = self.cursor
        while i > 0 and not self._is_word_char(self.line[i - 1]):
            i -= 1
        while i > 0 and self._is_word_char(self.line[i - 1]):
            i -= 1
        self.cursor = i

    def _move_next_word(self):
        i = self.cursor
        n = len(self.line)
        while i < n and not self._is_word_char(self.line[i]):
            i += 1
        while i < n and self._is_word_char(self.line[i]):
            i += 1
        self.cursor = i

    def _insert(self, ch):
        pos = self.cursor
        self.line = self.line[:pos] + ch + self.line[pos:]
        self.cursor += 1
        for span in self.spans:
            if pos <= span["start"]:
                span["start"] += 1
                span["end"] += 1
            elif pos < span["end"]:
                span["end"] += 1

    def _backspace(self):
        if self.cursor == 0:
            return
        self._delete_range(self.cursor - 1, self.cursor)
        self.cursor -= 1

    def _delete_forward(self):
        if self.cursor >= len(self.line):
            return
        self._delete_range(self.cursor, self.cursor + 1)

    def _delete_previous_word(self):
        end = self.cursor
        start = end
        while start > 0 and self.line[start - 1].isspace():
            start -= 1
        while start > 0 and not self.line[start - 1].isspace():
            start -= 1
        self._delete_range(start, end)
        self.cursor = start

    def _delete_range(self, start, end):
        if start >= end:
            return
        self.line = self.line[:start] + self.line[end:]
        deleted = end - start
        kept = []
        for span in self.spans:
            old_start, old_end = span["start"], span["end"]
            if end <= old_start:
                span["start"] -= deleted
                span["end"] -= deleted
                kept.append(span)
            elif start >= old_end:
                kept.append(span)
            else:
                overlap_start = max(start, old_start)
                overlap_end = min(end, old_end)
                span["end"] = old_end - (overlap_end - overlap_start)
                if start < old_start:
                    span["start"] = start
                    span["end"] -= min(deleted, old_start - start)
                if span["start"] < span["end"]:
                    kept.append(span)
        self.spans = kept

    def _enter(self):
        self.line = ""
        self.cursor = 0
        self.line_id += 1
        self.spans = []
        self.unsafe = False
        self.unsafe_reason = None


def write_sidecar(pid, argv):
    """Best-effort 写 {pid, cmd, cwd, started_at};失败不影响主功能。"""
    try:
        payload = {
            "pid": pid,
            "cmd": os.path.basename(argv[0]),
            "cwd": os.getcwd(),
            "started_at": time.time(),
        }
        path = SIDECAR_PATH_FMT.format(pid=pid)
        with open(path, "w") as f:
            json.dump(payload, f)
        os.chmod(path, 0o600)
    except OSError:
        pass


def remove_sidecar(pid):
    try:
        os.unlink(SIDECAR_PATH_FMT.format(pid=pid))
    except OSError:
        pass


# Session color palette — order MUST match SessionColorManager.assignableColors
# on the Mac side so the banner hue matches the Mac App's session list.
# Values are 256-color ANSI codes chosen for reasonable terminal fidelity.
SESSION_COLORS = [
    ("red", 196),
    ("blue", 39),
    ("green", 46),
    ("yellow", 226),
    ("orange", 208),
    ("purple", 129),
    ("cyan", 51),
    ("magenta", 201),
    ("pink", 213),
    ("white", 15),
    ("gray", 244),
]


# REQ-018: white 作为身份色在 Mac 浅色模式不可读;pid 公式命中 white 时
# 确定性二次映射到 10 色池。canonical 列表与 %11 模数保持不变(只有 white
# 命中的 1/11 会话换色)。⚠ 与 SessionColorManager.colorName(forPid:) 必须同步。
SESSION_COLORS_NO_WHITE = [c for c in SESSION_COLORS if c[0] != "white"]


def color_banner(child_pid):
    """Return (name, ansi_chip) for a pid-derived session color."""
    name, code = SESSION_COLORS[child_pid % len(SESSION_COLORS)]
    if name == "white":
        name, code = SESSION_COLORS_NO_WHITE[child_pid % len(SESSION_COLORS_NO_WHITE)]
    # bg 256-color + black fg for readable label, padded to 9 chars.
    chip = f"\033[48;5;{code}m\033[38;5;232m  {name.upper():^9}  \033[0m"
    return name, chip


def set_raw(fd):
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    return old


def restore_termios(fd, old):
    try:
        termios.tcsetattr(fd, termios.TCSANOW, old)
    except OSError:
        pass


def forward_winsize(src_fd, master_fd):
    """Copy src_fd's window size to master_fd so child sees correct cols/rows."""
    try:
        packed = fcntl.ioctl(src_fd, termios.TIOCGWINSZ, b"\x00" * 8)
        fcntl.ioctl(master_fd, termios.TIOCSWINSZ, packed)
    except OSError:
        pass


def graceful_wait(pid, timeout):
    """Poll waitpid(WNOHANG) until child exits or timeout.

    Returns True if the child has been reaped / is no longer our child,
    False if it's still alive when the deadline passes. Tolerates
    ChildProcessError (main loop may have already reaped via WNOHANG) and
    treats it as a successful exit signal.
    """
    deadline = time.monotonic() + timeout
    while True:
        try:
            wpid, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return True
        if wpid == pid:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def safe_kill(pid, sig):
    """os.kill that swallows ESRCH (child already gone). Returns True if sent."""
    try:
        os.kill(pid, sig)
        return True
    except ProcessLookupError:
        return False


def socket_server(sock_path, master_fd, stop_event, log, line_buffer, line_lock):
    # Race tolerance: if the main thread has already requested shutdown
    # (e.g. child exited in under a millisecond), skip setup entirely.
    if stop_event.is_set():
        return

    try:
        if os.path.exists(sock_path):
            os.unlink(sock_path)
    except OSError:
        pass

    try:
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(sock_path)
        os.chmod(sock_path, 0o600)
        srv.listen(4)
        srv.settimeout(0.25)
    except OSError as e:
        # Setup lost to interpreter shutdown / main-thread cleanup race.
        log(f"socket_server setup aborted: {e}")
        try:
            os.unlink(sock_path)
        except OSError:
            pass
        return

    log(f"socket listening at {sock_path}")

    while not stop_event.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            handle_client(conn, master_fd, log, line_buffer, line_lock)
        finally:
            try:
                conn.close()
            except OSError:
                pass

    try:
        srv.close()
    except OSError:
        pass
    try:
        os.unlink(sock_path)
    except OSError:
        pass


def handle_client(conn, master_fd, log, line_buffer, line_lock):
    conn.settimeout(2.0)
    buf = b""
    while True:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            reply = process_message(line, master_fd, log, line_buffer, line_lock)
            try:
                conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
            except OSError:
                return


def process_message(raw_line, master_fd, log, line_buffer=None, line_lock=None):
    try:
        msg = json.loads(raw_line)
    except json.JSONDecodeError as e:
        return {"error": f"invalid json: {e}"}

    if "ping" in msg:
        return {"ok": True, "pong": True}

    if "snapshot" in msg:
        if line_buffer is None:
            return {"ok": False, "error": "unsafe line state"}
        with line_lock:
            return line_buffer.snapshot()

    if "submitSnapshot" in msg:
        if line_buffer is None:
            snapshot = {"ok": False, "error": "unsafe line state"}
        else:
            with line_lock:
                snapshot = line_buffer.snapshot()
                try:
                    written = os.write(master_fd, b"\r")
                except OSError as e:
                    log(f"write(master) failed: {e}")
                    return {"error": f"write failed: {e}"}
                line_buffer.apply_text("\r")
                log("submitSnapshot wrote enter")
                if snapshot.get("ok") is True:
                    snapshot["bytes"] = written
                return snapshot
        try:
            written = os.write(master_fd, b"\r")
        except OSError as e:
            log(f"write(master) failed: {e}")
            return {"error": f"write failed: {e}"}
        log("submitSnapshot wrote enter without line buffer")
        snapshot["bytes"] = written
        return snapshot

    if "inject" in msg:
        payload = msg["inject"]
        if not isinstance(payload, str):
            return {"error": "inject must be a string"}
        asr_span = bool(msg.get("asrSpan", False))
        span_id = None
        if line_buffer is not None:
            with line_lock:
                span_id = line_buffer.inject(payload, asr_span=asr_span)
        data = payload.encode("utf-8")
        try:
            written = os.write(master_fd, data)
        except OSError as e:
            log(f"write(master) failed: {e}")
            return {"error": f"write failed: {e}"}
        log(f"injected {written}B: {data[:40]!r}{'…' if len(data) > 40 else ''}")
        reply = {"ok": True, "bytes": written}
        if span_id is not None:
            reply["spanId"] = span_id
        return reply

    return {"error": "unknown message; expected 'inject', 'snapshot', or 'ping'"}


def main():
    if len(sys.argv) < 2:
        print("usage: vibepty <program> [args...]", file=sys.stderr)
        sys.exit(2)

    argv = sys.argv[1:]

    # Capture terminal settings before we mess with them.
    stdin_fd = sys.stdin.fileno()
    stdin_is_tty = os.isatty(stdin_fd)

    # Fork with a fresh PTY. Parent gets master_fd; child has slave as stdio.
    pid, master_fd = pty.fork()
    if pid == 0:
        # Child process: exec the target command.
        try:
            os.execvp(argv[0], argv)
        except OSError as e:
            print(f"vibepty: exec {argv[0]}: {e}", file=sys.stderr)
            os._exit(127)

    sock_path = SOCK_PATH_FMT.format(pid=pid)
    stop_event = threading.Event()
    line_buffer = LineBuffer()
    line_lock = threading.Lock()
    write_sidecar(pid, argv)

    log_enabled = os.environ.get("VIBEPTY_LOG") == "1"

    def log(msg):
        if log_enabled:
            sys.stderr.write(f"[vibepty pid={pid}] {msg}\n")
            sys.stderr.flush()

    color_name, color_chip = color_banner(pid)
    sys.stderr.write(
        f"[vibepty] {color_chip} child pid={pid} sock={sock_path}\n"
    )
    sys.stderr.flush()

    # Forward initial winsize from our terminal to child's PTY.
    if stdin_is_tty:
        forward_winsize(stdin_fd, master_fd)

    def on_winch(signum, frame):
        if stdin_is_tty:
            forward_winsize(stdin_fd, master_fd)

    signal.signal(signal.SIGWINCH, on_winch)

    # Async-signal-safe: handlers only bump a counter / flip a flag. Main
    # loop does the real work (write I/O, break, etc.). Signals only fire
    # between Python bytecodes (GIL), so `count += 1` is effectively atomic.
    #
    # SIGINT semantics: first INT in a quiet window relays 0x03 to child
    # (Ctrl-C), matching terminal line-discipline behavior so apps like Claude
    # can cancel current input without dying. A SECOND INT within
    # SIGINT_DOUBLE_TAP_WINDOW seconds of the first is "force exit" — main
    # loop breaks and finally escalates through TERM/KILL. After the window
    # elapses, the next INT is again treated as a fresh first-tap.
    # SIGTERM always exits immediately.
    sigint_count = [0]
    sigterm_requested = threading.Event()

    def on_sigint(signum, frame):
        sigint_count[0] += 1

    def on_sigterm(signum, frame):
        sigterm_requested.set()

    signal.signal(signal.SIGINT, on_sigint)
    signal.signal(signal.SIGTERM, on_sigterm)

    # Put OUR terminal stdin in raw mode so Ctrl+C/Ctrl+D bytes go to master,
    # not interpreted by our shell's line discipline.
    old_termios = None
    if stdin_is_tty:
        old_termios = set_raw(stdin_fd)

    # Start socket listener in a background thread.
    sock_thread = threading.Thread(
        target=socket_server,
        args=(sock_path, master_fd, stop_event, log, line_buffer, line_lock),
        daemon=True,
    )
    sock_thread.start()

    # Main relay loop: stdin ⇄ master_fd, until child EOFs master.
    SIGINT_DOUBLE_TAP_WINDOW = 2.0  # seconds; second INT within window → exit
    seen_sigint_count = 0
    last_sigint_ts = 0.0
    child_alive = True
    try:
        while child_alive:
            if sigterm_requested.is_set():
                log("SIGTERM observed, breaking main loop")
                break

            cur_count = sigint_count[0]
            if cur_count > seen_sigint_count:
                seen_sigint_count = cur_count
                now = time.monotonic()
                if (
                    last_sigint_ts > 0.0
                    and (now - last_sigint_ts) < SIGINT_DOUBLE_TAP_WINDOW
                ):
                    log(
                        f"double SIGINT within {now - last_sigint_ts:.2f}s, "
                        "breaking main loop"
                    )
                    break
                last_sigint_ts = now
                try:
                    with line_lock:
                        line_buffer.apply_user_bytes(b"\x03")
                    os.write(master_fd, b"\x03")
                except OSError:
                    pass

            try:
                rs, _, _ = select.select([stdin_fd, master_fd], [], [], 0.25)
            except OSError as e:
                if e.errno == errno.EINTR:
                    continue
                raise

            if master_fd in rs:
                try:
                    data = os.read(master_fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                os.write(1, data)

            if stdin_fd in rs:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    # stdin closed (e.g. pipe). Send EOF but keep reading child.
                    try:
                        os.close(master_fd)
                    except OSError:
                        pass
                    break
                try:
                    with line_lock:
                        line_buffer.apply_user_bytes(data)
                    os.write(master_fd, data)
                except OSError:
                    break

            # Non-blocking reap.
            try:
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    child_alive = False
            except ChildProcessError:
                child_alive = False
    finally:
        stop_event.set()
        if old_termios is not None:
            restore_termios(stdin_fd, old_termios)

        # Close master_fd first — child sees SIGHUP/EOF, gentlest signal.
        # Safe to double-close: OSError is swallowed.
        try:
            os.close(master_fd)
        except OSError:
            pass

        # Escalating wait: gentle → SIGTERM → SIGKILL, total budget ~5s.
        if not graceful_wait(pid, 3.0):
            log("child still alive after 3s, sending SIGTERM")
            safe_kill(pid, signal.SIGTERM)
            if not graceful_wait(pid, 2.0):
                log("child still alive after SIGTERM, sending SIGKILL")
                safe_kill(pid, signal.SIGKILL)
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass

        try:
            os.unlink(sock_path)
        except OSError:
            pass
        remove_sidecar(pid)
        sys.stderr.write("[vibepty] exited\n")


if __name__ == "__main__":
    main()
