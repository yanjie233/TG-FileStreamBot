#!/bin/bash
set -euo pipefail

# ============================================================
#  TG-FileStreamBot 一键安装管理脚本
#  仓库: https://github.com/yanjie233/TG-FileStreamBot
# ============================================================

INSTALL_DIR="/etc/fsb"
BINARY_PATH="${INSTALL_DIR}/fsb"
CONFIG_FILE="${INSTALL_DIR}/fsb.env"
LOG_DIR="/var/log/fsb"
SERVICE_NAME="fsb"
REPO="yanjie233/TG-FileStreamBot"
GITHUB_API="https://api.github.com/repos/${REPO}/releases/latest"

# 运行时检测
DISTRO=""
ARCH=""
INIT_SYSTEM=""
CURRENT_VERSION=""
DOWNLOADER=""

# 临时文件追踪
TMPFILES=()

# ============================================================
#  颜色与样式
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[成功]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*" >&2; }

header() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}========================================${NC}"
}

# ============================================================
#  工具函数
# ============================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        error "请使用: sudo bash $0"
        exit 1
    fi
}

detect_downloader() {
    if command -v curl &>/dev/null; then
        DOWNLOADER="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOADER="wget"
    else
        error "未找到 curl 或 wget，请先安装"
        exit 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local retries=3
    local attempt=0

    while (( attempt < retries )); do
        if [[ "$DOWNLOADER" == "curl" ]]; then
            if curl -fsSL --connect-timeout 15 --retry 2 -o "$output" "$url"; then
                return 0
            fi
        else
            if wget -q --timeout=15 --tries=2 -O "$output" "$url"; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        if (( attempt < retries )); then
            warn "下载失败，${attempt}/${retries} 次重试..."
            sleep 2
        fi
    done
    return 1
}

download_api() {
    local url="$1"
    local output="$2"
    local retries=3
    local attempt=0

    while (( attempt < retries )); do
        if [[ "$DOWNLOADER" == "curl" ]]; then
            if curl -fsSL --connect-timeout 15 --retry 2 \
                -H "Accept: application/vnd.github.v3+json" \
                -o "$output" "$url"; then
                return 0
            fi
        else
            if wget -q --timeout=15 --tries=2 \
                --header="Accept: application/vnd.github.v3+json" \
                -O "$output" "$url"; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        if (( attempt < retries )); then
            warn "API 请求失败，${attempt}/${retries} 次重试..."
            sleep 2
        fi
    done
    return 1
}

cleanup() {
    for f in "${TMPFILES[@]}"; do
        rm -rf "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT

mktempdir() {
    local dir
    dir=$(mktemp -d)
    TMPFILES+=("$dir")
    echo "$dir"
}

prompt_input() {
    local msg="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        echo -en "${CYAN}${msg}${NC} [${DIM}${default}${NC}]: "
    else
        echo -en "${CYAN}${msg}${NC}: "
    fi

    read -r result < /dev/tty
    echo "${result:-$default}"
}

prompt_confirm() {
    local msg="$1"
    local default="${2:-N}"
    local hint

    if [[ "${default^^}" == "Y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    echo -en "${CYAN}${msg}${NC} [${hint}]: "
    local result
    read -r result < /dev/tty

    if [[ -z "$result" ]]; then
        [[ "${default^^}" == "Y" ]]
    else
        [[ "${result^^}" == "Y" || "$result" == "是" ]]
    fi
}

# ============================================================
#  系统检测
# ============================================================

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            error "不支持的系统架构: $machine"
            error "仅支持 amd64 (x86_64) 和 arm64 (aarch64)"
            exit 1
            ;;
    esac
}

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测系统发行版: /etc/os-release 不存在"
        exit 1
    fi

    source /etc/os-release

    case "${ID:-}" in
        debian)
            DISTRO="debian"
            INIT_SYSTEM="systemd"
            ;;
        ubuntu)
            DISTRO="ubuntu"
            INIT_SYSTEM="systemd"
            ;;
        alpine)
            DISTRO="alpine"
            INIT_SYSTEM="openrc"
            ;;
        *)
            error "不支持的发行版: ${ID:-未知}"
            error "仅支持 Debian、Ubuntu、Alpine"
            exit 1
            ;;
    esac

    # 验证 init 系统
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if ! command -v systemctl &>/dev/null; then
            error "未找到 systemctl，无法管理服务"
            exit 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if ! command -v rc-service &>/dev/null; then
            error "未找到 rc-service，请确认 OpenRC 已安装"
            exit 1
        fi
    fi
}

