# vpn.sh — Mihomo 代理控制函数（通过 source 加载，作用于当前 shell）
#
# 用法：
#   vpn on       启动/确认 Mihomo 进程，并开启当前终端代理
#   vpn off      关闭当前终端代理（不停止 Mihomo 进程）
#   vpn stop     停止 Mihomo 进程（同时关闭代理）
#   vpn status   查看 Mihomo 进程、端口、代理、订阅状态
#   vpn restart  重启 Mihomo 进程
#   vpn log      查看 Mihomo 最近日志
#   vpn local-proxy 设置/关闭本地上游代理
#   vpn sub ...  订阅管理：list/add/use/update/remove/auto（详见 vpn sub help）
#
# 设计要点：
#   - 进程控制用 PID 文件和 kill，避免按模糊进程名误杀
#   - 代理开关用 export，只对当前 shell 生效
#   - 兼容旧的 CLASH_* 环境变量和 unvpn 函数名
#   - 订阅通过 mihomo proxy-providers (type: file) 加载，config.yaml 由
#     config.base.yaml + 当前订阅自动生成；vpn on/restart 自动检查更新

# ---- 配置区（如需修改端口或路径，改这里即可）----
# CLASH_* 保留为兼容别名；新的配置优先使用 MIHOMO_*。
MIHOMO_DIR="${MIHOMO_DIR:-${CLASH_DIR:-$HOME/clash}}"
MIHOMO_BIN="${MIHOMO_BIN:-${CLASH_BIN:-$MIHOMO_DIR/mihomo}}"
MIHOMO_LOG="${MIHOMO_LOG:-${CLASH_LOG:-$MIHOMO_DIR/mihomo.log}}"
MIHOMO_PIDFILE="${MIHOMO_PIDFILE:-$MIHOMO_DIR/mihomo.pid}"
# ---- 端口设置 ----
# 优先级：环境变量 > $MIHOMO_DIR/ports.conf（KEY=VALUE 格式）> 默认值
# 共享服务器上若默认端口被其他用户的实例占用，在此换一套专属端口即可，例如：
#   PROXY_PORT=17890
#   SOCKS_PORT=17891
#   HTTP_PORT=17892
#   CONTROL_PORT=19090
PORTS_CONF="${PORTS_CONF:-$MIHOMO_DIR/ports.conf}"

_vpn_conf_get() {
    # 从 ports.conf 读取 KEY 的值（忽略空行与 # 注释）
    local f="$PORTS_CONF" key="$1" line k v
    [ -r "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"
        v="${line#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        if [ "$k" = "$key" ] && [ -n "$v" ]; then
            printf '%s\n' "$v"
            return 0
        fi
    done < "$f"
}

# 可选上游本地代理：订阅节点经此代理建立连接，例如 socks5://localhost:9632
# 优先级：环境变量 > ports.conf；为空表示关闭
LOCAL_PROXY="${LOCAL_PROXY:-$(_vpn_conf_get LOCAL_PROXY)}"

# ponytail: only unauthenticated host:port URLs; add credential parsing if needed.
_vpn_local_proxy_parse() {
    local url="$LOCAL_PROXY" authority host port
    case "$url" in
        socks5://*) LOCAL_PROXY_TYPE=socks5; authority="${url#socks5://}" ;;
        http://*) LOCAL_PROXY_TYPE=http; authority="${url#http://}" ;;
        *)
            echo "[vpn] 错误：LOCAL_PROXY 仅支持 socks5://host:port 或 http://host:port" >&2
            return 1
            ;;
    esac

    case "$authority" in
        ''|*'@'*|*'/'*|*'?'*|*'#'*)
            echo "[vpn] 错误：LOCAL_PROXY 地址无效：$LOCAL_PROXY" >&2
            return 1
            ;;
        \[*\]:*)
            host="${authority#\[}"
            host="${host%%\]:*}"
            port="${authority##*\]:}"
            [ "$authority" = "[$host]:$port" ] || {
                echo "[vpn] 错误：LOCAL_PROXY 地址无效：$LOCAL_PROXY" >&2
                return 1
            }
            ;;
        *:*)
            host="${authority%:*}"
            port="${authority##*:}"
            case "$host" in *:*)
                echo "[vpn] 错误：IPv6 地址请使用 [::1]:port 格式" >&2
                return 1
                ;;
            esac
            ;;
        *)
            echo "[vpn] 错误：LOCAL_PROXY 必须包含端口：$LOCAL_PROXY" >&2
            return 1
            ;;
    esac

    case "$host" in ''|*[!A-Za-z0-9._:-]*)
        echo "[vpn] 错误：LOCAL_PROXY 主机名无效：$LOCAL_PROXY" >&2
        return 1
        ;;
    esac
    case "$port" in ''|*[!0-9]*)
        echo "[vpn] 错误：LOCAL_PROXY 端口无效：$LOCAL_PROXY" >&2
        return 1
        ;;
    esac
    if ((10#$port < 1 || 10#$port > 65535)); then
        echo "[vpn] 错误：LOCAL_PROXY 端口必须在 1-65535：$LOCAL_PROXY" >&2
        return 1
    fi
    LOCAL_PROXY_SERVER="$host"
    LOCAL_PROXY_PORT="$port"
}

# 用户显式设置的端口值（环境变量或 ports.conf）；为空表示未显式指定，
# 生成配置时将保留 config.base.yaml 中原有的端口设置
VPN_PROXY_PORT_SET="${PROXY_PORT:-$(_vpn_conf_get PROXY_PORT)}"
VPN_SOCKS_PORT_SET="${SOCKS_PORT:-$(_vpn_conf_get SOCKS_PORT)}"
VPN_HTTP_PORT_SET="${HTTP_PORT:-$(_vpn_conf_get HTTP_PORT)}"

PROXY_PORT="${VPN_PROXY_PORT_SET:-7890}"
SOCKS_PORT="${VPN_SOCKS_PORT_SET:-7891}"
HTTP_PORT="${VPN_HTTP_PORT_SET:-7892}"
LISTEN_PORTS="${LISTEN_PORTS:-$PROXY_PORT $SOCKS_PORT $HTTP_PORT}"
NO_PROXY_LIST="localhost,127.0.0.1,::1,*.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,::1"

# ---- 订阅配置 ----
SUBS_DIR="${SUBS_DIR:-$MIHOMO_DIR/subs}"
SUBS_LIST="${SUBS_LIST:-$SUBS_DIR/subs.list}"
SUBS_ACTIVE="${SUBS_ACTIVE:-$SUBS_DIR/subs.active}"
SUBS_AUTO="${SUBS_AUTO:-$SUBS_DIR/subs.auto}"
BASE_CONFIG="${BASE_CONFIG:-$MIHOMO_DIR/config.base.yaml}"
CONFIG_FILE="${CONFIG_FILE:-$MIHOMO_DIR/config.yaml}"
SUB_UPDATE_INTERVAL="${SUB_UPDATE_INTERVAL:-86400}"   # 自动更新间隔（秒），默认 24h
SUB_DOWNLOAD_TIMEOUT="${SUB_DOWNLOAD_TIMEOUT:-30}"
SUB_UA="${SUB_UA:-clash-verge/v2.0.0}"
SUB_HEALTH_URL="${SUB_HEALTH_URL:-http://cp.cloudflare.com/generate_204}"

# ---- 控制 API（节点切换/全局模式）----
CONTROL_PORT="${CONTROL_PORT:-$(_vpn_conf_get CONTROL_PORT)}"
CONTROL_PORT="${CONTROL_PORT:-9090}"
CONTROL_SECRET_FILE="${CONTROL_SECRET_FILE:-$SUBS_DIR/controller.secret}"

# ---- 内部辅助 ----
_vpn_mihomo_pid() {
    local pid

    if [ -r "$MIHOMO_PIDFILE" ]; then
        read -r pid < "$MIHOMO_PIDFILE"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
            && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
                | grep -Fq -- "$MIHOMO_BIN -d $MIHOMO_DIR"; then
            printf '%s\n' "$pid"
            return 0
        fi
        rm -f "$MIHOMO_PIDFILE"
    fi

    # 兜底按命令行查找（pgrep 在部分老系统上不可用，改用 ps 按字段精确匹配，
    # 避免子串误匹配到搜索进程自身）
    ps -eo pid=,args= 2>/dev/null \
        | awk -v bin="$MIHOMO_BIN" -v dir="$MIHOMO_DIR" \
            '$2 == bin && $3 == "-d" && $4 == dir {print $1; exit}'
}

_vpn_mihomo_running() {
    [ -n "$(_vpn_mihomo_pid)" ]
}

_vpn_port_listening() {
    ss -ltnH 2>/dev/null | grep -Eq ":${1}[[:space:]]"
}

_vpn_pid_owns_port() {
    # 判断本用户的指定 pid 是否监听了指定端口（ss 仅对本用户进程显示 pid）
    ss -ltnpH "sport = :$2" 2>/dev/null | grep -qE "pid=${1}[),]"
}

_vpn_port_owner_desc() {
    # 输出监听端口的进程描述（进程名+pid）；其他用户的进程无权限查看，返回空
    ss -ltnpH "sport = :$1" 2>/dev/null \
        | grep -oE '"[^"]+",pid=[0-9]+' | sort -u | head -n 5
}

_vpn_check_ports() {
    # 启动前检测所需端口：空闲或已被自己的实例监听才放行
    local port self busy=0 seen=" " owner
    for port in $PROXY_PORT $SOCKS_PORT $HTTP_PORT $CONTROL_PORT; do
        case "$seen" in *" $port "*) continue ;; esac
        seen="$seen$port "
        _vpn_port_listening "$port" || continue

        # 端口已被监听：若是自己的 Mihomo 则视为正常（重复 vpn on 场景）
        self=$(_vpn_mihomo_pid)
        if [ -n "$self" ] && _vpn_pid_owns_port "$self" "$port"; then
            continue
        fi

        owner=$(_vpn_port_owner_desc "$port")
        if [ -n "$owner" ]; then
            echo "[vpn] 错误：端口 $port 已被其他进程占用 → $owner" >&2
        else
            echo "[vpn] 错误：端口 $port 已被占用（无权限查看详情，通常是其他用户的进程）" >&2
        fi
        busy=1
    done
    [ "$busy" = 0 ] && return 0
    cat >&2 <<EOF
[vpn] 解决办法：
  1. 若是残留的旧实例：先执行 vpn stop 再重试；
  2. 共享服务器上请换一套专属端口（写入 $PORTS_CONF 或用环境变量）：
       PROXY_PORT=<空闲端口> SOCKS_PORT=... HTTP_PORT=... CONTROL_PORT=...
     之后重新执行 vpn on / vpn restart。
EOF
    return 1
}

