#!/bin/bash

KIRO_PROXY_DIR="$HOME/.kiro-proxy"
USAGE_DIR="$KIRO_PROXY_DIR/usage/$(date +%Y/%m)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_SETTINGS_BACKUP="$HOME/.claude/settings.json.backup.$(date +%Y%m%d_%H%M%S)"
PROXY_URL="http://localhost:3456"
PROXY_LOG="$KIRO_PROXY_DIR/proxy.log"
OPUS_MODEL="claude-opus-4-7"
SONNET_MODEL="claude-sonnet-4-6"
HAIKU_MODEL="claude-haiku-4-5-20251001"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

check_kiro_auth() {
    local token_file="$HOME/.aws/sso/cache/kiro-auth-token.json"
    if [ ! -f "$token_file" ]; then
        log_error "Kiro auth token 不存在: $token_file"
        log_info "请先运行: kiro auth"
        exit 1
    fi
    log_info "Kiro auth token 文件存在 ✓"
}

create_dirs() {
    log_step "创建 kiro-proxy 所需目录..."
    mkdir -p "$USAGE_DIR"
    log_info "目录创建完成 ✓"
}

check_proxy_running() {
    if curl --noproxy '*' -s "$PROXY_URL/health" > /dev/null 2>&1; then
        log_info "Kiro Proxy 已在运行 ✓"
        return 0
    fi
    return 1
}

start_proxy() {
    log_step "启动 Kiro Proxy..."
    set -m
    nohup npx @colin3191/kiro-proxy@latest > "$PROXY_LOG" 2>&1 &
    local pid=$!
    local pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    echo "$pid $pgid" > "$KIRO_PROXY_DIR/proxy.pid"

    local retries=0
    while [ $retries -lt 60 ]; do
        sleep 1
        if curl --noproxy '*' -s "$PROXY_URL/health" > /dev/null 2>&1; then
            log_info "Kiro Proxy 启动成功 (PID: $pid) ✓"
            log_info "  Anthropic API: $PROXY_URL/v1/messages"
            log_info "  OpenAI API:     $PROXY_URL/v1/chat/completions"
            log_info "  Models:         $PROXY_URL/v1/models"
            return 0
        fi
        retries=$((retries + 1))
    done

    log_error "Kiro Proxy 启动超时"
    exit 1
}

stop_proxy() {
    local stopped=0
    if [ -f "$KIRO_PROXY_DIR/proxy.pid" ]; then
        local pid pgid
        read -r pid pgid < "$KIRO_PROXY_DIR/proxy.pid"
        if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
            kill -TERM "-$pgid" 2>/dev/null
            log_info "Kiro Proxy (PID: $pid, PGID: $pgid) 已停止 ✓"
            stopped=1
        elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ -z "$pgid" ]; then
                pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
            fi
            if [ -n "$pgid" ]; then
                kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
            else
                kill -TERM "$pid" 2>/dev/null
            fi
            log_info "Kiro Proxy (PID: $pid) 已停止 ✓"
            stopped=1
        fi
        rm -f "$KIRO_PROXY_DIR/proxy.pid"
    fi

    if [ "$stopped" -eq 0 ]; then
        pkill -f "npm exec @colin3191/kiro-proxy" 2>/dev/null && stopped=1
        pkill -f "node .*/node_modules/.bin/kiro-proxy" 2>/dev/null && stopped=1
        if [ "$stopped" -eq 1 ]; then
            log_info "Kiro Proxy 已停止 ✓"
        fi
    fi
}

backup_settings() {
    if [ -f "$CLAUDE_SETTINGS" ]; then
        cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS_BACKUP"
        log_info "Claude Settings 已备份到: $CLAUDE_SETTINGS_BACKUP"
    fi
}