ensure_alpine_deps() {
    if [[ "$DISTRO" == "alpine" ]]; then
        local missing=()
        command -v bash &>/dev/null || missing+=(bash)
        command -v curl &>/dev/null || missing+=(curl)

        if (( ${#missing[@]} > 0 )); then
            info "Alpine 系统正在安装依赖: ${missing[*]}"
            apk add --no-cache "${missing[@]}" 2>/dev/null || {
                error "安装 Alpine 依赖失败"
                exit 1
            }
        fi
    fi
}

get_current_version() {
    if [[ -x "$BINARY_PATH" ]]; then
        local ver
        ver=$("$BINARY_PATH" --version 2>/dev/null | head -1 || true)
        if [[ -n "$ver" ]]; then
            CURRENT_VERSION="$ver"
        else
            CURRENT_VERSION="未知版本"
        fi
    else
        CURRENT_VERSION=""
    fi
}

# ============================================================
#  版本获取
# ============================================================

get_latest_version() {
    local tmpdir
    tmpdir=$(mktempdir)
    local api_resp="${tmpdir}/api.json"

    info "正在获取最新版本信息..."
    if ! download_api "$GITHUB_API" "$api_resp"; then
        error "无法连接 GitHub API，请检查网络"
        return 1
    fi

    local tag
    tag=$(grep -m1 '"tag_name"' "$api_resp" | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/' || true)

    if [[ -z "$tag" ]]; then
        error "无法解析版本号"
        return 1
    fi

    echo "$tag"
}

get_release_asset_url() {
    local asset_name="$1"
    local tmpdir
    tmpdir=$(mktempdir)
    local api_resp="${tmpdir}/api.json"

    if ! download_api "$GITHUB_API" "$api_resp"; then
        error "无法获取发布信息"
        return 1
    fi

    awk -v target="$asset_name" '
        $0 ~ "\"name\": \"" target "\"" { in_asset = 1 }
        in_asset && /"browser_download_url"/ {
            line = $0
            sub(/^.*"browser_download_url": "/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
        in_asset && /\}/ { in_asset = 0 }
    ' "$api_resp"
}

# ============================================================
#  二进制安装/更新
# ============================================================

install_binary() {
    header "安装 TG-FileStreamBot"

    local version
    version=$(get_latest_version) || return 1
    info "最新版本: ${BOLD}${version}${NC}"

    local binary_name="fsb-linux-${ARCH}"
    local url
    url=$(get_release_asset_url "$binary_name") || return 1

    if [[ -z "$url" ]]; then
        error "未找到对应的发布资源: ${binary_name}"
        return 1
    fi

    info "系统架构: ${ARCH}"
    info "下载地址: ${url}"

    local tmpdir
    tmpdir=$(mktempdir)
    local tmpfile="${tmpdir}/${binary_name}"

    info "正在下载二进制文件..."
    if ! download_file "$url" "$tmpfile"; then
        error "下载失败，请检查网络连接"
        return 1
    fi

    chmod +x "$tmpfile"

    # 验证二进制可执行
    if ! "$tmpfile" --version &>/dev/null; then
        # 有些版本不支持 --version，尝试不带参数运行会阻塞，跳过验证
        warn "无法验证二进制文件，继续安装..."
    fi

    mkdir -p "$INSTALL_DIR"

    # 如果服务正在运行，先停止
    if service_is_running; then
        info "正在停止当前服务..."
        stop_service_silent
    fi

    mv -f "$tmpfile" "$BINARY_PATH"
    success "二进制文件已安装到 ${BINARY_PATH}"
    info "版本: ${version}"
}

update_binary() {
    header "更新 TG-FileStreamBot"

    if [[ -z "$CURRENT_VERSION" ]]; then
        warn "未检测到已安装的版本，将执行全新安装"
        install_binary
        return
    fi

    info "当前版本: ${CURRENT_VERSION}"

    local latest
    latest=$(get_latest_version) || return 1
    info "最新版本: ${BOLD}${latest}${NC}"

    install_binary
}

# ============================================================
#  服务管理
# ============================================================

generate_systemd_service() {
    cat > /etc/systemd/system/${SERVICE_NAME}.service << 'UNIT'
[Unit]
Description=TG-FileStreamBot - Telegram 文件流媒体服务
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/fsb
ExecStart=/etc/fsb/fsb run
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
EnvironmentFile=/etc/fsb/fsb.env

[Install]
WantedBy=multi-user.target
UNIT
}

generate_openrc_service() {
    cat > /etc/init.d/${SERVICE_NAME} << 'INITSCRIPT'
#!/sbin/openrc-run

name="fsb"
description="TG-FileStreamBot - Telegram 文件流媒体服务"
command="/etc/fsb/fsb"
command_args="run"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
directory="/etc/fsb"

extra_started_commands="reload"
description_reload="重新加载配置"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -f /etc/fsb/fsb.env ]; then
        eerror "配置文件 /etc/fsb/fsb.env 不存在"
        return 1
    fi
}

reload() {
    einfo "重新加载配置..."
    start_pre || return 1
    stop
    start
}
INITSCRIPT
    chmod +x /etc/init.d/${SERVICE_NAME}
}

install_service() {
    if [[ ! -x "$BINARY_PATH" ]]; then
        error "二进制文件不存在，请先安装"
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "配置文件不存在，建议先配置再启动服务"
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        generate_systemd_service
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME} &>/dev/null
        success "systemd 服务已安装并设置开机自启"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        generate_openrc_service
        rc-update add ${SERVICE_NAME} default &>/dev/null
        success "OpenRC 服务已安装并添加到默认运行级别"
    fi
}

service_is_running() {
    if [[ ! -x "$BINARY_PATH" ]]; then
        return 1
    fi
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet ${SERVICE_NAME} 2>/dev/null
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service ${SERVICE_NAME} status &>/dev/null
    else
        return 1
    fi
}

start_service() {
    header "启动服务"

    if [[ ! -x "$BINARY_PATH" ]]; then
        error "二进制文件不存在，请先安装"
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "配置文件 ${CONFIG_FILE} 不存在"
        error "请先运行「配置 FSB」"
        return 1
    fi

    if service_is_running; then
        warn "服务已经在运行中"
        return 0
    fi

    # 确保服务已安装
    install_service

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl start ${SERVICE_NAME}; then
            success "服务已启动"
        else
            error "服务启动失败，查看日志: journalctl -u ${SERVICE_NAME} -n 20"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if rc-service ${SERVICE_NAME} start; then
            success "服务已启动"
        else
            error "服务启动失败，查看日志: tail -20 ${LOG_DIR}/${SERVICE_NAME}.log"
            return 1
        fi
    fi
}

stop_service() {
    header "停止服务"

    if ! service_is_running; then
        warn "服务当前未运行"
        return 0
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop ${SERVICE_NAME}
        success "服务已停止"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service ${SERVICE_NAME} stop
        success "服务已停止"
    fi
}

stop_service_silent() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service ${SERVICE_NAME} stop 2>/dev/null || true
    fi
}

restart_service() {
    header "重启服务"

    if [[ ! -x "$BINARY_PATH" ]]; then
        error "二进制文件不存在，请先安装"
        return 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "配置文件 ${CONFIG_FILE} 不存在"
        return 1
    fi

    install_service

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart ${SERVICE_NAME}
        success "服务已重启"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service ${SERVICE_NAME} restart
        success "服务已重启"
    fi
}

show_service_status() {
    header "服务状态"

    if [[ ! -x "$BINARY_PATH" ]]; then
        warn "FSB 未安装"
        return 0
    fi

    info "二进制路径: ${BINARY_PATH}"
    info "配置文件: ${CONFIG_FILE}"

    if [[ -n "$CURRENT_VERSION" ]]; then
        info "当前版本: ${CURRENT_VERSION}"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        info "配置文件: ${GREEN}已存在${NC}"
    else
        warn "配置文件: 未创建"
    fi

    echo ""
    if service_is_running; then
        echo -e "  服务状态: ${GREEN}● 运行中${NC}"
    else
        echo -e "  服务状态: ${RED}● 已停止${NC}"
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        echo ""
        systemctl status ${SERVICE_NAME} --no-pager 2>/dev/null || true
    fi
}

view_logs() {
    header "查看日志"

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        info "使用 Ctrl+C 退出日志查看"
        echo ""
        journalctl -u ${SERVICE_NAME} -f --no-pager
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        local logfile="${LOG_DIR}/${SERVICE_NAME}.log"
        if [[ -f "$logfile" ]]; then
            info "日志文件: ${logfile}"
            info "使用 Ctrl+C 退出日志查看"
            echo ""
            tail -f "$logfile"
        else
            warn "日志文件不存在: ${logfile}"
        fi
    fi
}

# ============================================================
#  配置向导
# ============================================================

read_env_value() {
    local file="$1"
    local key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- || true
}

generate_config() {
    header "FSB 配置文件生成向导"

    local existing_values=()
    if [[ -f "$CONFIG_FILE" ]]; then
        warn "配置文件已存在: ${CONFIG_FILE}"
        echo ""
        echo "  1) 重新生成配置文件"
        echo "  2) 编辑现有配置文件"
        echo "  3) 返回"
        echo ""
        echo -en "${CYAN}请选择 [1-3]${NC}: "
        local choice
        read -r choice < /dev/tty

        case "$choice" in
            1) ;;
            2)
                local editor="${EDITOR:-vi}"
                if command -v "$editor" &>/dev/null; then
                    "$editor" "$CONFIG_FILE"
                    success "配置文件已编辑"
                else
                    warn "未找到编辑器 ${editor}，将使用交互式向导"
                fi
                return 0
                ;;
            *) return 0 ;;
        esac
    fi

    echo ""
    echo -e "${BOLD}[必填] 以下为必须配置的变量${NC}"
    echo -e "${DIM}请从 my.telegram.org 获取 API_ID 和 API_HASH${NC}"
    echo -e "${DIM}请从 @BotFather 获取 BOT_TOKEN${NC}"
    echo ""

    # 读取现有值作为默认值
    local def_api_id="" def_api_hash="" def_bot_token="" def_log_channel=""
    local def_port="8080" def_host="" def_hash_length="6"
    local def_use_session="true" def_use_public_ip="false" def_allowed_users=""
    local def_concurrency="4" def_buffer="8" def_timeout="30" def_retries="3"

    if [[ -f "$CONFIG_FILE" ]]; then
        def_api_id=$(read_env_value "$CONFIG_FILE" "API_ID")
        def_api_hash=$(read_env_value "$CONFIG_FILE" "API_HASH")
        def_bot_token=$(read_env_value "$CONFIG_FILE" "BOT_TOKEN")
        def_log_channel=$(read_env_value "$CONFIG_FILE" "LOG_CHANNEL")
        def_port=$(read_env_value "$CONFIG_FILE" "PORT")
        def_host=$(read_env_value "$CONFIG_FILE" "HOST")
        def_hash_length=$(read_env_value "$CONFIG_FILE" "HASH_LENGTH")
        def_use_session=$(read_env_value "$CONFIG_FILE" "USE_SESSION_FILE")
        def_use_public_ip=$(read_env_value "$CONFIG_FILE" "USE_PUBLIC_IP")
        def_allowed_users=$(read_env_value "$CONFIG_FILE" "ALLOWED_USERS")
        def_concurrency=$(read_env_value "$CONFIG_FILE" "STREAM_CONCURRENCY")
        def_buffer=$(read_env_value "$CONFIG_FILE" "STREAM_BUFFER_COUNT")
        def_timeout=$(read_env_value "$CONFIG_FILE" "STREAM_TIMEOUT_SEC")
        def_retries=$(read_env_value "$CONFIG_FILE" "STREAM_MAX_RETRIES")
    fi

    # 必填项
    local api_id api_hash bot_token log_channel
    while true; do
        api_id=$(prompt_input "请输入 API_ID" "$def_api_id")
        [[ -n "$api_id" ]] && break
        error "API_ID 不能为空"
    done

    while true; do
        api_hash=$(prompt_input "请输入 API_HASH" "$def_api_hash")
        [[ -n "$api_hash" ]] && break
        error "API_HASH 不能为空"
    done

    while true; do
        bot_token=$(prompt_input "请输入 BOT_TOKEN" "$def_bot_token")
        [[ -n "$bot_token" ]] && break
        error "BOT_TOKEN 不能为空"
    done

    while true; do
        log_channel=$(prompt_input "请输入 LOG_CHANNEL (频道 ID，如 -1001234567890)" "$def_log_channel")
        [[ -n "$log_channel" ]] && break
        error "LOG_CHANNEL 不能为空"
    done

    echo ""
    echo -e "${BOLD}[可选] 以下为可选配置（直接回车使用默认值）${NC}"
    echo ""

    local port host hash_length use_session use_public_ip allowed_users
    local concurrency buffer_count timeout_sec max_retries

    port=$(prompt_input "HTTP 端口" "$def_port")
    host=$(prompt_input "监听地址（留空自动检测）" "$def_host")
    hash_length=$(prompt_input "URL 哈希长度 (5-32)" "$def_hash_length")
    use_session=$(prompt_input "使用会话文件持久化 (true/false)" "$def_use_session")
    use_public_ip=$(prompt_input "使用公网 IP (true/false)" "$def_use_public_ip")
    allowed_users=$(prompt_input "允许的用户 ID（逗号分隔，留空不限制）" "$def_allowed_users")

    echo ""
    echo -e "${BOLD}[流性能] 下载性能调优${NC}"
    echo ""

    concurrency=$(prompt_input "并发流数量" "$def_concurrency")
    buffer_count=$(prompt_input "缓冲块数量" "$def_buffer")
    timeout_sec=$(prompt_input "流超时时间（秒）" "$def_timeout")
    max_retries=$(prompt_input "最大重试次数" "$def_retries")

    # 多机器人支持
    local multi_tokens=()
    echo ""
    if prompt_confirm "是否配置多机器人加速 (MULTI_TOKEN)？" "N"; then
        local token_num=1
        while (( token_num <= 50 )); do
            local token_val
            token_val=$(prompt_input "请输入 MULTI_TOKEN${token_num}（留空停止添加）" "")
            if [[ -z "$token_val" ]]; then
                break
            fi
            multi_tokens+=("MULTI_TOKEN${token_num}=${token_val}")
            token_num=$((token_num + 1))
        done
    fi

    # 写入配置文件
    mkdir -p "$INSTALL_DIR"

    cat > "$CONFIG_FILE" << EOF
