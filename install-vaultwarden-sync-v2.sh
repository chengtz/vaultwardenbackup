#!/bin/sh
# ============================================================
# Vaultwarden Primary -> Standby Sync Setup Wizard
# For serv00 / ct8 FreeBSD user environment
# ============================================================
#
# What this installer does:
#   1. Creates backup_to_standby.sh on the PRIMARY node.
#   2. Connects to the STANDBY node by SSH.
#   3. Creates restore_from_primary.sh on the STANDBY node.
#   4. Optionally runs one test sync immediately.
#   5. Optionally adds a cron job on the PRIMARY node.
#
# What it DOES NOT do:
#   - It does not deploy Vaultwarden itself.
#   - It does not sync .env.
#   - It does not create your SSH key automatically unless you choose to do it manually before running.
#   - It does not configure domains, proxy, SSL, or Cloudflare.
#
# Recommended usage:
#   Run this script ONLY on the PRIMARY Vaultwarden node.
#
# Important:
#   The sync direction is one-way:
#     PRIMARY -> STANDBY
#
#   Do not edit/add passwords on the standby node during normal use.
#   Any standby-side change can be overwritten by the next sync.
#
# ============================================================

set -eu

say() {
  printf "\n\033[1;32m%s\033[0m\n" "$*"
}

info() {
  printf "\033[1;36m%s\033[0m\n" "$*"
}

warn() {
  printf "\n\033[1;33m%s\033[0m\n" "$*"
}

err() {
  printf "\n\033[1;31m%s\033[0m\n" "$*" >&2
}

line() {
  printf "%s\n" "------------------------------------------------------------"
}

pause() {
  printf "\n按回车继续..."
  read _
}

confirm() {
  printf "\n%s [y/N]: " "$1"
  read ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read value
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf "%s" "$value"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "缺少命令：$1"
    exit 1
  fi
}

show_intro() {
  clear 2>/dev/null || true
  cat <<'EOF'
============================================================
 Vaultwarden 主节点 -> 备用节点 同步配置向导
 适用于 serv00 / ct8 FreeBSD 普通用户环境
============================================================

本脚本适合这种架构：

  主节点：日常使用，浏览器/插件连接这里
  备用节点：接收主节点数据，作为冷备/热备
  同步方向：主节点 -> 备用节点

同步内容：
  data/db.sqlite3
  data/attachments/
  data/sends/
  data/rsa_key.pem
  data/rsa_key.pub.pem

不会同步：
  .env
  logs/
  pkg-extract/
  域名/端口/ADMIN_TOKEN 配置

重要提醒：
  备用节点同步后会拥有完整密码库数据，包括账号、2FA、密码条目。
  所以备用节点安全等级必须和主节点一样高。

EOF

  confirm "确认你是在【主节点】运行此脚本，并且备用节点已部署好 Vaultwarden？" || exit 1
}

check_env() {
  say "步骤 1/8：检查主节点环境"

  need_cmd ssh
  need_cmd scp
  need_cmd tar
  need_cmd sqlite3
  need_cmd crontab
  need_cmd hostname
  need_cmd whoami

  echo "当前用户：$(whoami)"
  echo "当前主机：$(hostname)"
  echo "HOME：$HOME"

  line
  echo "如果上面显示的是备用节点，请立即退出，不要继续。"
  confirm "确认当前机器是主节点？" || exit 1
}

