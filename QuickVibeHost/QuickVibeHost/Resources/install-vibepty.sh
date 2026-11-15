#!/usr/bin/env bash
# install-vibepty.sh — 把 vibepty.py 装到 ~/.vibepty/bin/vibepty，
# 并在 ~/.zshrc（和 ~/.bashrc，如果存在）加一行 `alias claude='vibepty claude'`。
#
# 幂等：重复跑不会产生重复 alias。
#
# 安装后，新开的终端里 `claude` 会自动走 vibepty 包装；已经开着的 claude
# 会话需要退出并重开才会生效。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/vibepty.py"

if [ ! -f "$SRC" ]; then
    echo "[install-vibepty] ERROR: 找不到 $SRC" >&2
    exit 1
fi

INSTALL_DIR="$HOME/.vibepty/bin"
INSTALL_PATH="$INSTALL_DIR/vibepty"
ALIAS_LINE="alias claude='$INSTALL_PATH claude'"
ALIAS_MARKER="# vibepty-alias (managed by install-vibepty.sh)"
# REQ-019: codex 直通输入同款包装;独立 marker,幂等更新互不影响
CODEX_ALIAS_LINE="alias codex='$INSTALL_PATH codex'"
CODEX_ALIAS_MARKER="# vibepty-alias-codex (managed by install-vibepty.sh)"

mkdir -p "$INSTALL_DIR"
cp "$SRC" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
echo "[install-vibepty] installed: $INSTALL_PATH"

add_alias_to() {
    local rc="$1"
    local create_if_missing="${2:-0}"
    local marker="$3"
    local alias_line="$4"

    if [ ! -f "$rc" ]; then
        if [ "$create_if_missing" = "1" ]; then
            : > "$rc"
            echo "[install-vibepty] created empty $rc"
        else
            return 0
        fi
    fi

    if grep -Fq "$marker" "$rc"; then
        # 已有标记块，替换其中的 alias 行以防路径变化
        tmp="$(mktemp)"
        awk -v marker="$marker" -v alias_line="$alias_line" '
            $0 == marker { print; getline; print alias_line; next }
            { print }
        ' "$rc" > "$tmp"
        mv "$tmp" "$rc"
        echo "[install-vibepty] updated alias in $rc ($marker)"
    else
        printf '\n%s\n%s\n' "$marker" "$alias_line" >> "$rc"
        echo "[install-vibepty] appended alias to $rc ($marker)"
    fi
}

# zsh 是 macOS 默认 shell，缺失时主动创建；bash 保守处理（存在才写）
add_alias_to "$HOME/.zshrc" 1 "$ALIAS_MARKER" "$ALIAS_LINE"
add_alias_to "$HOME/.bashrc" 0 "$ALIAS_MARKER" "$ALIAS_LINE"
add_alias_to "$HOME/.zshrc" 1 "$CODEX_ALIAS_MARKER" "$CODEX_ALIAS_LINE"
add_alias_to "$HOME/.bashrc" 0 "$CODEX_ALIAS_MARKER" "$CODEX_ALIAS_LINE"

cat <<EOF

[install-vibepty] done.

下一步：
  1. 开一个新终端（或 source ~/.zshrc）
  2. 运行 claude —— 应该看到一行 '[vibepty] child pid=XXXX sock=/tmp/vibepty-XXXX.sock'
  3. 已经在跑的 claude 会话需要退出重开才会走 vibepty。

参数透传：
  vibepty 不消费任何自有 flag，argv 完全透传。
  例：\`claude --resume <session-id>\` 会被 vibepty 原样 exec 成
      \`claude --resume <session-id>\`，恢复会话正常工作。

卸载：
  删除 $INSTALL_PATH 和 ~/.zshrc 里标注 '$ALIAS_MARKER' 的两行即可。
EOF