_vpn_start_mihomo() {
    local pid i
    pid="$(_vpn_mihomo_pid)"
    if [ -n "$pid" ]; then
        echo "[vpn] Mihomo 已在运行（PID: $pid）"
        return 0
    fi

    # 每次启动前检测端口是否被占用（防止绑定失败后静默降级）
    _vpn_check_ports || return 1

    if [ ! -x "$MIHOMO_BIN" ]; then
        echo "[vpn] 错误：找不到可执行文件 $MIHOMO_BIN" >&2
        return 1
    fi

    nohup "$MIHOMO_BIN" -d "$MIHOMO_DIR" >> "$MIHOMO_LOG" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$MIHOMO_PIDFILE"

    # 等混合代理端口起来；必须确认是本进程在监听，
    # 否则可能误把别人的监听当成启动成功（共享服务器常见）
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$MIHOMO_PIDFILE"
            echo "[vpn] Mihomo 启动失败，请查看日志：tail -f $MIHOMO_LOG" >&2
            return 1
        fi
        if _vpn_pid_owns_port "$pid" "$PROXY_PORT"; then
            echo "[vpn] Mihomo 已启动（PID: $pid），监听 :$PROXY_PORT"
            return 0
        fi
        sleep 0.5
    done

    rm -f "$MIHOMO_PIDFILE"
    echo "[vpn] 启动超时：本进程未能在 :$PROXY_PORT 上监听，最近日志：" >&2
    grep -E 'level=(error|warning)' "$MIHOMO_LOG" 2>/dev/null | tail -n 3 | sed 's/^/[vpn]   /' >&2
    return 1
}

_vpn_stop_mihomo() {
    local pid i
    pid="$(_vpn_mihomo_pid)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$MIHOMO_PIDFILE"
        echo "[vpn] Mihomo 进程已停止"
    else
        echo "[vpn] Mihomo 未在运行"
    fi
}

_vpn_set_proxy() {
    export http_proxy="http://127.0.0.1:$PROXY_PORT"
    export https_proxy="http://127.0.0.1:$PROXY_PORT"
    export HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
    export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT"
    export all_proxy="socks5://127.0.0.1:$SOCKS_PORT"
    export ALL_PROXY="socks5://127.0.0.1:$SOCKS_PORT"
    export no_proxy="$NO_PROXY_LIST"
    export NO_PROXY="$NO_PROXY_LIST"
}

_vpn_unset_proxy() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
}

_vpn_test() {
    local url="$1"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null)
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        echo "  ✓ $url  →  HTTP $code"
    else
        echo "  ✗ $url  →  HTTP $code (失败)"
    fi
}

# ---- 订阅管理 ----

_vpn_sub_entry() {
    awk -F '\t' -v k="$1" '$1==k || $2==k {print; exit}' "$SUBS_LIST" 2>/dev/null
}

_vpn_sub_id() {
    local line
    line=$(_vpn_sub_entry "$1")
    [ -n "$line" ] && printf '%s\n' "$line" | cut -f1
}

_vpn_b64_decode() {
    # 标准/urlsafe base64 解码（容忍空白与缺失 padding）；stdin -> stdout
    local pad tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/vpnb64.XXXXXX")" || return 1
    tr -d ' \t\r\n' | tr '_-' '/+' > "$tmp"
    pad=$(( (4 - $(wc -c < "$tmp") % 4) % 4 ))
    while [ "$pad" -gt 0 ]; do printf '=' >> "$tmp"; pad=$((pad - 1)); done
    base64 -d "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

_vpn_sub_url_decode() {
    local url="$1" real
    case "$url" in
        sub://*)
            real=$(_vpn_b64_decode <<< "${url#sub://}" 2>/dev/null) \
                && printf '%s' "$real" || printf '%s' "$url"
            ;;
        *) printf '%s' "$url" ;;
    esac
}