collect_inputs() {
  say "步骤 2/8：填写同步参数"

  DEFAULT_PRIMARY_APP_DIR="$HOME/apps/vaultwarden"

  cat <<EOF
主节点 Vaultwarden 目录通常是：
  $DEFAULT_PRIMARY_APP_DIR

这个目录下应该有：
  data/db.sqlite3
  start.sh
  stop.sh
  .env

EOF

  PRIMARY_APP_DIR="$(ask "主节点 Vaultwarden 目录" "$DEFAULT_PRIMARY_APP_DIR")"
  echo

  if [ ! -d "$PRIMARY_APP_DIR" ]; then
    err "主节点目录不存在：$PRIMARY_APP_DIR"
    exit 1
  fi

  if [ ! -f "$PRIMARY_APP_DIR/data/db.sqlite3" ]; then
    err "未找到主节点数据库：$PRIMARY_APP_DIR/data/db.sqlite3"
    exit 1
  fi

  cat <<'EOF'

现在填写备用节点 SSH 信息。

示例：
  SSH 用户名：standby_user
  SSH 主机：standby.example.com
  备用节点目录：/usr/home/standby_user/apps/vaultwarden

注意：
  这里不要填写主节点自己的信息。
EOF

  STANDBY_USER="$(ask "备用节点 SSH 用户名" "")"
  echo
  [ -n "$STANDBY_USER" ] || { err "备用节点 SSH 用户名不能为空"; exit 1; }

  STANDBY_HOST="$(ask "备用节点 SSH 主机/IP" "")"
  echo
  [ -n "$STANDBY_HOST" ] || { err "备用节点 SSH 主机不能为空"; exit 1; }

  STANDBY_APP_DIR="$(ask "备用节点 Vaultwarden 目录" "/usr/home/$STANDBY_USER/apps/vaultwarden")"
  echo
  [ -n "$STANDBY_APP_DIR" ] || { err "备用节点 Vaultwarden 目录不能为空"; exit 1; }

  cat <<'EOF'

现在填写 SSH 私钥路径。

如果你已经配置了主节点 -> 备用节点免密登录，可以填对应私钥。
如果没配置免密，也可以先留默认；脚本会提示你可能需要手动输入密码。

推荐私钥命名：
  ~/.ssh/vaultwarden_sync_key

EOF

  SSH_KEY_DEFAULT="$HOME/.ssh/vaultwarden_sync_key"
  SSH_KEY="$(ask "SSH 私钥路径" "$SSH_KEY_DEFAULT")"
  echo

  cat <<'EOF'

现在填写定时同步计划。

cron 示例：
  0 3 * * *       每天 03:00 同步
  0 3,15 * * *    每天 03:00 和 15:00 同步
  */30 * * * *    每 30 分钟同步一次，不建议密码库频繁折腾时使用

留空则不配置定时任务，只生成脚本。
EOF

  CRON_EXPR="$(ask "定时同步 cron 表达式，留空则不配置" "")"
  echo

  show_summary
}

show_summary() {
  say "请核对配置"

  cat <<EOF
主节点目录：
  $PRIMARY_APP_DIR

备用节点：
  $STANDBY_USER@$STANDBY_HOST

备用节点 Vaultwarden 目录：
  $STANDBY_APP_DIR

SSH 私钥：
  $SSH_KEY

定时任务：
  ${CRON_EXPR:-不配置}

将创建：
  主节点：$PRIMARY_APP_DIR/backup_to_standby.sh
  备用节点：$STANDBY_APP_DIR/restore_from_primary.sh
  主节点日志：$PRIMARY_APP_DIR/logs/sync-to-standby.log

EOF

  warn "同步方向是【主节点 -> 备用节点】，备用节点数据会被主节点覆盖。"
  confirm "确认以上信息正确？" || exit 1
}

test_ssh_connection() {
  say "步骤 3/8：测试 SSH 连接备用节点"

  SSH_OPT=""
  if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPT="-i $SSH_KEY"
    echo "使用 SSH key：$SSH_KEY"
  else
    warn "指定的 SSH key 不存在或未填写。接下来可能需要输入备用节点密码。"
  fi

  echo
  echo "测试命令："
  echo "  ssh $SSH_OPT $STANDBY_USER@$STANDBY_HOST 'hostname && whoami && pwd'"
  echo

  if ssh $SSH_OPT "$STANDBY_USER@$STANDBY_HOST" 'hostname && whoami && pwd'; then
    say "SSH 连接测试成功"
  else
    err "SSH 连接失败。请先确认账号、主机、密码或 SSH key。"
    exit 1
  fi

  confirm "确认上面返回的是备用节点信息？" || exit 1
}

