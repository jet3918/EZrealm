#!/bin/sh
# Alpine Realm Manager (OpenRC + apk)
# Author: ChatGPT
# Config: /root/realm/config.toml
# Service: /etc/init.d/realm

CURRENT_VERSION="alpine-1.0.0"

REALM_DIR="/root/realm"
BIN_PATH="$REALM_DIR/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
LOG_FILE="/var/log/realm_manager.log"

# OpenRC
OPENRC_SERVICE="/etc/init.d/realm"
RUN_DIR="/run"
PID_FILE="$RUN_DIR/realm.pid"

# URLs
REALM_RELEASES_URL="https://github.com/zhboner/realm/releases"
FALLBACK_VERSION="2.7.0"

# Colors (POSIX)
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[0;34m')"
NC="$(printf '\033[0m')"

log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

die() {
  echo "${RED}✖ $1${NC}"
  log "ERROR: $1"
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "必须使用 root 运行"
}

install_deps() {
  echo "${BLUE}▶ 检查依赖...${NC}"
  # Alpine packages: curl wget tar ca-certificates
  for cmd in curl wget tar; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
  done

  if [ -n "$MISSING" ]; then
    echo "${YELLOW}▶ 缺少依赖：$MISSING，开始安装...${NC}"
    apk update >/dev/null 2>&1 || true
    apk add --no-cache curl wget tar ca-certificates >/dev/null 2>&1 || die "依赖安装失败（apk add）"
  fi

  # ensure certs
  update-ca-certificates >/dev/null 2>&1 || true
}

init_dirs() {
  mkdir -p "$REALM_DIR" || die "无法创建目录 $REALM_DIR"
  mkdir -p "$RUN_DIR" >/dev/null 2>&1 || true
  touch "$LOG_FILE" || die "无法创建日志 $LOG_FILE"
}

# Fetch latest version from GitHub releases html (best-effort)
get_latest_version() {
  v="$(curl -fsSL "$REALM_RELEASES_URL" 2>/dev/null | \
      sed -n 's/.*\/zhboner\/realm\/releases\/tag\/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | \
      head -n 1)"
  if echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$v"
    return 0
  fi
  echo ""
  return 1
}

download_realm() {
  latest="$(get_latest_version)"
  if [ -z "$latest" ]; then
    latest="$FALLBACK_VERSION"
    echo "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v$latest${NC}"
    log "WARN: latest version fetch failed, fallback=$latest"
  else
    echo "${GREEN}✓ 检测到最新版本 v$latest${NC}"
  fi

  # Alpine usually musl. Prefer musl build if exists, else gnu.
  url_musl="https://github.com/zhboner/realm/releases/download/v${latest}/realm-x86_64-unknown-linux-musl.tar.gz"
  url_gnu="https://github.com/zhboner/realm/releases/download/v${latest}/realm-x86_64-unknown-linux-gnu.tar.gz"

  echo "${BLUE}▶ 下载 Realm v$latest...${NC}"
  cd "$REALM_DIR" || die "无法进入目录 $REALM_DIR"

  # try musl first
  if wget -qO realm.tar.gz "$url_musl" >/dev/null 2>&1; then
    dl_url="$url_musl"
  else
    # try gnu
    if wget -qO realm.tar.gz "$url_gnu" >/dev/null 2>&1; then
      dl_url="$url_gnu"
    else
      rm -f realm.tar.gz >/dev/null 2>&1 || true
      die "下载失败：请检查网络/GitHub 访问。尝试地址：$url_musl 或 $url_gnu"
    fi
  fi

  log "Downloaded realm from: $dl_url"

  tar -xzf realm.tar.gz || die "解压失败：realm.tar.gz"
  rm -f realm.tar.gz

  [ -f "$BIN_PATH" ] || die "解压后未找到 realm 可执行文件"
  chmod +x "$BIN_PATH" || die "chmod 失败"
  echo "${GREEN}✔ Realm 下载/更新完成${NC}"
  log "Realm installed/updated (version=$latest)"
}

init_config_if_missing() {
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
[network]
no_tcp = false
use_udp = true
# ipv6_only = false
EOF
    echo "${GREEN}✔ 已初始化配置文件：$CONFIG_FILE${NC}"
    log "Config initialized: $CONFIG_FILE"
  fi
}

create_openrc_service() {
  echo "${BLUE}▶ 创建 OpenRC 服务...${NC}"
  cat > "$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
name="realm"
description="Realm Proxy Service"

command="$BIN_PATH"
command_args="-c $CONFIG_FILE"
command_background="yes"
pidfile="$PID_FILE"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
  need net
}

start_pre() {
  checkpath --directory --mode 0755 $RUN_DIR
}

EOF

  chmod +x "$OPENRC_SERVICE" || die "无法设置 $OPENRC_SERVICE 可执行"
  rc-update add realm default >/dev/null 2>&1 || true
  echo "${GREEN}✔ OpenRC 服务已创建并加入开机自启（default runlevel）${NC}"
  log "OpenRC service created: $OPENRC_SERVICE"
}