_vpn_sub_fetch() {
    local url="$1" out="$2" real
    real=$(_vpn_sub_url_decode "$url")
    curl -fsSL --max-time "$SUB_DOWNLOAD_TIMEOUT" --retry 1 \
        -A "$SUB_UA" -o "$out" "$real" 2>/dev/null
}

# ---- 纯 Shell 工具集（替代原内嵌 Python：URL 编码 / JSON 解析 / YAML 处理）----

_vpn_url_encode() {
    # 百分号编码（保留 '/'），用于控制 API 路径中的中文/emoji 组名
    (
        export LC_ALL=C
        local s="$1" out="" i ch
        for ((i = 0; i < ${#s}; i++)); do
            ch="${s:i:1}"
            case "$ch" in
                [a-zA-Z0-9._~/-]) out+="$ch" ;;
                *) out+="$(printf '%s' "$ch" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g')" ;;
            esac
        done
        printf '%s' "$out"
    )
}

_vpn_json_get_str() {
    # 读取 JSON 顶层字符串字段: _vpn_json_get_str <json> <key>
    local json="$1" key="$2" pat rest i ch esc=0 out=""
    pat="\"${key}\":"
    case "$json" in *"$pat"*) rest="${json#*"$pat"}" ;; *) return 1 ;; esac
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in '"'*) ;; *) return 1 ;; esac
    rest="${rest:1}"
    for ((i = 0; i < ${#rest}; i++)); do
        ch="${rest:i:1}"
        if [ "$esc" = 1 ]; then
            out+="$ch"; esc=0
        elif [ "$ch" = '\' ]; then
            esc=1
        elif [ "$ch" = '"' ]; then
            break
        else
            out+="$ch"
        fi
    done
    printf '%s' "$out"
}

_vpn_json_get_arr() {
    # 读取 JSON 字符串数组字段，逐行输出各元素: _vpn_json_get_arr <json> <key>
    local json="$1" key="$2" pat rest i ch cur="" instr=0 esc=0 res=""
    pat="\"${key}\":["
    case "$json" in *"$pat"*) rest="${json#*"$pat"}" ;; *) return 1 ;; esac
    for ((i = 0; i < ${#rest}; i++)); do
        ch="${rest:i:1}"
        if [ "$instr" = 1 ]; then
            if [ "$esc" = 1 ]; then cur+="$ch"; esc=0; continue; fi
            case "$ch" in
                '\') esc=1 ;;
                '"') instr=0; res+="$cur"$'\n' ;;
                *) cur+="$ch" ;;
            esac
        else
            case "$ch" in
                '"') instr=1; cur="" ;;
                ']') printf '%s' "$res"; return 0 ;;
            esac
        fi
    done
    return 1
}

_vpn_yaml_strip_sections() {
    # 删除 YAML 中指定顶层键所在的整块内容: <src> <dst> <键1:键2:...>
    awk -v keys="$3" '
        BEGIN {
            n = split(keys, a, ":")
            for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1
        }
        /^[A-Za-z][A-Za-z0-9_-]*[[:space:]]*:/ {
            k = $0
            sub(/[[:space:]]*:.*$/, "", k)
            skip = (k in drop) ? 1 : 0
        }
        !skip { print }
    ' "$1" > "$2"
}

_vpn_yaml_top_scalar() {
    # 读取顶层标量键的行内值: _vpn_yaml_top_scalar <file> <key>
    awk -v key="$2" '
        $0 ~ "^" key "[[:space:]]*:" {
            sub("^" key "[[:space:]]*:[[:space:]]*", "")
            print
            exit
        }
    ' "$1"
}