check_remote_vaultwarden() {
  say "步骤 4/8：检查备用节点 Vaultwarden 目录"

  SSH_OPT=""
  if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPT="-i $SSH_KEY"
  fi

  REMOTE_CHECK="
    set -eu
    echo '检查目录：$STANDBY_APP_DIR'
    test -d '$STANDBY_APP_DIR'
    test -d '$STANDBY_APP_DIR/data'
    test -x '$STANDBY_APP_DIR/start.sh' || echo '警告：start.sh 不存在或不可执行'
    test -x '$STANDBY_APP_DIR/stop.sh' || echo '警告：stop.sh 不存在或不可执行'
    ls -ld '$STANDBY_APP_DIR' '$STANDBY_APP_DIR/data'
  "

  if ssh $SSH_OPT "$STANDBY_USER@$STANDBY_HOST" "$REMOTE_CHECK"; then
    say "备用节点目录检查完成"
  else
    err "备用节点 Vaultwarden 目录检查失败。请确认备用节点已部署 Vaultwarden。"
    exit 1
  fi
}

prepare_remote_restore_script() {
  say "步骤 5/8：在备用节点创建恢复脚本"

  SSH_OPT=""
  SCP_OPT=""
  if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPT="-i $SSH_KEY"
    SCP_OPT="-i $SSH_KEY"
  fi

  tmp_restore="/tmp/restore_from_primary.$$"

  cat > "$tmp_restore" <<'REMOTE_RESTORE'
#!/bin/sh
set -eu

APP_DIR="$HOME/apps/vaultwarden"
INCOMING_DIR="$APP_DIR/incoming"
RESTORE_TMP="$APP_DIR/restore-tmp"
DATA_DIR="$APP_DIR/data"
BACKUP_KEEP_DIR="$APP_DIR/local-before-restore"

cd "$APP_DIR"

LATEST_BACKUP="$(ls -t "$INCOMING_DIR"/vaultwarden-data-*.tar.gz 2>/dev/null | head -n 1 || true)"

if [ -z "$LATEST_BACKUP" ]; then
  echo "No backup package found in $INCOMING_DIR"
  exit 1
fi

echo "Using backup: $LATEST_BACKUP"

echo "Stopping Vaultwarden on standby..."
if [ -x ./stop.sh ]; then
  ./stop.sh || true
else
  pkill -f "$APP_DIR/pkg-extract/usr/local/bin/vaultwarden" 2>/dev/null || true
fi

echo "Backing up current standby data before restore..."
mkdir -p "$BACKUP_KEEP_DIR"
if [ -d "$DATA_DIR" ]; then
  tar -czf "$BACKUP_KEEP_DIR/standby-before-restore-$(date +%F-%H%M%S).tar.gz" data
fi

echo "Extracting backup..."
rm -rf "$RESTORE_TMP"
mkdir -p "$RESTORE_TMP"
tar -xzf "$LATEST_BACKUP" -C "$RESTORE_TMP"

echo "Replacing data directory..."
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

if [ -d "$RESTORE_TMP/data" ]; then
  cp -Rp "$RESTORE_TMP/data/." "$DATA_DIR/"
else
  echo "Backup package does not contain data directory"
  exit 1
fi

rm -rf "$RESTORE_TMP"

echo "Starting Vaultwarden on standby..."
if [ -x ./start.sh ]; then
  ./start.sh
else
  echo "start.sh not found or not executable. Please start Vaultwarden manually."
fi

echo "Restore completed."
REMOTE_RESTORE

  ssh $SSH_OPT "$STANDBY_USER@$STANDBY_HOST" "mkdir -p '$STANDBY_APP_DIR/incoming' '$STANDBY_APP_DIR/local-before-restore'"
  scp $SCP_OPT "$tmp_restore" "$STANDBY_USER@$STANDBY_HOST:$STANDBY_APP_DIR/restore_from_primary.sh"

  # Replace APP_DIR line inside remote script with actual remote path.
  ssh $SSH_OPT "$STANDBY_USER@$STANDBY_HOST" "
    sed -i '' 's|APP_DIR=\"\$HOME/apps/vaultwarden\"|APP_DIR=\"$STANDBY_APP_DIR\"|' '$STANDBY_APP_DIR/restore_from_primary.sh'
    chmod +x '$STANDBY_APP_DIR/restore_from_primary.sh'
    ls -l '$STANDBY_APP_DIR/restore_from_primary.sh'
  "

  rm -f "$tmp_restore"
}