service_status() {
  if rc-service realm status >/dev/null 2>&1; then
    echo "${GREEN}● 运行中${NC}"
  else
    echo "${RED}● 未运行${NC}"
  fi
}

service_start() {
  rc-service realm start || die "启动失败（检查 $LOG_FILE 与 $CONFIG_FILE）"
  rc-update add realm default >/dev/null 2>&1 || true
  echo "${GREEN}✔ 已启动，并设置开机自启${NC}"
  log "Service started"
}

service_stop() {
  rc-service realm stop >/dev/null 2>&1 || true
  echo "${YELLOW}⚠ 已停止${NC}"
  log "Service stopped"
}

service_restart() {
  rc-service realm restart || die "重启失败（检查 $LOG_FILE 与 $CONFIG_FILE）"
  echo "${GREEN}✔ 已重启${NC}"
  log "Service restarted"
}

# endpoints helpers
list_rules() {
  echo "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
  echo "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
  printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "本地 listen" "目标 remote" "备注"
  echo "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"

  [ -f "$CONFIG_FILE" ] || { echo "未发现配置文件：$CONFIG_FILE"; return; }

  # We assume each endpoint block looks like:
  # [[endpoints]]
  # # 备注: xxx
  # listen = "..."
  # remote = "..."
  # We'll parse by scanning for [[endpoints]]
  awk '
    BEGIN{idx=0; remark=""; listen=""; remote=""; in=0}
    /^\[\[endpoints\]\]/{ idx++; remark=""; listen=""; remote=""; in=1; next }
    in==1 && /^# *备注:/{ sub(/^# *备注:[ ]*/,""); remark=$0; next }
    in==1 && /^listen *=/{ gsub(/.*"|"$/, "", $0); listen=$0; next }
    in==1 && /^remote *=/{ gsub(/.*"|"$/, "", $0); remote=$0;
        printf " %-4d| %-30s| %-40s| %-20s\n", idx, listen, remote, remark;
        print "---------------------------------------------------------------------------------------------------------";
        next
    }
  ' "$CONFIG_FILE"
}

add_rule() {
  echo "${BLUE}▶ 添加新规则（输入 q 退出）${NC}"
  while :; do
    printf "本地监听端口: "
    read local_port || return
    [ "$local_port" = "q" ] && break

    echo "$local_port" | grep -Eq '^[0-9]+$' || { echo "${RED}✖ 端口必须为数字${NC}"; continue; }

    printf "目标服务器IP/域名: "
    read remote_ip || return
    [ -z "$remote_ip" ] && { echo "${RED}✖ 目标不能为空${NC}"; continue; }

    printf "目标端口: "
    read remote_port || return
    echo "$remote_port" | grep -Eq '^[0-9]+$' || { echo "${RED}✖ 端口必须为数字${NC}"; continue; }

    printf "规则备注: "
    read remark || return

    echo ""
    echo "${YELLOW}请选择监听模式：${NC}"
    echo "1) 双栈监听 [::]:$local_port (默认)"
    echo "2) 仅IPv4监听 0.0.0.0:$local_port"
    echo "3) 自定义监听地址"
    printf "请输入选项 [1-3] (默认1): "
    read ip_choice || ip_choice="1"
    [ -z "$ip_choice" ] && ip_choice="1"

    case "$ip_choice" in
      1) listen_addr="[::]:$local_port" ;;
      2) listen_addr="0.0.0.0:$local_port" ;;
      3)
        while :; do
          printf "请输入完整监听地址(如 0.0.0.0:80 或 [::]:443): "
          read listen_addr || return
          echo "$listen_addr" | grep -Eq '^(\[.*\]|[0-9a-fA-F\.:]+):[0-9]+$' && break
          echo "${RED}✖ 格式错误${NC}"
        done
        ;;
      *) listen_addr="[::]:$local_port" ;;
    esac

    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_ip:$remote_port"
EOF

    log "Rule added: $listen_addr -> $remote_ip:$remote_port remark=$remark"
    echo "${GREEN}✔ 添加成功：$listen_addr → $remote_ip:$remote_port${NC}"

    service_restart >/dev/null 2>&1 || {
      echo "${YELLOW}⚠ 规则已写入，但重启失败。请检查配置：$CONFIG_FILE 和日志：$LOG_FILE${NC}"
    }

    printf "继续添加？(y/n): "
    read cont || cont="n"
    [ "$cont" = "y" ] || break
  done
}