_vpn_rule_extra_groups() {
    # 扫描 rules 中被引用但生成模板未定义的策略组名（每行一个，已排序）
    awk '
        BEGIN {
            ns = split("🚀节点选择 ♻️自动选择 🐟漏网之鱼 🛑广告拦截 DIRECT REJECT REJECT-DROP PASS COMPATIBLE GLOBAL", b, " ")
            for (i = 1; i <= ns; i++) known[b[i]] = 1
            no = split("no-resolve force-remote-dns force-ipv6 force-ipv4 ip-asn resolve", o, " ")
            for (i = 1; i <= no; i++) opt[o[i]] = 1
        }
        /^rules:[[:space:]]*(#.*)?$/ { inr = 1; next }
        /^[^[:space:]#]/ { inr = 0 }
        inr && /^[[:space:]]*-([[:space:]]|$)/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            cnt = split(line, p, ",")
            t = p[cnt]
            gsub(/[[:space:]]/, "", t)
            if (t == "") next
            if (t in opt) {
                if (cnt < 2) next
                t = p[cnt - 1]
                gsub(/[[:space:]]/, "", t)
            }
            if ((t in known) || (t in opt)) next
            extra[t] = 1
        }
        END { for (e in extra) print e }
    ' "$1" | sort
}

_vpn_write_minimal_base() {
    cat > "$1" <<EOF
mixed-port: ${VPN_PROXY_PORT_SET:-7890}
allow-lan: true
mode: rule
log-level: info
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
rules:
  - MATCH,🚀节点选择
EOF
}

_vpn_count_proxies() {
    # 统计含 proxies: 块的文件中的节点条目数
    awk '/^(proxies|Proxy):[[:space:]]*(#.*)?$/ { p = 1; next }
         /^[^[:space:]#]/ { p = 0 }
         p && /^[[:space:]]*-([[:space:]]|$)/ { c++ }
         END { print c + 0 }' "$1"
}

_vpn_migrate_legacy_config() {
    # 旧 config.yaml -> 基础配置 + 默认订阅（proxies 原样搬移）；stdout 输出节点数。
    # 先写临时文件校验，成功后才覆盖目标，避免失败时破坏现有数据
    local src="$1" base_out="$2" prov_out="$3" n tmpp tmpb
    tmpp="$prov_out.tmp.$$"
    tmpb="$base_out.tmp.$$"
    awk '
        /^[A-Za-z][A-Za-z0-9_-]*[[:space:]]*:/ {
            p = ($0 ~ /^(proxies|Proxy)[[:space:]]*:/) ? 1 : 0
        }
        p { print }
    ' "$src" > "$tmpp"
    n=$(_vpn_count_proxies "$tmpp")
    if [ ! -s "$tmpp" ] || [ "$n" -eq 0 ] 2>/dev/null; then
        rm -f "$tmpp" "$tmpb"
        return 1
    fi
    _vpn_yaml_strip_sections "$src" "$tmpb" "proxies:Proxy:proxy-providers:proxy-groups:"
    mv -f "$tmpp" "$prov_out"
    mv -f "$tmpb" "$base_out"
    echo "$n"
}

_vpn_sub_normalize() {
    # 规范化订阅为 mihomo 可用的 provider 文件；stdout 输出节点数。
    # Clash YAML 直接透传（mihomo 支持把含 proxies: 的完整配置作为 file provider）；
    # 纯 base64 订阅先解码为 URI 列表（mihomo 可解析 ss/vmess/trojan 等分享链接）
    local raw="$1" out="$2" n dups
    if grep -Eq '^(proxies|Proxy)[[:space:]]*:' "$raw"; then
        cp -f -- "$raw" "$out"
    else
        # 尝试按 base64 订阅解码（标准/urlsafe），得到 URI 列表或 YAML 文本
        _vpn_b64_decode < "$raw" > "$out" 2>/dev/null || { rm -f "$out"; return 1; }
        if ! grep -Eq '^(proxies|Proxy)[[:space:]]*:' "$out" && ! grep -q '://' "$out"; then
            rm -f "$out"
            return 1
        fi
    fi
    n=$(_vpn_count_proxies "$out")
    if [ "$n" -eq 0 ] 2>/dev/null; then
        n=$(grep -c '://' "$out" 2>/dev/null || true)
        n=${n:-0}
    fi
    if [ "$n" -eq 0 ] 2>/dev/null; then
        echo "[vpn] 订阅解析失败：找不到代理列表" >&2
        rm -f "$out"
        return 1
    fi
    # 重名检测（提示性；不再像旧版那样静默改名）
    if grep -Eq '^(proxies|Proxy)[[:space:]]*:' "$out"; then
        dups=$(awk '/^(proxies|Proxy):[[:space:]]*(#.*)?$/ { p = 1; next }
                    /^[^[:space:]#]/ { p = 0 }
                    p && /(^|[[:space:]])name:/ {
                        s = $0
                        sub(/^.*name:[[:space:]]*/, "", s)
                        print s
                    }' "$out" \
                | sed 's/[",].*$//' | sort | uniq -d)
        if [ -n "$dups" ]; then
            echo "[vpn] 警告：订阅存在重名节点（mihomo 可能拒绝加载），请更新订阅：" >&2
            printf '%s\n' "$dups" | sed 's/^/[vpn]       /' >&2
        fi
    fi
    echo "$n"
}

_vpn_sub_ensure() {
    mkdir -p "$SUBS_DIR"

    # 首次使用：把现有 config.yaml 的 proxies/proxy-groups 抽离为「默认订阅」
    if [ ! -f "$SUBS_LIST" ]; then
        if [ -f "$CONFIG_FILE" ]; then
            n=$(_vpn_migrate_legacy_config "$CONFIG_FILE" "$BASE_CONFIG" "$SUBS_DIR/sub_1.yaml")
            if [ $? -eq 0 ] && [ -n "$n" ]; then
                cp -f "$CONFIG_FILE" "$CONFIG_FILE.bak-inline" 2>/dev/null || true
                printf 'sub_1\t默认订阅\tlocal\t%s\n' "$(date +%s)" > "$SUBS_LIST"
                printf '%s\n' sub_1 > "$SUBS_ACTIVE"
                printf '1\n' > "$SUBS_AUTO"
                if [ "$n" -gt 0 ] 2>/dev/null && _vpn_sub_gen_config sub_1; then
                    echo "[vpn] 已将现有 config.yaml 抽离为基础配置 + 默认订阅（$n 个节点）"
                    echo "[vpn] 原配置备份: $CONFIG_FILE.bak-inline，基础模板: $BASE_CONFIG"
                fi
            else
                : > "$SUBS_LIST"
                echo "[vpn] 警告：现有 config.yaml 迁移失败，未创建默认订阅" >&2
            fi
        else
            : > "$SUBS_LIST"
        fi
    fi

    # 无基础配置时生成最小模板（仅首次且无 config.yaml 时）
    if [ ! -f "$BASE_CONFIG" ] && [ ! -f "$CONFIG_FILE" ]; then
        _vpn_write_minimal_base "$BASE_CONFIG" \
            && echo "[vpn] 已生成最小基础配置 $BASE_CONFIG"
    fi

    # config.yaml 缺失时按当前订阅重新生成
    if [ ! -f "$CONFIG_FILE" ] && [ -s "$SUBS_ACTIVE" ] 2>/dev/null; then
        _vpn_sub_gen_config "$(cat "$SUBS_ACTIVE")"
    fi
}

_vpn_sub_gen_config() {
    # 由基础配置 + 当前订阅生成 $CONFIG_FILE（纯 shell 实现）
    local id="$1" mode tmp strip qn
    [ -f "$BASE_CONFIG" ] || { echo "[vpn] 错误：缺少基础配置 $BASE_CONFIG" >&2; return 1; }
    [ -f "$SUBS_DIR/$id.yaml" ] || { echo "[vpn] 错误：缺少订阅文件 $SUBS_DIR/$id.yaml" >&2; return 1; }
    [ -z "$LOCAL_PROXY" ] || _vpn_local_proxy_parse || return 1
    mode=$(_vpn_current_mode)

    # 剥离由脚本统一注入的顶层键；端口仅在显式设置时接管（否则保留 base 原值）
    strip="proxies:Proxy:proxy-providers:proxy-groups:external-controller:secret:mode:"
    if [ -n "${VPN_PROXY_PORT_SET}${VPN_SOCKS_PORT_SET}${VPN_HTTP_PORT_SET}" ]; then
        strip="${strip}mixed-port:socks-port:port:"
    fi

    tmp="$CONFIG_FILE.tmp.$$"
    _vpn_yaml_strip_sections "$BASE_CONFIG" "$tmp" "$strip"

    {
        echo ""
        cat <<EOF
external-controller: 127.0.0.1:$CONTROL_PORT
secret: $(_vpn_control_secret)
EOF
        [ -n "$mode" ] && echo "mode: $mode"

        if [ -n "$VPN_PROXY_PORT_SET" ]; then
            echo "mixed-port: $VPN_PROXY_PORT_SET"
            if [ -n "$VPN_SOCKS_PORT_SET" ] && [ "$VPN_SOCKS_PORT_SET" != "$VPN_PROXY_PORT_SET" ]; then
                echo "socks-port: $VPN_SOCKS_PORT_SET"
            fi
            if [ -n "$VPN_HTTP_PORT_SET" ] && [ "$VPN_HTTP_PORT_SET" != "$VPN_PROXY_PORT_SET" ] \
                && { [ -z "$VPN_SOCKS_PORT_SET" ] || [ "$VPN_HTTP_PORT_SET" != "$VPN_SOCKS_PORT_SET" ]; }; then
                echo "port: $VPN_HTTP_PORT_SET"
            fi
        elif [ -n "${VPN_SOCKS_PORT_SET}${VPN_HTTP_PORT_SET}" ]; then
            # 未显式设置 mixed-port：保留基础配置端口，仅覆盖显式给出的独立端口
            [ -n "$VPN_SOCKS_PORT_SET" ] && echo "socks-port: $VPN_SOCKS_PORT_SET"
            [ -n "$VPN_HTTP_PORT_SET" ] && echo "port: $VPN_HTTP_PORT_SET"
        fi

        if [ -n "$LOCAL_PROXY" ]; then
            cat <<EOF

proxies:
  - name: local-proxy
    type: $LOCAL_PROXY_TYPE
    server: $LOCAL_PROXY_SERVER
    port: $LOCAL_PROXY_PORT
EOF
        fi

        cat <<EOF

proxy-providers:
  $id:
    type: file
    path: subs/$id.yaml
EOF
        if [ -n "$LOCAL_PROXY" ]; then
            cat <<EOF
    override:
      dialer-proxy: local-proxy
EOF
        fi
        cat <<EOF
    health-check:
      enable: true
      url: $SUB_HEALTH_URL
      interval: 300

proxy-groups:
  - name: 🚀节点选择
    type: select
    proxies:
      - ♻️自动选择
      - DIRECT
    use:
      - $id
  - name: ♻️自动选择
    type: url-test
    url: http://cp.cloudflare.com/generate_204
    interval: 300
    use:
      - $id
  - name: 🐟漏网之鱼
    type: select
    proxies:
      - 🚀节点选择
      - DIRECT
  - name: 🛑广告拦截
    type: select
    proxies:
      - REJECT
      - DIRECT
EOF
        # rules 引用但模板未定义的策略组：自动补 select 组，避免 mihomo 解析失败
        while IFS= read -r qn; do
            [ -n "$qn" ] || continue
            cat <<EOF
  - name: $qn
    type: select
    use:
      - $id
EOF
        done < <(_vpn_rule_extra_groups "$BASE_CONFIG")
    } >> "$tmp"

    mv -f "$tmp" "$CONFIG_FILE"
    return 0
}

_vpn_control_secret() {
    local f="$CONTROL_SECRET_FILE"
    if [ ! -s "$f" ] 2>/dev/null; then
        mkdir -p "$SUBS_DIR"
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$f"
        chmod 600 "$f"
    fi
    cat "$f"
}

_vpn_api() {
    # _vpn_api <METHOD> <PATH> [JSON_BODY] —— 基于 curl 的控制 API 调用
    local method="$1" path="$2" body="${3:-}"
    local rest enc="/" seg out rc http_code
    rest="${path#/}"
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        enc+="$(_vpn_url_encode "$seg")"
        case "$rest" in
            */*) enc+="/"; rest="${rest#*/}" ;;
            *) break ;;
        esac
    done

    if [ -n "$body" ]; then
        out=$(curl -s --max-time 5 -X "$method" \
            -H "Authorization: Bearer $(_vpn_control_secret)" \
            -H 'Content-Type: application/json' \
            --data-binary "$body" \
            -w '\n%{http_code}' "http://127.0.0.1:$CONTROL_PORT$enc" 2>/dev/null)
        rc=$?
    else
        out=$(curl -s --max-time 5 -X "$method" \
            -H "Authorization: Bearer $(_vpn_control_secret)" \
            -w '\n%{http_code}' "http://127.0.0.1:$CONTROL_PORT$enc" 2>/dev/null)
        rc=$?
    fi
    http_code="${out##*$'\n'}"
    out="${out%$'\n'*}"
    case "${http_code:-x}" in *[!0-9]*|'') http_code="" ;; esac
    if [ "$rc" != 0 ] || [ -z "$http_code" ] || [ "$http_code" -ge 400 ] 2>/dev/null; then
        echo "[vpn] API 请求失败（HTTP ${http_code:-curl 错误码 $rc}；请确认已 vpn on，且控制端口 $CONTROL_PORT 可用）" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

_vpn_current_mode() {
    cat "$SUBS_DIR/mode" 2>/dev/null || true
}

_vpn_current_group() {
    # 节点操作统一作用于 🚀节点选择；全局模式下 GLOBAL 组指向它
    printf '🚀节点选择\n'
}

_vpn_post_start() {
    # 启动完成后：全局模式下确保 GLOBAL 组指向 🚀节点选择（所有流量跟随所选节点）
    [ "$(_vpn_current_mode)" = "global" ] || return 0
    local i
    for i in 1 2 3 4 5; do
        if _vpn_api PUT "/proxies/GLOBAL" '{"name":"🚀节点选择"}' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "[vpn] 警告：无法设置 GLOBAL 组指向 🚀节点选择，请检查控制 API" >&2
    return 1
}

_vpn_sub_regen_restart() {
    # 重新生成 config.yaml（当前订阅 + 模式）并按需重启
    local id
    id=$(cat "$SUBS_ACTIVE" 2>/dev/null || true)
    if [ -z "$id" ]; then
        echo "[vpn] 暂无订阅，请先 vpn sub add" >&2
        return 1
    fi
    _vpn_sub_gen_config "$id" || return 1
    if _vpn_mihomo_running; then
        _vpn_sub_restart
    else
        echo "[vpn] 已重新生成配置，执行 vpn on 生效"
    fi
}

_vpn_sub_update_one() {
    # 返回值：0=有更新 1=失败 2=无变化
    local id="$1" url raw tmp out n rc
    url=$(awk -F '\t' -v id="$id" '$1==id {print $3}' "$SUBS_LIST")
    if [ -z "$url" ] || [ "$url" = "local" ]; then
        echo "  - $id: 本地订阅，无可更新 URL"
        return 2
    fi
    tmp="$SUBS_DIR/.$id.dl.$$"
    if ! _vpn_sub_fetch "$url" "$tmp"; then
        rm -f "$tmp"
        echo "  ✗ $id: 下载失败"
        return 1
    fi
    out="$SUBS_DIR/.$id.nm.$$"
    if ! n=$(_vpn_sub_normalize "$tmp" "$out"); then
        rm -f "$tmp" "$out"
        echo "  ✗ $id: 订阅内容解析失败"
        return 1
    fi
    if cmp -s "$out" "$SUBS_DIR/$id.yaml" 2>/dev/null; then
        rc=2
        msg="= $id: 无变化（$n 个节点）"
    else
        rc=0
        mv -f "$tmp" "$SUBS_DIR/$id.raw"
        mv -f "$out" "$SUBS_DIR/$id.yaml"
        msg="✓ $id: 已更新（$n 个节点）"
    fi
    rm -f "$tmp" "$out"
    awk -F '\t' -v id="$id" -v now="$(date +%s)" \
        'BEGIN{OFS="\t"} $1==id {$4=now} {print}' "$SUBS_LIST" > "$SUBS_LIST.tmp" \
        && mv -f "$SUBS_LIST.tmp" "$SUBS_LIST"
    echo "$msg"
    return $rc
}

_vpn_sub_check() {
    # 供 vpn on / vpn restart 调用：到时间才更新，否则静默
    _vpn_sub_ensure
    [ -s "$SUBS_ACTIVE" ] 2>/dev/null || return 0
    [ "$(cat "$SUBS_AUTO" 2>/dev/null)" = "1" ] || return 0
    local id epoch now
    id=$(cat "$SUBS_ACTIVE")
    epoch=$(awk -F '\t' -v id="$id" '$1==id {print $4}' "$SUBS_LIST")
    [ -n "$epoch" ] || return 0
    now=$(date +%s)
    [ $((now - epoch)) -lt "$SUB_UPDATE_INTERVAL" ] && return 0
    echo "[vpn] 当前订阅已超过 $((SUB_UPDATE_INTERVAL / 3600))h 未更新，开始自动更新..."
    _vpn_sub_update_one "$id"
    local rc=$?
    if [ "$rc" = "0" ] && _vpn_mihomo_running; then
        echo "[vpn] 订阅已更新，重启 Mihomo 生效..."
        vpn restart
    elif [ "$rc" = "1" ]; then
        echo "[vpn] 自动更新失败（可能网络不通），继续使用现有配置"
    fi
}

_vpn_sub_restart() {
    vpn restart
}

vpn_sub() {
    local cmd="${1:-list}"
    case "$cmd" in
        list|ls)
            _vpn_sub_ensure
            local i=0 id name url epoch active_id mark n total auto
            active_id=$(cat "$SUBS_ACTIVE" 2>/dev/null || true)
            total=$(wc -l < "$SUBS_LIST" 2>/dev/null || echo 0)
            echo "===== 订阅列表（$total 个）====="
            while IFS=$'\t' read -r id name url epoch; do
                [ -n "$id" ] || continue
                i=$((i + 1))
                [ "$id" = "$active_id" ] && mark="*" || mark=" "
                n=$(grep -c '^- name:' "$SUBS_DIR/$id.yaml" 2>/dev/null)
                n=${n:-0}
                printf '%s %d. %-20s [%s] 节点:%-5s 更新:%s\n' \
                    "$mark" "$i" "$name" "$id" "$n" \
                    "$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 未知)"
            done < "$SUBS_LIST"
            [ "$total" = "0" ] && echo "  暂无订阅，添加: vpn sub add <订阅URL> [名称]"
            auto=$(cat "$SUBS_AUTO" 2>/dev/null)
            [ "$auto" = "1" ] && auto=开 || auto=关
            echo "自动更新: $auto（间隔 $((SUB_UPDATE_INTERVAL / 3600))h，vpn on/restart 时检查）"
            ;;

        add)
            _vpn_sub_ensure
            local url="$2" name="$3" id next n tmp
            if [ -z "$url" ]; then
                echo "用法: vpn sub add <订阅URL> [名称]" >&2
                return 1
            fi
            next=$(($(wc -l < "$SUBS_LIST" 2>/dev/null) + 1))
            while grep -qF "$(printf 'sub_%s\t' "$next")" "$SUBS_LIST" 2>/dev/null; do
                next=$((next + 1))
            done
            id="sub_$next"
            [ -n "$name" ] || name="订阅-$next"
            name=$(printf '%s' "$name" | tr '\t\n' '  ')
            echo "[vpn] 正在下载订阅..."
            tmp="$SUBS_DIR/.$id.dl.$$"
            if ! _vpn_sub_fetch "$url" "$tmp"; then
                rm -f "$tmp"
                echo "[vpn] 下载失败，请检查 URL 与网络" >&2
                return 1
            fi
            if ! n=$(_vpn_sub_normalize "$tmp" "$SUBS_DIR/$id.yaml"); then
                rm -f "$tmp"
                echo "[vpn] 订阅内容解析失败（需为 Clash 配置 / 代理列表 / base64 订阅）" >&2
                return 1
            fi
            mv -f "$tmp" "$SUBS_DIR/$id.raw"
            printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$url" "$(date +%s)" >> "$SUBS_LIST"
            echo "[vpn] 已添加订阅「$name」（$id），$n 个节点"
            if [ ! -s "$SUBS_ACTIVE" ] 2>/dev/null; then
                printf '%s\n' "$id" > "$SUBS_ACTIVE"
                if _vpn_sub_gen_config "$id"; then
                    echo "[vpn] 已设为当前订阅"
                    if _vpn_mihomo_running; then
                        _vpn_sub_restart
                    else
                        echo "[vpn] Mihomo 未在运行，执行 vpn on 即可生效"
                    fi
                fi
            fi
            return 0
            ;;

        use|switch|select)
            _vpn_sub_ensure
            local key="$2" id name
            if [ -z "$key" ]; then
                echo "用法: vpn sub use <名称|ID>" >&2
                return 1
            fi
            id=$(_vpn_sub_id "$key")
            if [ -z "$id" ]; then
                echo "[vpn] 找不到订阅: $key（vpn sub list 查看）" >&2
                return 1
            fi
            printf '%s\n' "$id" > "$SUBS_ACTIVE"
            if ! _vpn_sub_gen_config "$id"; then return 1; fi
            name=$(awk -F '\t' -v id="$id" '$1==id {print $2}' "$SUBS_LIST")
            echo "[vpn] 已切换到订阅「$name」（$id）"
            if _vpn_mihomo_running; then
                _vpn_sub_restart
            else
                echo "[vpn] Mihomo 未在运行，执行 vpn on 即可生效"
            fi
            return 0
            ;;

        update|refresh)
            _vpn_sub_ensure
            local arg="$2" ids id active_id changed=0 failed=0 rc
            active_id=$(cat "$SUBS_ACTIVE" 2>/dev/null || true)
            if [ "$arg" = "all" ]; then
                ids=$(cut -f1 "$SUBS_LIST" 2>/dev/null)
            elif [ -n "$arg" ]; then
                id=$(_vpn_sub_id "$arg")
                [ -n "$id" ] || { echo "[vpn] 找不到订阅: $arg" >&2; return 1; }
                ids="$id"
            else
                [ -n "$active_id" ] || { echo "[vpn] 暂无订阅" >&2; return 1; }
                ids="$active_id"
            fi
            [ -n "$ids" ] || { echo "[vpn] 暂无订阅" >&2; return 1; }
            for id in $ids; do
                _vpn_sub_update_one "$id"
                rc=$?
                case $rc in
                    0) [ "$id" = "$active_id" ] && changed=1 ;;
                    1) failed=1 ;;
                esac
            done
            if [ "$changed" = "1" ] && _vpn_mihomo_running; then
                echo "[vpn] 当前订阅已更新，重启 Mihomo 生效..."
                _vpn_sub_restart
            fi
            [ "$failed" = "1" ] && return 1
            ;;

        remove|rm)
            _vpn_sub_ensure
            local key="$2" id active_id
            if [ -z "$key" ]; then
                echo "用法: vpn sub remove <名称|ID>" >&2
                return 1
            fi
            id=$(_vpn_sub_id "$key")
            [ -n "$id" ] || { echo "[vpn] 找不到订阅: $key" >&2; return 1; }
            active_id=$(cat "$SUBS_ACTIVE" 2>/dev/null || true)
            if [ "$id" = "$active_id" ]; then
                echo "[vpn] 不能删除当前使用中的订阅，请先 vpn sub use 切换到其他订阅" >&2
                return 1
            fi
            grep -vF "$(printf '%s\t' "$id")" "$SUBS_LIST" > "$SUBS_LIST.tmp" \
                && mv -f "$SUBS_LIST.tmp" "$SUBS_LIST"
            rm -f "$SUBS_DIR/$id.yaml" "$SUBS_DIR/$id.raw"
            echo "[vpn] 已删除订阅: $key"
            ;;

        auto)
            _vpn_sub_ensure
            local arg="${2:-status}"
            case "$arg" in
                on|1)
                    printf '1\n' > "$SUBS_AUTO"
                    echo "[vpn] 自动更新已开启（间隔 $((SUB_UPDATE_INTERVAL / 3600))h）"
                    ;;
                off|0)
                    printf '0\n' > "$SUBS_AUTO"
                    echo "[vpn] 自动更新已关闭"
                    ;;
                status)
                    [ "$(cat "$SUBS_AUTO" 2>/dev/null)" = "1" ] && echo "开" || echo "关"
                    ;;
                *)
                    echo "用法: vpn sub auto on|off|status" >&2
                    return 1
                    ;;
            esac
            ;;

        check)
            _vpn_sub_check
            ;;

        help|-h|--help)
            cat <<'EOF'