write_primary_backup_script() {
  say "步骤 6/8：在主节点创建备份推送脚本"

  SCRIPT_PATH="$PRIMARY_APP_DIR/backup_to_standby.sh"

  mkdir -p "$PRIMARY_APP_DIR/backups" "$PRIMARY_APP_DIR/logs"

  cat > "$SCRIPT_PATH" <<EOF
#!/bin/sh
set -eu

APP_DIR="$PRIMARY_APP_DIR"
DATA_DIR="\$APP_DIR/data"
BACKUP_DIR="\$APP_DIR/backups"
TMP_DIR="\$APP_DIR/backup-tmp"

REMOTE_USER="$STANDBY_USER"
REMOTE_HOST="$STANDBY_HOST"
REMOTE_APP_DIR="$STANDBY_APP_DIR"
SSH_KEY="$SSH_KEY"

DATE_TAG="\$(date +%F-%H%M%S)"
BACKUP_NAME="vaultwarden-data-\$DATE_TAG.tar.gz"
SQLITE_BACKUP="\$TMP_DIR/data/db.sqlite3"

cd "\$APP_DIR"

mkdir -p "\$BACKUP_DIR" "\$TMP_DIR/data"

echo "Creating safe SQLite backup..."
if [ -f "\$DATA_DIR/db.sqlite3" ]; then
  sqlite3 "\$DATA_DIR/db.sqlite3" ".backup '\$SQLITE_BACKUP'"
else
  echo "db.sqlite3 not found: \$DATA_DIR/db.sqlite3"
  exit 1
fi

echo "Copying attachments/sends/rsa files..."
if [ -d "\$DATA_DIR/attachments" ]; then
  cp -Rp "\$DATA_DIR/attachments" "\$TMP_DIR/data/"
fi

if [ -d "\$DATA_DIR/sends" ]; then
  cp -Rp "\$DATA_DIR/sends" "\$TMP_DIR/data/"
fi

if [ -f "\$DATA_DIR/rsa_key.pem" ]; then
  cp -p "\$DATA_DIR/rsa_key.pem" "\$TMP_DIR/data/"
fi

if [ -f "\$DATA_DIR/rsa_key.pub.pem" ]; then
  cp -p "\$DATA_DIR/rsa_key.pub.pem" "\$TMP_DIR/data/"
fi

echo "Packing backup..."
tar -czf "\$BACKUP_DIR/\$BACKUP_NAME" -C "\$TMP_DIR" data

echo "Cleaning temp files..."
rm -rf "\$TMP_DIR"

SSH_OPT=""
if [ -n "\$SSH_KEY" ] && [ -f "\$SSH_KEY" ]; then
  SSH_OPT="-i \$SSH_KEY"
fi

echo "Uploading backup to standby..."
ssh \$SSH_OPT "\$REMOTE_USER@\$REMOTE_HOST" "mkdir -p '\$REMOTE_APP_DIR/incoming'"
scp \$SSH_OPT "\$BACKUP_DIR/\$BACKUP_NAME" "\$REMOTE_USER@\$REMOTE_HOST:\$REMOTE_APP_DIR/incoming/"

echo "Triggering restore on standby..."
ssh \$SSH_OPT "\$REMOTE_USER@\$REMOTE_HOST" "cd '\$REMOTE_APP_DIR' && ./restore_from_primary.sh"

echo "Removing old local backups, keeping latest 7..."
ls -t "\$BACKUP_DIR"/vaultwarden-data-*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

echo "Sync completed: \$BACKUP_NAME"
EOF

  chmod +x "$SCRIPT_PATH"
  echo "已创建：$SCRIPT_PATH"
}

