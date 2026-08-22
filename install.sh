#!/usr/bin/env bash
#
# install.sh — mihomo-server 一键安装
#
# 做三件事：
#   1. 把「source 本仓库的 vpn.sh」追加到 ~/.bashrc（幂等，不会重复添加）
#   2. 创建数据目录（默认 ~/clash，存放配置/订阅/日志，与代码目录分离）
#   3. 数据目录缺少 mihomo 内核时，自动调用 install-mihomo.sh 下载
#
# 用法：
#   ./install.sh                  # 默认安装（数据目录 ~/clash）
#   ./install.sh --dir ~/myproxy  # 指定数据目录（会在 bashrc 中导出 MIHOMO_DIR）
#   ./install.sh --skip-core      # 跳过内核下载（自行放置 mihomo 二进制）
#
# 卸载：删除 ~/.bashrc 中由本脚本添加的行即可。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASHRC="${BASHRC:-$HOME/.bashrc}"
DATA_DIR="$HOME/clash"
SKIP_CORE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)
            [ $# -ge 2 ] || { echo "[install] 错误：--dir 需要参数" >&2; exit 1; }
            DATA_DIR="$(cd "$2" 2>/dev/null && pwd || printf '%s' "$2")"
            shift 2
            ;;
        --skip-core)
            SKIP_CORE=1
            shift
            ;;
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[install] 未知参数: $1" >&2
            exit 1
            ;;
    esac
done

VPN_SH="$SCRIPT_DIR/vpn.sh"
if [ ! -f "$VPN_SH" ]; then
    echo "[install] 错误：找不到 $VPN_SH，请在仓库目录内执行本脚本" >&2
    exit 1
fi

echo "[install] 脚本目录: $SCRIPT_DIR"
echo "[install] 数据目录: $DATA_DIR"

# ---- 1. 写入 ~/.bashrc（幂等）----
touch "$BASHRC"

MARKER="# >>> mihomo-server >>>"
if grep -Fq "$VPN_SH" "$BASHRC"; then
    echo "[install] ~/.bashrc 已包含本脚本加载项，跳过"
else
    {
        echo ""
        echo "$MARKER"
        if [ "$DATA_DIR" != "$HOME/clash" ]; then
            echo "export MIHOMO_DIR=\"$DATA_DIR\""
        fi
        echo '[ -f "'"$VPN_SH"'" ] && . "'"$VPN_SH"'"'
        echo "# <<< mihomo-server <<<"
    } >> "$BASHRC"
    echo "[install] 已将加载项追加到 $BASHRC"
fi

# 提示旧版手动添加的重复加载项
if grep -Fn 'clash/vpn.sh' "$BASHRC" | grep -vF "$VPN_SH" | grep -q '^\s*[0-9]*:.\{0,\}source\|\.\s'; then
    echo "[install] 注意：检测到指向其他位置的 vpn.sh 加载行，可能重复定义 vpn 函数，建议手动清理" >&2
fi

# ---- 2. 创建数据目录 ----
mkdir -p "$DATA_DIR/subs"

# ---- 3. 下载 mihomo 内核（可选）----
if [ "$SKIP_CORE" = 1 ]; then
    echo "[install] 已跳过内核下载"
elif [ ! -x "$DATA_DIR/mihomo" ]; then
    if [ -x "$SCRIPT_DIR/install-mihomo.sh" ]; then
        echo "[install] 正在下载 mihomo 内核..."
        "$SCRIPT_DIR/install-mihomo.sh" --dir "$DATA_DIR" \
            || echo "[install] 警告：内核下载失败，可稍后手动执行 $SCRIPT_DIR/install-mihomo.sh" >&2
    else
        echo "[install] 警告：找不到 install-mihomo.sh，请手动放置 mihomo 到 $DATA_DIR/" >&2
    fi
else
    echo "[install] mihomo 内核已存在，跳过下载"
fi

# ---- 完成 ----
cat <<EOF

[install] 安装完成！接下来：

  1. 执行:  source ~/.bashrc      # 或新开一个终端
  2. 共享服务器建议先设置专属端口（避免与他人冲突）:
       vpn port set 27890 27891 27892 29090
  3. 添加订阅并启动:
       vpn sub add "<订阅URL>" "我的订阅"
       vpn on

卸载方式：删除 $BASHRC 中 "$MARKER" 至 "# <<< mihomo-server <<<" 之间的行。
EOF