vpn sub - 订阅管理命令

子命令:
  vpn sub list                  列出所有订阅（* 为当前使用）
  vpn sub add <URL> [名称]      添加订阅（clash yaml / base64 / sub:// / json 均可）
  vpn sub use <名称|ID>         切换当前订阅（重新生成 config.yaml 并重启）
  vpn sub update [all|名称|ID]  更新订阅（默认当前订阅；all 更新全部）
  vpn sub remove <名称|ID>      删除订阅
  vpn sub auto on|off|status    自动更新开关（vpn on/restart 时自动检查，默认间隔 24h）
  vpn sub help                  显示本帮助

说明:
  - 订阅文件保存在 $SUBS_DIR/，config.yaml 由 $BASE_CONFIG 自动生成
  - 手动调整 dns/rules/端口请编辑 $BASE_CONFIG
  - 第一次运行时，现有 config.yaml 会被抽离为基础配置 + 默认订阅
    （原文件备份为 config.yaml.bak-inline）
EOF
            ;;

        *)
            echo "[vpn] 未知子命令: $cmd" >&2
            echo "  用法: vpn sub list|add|use|update|remove|auto|check|help" >&2
            return 2
            ;;
    esac
}

# ---- 节点切换 / 全局模式 ----
_VPN_SKIP_NODES="♻️自动选择 🐟漏网之鱼 🛑广告拦截 🎬媒体解锁 🤖AI网站 REJECT REJECT-DROP PASS COMPATIBLE GLOBAL default"