# TG-FileStreamBot 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ========== 必填变量 ==========
API_ID=${api_id}
API_HASH=${api_hash}
BOT_TOKEN=${bot_token}
LOG_CHANNEL=${log_channel}

# ========== 可选变量 ==========
DEV=false
PORT=${port}
HASH_LENGTH=${hash_length}
USE_SESSION_FILE=${use_session}
USE_PUBLIC_IP=${use_public_ip}
EOF

    if [[ -n "$host" ]]; then
        echo "HOST=${host}" >> "$CONFIG_FILE"
    fi

    if [[ -n "$allowed_users" ]]; then
        echo "ALLOWED_USERS=${allowed_users}" >> "$CONFIG_FILE"
    fi

    cat >> "$CONFIG_FILE" << EOF

# ========== 流性能调优 ==========
STREAM_CONCURRENCY=${concurrency}
STREAM_BUFFER_COUNT=${buffer_count}
STREAM_TIMEOUT_SEC=${timeout_sec}
STREAM_MAX_RETRIES=${max_retries}
EOF

    if (( ${#multi_tokens[@]} > 0 )); then
        echo "" >> "$CONFIG_FILE"
        echo "# ========== 多机器人配置 ==========" >> "$CONFIG_FILE"
        for token_line in "${multi_tokens[@]}"; do
            echo "$token_line" >> "$CONFIG_FILE"
        done
    fi

    echo ""
    success "配置文件已生成: ${CONFIG_FILE}"
}

# ============================================================
#  卸载
# ============================================================

uninstall() {
    header "卸载 TG-FileStreamBot"

    echo ""
    echo -e "${RED}${BOLD}即将删除以下内容:${NC}"
    echo ""

    local items_to_remove=()

    if service_is_running; then
        echo "  ${RED}●${NC} 停止并禁用服务"
        items_to_remove+=("service")
    fi

    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        echo "  ${RED}●${NC} /etc/systemd/system/${SERVICE_NAME}.service"
        items_to_remove+=("systemd")
    fi

    if [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
        echo "  ${RED}●${NC} /etc/init.d/${SERVICE_NAME}"
        items_to_remove+=("openrc")
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        echo "  ${RED}●${NC} ${INSTALL_DIR}/ (二进制与配置)"
        items_to_remove+=("install")
    fi

    if [[ -d "$LOG_DIR" ]]; then
        echo "  ${RED}●${NC} ${LOG_DIR}/ (日志)"
        items_to_remove+=("logs")
    fi

    if (( ${#items_to_remove[@]} == 0 )); then
        warn "未找到已安装的 FSB"
        return 0
    fi

    echo ""
    if ! prompt_confirm "确认卸载？此操作不可撤销" "N"; then
        info "已取消卸载"
        return 0
    fi

    echo ""

    # 停止服务
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service ${SERVICE_NAME} stop 2>/dev/null || true
        rc-update del ${SERVICE_NAME} default 2>/dev/null || true
    fi

    # 删除服务文件
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    if [[ -f "/etc/init.d/${SERVICE_NAME}" ]]; then
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi

    # 删除安装目录和日志
    rm -rf "$INSTALL_DIR"
    rm -rf "$LOG_DIR"

    CURRENT_VERSION=""
    success "卸载完成"
}

# ============================================================
#  菜单系统
# ============================================================

show_menu() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  TG-FileStreamBot 管理工具 v1.1${NC}"
    echo -e "${BOLD}========================================${NC}"

    # 显示当前状态
    if [[ -n "$CURRENT_VERSION" ]]; then
        echo -e "  版本: ${CYAN}${CURRENT_VERSION}${NC}"
    fi

    local status_text="${RED}未安装${NC}"
    if [[ -x "$BINARY_PATH" ]]; then
        if service_is_running; then
            status_text="${GREEN}运行中${NC}"
        else
            status_text="${YELLOW}已停止${NC}"
        fi
    fi
    echo -e "  状态: ${status_text}"
    echo ""

    local installed=false
    local running=false
    [[ -x "$BINARY_PATH" ]] && installed=true
    service_is_running && running=true

    if [[ "$installed" == "false" ]]; then
        # 未安装状态
        echo "  1) 安装 FSB"
        echo "  0) 退出"
    else
        # 已安装状态
        echo "  1) 重新安装 FSB"
        echo "  2) 更新 FSB"
        echo "  3) 配置 FSB"
        if [[ "$running" == "true" ]]; then
            echo "  4) 重启服务"
            echo "  5) 停止服务"
        else
            echo "  4) 启动服务"
        fi
        echo "  6) 查看状态"
        echo "  7) 查看日志"
        echo "  8) 卸载 FSB"
        echo "  0) 退出"
    fi

    echo -e "${BOLD}========================================${NC}"
}

read_choice() {
    echo -en "${CYAN}请选择操作${NC}: "
    local choice
    read -r choice < /dev/tty

    local installed=false
    local running=false
    [[ -x "$BINARY_PATH" ]] && installed=true
    service_is_running && running=true

    if [[ "$installed" == "false" ]]; then
        case "$choice" in
            1) install_binary ;;
            0) echo ""; success "再见！"; exit 0 ;;
            *) warn "无效选择，请输入 0 或 1" ;;
        esac
    else
        case "$choice" in
            1)
                warn "FSB 已安装，将执行重新安装"
                install_binary
                ;;
            2) update_binary ;;
            3) generate_config ;;
            4)
                if [[ "$running" == "true" ]]; then
                    restart_service
                else
                    start_service
                fi
                ;;
            5)
                if [[ "$running" == "true" ]]; then
                    stop_service
                else
                    warn "无效选择"
                fi
                ;;
            6) show_service_status ;;
            7) view_logs ;;
            8) uninstall ;;
            0) echo ""; success "再见！"; exit 0 ;;
            *) warn "无效选择" ;;
        esac
    fi

    get_current_version
}

