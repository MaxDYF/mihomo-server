#!/usr/bin/env bash
# install-mihomo.sh — 下载并安装最新版 Mihomo (Clash Meta) 内核
#
# 用法：
#   ./install-mihomo.sh                # 下载最新版到 ~/clash/
#   ./install-mihomo.sh --dir /opt/clash
#   ./install-mihomo.sh --version v1.19.30
#
# 依赖：curl, python3（用于解析 GitHub API 的 JSON）

set -euo pipefail

MIHOMO_DIR="${MIHOMO_DIR:-$HOME/clash}"
VERSION=""
REPO="MetaCubeX/mihomo"

usage() {
    cat <<'EOF'
用法: install-mihomo.sh [--dir <目录>] [--version <标签>]

  --dir <目录>       安装目录（默认 $HOME/clash，可用环境变量 MIHOMO_DIR 覆盖）
  --version <标签>   指定版本标签，如 v1.19.30（默认最新版）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) MIHOMO_DIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage >&2; exit 1 ;;
    esac
done

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l|armv6l) echo armv7 ;;
        *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
}

ARCH=$(detect_arch)
mkdir -p "$MIHOMO_DIR"

echo "[install] 架构: $ARCH，目标目录: $MIHOMO_DIR"

if [ -z "$VERSION" ]; then
    echo "[install] 查询最新版本..."
    TAG=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
else
    TAG="$VERSION"
fi
echo "[install] 版本: $TAG"

ASSET=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
    | python3 -c "
import json, sys
tag = sys.argv[1]
arch = sys.argv[2]
want = 'mihomo-linux-%s-v%s.gz' % (arch, tag.lstrip('v'))
assets = [a['browser_download_url'] for a in json.load(sys.stdin)['assets']]
if want in assets:
    print(want)
else:
    for a in assets:
        if a.endswith('.gz') and ('linux-%s' % arch) in a and 'compatible' not in a and 'go120' not in a and 'go123' not in a and '-v1-' not in a and '-v2-' not in a and '-v3-' not in a:
            print(a.split('/')[-1]); break
    else:
        sys.exit('未找到匹配的下载文件')
" "$TAG" "$ARCH")

URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
echo "[install] 下载: $URL"

TMP="$MIHOMO_DIR/.mihomo.dl.$$"
trap 'rm -f "$TMP" "$TMP.gz"' EXIT
curl -fL --max-time 300 -o "$TMP.gz" "$URL"
gunzip -f "$TMP.gz"
chmod +x "$TMP"
mv -f "$TMP" "$MIHOMO_DIR/mihomo"
trap - EXIT

echo "[install] 完成: $MIHOMO_DIR/mihomo"
"$MIHOMO_DIR/mihomo" -v
echo "[install] 可执行文件：$MIHOMO_DIR/mihomo"