_vpn_node_skipped() {
    case "$_VPN_SKIP_NODES" in *" $1 "*) return 0 ;; esac
    return 1
}

_vpn_node_filter() {
    # 过滤策略组与特殊名称，只留真实节点（含 DIRECT），输出带序号（stdin: 组 JSON）
    local data now n i=0 mark
    data=$(cat)
    now=$(_vpn_json_get_str "$data" now 2>/dev/null) || now=""
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        _vpn_node_skipped "$n" && continue
        i=$((i + 1))
        if [ "$n" = "$now" ]; then mark='*'; else mark=' '; fi
        printf '%s %3d. %s\n' "$mark" "$i" "$n"
    done < <(_vpn_json_get_arr "$data" all)
}

_vpn_node_pick() {
    # 解析名称或序号 -> 节点名；输出到 stdout（stdin: 组 JSON）
    local key="$1" data n i=0
    printf '%s' "$key" | grep -Eq '^[0-9]+$' || {
        printf '%s\n' "$key"
        return 0
    }
    data=$(cat)
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        _vpn_node_skipped "$n" && continue
        i=$((i + 1))
        if [ "$i" = "$key" ]; then
            printf '%s\n' "$n"
            return 0
        fi
    done < <(_vpn_json_get_arr "$data" all)
    return 1
}