test_sync_once() {
  say "步骤 7/8：可选，同步测试"

  cat <<EOF
现在可以立即执行一次同步测试。

测试会做这些事：
  1. 主节点生成 SQLite 安全备份
  2. 主节点打包 data 数据
  3. 上传到备用节点
  4. 备用节点停止 Vaultwarden
  5. 备用节点备份现有 data
  6. 备用节点覆盖为主节点数据
  7. 备用节点启动 Vaultwarden

注意：
  备用节点当前 data 会被覆盖，但会先保存到：
    local-before-restore/

EOF

  if confirm "是否立即执行一次同步测试？"; then
    "$PRIMARY_APP_DIR/backup_to_standby.sh"
  else
    warn "已跳过测试。建议稍后手动执行：$PRIMARY_APP_DIR/backup_to_standby.sh"
  fi
}

install_cron() {
  say "步骤 8/8：配置定时任务"

  if [ -z "$CRON_EXPR" ]; then
    warn "未配置 crontab。你可以之后手动运行："
    echo "  $PRIMARY_APP_DIR/backup_to_standby.sh"
    return 0
  fi

  CRON_LINE="$CRON_EXPR $PRIMARY_APP_DIR/backup_to_standby.sh >> $PRIMARY_APP_DIR/logs/sync-to-standby.log 2>&1"

  echo "将写入以下 crontab："
  echo "$CRON_LINE"

  confirm "确认写入 crontab？" || {
    warn "已跳过 crontab 配置。"
    return 0
  }

  tmp_cron="/tmp/vaultwarden-cron.$$"
  crontab -l 2>/dev/null | grep -v "backup_to_standby.sh" > "$tmp_cron" || true
  echo "$CRON_LINE" >> "$tmp_cron"
  crontab "$tmp_cron"
  rm -f "$tmp_cron"

  echo
  echo "当前 crontab："
  crontab -l
}

show_finish() {
  say "完成"

  cat <<EOF
已完成同步配置。

主节点脚本：
  $PRIMARY_APP_DIR/backup_to_standby.sh

备用节点脚本：
  $STANDBY_APP_DIR/restore_from_primary.sh

手动同步：
  cd $PRIMARY_APP_DIR
  ./backup_to_standby.sh

查看定时日志：
  tail -n 100 $PRIMARY_APP_DIR/logs/sync-to-standby.log

检查备用节点：
  ssh $STANDBY_USER@$STANDBY_HOST
  cd $STANDBY_APP_DIR
  curl -I http://127.0.0.1:你的端口
  grep -E 'DOMAIN|SIGNUPS_ALLOWED|ROCKET_PORT' .env

安全提醒：
  1. 备用节点现在会拥有完整密码库数据。
  2. 不要在备用节点日常新增/修改密码。
  3. 不要同步 .env。
  4. 注册完成后，主备节点都应 SIGNUPS_ALLOWED=false。
  5. 若主节点故障期间在备用节点修改过数据，回切前要先判断哪边数据最新。

EOF
}

main() {
  show_intro
  check_env
  collect_inputs
  test_ssh_connection
  check_remote_vaultwarden
  prepare_remote_restore_script
  write_primary_backup_script
  test_sync_once
  install_cron
  show_finish
}

main "$@"