# ============================================================
#  CLI 参数支持
# ============================================================

cli_main() {
    local cmd="${1:-}"

    check_root
    detect_downloader
    detect_arch
    detect_distro
    ensure_alpine_deps
    get_current_version

    case "$cmd" in
        install)
            install_binary
            install_service
            echo ""
            info "安装完成！接下来请运行配置:"
            echo -e "  ${CYAN}bash $0 config${NC}"
            ;;
        update)
            update_binary
            ;;
        config)
            generate_config
            ;;
        start)
            start_service
            ;;
        stop)
            stop_service
            ;;
        restart)
            restart_service
            ;;
        status)
            show_service_status
            ;;
        logs)
            view_logs
            ;;
        uninstall)
            uninstall
            ;;
        *)
            error "未知命令: $cmd"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "可用命令:"
            echo "  install    安装 FSB"
            echo "  update     更新 FSB"
            echo "  config     配置 FSB"
            echo "  start      启动服务"
            echo "  stop       停止服务"
            echo "  restart    重启服务"
            echo "  status     查看状态"
            echo "  logs       查看日志"
            echo "  uninstall  卸载 FSB"
            echo ""
            echo "不带参数运行进入交互菜单"
            exit 1
            ;;
    esac
}

# ============================================================
#  主入口
# ============================================================

main() {
    # 支持 CLI 参数
    if [[ $# -gt 0 ]]; then
        cli_main "$1"
        return
    fi

    # 交互模式
    check_root
    detect_downloader
    detect_arch
    detect_distro
    ensure_alpine_deps
    get_current_version

    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║  TG-FileStreamBot 安装管理工具       ║"
    echo "  ║https://github.com/yanjie233/TG-FileStreamBot║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    info "系统: ${DISTRO} | 架构: ${ARCH} | 初始化: ${INIT_SYSTEM}"

    while true; do
        show_menu
        read_choice
    done
}

main "$@"