vpn_node() {
    local cmd="${1:-list}" group data target now
    group=$(_vpn_current_group)
    case "$cmd" in
        list|ls)
            data=$(_vpn_api GET "/proxies/$group") || return 1
            echo "===== 节点列表（$group 组）====="
            printf '%s' "$data" | _vpn_node_filter
            ;;
        use|select|switch)
            local key="$2"
            if [ -z "$key" ]; then
                echo "用法: vpn node use <节点名称|序号>" >&2
                return 1
            fi
            data=$(_vpn_api GET "/proxies/$group") || return 1
            target=$(printf '%s' "$data" | _vpn_node_pick "$key") || {
                echo "[vpn] 找不到节点: $key" >&2
                return 1
            }
            _vpn_api PUT "/proxies/$group" \
                "$(printf '{"name":"%s"}' "${target//\"/\\\"}")" >/dev/null || return 1
            echo "[vpn] 已切换: $group → $target"
            ;;
        auto)
            _vpn_api PUT "/proxies/🚀节点选择" '{"name":"♻️自动选择"}' >/dev/null || return 1
            echo "[vpn] 已切换: 🚀节点选择 → ♻️自动选择（自动测速选优）"
            ;;
        show|status)
            data=$(_vpn_api GET "/proxies/$group") || return 1
            now=$(_vpn_json_get_str "$data" now 2>/dev/null) || now=""
            if [ "$(_vpn_current_mode)" = "global" ]; then
                echo "全局模式: GLOBAL → 🚀节点选择 → $now（所有流量走该节点）"
            else
                echo "规则模式: 🚀节点选择 → $now"
            fi
            ;;
        help|-h|--help)
            cat <<'EOF'
vpn node - 节点切换命令

子命令:
  vpn node list             列出当前组的全部节点（* 为当前选中）
  vpn node use <名称|序号>  切换节点（序号见 list 输出）
  vpn node auto             切回自动选择（url-test 测速选优）
  vpn node show             查看当前选中的节点

说明:
  - 规则模式下切换的是「🚀节点选择」组
  - 全局模式（vpn global on）下切换的是「GLOBAL」组，所有流量走选中节点
EOF
            ;;
        *)
            echo "[vpn] 未知子命令: $cmd" >&2
            echo "  用法: vpn node list|use|auto|show|help" >&2
            return 2
            ;;
    esac
}