delete_rule() {
  [ -f "$CONFIG_FILE" ] || { echo "未发现配置文件：$CONFIG_FILE"; return; }

  # Build a list of start line numbers of each [[endpoints]] block
  starts="$(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" | cut -d: -f1)"
  [ -n "$starts" ] || { echo "没有发现任何转发规则。"; return; }

  list_rules
  echo "请输入要删除的转发规则序号，直接回车返回主菜单。"
  printf "选择: "
  read choice || return
  [ -z "$choice" ] && { echo "返回主菜单。"; return; }
  echo "$choice" | grep -Eq '^[0-9]+$' || { echo "无效输入。"; return; }

  # Convert starts to positional list
  # We need start line of chosen block and start line of next block - 1 as end
  i=1
  chosen_start=""
  next_start=""
  prev=""
  for s in $starts; do
    if [ "$i" -eq "$choice" ]; then
      chosen_start="$s"
    elif [ -n "$chosen_start" ] && [ -z "$next_start" ]; then
      next_start="$s"
      break
    fi
    i=$((i+1))
    prev="$s"
  done

  [ -n "$chosen_start" ] || { echo "选择超出范围。"; return; }

  if [ -n "$next_start" ]; then
    end_line=$((next_start - 1))
  else
    end_line="$(wc -l < "$CONFIG_FILE" | tr -d ' ')"
  fi

  # Delete range using awk (more portable than sed -i differences)
  tmp="$CONFIG_FILE.tmp.$$"
  awk -v s="$chosen_start" -v e="$end_line" 'NR<s || NR>e {print}' "$CONFIG_FILE" > "$tmp" || {
    rm -f "$tmp"
    die "删除失败（写临时文件失败）"
  }
  mv "$tmp" "$CONFIG_FILE" || die "删除失败（覆盖配置失败）"

  # Remove excessive empty lines (keep single blank lines)
  tmp2="$CONFIG_FILE.tmp2.$$"
  awk '{
    if ($0 ~ /^[[:space:]]*$/) {
      if (blank==0) { print ""; blank=1 }
    } else {
      print; blank=0
    }
  }' "$CONFIG_FILE" > "$tmp2" && mv "$tmp2" "$CONFIG_FILE"

  echo "${GREEN}✔ 已删除规则 #$choice${NC}"
  log "Rule deleted: index=$choice lines=$chosen_start-$end_line"

  service_restart >/dev/null 2>&1 || {
    echo "${YELLOW}⚠ 删除完成，但重启失败。请检查配置：$CONFIG_FILE 和日志：$LOG_FILE${NC}"
  }
}

view_logs() {
  echo "${BLUE}最近日志：${NC}"
  tail -n 50 "$LOG_FILE" 2>/dev/null || echo "暂无日志：$LOG_FILE"
}

install_or_update() {
  need_root
  install_deps
  init_dirs
  download_realm
  init_config_if_missing
  create_openrc_service
  echo "${GREEN}✔ 安装/更新完成${NC}"
}

uninstall_all() {
  echo "${YELLOW}▶ 正在卸载...${NC}"
  rc-service realm stop >/dev/null 2>&1 || true
  rc-update del realm default >/dev/null 2>&1 || true
  rm -f "$OPENRC_SERVICE" >/dev/null 2>&1 || true
  rm -rf "$REALM_DIR" >/dev/null 2>&1 || true
  rm -f "$PID_FILE" >/dev/null 2>&1 || true
  echo "${GREEN}✔ 已卸载（保留日志：$LOG_FILE）${NC}"
  log "Uninstalled"
}

check_installed() {
  if [ -f "$BIN_PATH" ] && [ -f "$OPENRC_SERVICE" ]; then
    echo "${GREEN}已安装${NC}"
  else
    echo "${RED}未安装${NC}"
  fi
}

main_menu() {
  need_root
  init_dirs
  log "Script start v$CURRENT_VERSION"

  while :; do
    clear
    echo "${YELLOW}▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂﹍▂${NC}"
    echo ""
    echo "        ${BLUE}Realm Alpine 管理脚本 v$CURRENT_VERSION${NC}"
    echo "        OpenRC + apk | 配置：$CONFIG_FILE"
    echo ""
    echo "服务状态：$(service_status)"
    echo "安装状态：$(check_installed)"
    echo ""
    echo "${YELLOW}------------------${NC}"
    echo "1. 安装/更新 Realm"
    echo "2. 添加转发规则"
    echo "3. 查看转发规则"
    echo "4. 删除转发规则"
    echo "${YELLOW}------------------${NC}"
    echo "5. 启动服务"
    echo "6. 停止服务"
    echo "7. 重启服务"
    echo "8. 查看日志"
    echo "${YELLOW}------------------${NC}"
    echo "9. 完全卸载"
    echo "0. 退出"
    echo "${YELLOW}------------------${NC}"
    echo ""
    printf "请输入选项: "
    read choice || exit 0

    case "$choice" in
      1) install_or_update ;;
      2) add_rule ;;
      3) list_rules ;;
      4) delete_rule ;;
      5) service_start ;;
      6) service_stop ;;
      7) service_restart ;;
      8) view_logs ;;
      9)
        printf "确认完全卸载？(y/n): "
        read confirm || confirm="n"
        [ "$confirm" = "y" ] && uninstall_all
        ;;
      0) exit 0 ;;
      *) echo "${RED}无效选项${NC}" ;;
    esac

    echo ""
    printf "按回车继续..."
    read _ || true
  done
}

main_menu