switch_to_kiro() {
    log_step "切换 Claude Code 到 Kiro Proxy (Opus)..."
    backup_settings

    if [ ! -f "$CLAUDE_SETTINGS" ]; then
        log_error "Claude Settings 文件不存在: $CLAUDE_SETTINGS"
        exit 1
    fi

    local tmp_settings=$(mktemp)
    python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS', 'r') as f:
    data = json.load(f)

if 'env' not in data:
    data['env'] = {}

old_base_url = data['env'].get('ANTHROPIC_BASE_URL', '')
old_auth_token = data['env'].get('ANTHROPIC_AUTH_TOKEN', '')

already_on_proxy = old_base_url == '$PROXY_URL'
if not already_on_proxy and '_kiro_proxy_backup' not in data:
    data['_kiro_proxy_backup'] = {
        'ANTHROPIC_BASE_URL': old_base_url,
        'ANTHROPIC_AUTH_TOKEN': old_auth_token
    }

data['env']['ANTHROPIC_BASE_URL'] = '$PROXY_URL'
data['env']['ANTHROPIC_AUTH_TOKEN'] = 'any'
data['env']['ANTHROPIC_MODEL'] = '$OPUS_MODEL'
data['env']['ANTHROPIC_DEFAULT_OPUS_MODEL'] = '$OPUS_MODEL'
data['env']['ANTHROPIC_DEFAULT_SONNET_MODEL'] = '$SONNET_MODEL'
data['env']['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = '$HAIKU_MODEL'
data['env']['CLAUDE_CODE_SUBAGENT_MODEL'] = '$SONNET_MODEL'

with open('$tmp_settings', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>&1

    if [ $? -eq 0 ]; then
        mv "$tmp_settings" "$CLAUDE_SETTINGS"
        log_info "Claude Code 已切换到 Kiro Proxy + $OPUS_MODEL ✓"
    else
        log_error "修改 Claude Settings 失败"
        rm -f "$tmp_settings"
        exit 1
    fi
}

switch_back() {
    log_step "切换回原始 Claude Code 配置..."

    if [ ! -f "$CLAUDE_SETTINGS" ]; then
        log_error "Claude Settings 文件不存在"
        exit 1
    fi

    local tmp_settings=$(mktemp)
    python3 -c "
import json
with open('$CLAUDE_SETTINGS', 'r') as f:
    data = json.load(f)

backup = data.pop('_kiro_proxy_backup', {})
if backup:
    if 'env' not in data:
        data['env'] = {}
    data['env']['ANTHROPIC_BASE_URL'] = backup.get('ANTHROPIC_BASE_URL', '')
    data['env']['ANTHROPIC_AUTH_TOKEN'] = backup.get('ANTHROPIC_AUTH_TOKEN', '')
    for key in ['ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL']:
        data['env'].pop(key, None)
    print('restored')
else:
    print('no_backup')
" 2>&1 | grep -q "restored"

    if [ $? -eq 0 ]; then
        python3 -c "
import json
with open('$CLAUDE_SETTINGS', 'r') as f:
    data = json.load(f)
backup = data.pop('_kiro_proxy_backup', {})
if 'env' not in data:
    data['env'] = {}
data['env']['ANTHROPIC_BASE_URL'] = backup.get('ANTHROPIC_BASE_URL', '')
data['env']['ANTHROPIC_AUTH_TOKEN'] = backup.get('ANTHROPIC_AUTH_TOKEN', '')
for key in ['ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL']:
    data['env'].pop(key, None)
with open('$tmp_settings', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
        mv "$tmp_settings" "$CLAUDE_SETTINGS"
        log_info "已切换回原始配置 ✓"
    else
        log_warn "未找到备份配置，请手动恢复"
        rm -f "$tmp_settings"
    fi

    stop_proxy
}

show_status() {
    echo ""
    echo "========================================="
    echo "  Kiro Proxy 状态"
    echo "========================================="

    if check_proxy_running; then
        local health=$(curl --noproxy '*' -s "$PROXY_URL/health" 2>/dev/null)
        echo -e "  代理服务:    ${GREEN}运行中${NC}"
        echo "  Provider:    $(echo "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("provider","N/A"))' 2>/dev/null)"
        echo "  Token过期:   $(echo "$health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expiresAt","N/A"))' 2>/dev/null)"
    else
        echo -e "  代理服务:    ${RED}未运行${NC}"
    fi

    if [ -f "$CLAUDE_SETTINGS" ]; then
        local current_url=$(python3 -c "import json; data=json.load(open('$CLAUDE_SETTINGS')); print(data.get('env',{}).get('ANTHROPIC_BASE_URL','N/A'))" 2>/dev/null)
        local current_model=$(python3 -c "import json; data=json.load(open('$CLAUDE_SETTINGS')); print(data.get('env',{}).get('ANTHROPIC_MODEL','N/A'))" 2>/dev/null)
        echo "  API地址:     $current_url"
        echo "  当前模型:    $current_model"

        if [ "$current_url" = "$PROXY_URL" ]; then
            echo -e "  模式:        ${CYAN}Kiro Proxy${NC}"
        else
            echo -e "  模式:        ${YELLOW}原始配置${NC}"
        fi
    fi

    echo "========================================="
    echo ""
}

show_help() {
    echo ""
    echo "用法: $0 <命令>"
    echo ""
    echo "命令:"
    echo "  start    启动 Kiro Proxy + 切换 Claude Code 到 Opus"
    echo "  stop     停止 Kiro Proxy + 切换回原始配置"
    echo "  restart  重启 Kiro Proxy"
    echo "  status   查看当前状态"
    echo ""
    echo "示例:"
    echo "  $0 start     # 一键启动代理并切换到 Opus"
    echo "  $0 stop      # 停止代理并恢复原始配置"
    echo "  $0 status    # 查看代理和 Claude Code 状态"
    echo ""
}

case "${1:-}" in
    start)
        echo ""
        log_info "🚀 启动 Kiro Proxy + Opus 模式"
        echo ""
        check_kiro_auth
        create_dirs
        if ! check_proxy_running; then
            start_proxy
        fi
        switch_to_kiro
        echo ""
        log_info "✅ 完成！现在可以运行: claude --model opus"
        echo ""
        ;;
    stop)
        echo ""
        log_info "🛑 停止 Kiro Proxy + 恢复原始配置"
        echo ""
        switch_back
        echo ""
        log_info "✅ 已恢复原始配置"
        echo ""
        ;;
    restart)
        echo ""
        log_info "🔄 重启 Kiro Proxy"
        echo ""
        stop_proxy
        create_dirs
        start_proxy
        echo ""
        ;;
    status)
        show_status
        ;;
    *)
        show_help
        exit 1
        ;;
esac