# ---- 主入口 ----
vpn() {
    local cmd="${1:-status}"
    case "$cmd" in
        on|start)
            vpn_sub check
            if _vpn_start_mihomo; then
                _vpn_set_proxy
                _vpn_post_start
                echo "[vpn] 当前终端代理已开启 → http://127.0.0.1:$PROXY_PORT"
            else
                return 1
            fi
            ;;
        off|disable)
            _vpn_unset_proxy
            echo "[vpn] 当前终端代理已关闭（Mihomo 进程仍在运行，可随时 vpn on 再开）"
            ;;
        stop)
            _vpn_unset_proxy
            _vpn_stop_mihomo
            echo "[vpn] 代理与 Mihomo 均已关闭"
            ;;
        restart)
            _vpn_stop_mihomo
            sleep 1
            vpn_sub check
            if _vpn_start_mihomo; then
                _vpn_set_proxy
                _vpn_post_start
            else
                return 1
            fi
            ;;
        status)
            local pid port port_info
            echo "===== Mihomo 进程 ====="
            if _vpn_mihomo_running; then
                pid="$(_vpn_mihomo_pid)"
                echo "  状态: 运行中"
                ps -p "$pid" -o pid=,args= | sed 's/^/  /'
            else
                echo "  状态: 未运行"
            fi
            if [ -x "$MIHOMO_BIN" ]; then
                "$MIHOMO_BIN" -v 2>&1 | head -n 1 | sed 's/^/  版本: /'
            fi
            echo "===== 端口监听 ====="
            for port in $LISTEN_PORTS $CONTROL_PORT; do
                port_info=$(ss -ltnH 2>/dev/null | grep -E ":${port}[[:space:]]" || true)
                if [ -n "$port_info" ]; then
                    echo "$port_info" | sed 's/^/  /'
                fi
            done
            echo "===== 当前终端代理 ====="
            if [ -n "$http_proxy" ]; then
                echo "  http_proxy  = $http_proxy"
                echo "  https_proxy = $https_proxy"
            else
                echo "  未设置（当前终端不走代理）"
            fi
            echo "===== 本地上游代理 ====="
            if [ -n "$LOCAL_PROXY" ]; then
                echo "  $LOCAL_PROXY（订阅节点通过 dialer-proxy 出站）"
            else
                echo "  未设置"
            fi
            echo "===== 订阅 ====="
            if [ -s "$SUBS_ACTIVE" ] 2>/dev/null; then
                _vpn_sub_ensure
                local sub_id sub_line sub_name sub_epoch sub_count sub_auto
                sub_id=$(cat "$SUBS_ACTIVE" 2>/dev/null)
                sub_line=$(_vpn_sub_entry "$sub_id")
                sub_name=$(printf '%s\n' "$sub_line" | cut -f2)
                sub_epoch=$(printf '%s\n' "$sub_line" | cut -f4)
                sub_count=$(grep -c '^- name:' "$SUBS_DIR/$sub_id.yaml" 2>/dev/null)
                sub_count=${sub_count:-0}
                [ "$(cat "$SUBS_AUTO" 2>/dev/null)" = "1" ] && sub_auto=开 || sub_auto=关
                echo "  当前: $sub_name [$sub_id]  节点: $sub_count"
                echo "  上次更新: $(date -d "@$sub_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 未知)  自动更新: $sub_auto"
                echo "  订阅管理: vpn sub list | vpn sub add <URL> | vpn sub use <名称> | vpn sub update"
            else
                echo "  未设置订阅（vpn sub add <订阅URL> [名称]）"
            fi
            echo "===== 模式与节点 ====="
            if _vpn_mihomo_running; then
                local node_mode node_group node_now node_data
                node_mode=$(_vpn_current_mode)
                [ -z "$node_mode" ] && node_mode=$(_vpn_yaml_top_scalar "$BASE_CONFIG" mode 2>/dev/null)
                [ -z "$node_mode" ] && node_mode=rule
                node_group=$(_vpn_current_group)
                node_data=$(_vpn_api GET "/proxies/$node_group" 2>/dev/null) && {
                    node_now=$(_vpn_json_get_str "$node_data" now 2>/dev/null) || node_now=""
                    echo "  模式: $node_mode  当前节点: $node_now"
                    echo "  切换: vpn node list | vpn node use <名称> | vpn node auto"
                } || echo "  模式: $node_mode（控制器未就绪，重启后可用 vpn node）"
            else
                echo "  Mihomo 未运行（vpn on 启动后可用 vpn node）"
            fi
            ;;
        test)
            echo "===== 连通性测试 ====="
            _vpn_test "https://www.google.com"
            _vpn_test "https://github.com"
            _vpn_test "https://www.baidu.com"
            ;;
        log)
            tail -n "${2:-30}" "$MIHOMO_LOG"
            ;;
        sub|subscription)
            shift
            vpn_sub "$@"
            ;;
        node)
            shift
            vpn_node "$@"
            ;;
        local-proxy|upstream)
            local arg="${2:-status}" url
            case "$arg" in
                on|set)
                    url="${3:-}"
                    [ -n "$url" ] || {
                        echo "用法: vpn local-proxy on <socks5://host:port|http://host:port>" >&2
                        return 1
                    }
                    LOCAL_PROXY="$url"
                    _vpn_sub_regen_restart || return 1
                    echo "[vpn] 已设置本地上游代理: $LOCAL_PROXY"
                    ;;
                off|disable)
                    LOCAL_PROXY=""
                    _vpn_sub_regen_restart || return 1
                    echo "[vpn] 已关闭本地上游代理"
                    ;;
                status)
                    [ -n "$LOCAL_PROXY" ] && echo "[vpn] 本地上游代理: $LOCAL_PROXY" \
                        || echo "[vpn] 本地上游代理: 未设置"
                    ;;
                *)
                    echo "用法: vpn local-proxy on <URL>|off|status" >&2
                    return 1
                    ;;
            esac
            ;;
        global|mode)
            local arg="${2:-status}"
            case "$arg" in
                on|global)
                    printf 'global\n' > "$SUBS_DIR/mode"
                    echo "[vpn] 已开启全局模式：所有流量走选中的节点（vpn node use 选择）"
                    _vpn_sub_regen_restart
                    ;;
                off|rule)
                    printf 'rule\n' > "$SUBS_DIR/mode"
                    echo "[vpn] 已关闭全局模式：按规则分流（vpn node use 选择 🚀节点选择）"
                    _vpn_sub_regen_restart
                    ;;
                status)
                    local mode base_mode
                    mode=$(_vpn_current_mode)
                    base_mode=$(_vpn_yaml_top_scalar "$BASE_CONFIG" mode 2>/dev/null)
                    [ -z "$mode" ] && mode="$base_mode"
                    echo "[vpn] 当前模式: $mode${base_mode:+（base 默认 $base_mode）}"
                    ;;
                *)
                    echo "用法: vpn global on|off|status" >&2
                    return 1
                    ;;
            esac
            ;;
        help|-h|--help)
            cat <<'EOF'
vpn - Mihomo 代理控制命令

子命令:
  vpn on        启动 Mihomo + 开启当前终端代理
  vpn off       关闭当前终端代理（保留 Mihomo 进程）
  vpn stop      停止 Mihomo 进程 + 关闭代理
  vpn restart   重启 Mihomo 进程
  vpn status    查看状态（进程/端口/代理/订阅）
  vpn test      测试连通性（Google/GitHub/Baidu）
  vpn log [N]   查看最近 N 行日志（默认 30）
  vpn sub       订阅管理：list/add/use/update/remove/auto（详见 vpn sub help）
  vpn node      节点切换：list/use/auto/show（规则模式选 🚀节点选择）
  vpn local-proxy  设置本地上游代理（如 socks5://localhost:9632）
  vpn global    全局模式 on|off|status（所有流量走选中的节点）
  vpn help      显示本帮助

注意:
  - "vpn on/off" 仅影响当前终端；新开终端需再次执行 vpn on
  - 如需永久开启，把 vpn on 加入 ~/.bashrc 末尾即可
  - 端口设置（优先级：环境变量 > $MIHOMO_DIR/ports.conf > 默认值）：
      PROXY_PORT=7890 SOCKS_PORT=7891 HTTP_PORT=7892 CONTROL_PORT=9090
    每次启动前会检测端口占用，被其他进程占用时会报错并提示处理方法；
    共享服务器上请为 ports.conf 配置一套专属端口，避免与他人冲突
  - 本地上游代理可写入 $PORTS_CONF：LOCAL_PROXY=socks5://localhost:9632，
    或用 vpn local-proxy on <URL> 临时设置；订阅节点通过该代理出站，DIRECT 仍直连
  - 手动调整 dns/rules/端口请编辑 config.base.yaml（由订阅功能自动生成 config.yaml）
EOF
            ;;
        *)
            echo "[vpn] 未知子命令: $cmd" >&2
            echo "  用法: vpn on|off|stop|status|restart|test|log|sub|node|local-proxy|global|help" >&2
            return 2
            ;;
    esac
}

# ---- 兼容旧命令名 ----
unvpn() {
    vpn off
}

# 加载提示（仅在新开 shell 时显示一次，可注释掉）
# echo "[vpn.sh] 已加载，输入 'vpn help' 查看用法"
