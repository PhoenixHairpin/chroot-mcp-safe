#!/system/bin/sh
# Portable launcher: ensure bash regardless of caller (termux / tsu / su / MT 管理器)
if [ -z "${BASH_VERSION:-}" ]; then
  for _b in /data/data/com.termux/files/usr/bin/bash /system/bin/bash /system/xbin/bash /sbin/bash /bin/bash; do
    [ -x "$_b" ] && exec "$_b" "$0" "$@"
  done
  echo "ERROR: 找不到 bash。请安装 termux (pkg install bash) 或在 /system/bin/bash 放置 bash 二进制。" >&2
  exit 1
fi

set -u
set -o pipefail

# ==============================================
# 运行时环境识别（兼容 termux/tsu/非termux的MT管理器/裸su）
# ==============================================
TERMUX_PREFIX="/data/data/com.termux/files/usr"
HAVE_TERMUX=0
[ -d "$TERMUX_PREFIX" ] && HAVE_TERMUX=1
export PATH="$TERMUX_PREFIX/bin:$TERMUX_PREFIX/sbin:/system/bin:/system/xbin:/vendor/bin:/sbin:/bin:$PATH"

_find_bin() {
  local name="$1" c
  for c in \
    "$TERMUX_PREFIX/bin/$name" \
    "$TERMUX_PREFIX/sbin/$name" \
    "/system/bin/$name" \
    "/system/xbin/$name" \
    "/vendor/bin/$name" \
    "/sbin/$name" \
    "/bin/$name"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  command -v "$name" 2>/dev/null || true
}

# 解析关键二进制；找不到时退化为裸名让 PATH 解析（不致整体崩盘）
CHROOT_BIN="$(_find_bin chroot)";   CHROOT_BIN="${CHROOT_BIN:-/system/bin/chroot}"
LOSETUP_BIN="$(_find_bin losetup)"; LOSETUP_BIN="${LOSETUP_BIN:-losetup}"
NSENTER_BIN="$(_find_bin nsenter)"; NSENTER_BIN="${NSENTER_BIN:-nsenter}"
UNSHARE_BIN="$(_find_bin unshare)"; UNSHARE_BIN="${UNSHARE_BIN:-unshare}"
BASH_BIN="$(_find_bin bash)";       BASH_BIN="${BASH_BIN:-/system/bin/sh}"
SH_BIN="$(_find_bin sh)";           SH_BIN="${SH_BIN:-/system/bin/sh}"

# ==============================================
# 状态目录: 优先 /data/local/tmp（始终可用），自动迁移老的 termux/tmp 状态文件
# ==============================================
STATE_DIR="/data/local/tmp/chroot-mcp"
LEGACY_STATE_DIR="$TERMUX_PREFIX/tmp"
mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
if [ -d "$LEGACY_STATE_DIR" ]; then
  for _legacy in "$LEGACY_STATE_DIR"/chroot-mcp-daemon-*.info; do
    [ -f "$_legacy" ] || continue
    _target="$STATE_DIR/$(basename "$_legacy")"
    [ -f "$_target" ] || cp -p "$_legacy" "$_target" 2>/dev/null
  done
fi

# 每发行版持久化配置（端口等），与 STATE_DIR 分离便于人工编辑
PORT_CONFIG_DIR="/data/local/chroot-config"
mkdir -p "$PORT_CONFIG_DIR" 2>/dev/null || true
chmod 755 "$PORT_CONFIG_DIR" 2>/dev/null || true

# ==============================================

# ==============================================
# chroot-mcp-safe.sh - Android chroot 容器管理脚本
# ==============================================
# 版本: v2.1.1 (Safe Edition)
# 日期: 2026-04-11
# 状态: ✅ 生产可用 (已验证稳定运行)
# ==============================================
# 本版本新增功能 (相比 v2.0):
#   1. ✅ Android 二进制支持: apex 使用 rbind 递归挂载
#      - 解决: /system/bin/toybox, getprop, pm, am 等可正常运行
#      - 解决: linkerconfig 挂载消除 linker 警告
#   2. ✅ Binder IPC 支持: /dev/binderfs 挂载
#      - 解决: pm, am, settings 等需要 Binder 的命令可运行
#   3. ✅ do_mount 函数新增 rbind 类型支持
#   4. ✅ cleanup 函数新增 linkerconfig/binderfs 卸载
#   5. ⚠️ Loop 设备清理: cleanup 函数确保正确释放
#      - 说明: Android losetup 不支持 --autoclear，依赖 namespace 隔离
#      - 解决: /system/bin/toybox, getprop, pm, am 等可正常运行
#      - 解决: linkerconfig 挂载消除 linker 警告
#   2. ✅ Binder IPC 支持: /dev/binderfs 挂载
#      - 解决: pm, am, settings 等需要 Binder 的命令可运行
#   3. ✅ do_mount 函数新增 rbind 类型支持
#   4. ✅ cleanup 函数新增 linkerconfig/binderfs 卸载
# ==============================================
# 发布版整理说明
# - 仅做注释/结构整理，不改变既有逻辑、行为与输出路径
# - 以当前稳定版为基线，便于后续审阅、比对与长期维护
# ==============================================
# ==============================================
# 配置区（保持能力不阉割，仅做防误触加固）
# ==============================================
# 默认rootfs路径（优先非proot目录；兼容历史proot目录）
if [ -z "${TARGET:-}" ]; then
  if [ -d "/data/local/chroot/ubuntu" ]; then
    TARGET="/data/local/chroot/ubuntu"
  elif [ -d "/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu" ]; then
    TARGET="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
  else
    TARGET="/data/local/chroot/ubuntu"
  fi
fi
DISTRO_NAME=""
PRINT_INSTALL_GUIDE=0
INTERACTIVE_MODE=0
LOG_FILE="${LOG_FILE:-$STATE_DIR/chroot-mcp-$(date +%s).log}"

HOST_ROOT_OPT="ro"
SYS_MOUNT_OPT="ro,nosuid"
DATA_MOUNT_OPT="rw"
SDCARD_MOUNT_OPT="rw"

CHROOT_MARKER="/.chroot_marker"
MOUNT_STACK=()
ORIGINAL_SELINUX_STATE=""
PERMISSIVE=0
RO_DATA=0
SAFE_MODE=0
IN_CLEANUP=0
CLEANUP_DONE=0
FALLBACK_PROOT=0
USE_PROOT_FALLBACK=0
DAEMON_MODE=0
SSHD_PRESENT=0
SSHD_RUNNING=0
ROOTFS_SSHD_PORT=""
ROOTFS_SSHD_PID=""
DAEMON_INFO_FILE=""
STATUS_MODE=0
STOP_MODE=0
MIGRATE_MODE=0
EMERGENCY_SYNC_MODE=0
REMOVE_MODE=0
SIZE_MODE=0
AUTO_MIGRATE=0
MIGRATE_IMAGE_MODE=0
AUTO_MIGRATE_IMAGE=0
RESIZE_IMAGE_MODE=0
IMAGE_MODE=0
IMAGE_FILE=""
IMAGE_MOUNTPOINT=""
IMAGE_LOOPDEV=""
IMAGE_SIZE_GB=""
ROOTFS_EXPLICIT=0
SSHD_PORT_EXPLICIT="${SSHD_PORT_EXPLICIT:-}"
MCP_ROOT_PASSWORD="${MCP_ROOT_PASSWORD:-123456}"
export MCP_ROOT_PASSWORD
ORIG_ARGC=$#
ORIG_ARGS=("$@")


# ==============================================
# 默认端口表（提前定义，wizard 也要用）
# ==============================================
get_rootfs_name() {
  if [ -n "${DISTRO_NAME:-}" ]; then
    echo "$DISTRO_NAME"
  elif [ -n "${TARGET:-}" ]; then
    basename "$TARGET"
  else
    echo ubuntu
  fi
}

get_default_distro_sshd_port() {
  case "$(get_rootfs_name)" in
    ubuntu) echo "8023" ;;
    debian) echo "8024" ;;
    arch)   echo "8025" ;;
    fedora) echo "8026" ;;
    alpine) echo "8027" ;;
    *)      echo "8023" ;;
  esac
}

# ==============================================
# 统一日志函数：前置流程也会调用 echo_warn/echo_info。
# echo_err 在 cleanup 已定义后会自动触发清理；更早阶段仅记录错误并退出。
log() {
  local content="[$(date '+%H:%M:%S')] $1"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo -e "$content" | tee -a "$LOG_FILE"
}

echo_info() { log "\e[32m[INFO]\e[0m $1"; }
echo_warn() { log "\e[33m[WARN]\e[0m $1"; }
echo_err()  {
  log "\e[31m[ERROR]\e[0m $1"
  if [ "${IN_CLEANUP:-0}" -eq 0 ] && type cleanup >/dev/null 2>&1; then
    cleanup
  fi
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --distro)
      [ $# -lt 2 ] && { echo "错误: --distro 需要一个参数(ubuntu/debian/arch/fedora/alpine)" >&2; exit 2; }
      DISTRO_NAME="$2"
      shift 2
      ;;
    --permissive)
      PERMISSIVE=1
      shift
      ;;
    --ro-data)
      RO_DATA=1
      shift
      ;;
    --safe)
      SAFE_MODE=1
      shift
      ;;
    --full-access)
      SAFE_MODE=0
      shift
      ;;
    --proot-fallback)
      FALLBACK_PROOT=1
      shift
      ;;
    --no-proot-fallback)
      FALLBACK_PROOT=0
      shift
      ;;
    --rootfs)
      [ $# -lt 2 ] && { echo "错误: --rootfs 需要一个目录参数" >&2; exit 2; }
      TARGET="$2"
      ROOTFS_EXPLICIT=1
      shift 2
      ;;
    --print-install)
      PRINT_INSTALL_GUIDE=1
      shift
      ;;
    --interactive|-i)
      INTERACTIVE_MODE=1
      shift
      ;;
    --daemon)
      DAEMON_MODE=1
      shift
      ;;
    --status)
      STATUS_MODE=1
      shift
      ;;
    --stop)
      STOP_MODE=1
      shift
      ;;
    --migrate)
      MIGRATE_MODE=1
      shift
      ;;
    --auto-migrate)
      AUTO_MIGRATE=1
      shift
      ;;
    --migrate-image)
      MIGRATE_IMAGE_MODE=1
      shift
      ;;
    --resize-image)
      RESIZE_IMAGE_MODE=1
      shift
      ;;
    --auto-migrate-image)
      AUTO_MIGRATE_IMAGE=1
      shift
      ;;
    --image-size-gb)
      [ $# -lt 2 ] && { echo "错误: --image-size-gb 需要一个正整数参数(单位GB)" >&2; exit 2; }
      IMAGE_SIZE_GB="$2"
      shift 2
      ;;
    --sshd-port)
      [ $# -lt 2 ] && { echo "错误: --sshd-port 需要一个端口号参数 1-65535" >&2; exit 2; }
      SSHD_PORT_EXPLICIT="$2"
      shift 2
      ;;
    --root-password)
      [ $# -lt 2 ] && { echo "错误: --root-password 需要一个密码参数" >&2; exit 2; }
      MCP_ROOT_PASSWORD="$2"
      export MCP_ROOT_PASSWORD
      shift 2
      ;;
    --emergency-sync)
      EMERGENCY_SYNC_MODE=1
      shift
      ;;
    --remove)
      REMOVE_MODE=1
      shift
      ;;
    --size|--sizes)
      SIZE_MODE=1
      shift
      ;;
    --help|-h)
      cat <<USAGE
用法: $0 [选项]
  --interactive,-i    交互式向导（推荐：选发行版/下载/启动）
  --daemon            后台模式：挂载 + 启动 chroot 内 sshd 后立即返回
  --status            查看后台模式状态
  --stop              停止后台模式并清理挂载
  --migrate           将当前 rootfs 迁移到 /data/local/chroot/<distro>
  --auto-migrate      启动前若 rootfs 在 termux 沙盒内自动迁移
  --migrate-image     将当前 rootfs 迁移为 ext4 镜像
  --resize-image      安全扩容现有 ext4 镜像（fsck + resize2fs）
  --auto-migrate-image  启动前若 rootfs 在 /data 子树内则自动迁移为镜像
  --image-size-gb <GB>  镜像目标大小（默认 20GB，不足自动提升）
  --sshd-port <PORT>  自定义 sshd 端口（被占用时自动重选空闲端口）
  --root-password <P> 自定义 root 密码（默认 123456）
  --emergency-sync    在所有运行中的容器与宿主全局 sync，掉电前急救
  --remove            删除已下载的容器（rootfs/镜像，便于反复测试）
  --size              显示所有容器的占用空间（rootfs/镜像/总和）
  --safe              /data 与 /storage 只读
  --full-access       /data 与 /storage 可写（默认）
  --permissive        临时 setenforce 0
  --ro-data           /data 只读
  --distro <名称>     ubuntu/debian/arch/fedora/alpine
  --rootfs <目录>     指定 rootfs 路径
  --proot-fallback    chroot 失败时回退 proot-distro
  --print-install     打印安装建议

环境变量:
  MCP_ROOT_PASSWORD   等价于 --root-password
  SSHD_PORT_EXPLICIT  等价于 --sshd-port

每个发行版的端口持久化在 $PORT_CONFIG_DIR/<distro>.port
USAGE
      exit 0
      ;;
    *)
      echo "警告: 忽略未知参数: $1" >&2
      shift
      ;;
  esac
done

# 无参数时的自动启动逻辑在 find_existing_rootfs 定义后处理


# ==============================================
# 后台 daemon 状态 / 生命周期管理
# ==============================================
get_daemon_info_file() {
  local name="${DISTRO_NAME:-}"
  [ -z "$name" ] && name="$(basename "$TARGET")"
  echo "$STATE_DIR/chroot-mcp-daemon-${name}.info"
}

read_daemon_info() {
  local file="$1"
  [ -f "$file" ] || return 1
  DAEMON_INFO_FILE="$file"
  while IFS='=' read -r k v; do
    case "$k" in
      TARGET) DAEMON_TARGET="$v" ;;
      PORT) DAEMON_PORT="$v" ;;
      SSHD_PID) DAEMON_SSHD_PID="$v" ;;
      LOG_FILE) DAEMON_LOG_FILE="$v" ;;
      STARTED_AT) DAEMON_STARTED_AT="$v" ;;
      IMAGE_FILE) DAEMON_IMAGE_FILE="$v" ;;
      IMAGE_LOOPDEV) DAEMON_IMAGE_LOOPDEV="$v" ;;
    esac
  done < "$file"
  return 0
}

pid_root_matches_target() {
  local pid="$1"
  local target="$2"
  local root=""

  [ -n "$pid" ] || return 1
  [ -n "$target" ] || return 1
  [ -d "/proc/$pid" ] || return 1

  root=$(readlink "/proc/$pid/root" 2>/dev/null || true)
  case "$root" in
    "$target"|"$target"/*)
      return 0
      ;;
  esac

  return 1
}

# 把字节数转成人类可读
_human_bytes() {
  local b="${1:-0}"
  awk -v n="$b" 'BEGIN{
    split("B K M G T", u);
    i=1;
    while(n>=1024 && i<5){ n/=1024; i++ }
    if (i==1) printf "%d%s", n, u[i];
    else      printf "%.1f%s", n, u[i];
  }'
}

# 计算单个发行版占用空间
# stdout: <bytes> <label> <path>
# label: image|dir|none
_distro_size_bytes() {
  local distro="$1"
  local image_file="/data/local/chroot-images/${distro}.img"
  local local_rootfs="/data/local/chroot/$distro"
  local pd_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$distro"
  case "$distro" in arch) pd_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/archlinux" ;; esac

  local bytes=0 label="none" path=""
  if [ -f "$image_file" ]; then
    bytes=$(stat -c '%s' "$image_file" 2>/dev/null || echo 0)
    label="image"
    path="$image_file"
  elif [ -d "$local_rootfs" ]; then
    bytes=$(du -sb --apparent-size "$local_rootfs" 2>/dev/null | awk '{print $1}')
    [ -z "$bytes" ] && bytes=$(du -sk "$local_rootfs" 2>/dev/null | awk '{print $1*1024}')
    label="dir"
    path="$local_rootfs"
  elif [ -d "$pd_rootfs" ]; then
    bytes=$(du -sb --apparent-size "$pd_rootfs" 2>/dev/null | awk '{print $1}')
    [ -z "$bytes" ] && bytes=$(du -sk "$pd_rootfs" 2>/dev/null | awk '{print $1*1024}')
    label="dir"
    path="$pd_rootfs"
  fi
  echo "$bytes $label $path"
}

# 计算镜像内已用/可用（仅当镜像存在）
# stdout: <used_bytes> <total_bytes>，失败时输出 "0 0"
_image_internal_usage() {
  local image_file="$1"
  local loopdev mp tmp_loop=0 base_loop
  [ -f "$image_file" ] || { echo "0 0"; return 0; }

  # losetup -j 可能返回 "/dev/loopN (lost)" 这类字段，只取第一段且去掉非路径文本
  loopdev=$("$LOSETUP_BIN" -j "$image_file" 2>/dev/null \
    | awk -F: 'NF>0{print $1}' \
    | awk '{print $1}' \
    | head -1)

  if [ -z "$loopdev" ]; then
    loopdev=$("$LOSETUP_BIN" -f --show "$image_file" 2>/dev/null) || { echo "0 0"; return 0; }
    tmp_loop=1
  fi

  # 已挂载的话直接通过 statvfs 取大小（用 stat -f，跨 toybox/coreutils 都支持）
  base_loop="${loopdev##*/}"   # loopN
  mp=$(awk -v want="$base_loop" '
    {
      sep=0
      for (i=1;i<=NF;i++) if ($i=="-") { sep=i; break }
      if (sep==0) next
      dev=$(sep+2)
      n=split(dev, parts, "/")
      if (parts[n]==want) { print $5; exit }
    }
  ' /proc/self/mountinfo 2>/dev/null)

  _stat_fs_used_total() {
    # 使用 stat -f；优先尝试 GNU 格式；不行再 toybox 兼容
    local out blksize blocks bavail
    # GNU coreutils: stat -f -c "%S %b %a" → fragsize blocks free-blocks
    out=$(stat -f -c '%S %b %a' "$1" 2>/dev/null) && [ -n "$out" ] && {
      read blksize blocks bavail <<<"$out"
      [ -n "$blksize" ] && [ -n "$blocks" ] && [ -n "$bavail" ] && {
        echo "$(( (blocks - bavail) * blksize )) $(( blocks * blksize ))"
        return 0
      }
    }
    # 退回 df -k（POSIX，几乎都支持）
    out=$(df -k "$1" 2>/dev/null | awk 'NR==2{print $3, $2}')
    [ -n "$out" ] && {
      read u t <<<"$out"
      [ -n "$u" ] && [ -n "$t" ] && {
        echo "$(( u * 1024 )) $(( t * 1024 ))"
        return 0
      }
    }
    echo "0 0"
  }

  if [ -n "$mp" ]; then
    local result
    result=$(_stat_fs_used_total "$mp")
    [ "$tmp_loop" -eq 1 ] && "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null
    echo "$result"
    return 0
  fi

  # 临时挂只读取 df
  local tmp_mp="$STATE_DIR/sizeprobe.$$"
  mkdir -p "$tmp_mp" 2>/dev/null
  if mount -t ext4 -o ro "$loopdev" "$tmp_mp" 2>/dev/null; then
    local result
    result=$(_stat_fs_used_total "$tmp_mp")
    umount "$tmp_mp" 2>/dev/null
    rmdir "$tmp_mp" 2>/dev/null
    [ "$tmp_loop" -eq 1 ] && "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null
    echo "$result"
    return 0
  fi
  rmdir "$tmp_mp" 2>/dev/null
  [ "$tmp_loop" -eq 1 ] && "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null
  echo "0 0"
}

# 显示所有容器占用大小（--size）
show_all_container_sizes() {
  local distros="ubuntu debian arch fedora alpine"
  local total_bytes=0 d info bytes label path used inner_total
  printf '\n  Container sizes\n'
  printf '  %s\n' '------------------------------------------------------------------'
  printf '  %-8s %-7s %12s %15s  %s\n' 'distro' 'kind' 'on_disk' 'in_image_used' 'path'
  printf '  %s\n' '------------------------------------------------------------------'
  for d in $distros; do
    info=$(_distro_size_bytes "$d")
    bytes=$(echo "$info" | awk '{print $1}')
    label=$(echo "$info" | awk '{print $2}')
    path=$(echo "$info" | cut -d' ' -f3-)

    if [ "$label" = "none" ]; then
      printf '  %-8s %-7s %12s %15s  %s\n' "$d" '-' '-' '-' '(not installed)'
      continue
    fi

    if [ "$label" = "image" ]; then
      read used inner_total < <(_image_internal_usage "$path")
      printf '  %-8s %-7s %12s %15s  %s\n' \
        "$d" "$label" "$(_human_bytes "$bytes")" \
        "$(_human_bytes "${used:-0}") / $(_human_bytes "${inner_total:-0}")" \
        "$path"
    else
      printf '  %-8s %-7s %12s %15s  %s\n' \
        "$d" "$label" "$(_human_bytes "$bytes")" '-' "$path"
    fi
    total_bytes=$(( total_bytes + bytes ))
  done
  printf '  %s\n' '------------------------------------------------------------------'
  printf '  %-8s %-7s %12s\n' 'TOTAL' '' "$(_human_bytes "$total_bytes")"
  printf '  %s\n\n' '------------------------------------------------------------------'
}

# 删除已下载的容器（rootfs 目录 / ext4 镜像 / proot-distro 副本 / 持久化端口）
# 用法: remove_distro_assets <distro> [--keep-port] [--force]
remove_distro_assets() {
  local distro="$1"; shift
  local keep_port=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-port) keep_port=1 ;;
      --force) force=1 ;;
    esac
    shift
  done
  [ -n "$distro" ] || { echo "[remove] 缺少发行版名" >&2; return 2; }

  # 拒绝删除正在运行中的容器
  local file="$STATE_DIR/chroot-mcp-daemon-${distro}.info"
  local rootfs_target
  rootfs_target="$(find_existing_rootfs "$distro")"
  if [ -f "$file" ]; then
    DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
    if read_daemon_info "$file" 2>/dev/null \
       && pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$rootfs_target}"; then
      echo "[remove] ${distro} 仍在运行（PID=${DAEMON_SSHD_PID}）。请先：$0 --stop --distro ${distro}" >&2
      return 1
    fi
  fi

  local image_file="/data/local/chroot-images/${distro}.img"
  local local_rootfs="/data/local/chroot/${distro}"
  local image_mp="/mnt/chroot-rootfs/${distro}"
  local pd_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/${distro}"
  case "$distro" in arch) pd_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/archlinux" ;; esac

  echo "[remove] 将删除以下内容："
  [ -f "$image_file" ]   && echo "  ext4 镜像:  $image_file ($(_human_bytes "$(stat -c %s "$image_file" 2>/dev/null || echo 0)"))"
  [ -d "$local_rootfs" ] && echo "  目录rootfs: $local_rootfs"
  [ -d "$pd_rootfs" ]    && echo "  proot-distro 副本: $pd_rootfs"
  [ -f "$file" ]         && echo "  daemon 状态: $file"
  if [ "$keep_port" -eq 0 ] && [ -f "$PORT_CONFIG_DIR/${distro}.port" ]; then
    echo "  端口配置:   $PORT_CONFIG_DIR/${distro}.port"
  fi

  if [ "$force" -ne 1 ]; then
    printf '确认删除? [y/N]: '
    local ans
    IFS= read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "[remove] 已取消"; return 0 ;; esac
  fi

  # 卸载/释放任何残留挂载
  if grep -Fq " $image_mp " /proc/self/mountinfo 2>/dev/null; then
    umount "$image_mp" 2>/dev/null || umount -l "$image_mp" 2>/dev/null || true
  fi
  local lp
  for lp in $("$LOSETUP_BIN" -j "$image_file" 2>/dev/null | awk -F: '{print $1}'); do
    [ -n "$lp" ] && "$LOSETUP_BIN" -d "$lp" 2>/dev/null || true
  done

  rm -f "$image_file" 2>/dev/null
  rm -rf "$local_rootfs" 2>/dev/null
  rm -rf "$pd_rootfs" 2>/dev/null
  rmdir "$image_mp" 2>/dev/null
  rm -f "$file" 2>/dev/null
  [ "$keep_port" -eq 0 ] && rm -f "$PORT_CONFIG_DIR/${distro}.port" 2>/dev/null

  echo "[remove] ${distro} 已删除"
  return 0
}

# 紧急同步：让所有运行容器内的 page cache + 宿主 cache 全部 fsync
emergency_sync_all() {
  echo "[emergency-sync] 触发宿主 + 全部运行容器的 sync..."
  local file pid target distros="ubuntu debian arch fedora alpine"
  for d in $distros; do
    file="$STATE_DIR/chroot-mcp-daemon-${d}.info"
    [ -f "$file" ] || continue
    DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
    if read_daemon_info "$file" 2>/dev/null \
       && pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-}"; then
      pid="${DAEMON_SSHD_PID}"
      target="${DAEMON_TARGET}"
      echo "  [container] ${d} pid=${pid} target=${target}"
      "$NSENTER_BIN" -t "$pid" -m -- "$SH_BIN" -c '
        sync 2>/dev/null
        sync 2>/dev/null
      ' 2>/dev/null || true
    fi
  done
  sync 2>/dev/null
  sync 2>/dev/null
  # 通知 kernel 把 dirty 页全部刷出
  if [ -w /proc/sys/vm/drop_caches ]; then
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi
  echo "[emergency-sync] 完成"
}

# 扫描所有发行版并显示运行状态概览
show_all_containers_status() {
  local distros="ubuntu debian arch fedora alpine"
  local name file alive port pid target started rootfs_target
  local has_image storage_label state_label state_glyph
  local running_count=0

  # 一次性扫 /proc，建立 root→pid 映射，避免每个发行版都重复扫
  # 使用 ls -l（单次系统调用批处理）大幅快于 readlink 循环
  local proc_dump
  proc_dump=$(ls -l /proc/[0-9]*/root 2>/dev/null \
    | awk '
        /-> \/(mnt\/chroot-rootfs|data\/local\/chroot|data\/data\/com\.termux\/files\/usr\/var\/lib\/proot-distro)/ {
          # $NF 是 "→ 后的目标路径"
          target=$NF
          # 第8字段是 "/proc/N/root"
          for (i=1;i<=NF;i++) if ($i ~ /^\/proc\/[0-9]+\/root$/) { src=$i; break }
          n=split(src, parts, "/")
          if (n>=3) print parts[3], target
        }')

  _pids_for_target() {
    local t="$1"
    awk -v t="$t" '$2==t || index($2,t"/")==1 {print $1}' <<<"$proc_dump" | sort -u | xargs 2>/dev/null
  }

  printf '\n  Containers\n'
  printf '  %s\n' '------------------------------------------------------------'
  printf '  %s %-8s %-7s %-6s %-6s %-6s %s\n' ' ' 'distro' 'state' 'pid' 'port' 'store' 'started'
  printf '  %s\n' '------------------------------------------------------------'

  for name in $distros; do
    file="$STATE_DIR/chroot-mcp-daemon-${name}.info"
    alive="no"
    port="-"
    pid="-"
    target="-"
    started="-"
    state_label="-"
    state_glyph="·"
    rootfs_target="$(find_existing_rootfs "$name")"
    has_image=0
    [ -f "/data/local/chroot-images/${name}.img" ] && has_image=1

    if [ "$has_image" -eq 1 ]; then
      storage_label='image'
    elif [ -n "$rootfs_target" ]; then
      storage_label='dir'
    else
      storage_label='-'
    fi

    if [ -f "$file" ]; then
      DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
      if read_daemon_info "$file" 2>/dev/null; then
        pid="${DAEMON_SSHD_PID:-}"
        port="${DAEMON_PORT:-}"
        target="${DAEMON_TARGET:-$rootfs_target}"
        started="${DAEMON_STARTED_AT:-}"
        if pid_root_matches_target "$pid" "$target"; then
          alive="yes"
          state_label='running'
          state_glyph='●'
          running_count=$((running_count + 1))
        fi
      fi
    fi

    if [ "$alive" = "no" ] && [ -n "$rootfs_target" ]; then
      local fg_pids
      fg_pids="$(_pids_for_target "$rootfs_target")"
      if [ -n "$fg_pids" ]; then
        pid="${fg_pids%% *}"
        target="$rootfs_target"
        port="-"
        started="-"
        alive="yes"
        state_label='live(fg)'
        state_glyph='◐'
        running_count=$((running_count + 1))
      fi
    fi

    if [ "$alive" = "yes" ]; then
      printf '  %s %-8s %-7s %-6s %-6s %-6s %s\n' \
        "$state_glyph" "$name" "$state_label" "$pid" "$port" "$storage_label" "$started"
    elif [ "$has_image" -eq 1 ] || [ -n "$rootfs_target" ]; then
      printf '  %s %-8s %-7s %-6s %-6s %-6s %s\n' \
        '○' "$name" 'ready' '-' '-' "$storage_label" '-'
    else
      printf '  %s %-8s %-7s %-6s %-6s %-6s %s\n' \
        '·' "$name" 'absent' '-' '-' '-' '-'
    fi
  done
  printf '  %s\n' '------------------------------------------------------------'
  printf '  ● running  后台 sshd 在跑（可SFTP/SSH）\n'
  printf '  ◐ live(fg) 有人在容器里开着前台 shell（无后台 sshd）\n'
  printf '  ○ ready    已安装但当前未启动\n'
  printf '  · absent   未安装\n\n'

  if [ "$running_count" -gt 0 ]; then
    return 0
  else
    return 1
  fi
}

daemon_status() {
  local file
  file="$(get_daemon_info_file)"
  if ! read_daemon_info "$file"; then
    echo "[status] 未找到后台状态文件: $file"
    return 1
  fi

  local alive="no"
  if pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$TARGET}"; then
    alive="yes"
  fi

  echo "[status] DISTRO=${DISTRO_NAME:-$(basename "${DAEMON_TARGET:-$TARGET}") }"
  echo "[status] TARGET=${DAEMON_TARGET:-unknown}"
  echo "[status] PORT=${DAEMON_PORT:-unknown}"
  echo "[status] SSHD_PID=${DAEMON_SSHD_PID:-unknown}"
  echo "[status] PID_ALIVE=$alive"
  echo "[status] LOG_FILE=${DAEMON_LOG_FILE:-unknown}"
  echo "[status] STARTED_AT=${DAEMON_STARTED_AT:-unknown}"
  [ -n "${DAEMON_IMAGE_FILE:-}" ] && echo "[status] IMAGE_FILE=${DAEMON_IMAGE_FILE}"
  [ -n "${DAEMON_IMAGE_LOOPDEV:-}" ] && echo "[status] IMAGE_LOOPDEV=${DAEMON_IMAGE_LOOPDEV}"
  if [ -n "${DAEMON_PORT:-}" ]; then
    ss -tnlp 2>/dev/null | grep -E ":${DAEMON_PORT} " || true
  fi
}

collect_mountpoint_users_in_current_ns() {
  local mp="$1"
  local p pid link hit=0
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    for what in root cwd exe; do
      [ -e "$p/$what" ] || continue
      link=$(readlink "$p/$what" 2>/dev/null || true)
      case "$link" in
        "$mp"|"$mp"/*)
          echo "$pid"
          hit=1
          break
          ;;
      esac
    done
  done | sort -u
}

summarize_pid_cmdlines() {
  local p pid out=""
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    [ -d "/proc/$pid" ] || continue
    p=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [ -z "$p" ] && p="[$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)]"
    out+="${out:+ ; }${pid}:${p}"
  done
  printf '%s' "$out"
}

# 早期需要在 daemon_stop / cleanup 路径中使用的挂载工具函数
# （主体在文件中段，但这些路径在主体定义之前就可能被调用）
is_mounted() {
  local dst="$1"
  grep -Fq " $dst " /proc/self/mountinfo
}

quick_lazy_umount() {
  local mp="$1"
  case "$mp" in
    "${TARGET:-}/storage/emulated/0"|"${TARGET:-}/sdcard"|"${TARGET:-}/apex")
      umount -l "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
      ;;
    *)
      umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
      ;;
  esac
}

list_loop_devices_for_image() {
  local image_file="$1"
  [ -n "$image_file" ] || return 0
  "$LOSETUP_BIN" -j "$image_file" 2>/dev/null | awk -F: '{print $1}' | xargs 2>/dev/null || true
}

log_mountpoint_evidence() {
  local tag="$1" mp="$2"
  local users user_cmds line
  [ -n "$mp" ] || return 0
  line=$(grep -F " $mp " /proc/self/mountinfo 2>/dev/null | tail -1 || true)
  users=$(collect_mountpoint_users_in_current_ns "$mp" | xargs 2>/dev/null || true)
  user_cmds=$(summarize_pid_cmdlines $users)
  log "[EVIDENCE][$tag] mountpoint=$mp mounted=$([ -n "$line" ] && echo yes || echo no) users=${users:-none} user_cmds=${user_cmds:-none}"
  [ -n "$line" ] && log "[EVIDENCE][$tag] mountinfo=$line"
}

log_loopdev_evidence() {
  local tag="$1" loopdev="$2"
  local info backing
  [ -n "$loopdev" ] || return 0
  info=$("$LOSETUP_BIN" "$loopdev" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' || true)
  backing=$(basename "$loopdev")
  backing=$(cat "/sys/block/${backing##*/}/loop/backing_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' || true)
  log "[EVIDENCE][$tag] loopdev=$loopdev info=${info:-none} backing=${backing:-unknown}"
}

umount_with_evidence() {
  local mp="$1"
  local tag="${2:-umount}"
  [ -n "$mp" ] || return 0
  if ! is_mounted "$mp"; then
    log "[EVIDENCE][$tag] mountpoint=$mp already_unmounted"
    return 0
  fi
  log_mountpoint_evidence "$tag:before" "$mp"
  if umount "$mp" 2>/dev/null; then
    log "[EVIDENCE][$tag] umount_ok mountpoint=$mp"
    return 0
  fi
  log "[EVIDENCE][$tag] umount_failed mountpoint=$mp fallback=lazy"
  if umount -l "$mp" 2>/dev/null; then
    log "[EVIDENCE][$tag] umount_lazy_ok mountpoint=$mp"
    return 0
  fi
  log "[EVIDENCE][$tag] umount_lazy_failed mountpoint=$mp"
  log_mountpoint_evidence "$tag:after_fail" "$mp"
  return 1
}

detach_loop_with_evidence() {
  local loopdev="$1"
  local tag="${2:-loop_detach}"
  [ -n "$loopdev" ] || return 0
  log_loopdev_evidence "$tag:before" "$loopdev"
  if "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null; then
    log "[EVIDENCE][$tag] detach_ok loopdev=$loopdev"
    return 0
  fi
  log "[EVIDENCE][$tag] detach_failed loopdev=$loopdev"
  log_loopdev_evidence "$tag:after_fail" "$loopdev"
  return 1
}

cleanup_stale_loop_devices_for_image() {
  local image_file="$1"
  local mountpoint="$2"
  local loops loopdev users
  [ -n "$image_file" ] || return 0
  loops=$(list_loop_devices_for_image "$image_file")
  [ -n "$loops" ] || return 0

  for loopdev in $loops; do
    if [ -n "$mountpoint" ] && grep -Fq " $mountpoint " /proc/self/mountinfo 2>/dev/null; then
      users=$(collect_mountpoint_users_in_current_ns "$mountpoint" | xargs 2>/dev/null || true)
      if [ -n "$users" ]; then
        echo_warn "检测到镜像挂载点仍被当前命名空间进程使用，跳过残留 loop 清理: $mountpoint users=$users loop=$loopdev"
        log_mountpoint_evidence "stale_loop_skip_busy" "$mountpoint"
        log_loopdev_evidence "stale_loop_skip_busy" "$loopdev"
        continue
      fi
      echo_warn "检测到镜像挂载点仍存在但无进程使用，先卸载再释放 loop: $mountpoint ($loopdev)"
      umount_with_evidence "$mountpoint" "stale_loop_mount_cleanup"
    else
      echo_warn "检测到镜像残留 loop 绑定，尝试释放: $loopdev -> $image_file"
      log_loopdev_evidence "stale_loop_orphan" "$loopdev"
    fi
    detach_loop_with_evidence "$loopdev" "stale_loop_detach"
  done
}

cleanup_current_namespace_stale_image_mount() {
  set_image_paths
  [ -f "$IMAGE_FILE" ] || return 0

  if grep -Fq " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null; then
    local users loopdev
    users=$(collect_mountpoint_users_in_current_ns "$IMAGE_MOUNTPOINT" | xargs 2>/dev/null || true)
    if [ -n "$users" ]; then
      echo_warn "检测到当前命名空间已有镜像挂载且仍被进程使用，保留: $IMAGE_MOUNTPOINT users=$users"
      log_mountpoint_evidence "stale_image_mount_busy" "$IMAGE_MOUNTPOINT"
      cleanup_stale_loop_devices_for_image "$IMAGE_FILE" "$IMAGE_MOUNTPOINT"
      return 0
    fi

    loopdev=$(grep -F " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
    case "$loopdev" in
      /dev/loop*|/dev/block/loop*) ;;
      *) loopdev="" ;;
    esac

    echo_warn "检测到当前命名空间残留镜像挂载，执行清理: $IMAGE_MOUNTPOINT ${loopdev:+($loopdev)}"
    umount_with_evidence "$IMAGE_MOUNTPOINT" "stale_image_mount_cleanup"
    [ -n "$loopdev" ] && detach_loop_with_evidence "$loopdev" "stale_image_mount_detach" || true
  fi

  cleanup_stale_loop_devices_for_image "$IMAGE_FILE" "$IMAGE_MOUNTPOINT"
}

daemon_stop() {
  local file
  file="$(get_daemon_info_file)"
  if ! read_daemon_info "$file"; then
    echo "[stop] 未找到后台状态文件: $file"
    # 即使没有状态文件，也尝试基于 DISTRO_NAME 找出残留进程/挂载并清理
    local fallback_target fallback_pids fallback_pid
    fallback_target="$(find_existing_rootfs "${DISTRO_NAME:-}")"
    if [ -n "$fallback_target" ]; then
      fallback_pids="$(collect_pids_by_root_prefix "$fallback_target")"
      if [ -n "$fallback_pids" ]; then
        fallback_pid="$(first_pid_from_list "$fallback_pids")"
        echo "[stop] 仍检测到残留进程，转入残留清理: pids=${fallback_pids}"
        stop_runtime_by_pid_target "$fallback_pid" "$fallback_target" "" "stop-fallback" || return $?
        return 0
      fi
      if grep -Fq " $fallback_target " /proc/self/mountinfo 2>/dev/null; then
        echo "[stop] 状态文件缺失，但宿主仍有残留挂载，执行 lazy umount: $fallback_target"
        local host_loopdev mp
        host_loopdev=$(grep -F " ${fallback_target} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
        # 反向 umount 所有 fallback_target 下的子挂载
        grep -F " $fallback_target" /proc/self/mountinfo 2>/dev/null \
          | awk '{print $5}' | tac | while read -r mp; do
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
          done
        umount "$fallback_target" 2>/dev/null || umount -l "$fallback_target" 2>/dev/null || true
        case "$host_loopdev" in /dev/loop*|/dev/block/loop*) "$LOSETUP_BIN" -d "$host_loopdev" 2>/dev/null || true;; esac
        return 0
      fi
    fi
    return 1
  fi

  [ -n "${DAEMON_TARGET:-}" ] || { echo "[stop] 状态文件缺少 TARGET"; return 1; }
  [ -n "${DAEMON_SSHD_PID:-}" ] || { echo "[stop] 状态文件缺少 SSHD_PID"; return 1; }
  if ! pid_root_matches_target "${DAEMON_SSHD_PID}" "${DAEMON_TARGET}"; then
    echo "[stop] 状态文件中的 sshd pid 与目标 rootfs 不匹配或已失效: ${DAEMON_SSHD_PID}"
    rm -f "$file"
    # pid 已死但宿主可能仍有残留挂载（上次 sshd 被外部 kill / 脚本被中断）
    if grep -Fq " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null; then
      echo "[stop] 检测到宿主残留挂载，执行清理: ${DAEMON_TARGET}"
      local host_loopdev mp
      host_loopdev=$(grep -F " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
      grep -F " $DAEMON_TARGET" /proc/self/mountinfo 2>/dev/null \
        | awk '{print $5}' | tac | while read -r mp; do
          umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        done
      umount "$DAEMON_TARGET" 2>/dev/null || umount -l "$DAEMON_TARGET" 2>/dev/null || true
      case "$host_loopdev" in /dev/loop*|/dev/block/loop*) "$LOSETUP_BIN" -d "$host_loopdev" 2>/dev/null || true;; esac
    fi
    return 0
  fi

  # ---- 优雅关停：先 sync 再 SIGTERM 再 umount ----
  echo "[stop] 第 1 步：进入容器执行 sync，刷出文件缓存"
  "$NSENTER_BIN" -t "${DAEMON_SSHD_PID}" -m -- "$SH_BIN" -c '
    sync 2>/dev/null
    sync 2>/dev/null
    sleep 0.2
    sync 2>/dev/null
  ' 2>/dev/null || true

  echo "[stop] 第 2 步：进入 mount namespace 清理: pid=${DAEMON_SSHD_PID} target=${DAEMON_TARGET}"
  "$NSENTER_BIN" -t "$DAEMON_SSHD_PID" -m -- "$BASH_BIN" -s -- "$DAEMON_TARGET" "$DAEMON_SSHD_PID" "${DAEMON_IMAGE_LOOPDEV:-}" <<'EOS'
TARGET="$1"
PID="$2"
LOOPDEV="$3"
collect_target_pids() {
  local p link pid
  for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    link=$(readlink "$p/root" 2>/dev/null || true)
    case "$link" in
      "$TARGET"|"$TARGET"/*)
        pid="${p##*/}"
        [ "$pid" = "$$" ] && continue
        echo "$pid"
        ;;
    esac
  done | sort -u
}
sync 2>/dev/null
kill "$PID" 2>/dev/null || true
sleep 1
for p in $(collect_target_pids); do kill "$p" 2>/dev/null || true; done
sleep 1
sync 2>/dev/null
kill -9 "$PID" 2>/dev/null || true
for p in $(collect_target_pids); do kill -9 "$p" 2>/dev/null || true; done
sync 2>/dev/null
for m in \
  "$TARGET/etc/resolv.conf" \
  "$TARGET/storage/emulated/0" \
  "$TARGET/sdcard" \
  "$TARGET/metadata" \
  "$TARGET/linkerconfig" \
  "$TARGET/apex" \
  "$TARGET/system_ext" \
  "$TARGET/odm" \
  "$TARGET/product" \
  "$TARGET/vendor" \
  "$TARGET/system" \
  "$TARGET/data" \
  "$TARGET/android_boot" \
  "$TARGET/android_odm" \
  "$TARGET/android_product" \
  "$TARGET/android_vendor" \
  "$TARGET/android_system" \
  "$TARGET/android_data" \
  "$TARGET/android_root" \
  "$TARGET/dev/shm" \
  "$TARGET/run" \
  "$TARGET/tmp" \
  "$TARGET/dev/binderfs" \
  "$TARGET/dev/pts" \
  "$TARGET/dev" \
  "$TARGET/sys" \
  "$TARGET/proc"
  do
  case "$m" in
    "$TARGET/storage/emulated/0"|"$TARGET/sdcard"|"$TARGET/apex")
      umount -l "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
      ;;
    *)
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
      ;;
  esac
done
rm -f "$TARGET/.chroot_marker" 2>/dev/null || true
sync 2>/dev/null
# 卸载前 remount 为只读，确保 ext4 落最终 commit
mount -o remount,ro "$TARGET" 2>/dev/null || true
sync 2>/dev/null
umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
[ -n "$LOOPDEV" ] && "$LOSETUP_BIN" -d "$LOOPDEV" 2>/dev/null || true
EOS
  local rc=$?

  if [ -n "${DAEMON_IMAGE_FILE:-}" ] && grep -Fq " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null; then
    local host_loopdev host_users
    host_users=$(collect_mountpoint_users_in_current_ns "${DAEMON_TARGET}" | xargs 2>/dev/null || true)
    if [ -n "$host_users" ]; then
      echo "[stop] 当前命名空间仍有进程使用挂载点，跳过宿主残留清理: ${DAEMON_TARGET} users=$host_users"
      log_mountpoint_evidence "daemon_stop_host_busy" "${DAEMON_TARGET}"
    else
      host_loopdev=$(grep -F " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
      case "$host_loopdev" in
        /dev/loop*|/dev/block/loop*) ;;
        *) host_loopdev="" ;;
      esac
      echo "[stop] 清理当前命名空间残留镜像挂载: ${DAEMON_TARGET} ${host_loopdev}"
      quick_lazy_umount "${DAEMON_TARGET}"
      [ -n "$host_loopdev" ] && "$LOSETUP_BIN" -d "$host_loopdev" 2>/dev/null || true
      [ -n "${DAEMON_IMAGE_FILE:-}" ] && cleanup_stale_loop_devices_for_image "${DAEMON_IMAGE_FILE}" "${DAEMON_TARGET}" || true
    fi
  fi

  rm -f "$file" 2>/dev/null || true
  echo "[stop] 状态文件已删除: $file"
  return $rc
}

has_interactive_tty() {
  [ -t 0 ] && [ -t 1 ]
}

collect_pids_by_root_prefix() {
  local root="$1"
  local p link
  [ -n "$root" ] || return 0
  for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    link=$(readlink "$p/root" 2>/dev/null || true)
    case "$link" in
      "$root"|"$root"/*)
        echo "${p##*/}"
        ;;
    esac
  done | sort -u | xargs 2>/dev/null || true
}

merge_pid_lists() {
  printf '%s\n' "$@" | tr ' ' '\n' | sed '/^$/d' | sort -u | xargs 2>/dev/null || true
}

first_pid_from_list() {
  local list="$1"
  set -- $list
  [ $# -gt 0 ] && echo "$1"
}

enter_existing_container() {
  local ns_pid="$1"
  local target="$2"

  [ -n "$ns_pid" ] || echo_err "直接进入失败：缺少目标 pid"
  [ -n "$target" ] || echo_err "直接进入失败：缺少目标 rootfs"
  [ -d "/proc/$ns_pid" ] || echo_err "直接进入失败：目标 pid 不存在: $ns_pid"

  echo_info "直接进入已运行容器: pid=$ns_pid target=$target"

  # 优先用 rootfs 自带的 bash；若 rootfs 没 bash（alpine/arch 默认），退回 /bin/sh
  local in_shell="/bin/bash"
  [ -x "$target/bin/bash" ] || in_shell="/bin/sh"
  "$NSENTER_BIN" -t "$ns_pid" -m "$SH_BIN" -c \
    "cd '$target' && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin $CHROOT_BIN . $in_shell -i"
}


stop_runtime_by_pid_target() {
  local ns_pid="$1"
  local target="$2"
  local loopdev="${3:-}"
  local label="${4:-runtime}"

  [ -n "$ns_pid" ] || { echo "[stop] 缺少清理 pid"; return 1; }
  [ -n "$target" ] || { echo "[stop] 缺少清理 TARGET"; return 1; }
  [ -d "/proc/$ns_pid" ] || { echo "[stop] 目标 pid 不存在: $ns_pid"; return 1; }

  echo "[stop] 进入 mount namespace 清理(${label}): pid=${ns_pid} target=${target}"
  "$NSENTER_BIN" -t "$ns_pid" -m -- "$BASH_BIN" -s -- "$target" "$ns_pid" "$loopdev" <<'EOS'
TARGET="$1"
PID="$2"
LOOPDEV="$3"
collect_target_pids() {
  local p link pid
  for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    link=$(readlink "$p/root" 2>/dev/null || true)
    case "$link" in
      "$TARGET"|"$TARGET"/*)
        pid="${p##*/}"
        [ "$pid" = "$$" ] && continue
        echo "$pid"
        ;;
    esac
  done | sort -u
}
sync 2>/dev/null
kill "$PID" 2>/dev/null || true
sleep 1
for p in $(collect_target_pids); do kill "$p" 2>/dev/null || true; done
sleep 1
sync 2>/dev/null
kill -9 "$PID" 2>/dev/null || true
for p in $(collect_target_pids); do kill -9 "$p" 2>/dev/null || true; done
sync 2>/dev/null
for m in \
  "$TARGET/etc/resolv.conf" \
  "$TARGET/storage/emulated/0" \
  "$TARGET/sdcard" \
  "$TARGET/metadata" \
  "$TARGET/linkerconfig" \
  "$TARGET/apex" \
  "$TARGET/system_ext" \
  "$TARGET/odm" \
  "$TARGET/product" \
  "$TARGET/vendor" \
  "$TARGET/system" \
  "$TARGET/data" \
  "$TARGET/android_boot" \
  "$TARGET/android_odm" \
  "$TARGET/android_product" \
  "$TARGET/android_vendor" \
  "$TARGET/android_system" \
  "$TARGET/android_data" \
  "$TARGET/android_root" \
  "$TARGET/dev/shm" \
  "$TARGET/run" \
  "$TARGET/tmp" \
  "$TARGET/dev/binderfs" \
  "$TARGET/dev/pts" \
  "$TARGET/dev" \
  "$TARGET/sys" \
  "$TARGET/proc"
  do
  case "$m" in
    "$TARGET/storage/emulated/0"|"$TARGET/sdcard"|"$TARGET/apex")
      umount -l "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
      ;;
    *)
      umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
      ;;
  esac
done
rm -f "$TARGET/.chroot_marker" 2>/dev/null || true
sync 2>/dev/null
# 卸载前 remount 为只读，确保 ext4 落最终 commit
mount -o remount,ro "$TARGET" 2>/dev/null || true
sync 2>/dev/null
umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
[ -n "$LOOPDEV" ] && "$LOSETUP_BIN" -d "$LOOPDEV" 2>/dev/null || true
EOS
  local rc=$?

  if grep -Fq " ${target} " /proc/self/mountinfo 2>/dev/null; then
    local host_loopdev host_users
    host_users=$(collect_mountpoint_users_in_current_ns "${target}" | xargs 2>/dev/null || true)
    if [ -n "$host_users" ]; then
      echo "[stop] 当前命名空间仍有进程使用挂载点，跳过宿主残留清理: ${target} users=$host_users"
      log_mountpoint_evidence "stop_runtime_host_busy" "${target}"
    else
      host_loopdev=$(grep -F " ${target} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
      case "$host_loopdev" in
        /dev/loop*|/dev/block/loop*) ;;
        *) host_loopdev="$loopdev" ;;
      esac
      echo "[stop] 清理当前命名空间残留挂载: ${target} ${host_loopdev}"
      quick_lazy_umount "${target}"
      [ -n "$host_loopdev" ] && "$LOSETUP_BIN" -d "$host_loopdev" 2>/dev/null || true
      [ -n "$host_loopdev" ] && [ -f "${IMAGE_FILE:-}" ] && cleanup_stale_loop_devices_for_image "${IMAGE_FILE}" "${target}" || true
    fi
  fi

  return $rc
}

# ==============================================
# rootfs 选择 / 迁移 / 镜像挂载
# ==============================================
# get_rootfs_name 已在文件顶部定义

set_image_paths() {
  local name
  name="$(get_rootfs_name)"
  IMAGE_FILE="/data/local/chroot-images/${name}.img"
  IMAGE_MOUNTPOINT="/mnt/chroot-rootfs/${name}"
}

resolve_image_size_mib() {
  local requested_gb="$1"
  local min_mib="$2"
  local requested_mib=""

  if [ -z "$requested_gb" ]; then
    requested_gb=20
  fi

  if ! [[ "$requested_gb" =~ ^[0-9]+$ ]] || [ "$requested_gb" -le 0 ]; then
    echo "[migrate-image] 非法镜像大小: ${requested_gb} GB（必须是正整数）" >&2
    return 1
  fi

  requested_mib=$(( requested_gb * 1024 ))
  if [ "$requested_mib" -lt "$min_mib" ]; then
    echo_warn "[migrate-image] 指定大小 ${requested_gb} GB 小于最小所需 $(( (min_mib + 1023) / 1024 )) GB，已自动提升"
    requested_mib="$min_mib"
  fi

  echo "$requested_mib"
}

resolve_image_resize_target_mib() {
  local requested_gb="$1"
  local current_bytes="$2"
  local current_mib

  if [ -z "$requested_gb" ]; then
    echo "[resize-image] 未提供目标大小" >&2
    return 1
  fi

  if ! [[ "$requested_gb" =~ ^[0-9]+$ ]] || [ "$requested_gb" -le 0 ]; then
    echo "[resize-image] 非法镜像大小: ${requested_gb} GB（必须是正整数）" >&2
    return 1
  fi

  current_mib=$(( (current_bytes + 1048575) / 1048576 ))
  if [ $(( requested_gb * 1024 )) -lt "$current_mib" ]; then
    echo_warn "[resize-image] 目标大小 ${requested_gb} GB 小于当前镜像大小 $(( (current_mib + 1023) / 1024 )) GB，已自动保持当前大小"
    echo "$current_mib"
    return 0
  fi

  echo $(( requested_gb * 1024 ))
}

ensure_loop_device_node() {
  local loopdev="$1"
  local sysdev major minor node_created=0

  [ -n "$loopdev" ] || return 1
  [ -b "$loopdev" ] && return 0

  sysdev="/sys/class/block/${loopdev##*/}/dev"
  [ -f "$sysdev" ] || return 1

  major=$(cut -d: -f1 "$sysdev" 2>/dev/null || true)
  minor=$(cut -d: -f2 "$sysdev" 2>/dev/null || true)
  [ -n "$major" ] && [ -n "$minor" ] || return 1

  if mknod "$loopdev" b "$major" "$minor" 2>/dev/null; then
    node_created=1
  fi

  [ "$node_created" -eq 1 ] || [ -b "$loopdev" ]
}

get_image_loopdev_for_file() {
  local image_file="$1"
  local loopdev=""

  loopdev=$(list_loop_devices_for_image "$image_file" | awk 'NF{print $1; exit}')
  [ -n "$loopdev" ] && {
    echo "$loopdev"
    return 0
  }

  loopdev=$(losetup -a 2>/dev/null | awk -v img="$image_file" '$0 ~ img {sub(/:.*/, "", $1); print $1; exit}')
  [ -n "$loopdev" ] && {
    echo "$loopdev"
    return 0
  }

  return 1
}

loopdev_has_active_mounts() {
  local loopdev="$1"
  local p

  [ -n "$loopdev" ] || return 1
  for p in /proc/[0-9]*/mountinfo; do
    [ -r "$p" ] || continue
    if grep -Fq " $loopdev " "$p"; then
      return 0
    fi
  done

  return 1
}

resize_rootfs_image() {
  local image_file="$IMAGE_FILE"
  local loopdev=""
  local target_mib current_bytes target_bytes daemon_file daemon_alive=0 need_detach=0 stop_confirm="" fsck_rc=0

  [ -f "$image_file" ] || { echo "[resize-image] 镜像不存在: $image_file"; return 1; }
  [ -n "$IMAGE_SIZE_GB" ] || { echo "[resize-image] 请使用 --image-size-gb 指定目标大小"; return 1; }

  daemon_file="$(get_daemon_info_file)"
  if read_daemon_info "$daemon_file" 2>/dev/null; then
    if pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$TARGET}"; then
      daemon_alive=1
      echo_warn "检测到后台容器正在运行: pid=${DAEMON_SSHD_PID} target=${DAEMON_TARGET:-$TARGET}"
      if has_interactive_tty; then
        stop_confirm=$(choose_option "扩容前需要安全停止运行中的容器，是否继续?" "继续并安全停止" "取消")
        [ "$stop_confirm" = "继续并安全停止" ] || { echo "[resize-image] 已取消"; return 1; }
      else
        echo "[resize-image] 容器仍在运行，请先执行 --stop 后重试"
        return 1
      fi
      daemon_stop || { echo "[resize-image] 停止运行中的容器失败"; return 1; }
    fi
  fi

  # 查找前台/残留容器进程（无 daemon-info 但仍有进程在 chroot 里跑的情况，例如交互式 shell 或 live(fg)）
  local resize_target_path live_pids live_pid
  resize_target_path="$(find_existing_rootfs "$(get_rootfs_name)")"
  if [ -n "$resize_target_path" ]; then
    live_pids="$(collect_pids_by_root_prefix "$resize_target_path")"
  fi
  if [ -n "$live_pids" ]; then
    live_pid="$(first_pid_from_list "$live_pids")"
    echo_warn "检测到前台/残留容器进程占用: pids=${live_pids}（target=${resize_target_path}）"
    if has_interactive_tty; then
      stop_confirm=$(choose_option "扩容前需要先终止这些进程并卸载，是否继续?" "继续并安全终止" "取消")
      [ "$stop_confirm" = "继续并安全终止" ] || { echo "[resize-image] 已取消"; return 1; }
    else
      echo "[resize-image] 容器仍有进程在跑(${live_pids})，请先 --stop 或退出 chroot 后重试"
      return 1
    fi
    stop_runtime_by_pid_target "$live_pid" "$resize_target_path" "" "live(fg)" \
      || { echo "[resize-image] 终止前台/残留容器失败"; return 1; }
    sleep 1
  fi

  cleanup_current_namespace_stale_image_mount
  loopdev="$(get_image_loopdev_for_file "$image_file" || true)"
  if [ -n "$loopdev" ]; then
    if ensure_loop_device_node "$loopdev"; then
      if loopdev_has_active_mounts "$loopdev"; then
        echo_warn "[resize-image] 镜像仍处于挂载状态，强制 lazy umount: $loopdev"
        local lp_mp
        lp_mp=$(grep -F " $loopdev " /proc/self/mountinfo 2>/dev/null | awk '{print $5}' | head -1)
        [ -n "$lp_mp" ] && (umount "$lp_mp" 2>/dev/null || umount -l "$lp_mp" 2>/dev/null || true)
        if loopdev_has_active_mounts "$loopdev"; then
          echo "[resize-image] 仍有挂载残留，请重启手机后再扩容: $loopdev"
          return 1
        fi
      fi
      losetup -d "$loopdev" 2>/dev/null || {
        echo "[resize-image] 无法释放残留 loop 设备: $loopdev"
        return 1
      }
    else
      echo_warn "检测到残留 loop 设备但无法补建设备节点，继续尝试直接附加镜像"
    fi
  fi

  current_bytes=$(stat -c '%s' "$image_file" 2>/dev/null || echo 0)
  target_mib=$(resolve_image_resize_target_mib "$IMAGE_SIZE_GB" "$current_bytes") || return 1
  target_bytes=$(( target_mib * 1048576 ))

  if [ "$target_bytes" -eq "$current_bytes" ]; then
    echo_info "[resize-image] 镜像文件已达到目标大小，无需扩展文件，仅执行文件系统检查/扩容"
  else
    echo_info "[resize-image] 扩展镜像文件到 $(( target_mib / 1024 )) GB"
    truncate -s "${target_mib}M" "$image_file" || { echo "[resize-image] truncate 失败"; return 1; }
  fi

  loopdev=$("$LOSETUP_BIN" -f --show "$image_file" 2>/dev/null) || { echo "[resize-image] loop 绑定失败"; return 1; }
  need_detach=1
  echo_info "[resize-image] 已绑定 loop: $loopdev"

  e2fsck -fy "$loopdev"
  fsck_rc=$?
  if [ "$fsck_rc" -gt 3 ]; then
    "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || true
    echo "[resize-image] e2fsck 失败(exit=$fsck_rc)，请检查镜像状态"
    return 1
  fi

  resize2fs "$loopdev" || {
    "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || true
    echo "[resize-image] resize2fs 失败"
    return 1
  }

  dumpe2fs -h "$loopdev" 2>/dev/null | grep -E 'Block count|Free blocks|Block size|Filesystem state' || true

  if [ "$need_detach" -eq 1 ]; then
    "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || {
      echo_warn "[resize-image] loop 设备释放失败，请手动检查: $loopdev"
      return 1
    }
  fi

  sync
  echo_info "[resize-image] 扩容完成: $image_file"
  return 0
}

mount_rootfs_image_if_exists() {
  set_image_paths
  [ -f "$IMAGE_FILE" ] || return 0

  mkdir -p /data/local/chroot-images "$IMAGE_MOUNTPOINT" || echo_err "无法创建镜像目录/挂载点"

  cleanup_stale_loop_devices_for_image "$IMAGE_FILE" "$IMAGE_MOUNTPOINT"

  if grep -Fq " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null; then
    local users existing_loop
    users=$(collect_mountpoint_users_in_current_ns "$IMAGE_MOUNTPOINT" | xargs 2>/dev/null || true)
    existing_loop=$(grep -F " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
    if [ -n "$users" ]; then
      echo_warn "检测到当前命名空间已有镜像挂载且被进程使用，拒绝抢占: $IMAGE_MOUNTPOINT users=$users"
      log_mountpoint_evidence "image_mount_busy" "$IMAGE_MOUNTPOINT"
      [ -n "$existing_loop" ] && log_loopdev_evidence "image_mount_busy" "$existing_loop"
      echo_err "检测到目标镜像挂载仍被当前命名空间进程使用，请先退出旧实例后再重试"
    fi
    echo_warn "检测到当前命名空间已有镜像挂载，先在本命名空间卸载后重新挂载，以确保 loop 设备由本实例独占管理"
    umount_with_evidence "$IMAGE_MOUNTPOINT" "image_mount_reclaim"
    cleanup_stale_loop_devices_for_image "$IMAGE_FILE" "$IMAGE_MOUNTPOINT"
  fi

  IMAGE_LOOPDEV=$("$LOSETUP_BIN" -f --show "$IMAGE_FILE" 2>/dev/null) || { echo "错误: 镜像 loop 绑定失败: $IMAGE_FILE" >&2; exit 1; }
  log_loopdev_evidence "image_mount_attach" "$IMAGE_LOOPDEV"

  # 启动前安全 fsck：-p 模式只修可自动修复的问题（重放 journal、清 needs_recovery 标记），通常 1-3s
  if command -v e2fsck >/dev/null 2>&1; then
    echo_info "镜像挂载前自动 e2fsck -p（修复可恢复错误，跳过严重错误）..."
    e2fsck -p "$IMAGE_LOOPDEV" >/dev/null 2>&1
    local fsck_rc=$?
    case "$fsck_rc" in
      0) echo_info "e2fsck 通过：镜像状态干净" ;;
      1) echo_info "e2fsck 修复了一些可恢复错误（rc=1）" ;;
      2) echo_warn "e2fsck 修复后建议重启设备（rc=2）但镜像可挂载" ;;
      4|8|16|32|128|*)
        detach_loop_with_evidence "$IMAGE_LOOPDEV" "image_mount_attach_fsck_fail"
        echo_err "e2fsck 检测到严重错误(rc=$fsck_rc)，请先执行: $0 --resize-image --distro $(get_rootfs_name) 或手动 e2fsck -fy $IMAGE_FILE"
        ;;
    esac
  else
    echo_warn "未找到 e2fsck，跳过启动前修复检查"
  fi

  mount -t ext4 -o noatime "$IMAGE_LOOPDEV" "$IMAGE_MOUNTPOINT" || {
    detach_loop_with_evidence "$IMAGE_LOOPDEV" "image_mount_attach_fail"
    echo "错误: 镜像挂载失败: $IMAGE_FILE -> $IMAGE_MOUNTPOINT" >&2
    exit 1
  }

  TARGET="$IMAGE_MOUNTPOINT"
  IMAGE_MODE=1
}

migrate_rootfs_to_image() {
  local src="$TARGET"
  local tmpimg loopdev bytes need_bytes min_size_mib size_mib

  [ -d "$src" ] || { echo "[migrate-image] 源 rootfs 不存在: $src"; return 1; }
  set_image_paths
  mkdir -p /data/local/chroot-images "$IMAGE_MOUNTPOINT" || return 1

  if [ -f "$IMAGE_FILE" ]; then
    echo "[migrate-image] 镜像已存在: $IMAGE_FILE"
    return 1
  fi

  bytes=$(du -sb "$src" 2>/dev/null | awk '{print $1}')
  [ -z "$bytes" ] && bytes=0
  need_bytes=$(( bytes + bytes / 3 + 268435456 ))
  min_size_mib=$(( (need_bytes + 1048575) / 1048576 ))
  size_mib=$(resolve_image_size_mib "$IMAGE_SIZE_GB" "$min_size_mib") || return 1
  tmpimg="${IMAGE_FILE}.tmp"

  echo "[migrate-image] 源: $src"
  echo "[migrate-image] 镜像: $IMAGE_FILE"
  echo "[migrate-image] 最小需求: ${min_size_mib} MiB"
  echo "[migrate-image] 申请大小: ${size_mib} MiB"

  rm -f "$tmpimg" 2>/dev/null || true
  truncate -s "${size_mib}M" "$tmpimg" || return 1
  /system/bin/mkfs.ext4 -F "$tmpimg" >/dev/null 2>&1 || { rm -f "$tmpimg"; echo "[migrate-image] mkfs.ext4 失败"; return 1; }

  loopdev=$("$LOSETUP_BIN" -f --show "$tmpimg" 2>/dev/null) || { rm -f "$tmpimg"; echo "[migrate-image] loop 绑定失败"; return 1; }
  mount -t ext4 "$loopdev" "$IMAGE_MOUNTPOINT" || {
    "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || true
    rm -f "$tmpimg"
    echo "[migrate-image] ext4 镜像挂载失败"
    return 1
  }

  (cd "$src" && tar --numeric-owner --xattrs --acls -cpf - .) | (cd "$IMAGE_MOUNTPOINT" && tar --numeric-owner --xattrs --acls -xpf -) || {
    umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
    "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || true
    rm -f "$tmpimg"
    echo "[migrate-image] rootfs 复制失败"
    return 1
  }

  chown 0:0 "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  chmod 755 "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  sync
  umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  "$LOSETUP_BIN" -d "$loopdev" 2>/dev/null || true
  mv "$tmpimg" "$IMAGE_FILE" || { rm -f "$tmpimg"; echo "[migrate-image] 保存镜像失败"; return 1; }
  [ -x /system/bin/restorecon ] && /system/bin/restorecon "$IMAGE_FILE" 2>/dev/null || true
  echo "[migrate-image] 完成: $IMAGE_FILE"
  return 0
}

migrate_rootfs() {
  local src="$TARGET"
  local name dst tmpdir bytes need_bytes avail_bytes sample_nonroot

  name="${DISTRO_NAME:-$(basename "$src")}" 
  dst="/data/local/chroot/$name"
  tmpdir="/data/local/chroot/.migrate-${name}-$$"

  [ -d "$src" ] || { echo "[migrate] 源 rootfs 不存在: $src"; return 1; }
  [ "$src" = "$dst" ] && { echo "[migrate] 已经是目标路径: $dst"; TARGET="$dst"; return 0; }

  mkdir -p /data/local/chroot || { echo "[migrate] 无法创建 /data/local/chroot"; return 1; }
  if [ -e "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    echo "[migrate] 目标路径已存在且非空: $dst"
    return 1
  fi

  bytes=$(du -sb "$src" 2>/dev/null | awk '{print $1}')
  [ -z "$bytes" ] && bytes=0
  need_bytes=$(( bytes + bytes / 5 + 134217728 ))
  avail_bytes=$(df -B1 /data/local 2>/dev/null | awk 'NR==2{print $4}')
  [ -z "$avail_bytes" ] && avail_bytes=0
  if [ "$avail_bytes" -gt 0 ] && [ "$avail_bytes" -lt "$need_bytes" ]; then
    echo "[migrate] 空间不足: need=$need_bytes avail=$avail_bytes"
    return 1
  fi

  echo "[migrate] 源: $src"
  echo "[migrate] 目标: $dst"
  echo "[migrate] 大小(bytes): $bytes"

  rm -rf "$tmpdir" 2>/dev/null || true
  mkdir -p "$tmpdir" || return 1

  (cd "$src" && tar --numeric-owner --xattrs --acls -cpf - .) | (cd "$tmpdir" && tar --numeric-owner --xattrs --acls -xpf -) || {
    rm -rf "$tmpdir" 2>/dev/null || true
    echo "[migrate] tar 复制失败"
    return 1
  }

  echo "[migrate] 修正 rootfs 根目录与关键目录属主/权限"
  chown 0:0 "$tmpdir" 2>/dev/null || true
  chmod 755 "$tmpdir" 2>/dev/null || true
  for key in "$tmpdir/bin" "$tmpdir/sbin" "$tmpdir/usr" "$tmpdir/usr/bin" "$tmpdir/usr/sbin" "$tmpdir/etc" "$tmpdir/root" "$tmpdir/tmp"; do
    [ -e "$key" ] || continue
    case "$key" in
      "$tmpdir/tmp") chmod 1777 "$key" 2>/dev/null || true ;;
      *) chown 0:0 "$key" 2>/dev/null || true; chmod 755 "$key" 2>/dev/null || true ;;
    esac
  done

  echo "[migrate] 扫描并修正 Termux app UID/GID 污染"
  sample_nonroot=$(find "$tmpdir" -xdev \( -uid 10349 -o -gid 10349 \) | head -n 1)
  if [ -n "$sample_nonroot" ]; then
    find "$tmpdir" -xdev \( -uid 10349 -o -gid 10349 \) -exec chown -h 0:0 {} + 2>/dev/null || true
  fi

  if [ -x /system/bin/restorecon ]; then
    /system/bin/restorecon -RF "$tmpdir" 2>/dev/null || true
  fi

  mv "$tmpdir" "$dst" || {
    rm -rf "$tmpdir" 2>/dev/null || true
    echo "[migrate] 移动到目标失败: $dst"
    return 1
  }

  chown 0:0 "$dst" 2>/dev/null || true
  chmod 755 "$dst" 2>/dev/null || true

  echo "[migrate] 验证 /bin/bash 与根目录权限"
  [ -x "$dst/bin/bash" ] || { echo "[migrate] 目标 rootfs 缺少可执行 /bin/bash"; return 1; }
  chown 0:0 "$dst/bin" 2>/dev/null || true
  chmod 755 "$dst/bin" 2>/dev/null || true
  chown 0:0 "$dst/bin/bash" 2>/dev/null || true

  TARGET="$dst"
  echo "[migrate] 完成: $TARGET"
  return 0
}

auto_migrate_if_needed() {
  case "$TARGET" in
    /data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/*)
      [ "$AUTO_MIGRATE" -eq 1 ] || return 0
      echo_warn "检测到 rootfs 位于 Termux /data 沙盒内，自动迁移到 /data/local/chroot 以获得更安全的标准路径映射能力"
      migrate_rootfs || echo_err "自动迁移失败，请先手动执行 --migrate"
      ;;
  esac
}

auto_migrate_image_if_needed() {
  [ "$AUTO_MIGRATE_IMAGE" -eq 1 ] || return 0
  set_image_paths

  case "$TARGET" in
    /mnt/chroot-rootfs/*)
      return 0
      ;;
    /data/*)
      if [ -f "$IMAGE_FILE" ]; then
        echo_warn "检测到现有镜像 rootfs: $IMAGE_FILE；本次启动将自动优先使用镜像以实现 /data 真1:1 映射"
        return 0
      fi
      echo_warn "检测到 rootfs 位于 /data 子树内，自动迁移为 ext4 镜像以实现 /data 真1:1 映射"
      migrate_rootfs_to_image || echo_err "自动镜像迁移失败，请先手动执行 --migrate-image"
      ;;
  esac
}

check_residual_state() {
  local file
  local daemon_alive=0
  local daemon_pid=""
  local daemon_target=""
  local daemon_port=""
  local residual_target=""
  local residual_pid=""
  local target_pids=""
  local image_pids=""
  local pids=""
  local prompt=""
  local choice=""

  file="$(get_daemon_info_file)"
  if read_daemon_info "$file"; then
    if pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$TARGET}"; then
      daemon_alive=1
      daemon_pid="${DAEMON_SSHD_PID}"
      daemon_target="${DAEMON_TARGET:-$TARGET}"
      daemon_port="${DAEMON_PORT:-unknown}"
      echo_warn "检测到后台实例已运行: pid=${daemon_pid} port=${daemon_port} target=${daemon_target}"
    else
      echo_warn "检测到陈旧后台状态文件，已清理: $file"
      rm -f "$file" 2>/dev/null || true
    fi
  fi

  set_image_paths
  if [ "$daemon_alive" -eq 0 ] \
     && ! grep -Fq " $TARGET " /proc/self/mountinfo 2>/dev/null \
     && { [ -z "${IMAGE_MOUNTPOINT:-}" ] || [ "$IMAGE_MOUNTPOINT" = "$TARGET" ] || ! grep -Fq " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null; }; then
    return 0
  fi

  target_pids="$(collect_pids_by_root_prefix "$TARGET")"
  if [ -n "${IMAGE_MOUNTPOINT:-}" ] && [ "$IMAGE_MOUNTPOINT" != "$TARGET" ]; then
    image_pids="$(collect_pids_by_root_prefix "$IMAGE_MOUNTPOINT")"
  fi
  pids="$(merge_pid_lists "$target_pids" "$image_pids")"
  if [ -n "$pids" ]; then
    if [ -n "$target_pids" ]; then
      residual_target="$TARGET"
    else
      residual_target="$IMAGE_MOUNTPOINT"
    fi
    residual_pid="$(first_pid_from_list "$pids")"
    echo_warn "检测到目标 rootfs 仍有存活进程: $pids"
    if [ "$daemon_alive" -eq 0 ]; then
      echo_warn "该状态更像残留/半残留实例；若继续强行启动，容易触发假性 ENOENT"
    fi
  fi

  if [ "$daemon_alive" -eq 0 ] && [ -z "$pids" ]; then
    return 0
  fi

  if ! has_interactive_tty; then
    if [ "$daemon_alive" -eq 1 ] && [ "$DAEMON_MODE" -eq 1 ]; then
      echo_info "后台实例已存在，当前无TTY，保持现状并退出；可用 --status 查看，或用 --stop 停止后再启动"
      exit 0
    fi
    echo_err "检测到已有运行中的实例或残留进程；当前无TTY无法交互选择。为避免假性 ENOENT，本次已中止。请先执行 --status/--stop，或在TTY中重新运行。"
  fi

  if [ "$daemon_alive" -eq 1 ]; then
    prompt="检测到已有运行中的容器，选择操作"
  else
    prompt="检测到目标 rootfs 仍有残留进程，继续强启可能触发假性 ENOENT；选择操作"
  fi
  choice=$(choose_option "$prompt" "直接进入容器" "停止后再进入" "退出脚本并保持运行" "安全结束容器")

  case "$choice" in
    "直接进入容器")
      if [ "$daemon_alive" -eq 1 ]; then
        enter_existing_container "$daemon_pid" "$daemon_target"
      else
        [ -n "$residual_pid" ] || echo_err "直接进入失败：未找到可用残留 pid"
        [ -n "$residual_target" ] || residual_target="$TARGET"
        enter_existing_container "$residual_pid" "$residual_target"
      fi
      exit $?
      ;;
    "停止后再进入")
      if [ "$daemon_alive" -eq 1 ]; then
        daemon_stop || echo_err "停止已有后台实例失败"
      else
        [ -n "$residual_pid" ] || echo_err "清理失败：未找到可用残留 pid"
        [ -n "$residual_target" ] || residual_target="$TARGET"
        stop_runtime_by_pid_target "$residual_pid" "$residual_target" "" "residual" || echo_err "清理残留实例失败"
      fi
      sleep 1
      return 0
      ;;
    "退出脚本并保持运行")
      echo_info "已退出脚本，保持现有容器/残留状态不变"
      exit 0
      ;;
    "安全结束容器")
      if [ "$daemon_alive" -eq 1 ]; then
        daemon_stop || echo_err "安全结束已有后台实例失败"
      else
        [ -n "$residual_pid" ] || echo_err "安全结束失败：未找到可用残留 pid"
        [ -n "$residual_target" ] || residual_target="$TARGET"
        stop_runtime_by_pid_target "$residual_pid" "$residual_target" "" "residual" || echo_err "安全结束残留实例失败"
      fi
      echo_info "现有容器已安全结束"
      exit 0
      ;;
    *)
      echo_info "未识别的选择，默认退出并保持现状"
      exit 0
      ;;
  esac
}

# ==============================================
# 交互向导 / 下载 / 发行版预设
# ==============================================
dialog_extract_text() {
  sed -n 's/.*"text":"\([^"]*\)".*/\1/p'
}

choose_option() {
  local prompt="$1"; shift
  local options=("$@")
  local selected=""

  if command -v termux-dialog >/dev/null 2>&1; then
    local csv
    csv=$(IFS=,; echo "${options[*]}")
    selected=$(termux-dialog radio -t "$prompt" -v "$csv" 2>/dev/null | dialog_extract_text | head -n1)
  fi

  if [ -z "$selected" ]; then
    echo "$prompt" >&2
    local i=1 opt idx
    for opt in "${options[@]}"; do
      echo "  [$i] $opt" >&2
      i=$((i+1))
    done
    printf '请输入编号: ' >&2
    IFS= read -r idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#options[@]}" ]; then
      selected="${options[$((idx-1))]}"
    else
      selected="${options[0]}"
    fi
  fi
  echo "$selected"
}

ask_text() {
  local prompt="$1"
  local val=""
  if command -v termux-dialog >/dev/null 2>&1; then
    val=$(termux-dialog text -t "$prompt" 2>/dev/null | dialog_extract_text | head -n1)
  fi
  if [ -z "$val" ]; then
    printf '%s: ' "$prompt" >&2
    IFS= read -r val
  fi
  echo "$val"
}

download_rootfs_archive() {
  local url="$1"
  local rootfs_dir="$2"
  local archive_name archive

  # 保留原始扩展名，便于 tar 自动识别压缩格式（.xz/.gz/.bz2）
  archive_name="rootfs-$(date +%s)"
  case "$url" in
    *.tar.xz|*.txz) archive_name="${archive_name}.tar.xz" ;;
    *.tar.gz|*.tgz) archive_name="${archive_name}.tar.gz" ;;
    *.tar.bz2|*.tbz2) archive_name="${archive_name}.tar.bz2" ;;
    *.tar.zst) archive_name="${archive_name}.tar.zst" ;;
    *.tar)          archive_name="${archive_name}.tar" ;;
    *)              archive_name="${archive_name}.tar.xz" ;;  # 默认按 xz 处理（LXC 默认）
  esac
  archive="$STATE_DIR/$archive_name"

  mkdir -p "$rootfs_dir" || return 1
  echo_info "下载: $url"
  echo_info "  → $archive"
  if ! curl -fL --retry 3 --retry-delay 2 -C - "$url" -o "$archive" 2>&1; then
    echo_warn "下载失败: $url"
    rm -f "$archive" 2>/dev/null
    return 1
  fi
  local size
  size=$(stat -c '%s' "$archive" 2>/dev/null || echo 0)
  if [ "${size:-0}" -lt 1048576 ]; then
    echo_warn "下载文件过小($size 字节)，可能是 404 / 重定向页面"
    rm -f "$archive" 2>/dev/null
    return 1
  fi

  echo_info "解压: $archive → $rootfs_dir"
  local tar_rc=0
  case "$archive" in
    *.tar.xz|*.txz)   tar -xJpf "$archive" -C "$rootfs_dir" 2>&1 || tar_rc=$? ;;
    *.tar.gz|*.tgz)   tar -xzpf "$archive" -C "$rootfs_dir" 2>&1 || tar_rc=$? ;;
    *.tar.bz2|*.tbz2) tar -xjpf "$archive" -C "$rootfs_dir" 2>&1 || tar_rc=$? ;;
    *.tar.zst)        tar --zstd -xpf "$archive" -C "$rootfs_dir" 2>&1 || tar_rc=$? ;;
    *)                tar -xpf "$archive" -C "$rootfs_dir" 2>&1 || tar_rc=$? ;;
  esac
  if [ "$tar_rc" -ne 0 ]; then
    echo_warn "tar 解压失败 (rc=$tar_rc)，归档可能损坏或缺少对应解压器"
    rm -f "$archive" 2>/dev/null
    return 1
  fi

  chown root:root "$rootfs_dir" 2>/dev/null || true
  chmod 755 "$rootfs_dir" 2>/dev/null || true
  rm -f "$archive" 2>/dev/null || true
  return 0
}

# 解析 LXC images index 页面，返回最新快照目录的 rootfs.tar.xz URL
_resolve_lxc_latest_rootfs() {
  local base="$1"
  local snapshots latest
  snapshots=$(curl -fsSL --max-time 30 "$base" 2>/dev/null \
    | grep -oE 'href="[0-9A-Za-z_%]+/"' \
    | sed 's/href="//;s/"//;s|/$||' \
    | grep -E '^[0-9]{8}' \
    | sort)
  latest=$(printf '%s\n' "$snapshots" | tail -1)
  [ -n "$latest" ] || return 1
  echo "${base}${latest}/rootfs.tar.xz"
}

# 解析 alpine dl-cdn 列表页，返回当前 minirootfs 的 tar.gz URL
_resolve_alpine_latest_rootfs() {
  local base="$1"
  local fname
  fname=$(curl -fsSL --max-time 30 "$base" 2>/dev/null \
    | grep -oE 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' \
    | sort -V | tail -1)
  [ -n "$fname" ] || return 1
  echo "${base}${fname}"
}

# 内置 arm64 rootfs 下载源（动态解析最新版本）
get_builtin_rootfs_urls() {
  local distro="$1"
  case "$distro" in
    alpine)
      local u
      u="$(_resolve_alpine_latest_rootfs 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/' 2>/dev/null)"
      [ -n "$u" ] && printf '%s\n' "$u"
      u="$(_resolve_alpine_latest_rootfs 'https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/' 2>/dev/null)"
      [ -n "$u" ] && printf '%s\n' "$u"
      ;;
    ubuntu)
      printf '%s\n' \
        'https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64-root.tar.xz' \
        'https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-arm64-root.tar.xz'
      ;;
    debian)
      local u
      u="$(_resolve_lxc_latest_rootfs 'https://images.linuxcontainers.org/images/debian/bookworm/arm64/default/' 2>/dev/null)"
      [ -n "$u" ] && printf '%s\n' "$u"
      u="$(_resolve_lxc_latest_rootfs 'https://images.linuxcontainers.org/images/debian/trixie/arm64/default/' 2>/dev/null)"
      [ -n "$u" ] && printf '%s\n' "$u"
      ;;
    arch)
      printf '%s\n' \
        'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz'
      ;;
    fedora)
      local u v
      # Fedora 索引页里只有数字版本号目录，挑最新
      v=$(curl -fsSL --max-time 30 'https://images.linuxcontainers.org/images/fedora/' 2>/dev/null \
        | grep -oE 'href="[0-9]+/"' | sed 's/href="//;s|/"||' | sort -n | tail -1)
      if [ -n "$v" ]; then
        u="$(_resolve_lxc_latest_rootfs "https://images.linuxcontainers.org/images/fedora/${v}/arm64/default/" 2>/dev/null)"
        [ -n "$u" ] && printf '%s\n' "$u"
      fi
      ;;
  esac
}

ensure_proot_distro_installed() {
  if command -v proot-distro >/dev/null 2>&1; then
    return 0
  fi
  if [ -x /data/data/com.termux/files/usr/bin/proot-distro ]; then
    return 0
  fi
  echo_warn '未检测到 proot-distro，尝试通过 pkg 自动安装（需要联网）...'
  if [ -x /data/data/com.termux/files/usr/bin/pkg ]; then
    /data/data/com.termux/files/usr/bin/pkg install -y proot-distro >/dev/null 2>&1 || true
  fi
  if [ -x /data/data/com.termux/files/usr/bin/proot-distro ]; then
    echo_info 'proot-distro 已自动安装'
    return 0
  fi
  return 1
}

# 通过 proot-distro 取 rootfs 到 termux 内置目录，再让 auto_migrate 把它搬到 /data/local/chroot
fetch_rootfs_via_proot_distro() {
  local distro="$1"
  local pd_alias="$distro"
  case "$distro" in
    arch) pd_alias='archlinux' ;;
  esac
  local pd_root="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$pd_alias"
  local pd_plugins_dir="/data/data/com.termux/files/usr/etc/proot-distro"
  local pd_default_plugin="$pd_plugins_dir/$pd_alias.sh"
  local pd_override_plugin="$pd_plugins_dir/$pd_alias.override.sh"
  local override_created=0

  ensure_proot_distro_installed || return 1

  if [ -x "$pd_root/bin/sh" ] || [ -x "$pd_root/bin/bash" ]; then
    echo_info "复用 proot-distro 已有 rootfs: $pd_root"
  else
    echo_info "通过 proot-distro 下载 $distro（${pd_alias}）..."
    echo_info "（首次下载较大，跨网慢一些。日志: $LOG_FILE）"

    # 已知问题：debian 等发行版的 distro_setup 会跑 dpkg-reconfigure locales，
    # 在 root+Termux 环境下经常以非 0 退出，导致 proot-distro 触发"失败清理"
    # 把整个 rootfs 目录删除。我们写一个 override 跳过 locales 钩子；rootfs 落
    # 盘后立刻会被我们 auto-migrate 到 ext4 镜像，locales 后续可在容器内补。
    if [ -f "$pd_default_plugin" ] && [ ! -f "$pd_override_plugin" ]; then
      mkdir -p "$pd_plugins_dir" 2>/dev/null || true
      {
        # 透传 TARBALL_URL/SHA256 等元数据，仅替换 distro_setup
        grep -E '^(DISTRO_NAME|DISTRO_COMMENT|TARBALL_URL|TARBALL_SHA256|DISTRO_TYPE)=' "$pd_default_plugin" 2>/dev/null
        echo
        echo '# Override generated by chroot-mcp-safe.sh: skip distro_setup hook'
        echo '# (locales/dpkg-reconfigure failures wipe the rootfs on root+Termux).'
        echo 'distro_setup() { :; }'
      } > "$pd_override_plugin" 2>/dev/null && override_created=1
      [ "$override_created" -eq 1 ] && echo_info "已写入临时 override 跳过 distro_setup: $pd_override_plugin"
    fi

    local install_log="$STATE_DIR/proot-distro-install-${pd_alias}-$(date +%s).log"
    /data/data/com.termux/files/usr/bin/proot-distro install "$pd_alias" 2>&1 | tee "$install_log" >&2
    local rc=${PIPESTATUS[0]}

    # 用完即删 override，避免污染 proot-distro 后续行为
    if [ "$override_created" -eq 1 ] && [ -f "$pd_override_plugin" ]; then
      rm -f "$pd_override_plugin" 2>/dev/null || true
    fi

    if [ -x "$pd_root/bin/sh" ] || [ -x "$pd_root/bin/bash" ]; then
      echo_info "rootfs 已就绪（即便 proot-distro 退出码=$rc）: $pd_root"
    else
      echo_warn "proot-distro install $pd_alias 失败（rc=$rc），日志: $install_log"
      cat <<INFO >&2
排查建议：
  1. 网络是否可达（Github/curl 镜像可能被墙），可换 wifi 或开代理；
  2. 已下载的部分残留可清理: rm -rf $pd_root
  3. 改用「我自己提供URL」，手动下 arm64 rootfs tar 包；
  4. 若上次下载未完成可再次执行该选项，proot-distro 会续传或重试。
INFO
      return 1
    fi
  fi

  # alpine/arch 等可能没有 /bin/bash —— 注入兼容性最小集
  if [ -x "$pd_root/bin/sh" ] && [ ! -x "$pd_root/bin/bash" ]; then
    case "$distro" in
      alpine)
        /data/data/com.termux/files/usr/bin/proot-distro login alpine -- sh -lc 'apk add --no-cache bash' >/dev/null 2>&1 || true
        ;;
      arch)
        /data/data/com.termux/files/usr/bin/proot-distro login archlinux -- sh -lc 'pacman -Sy --noconfirm bash' >/dev/null 2>&1 || true
        ;;
    esac
  fi

  # 设置目标到 termux 内置路径，主流程的 auto_migrate 会搬到 /data/local/chroot/$distro
  TARGET="$pd_root"
  AUTO_MIGRATE=1
  return 0
}

# 通过内置 URL 表直接拉 tar 包到 /data/local/chroot/<distro>
fetch_rootfs_via_builtin_urls() {
  local distro="$1"
  local target_dir="/data/local/chroot/$distro"
  local urls url
  echo_info "正在解析 $distro 最新 rootfs URL..."
  urls="$(get_builtin_rootfs_urls "$distro")"
  if [ -z "$urls" ]; then
    echo_warn "无法解析 $distro 的内置 URL（可能是网络问题）"
    return 1
  fi

  while IFS= read -r url; do
    [ -n "$url" ] || continue
    echo_info "尝试下载: $url"
    rm -rf "$target_dir" 2>/dev/null || true
    if download_rootfs_archive "$url" "$target_dir"; then
      TARGET="$target_dir"
      ROOTFS_EXPLICIT=1
      echo_info "rootfs 已落盘: $target_dir"
      return 0
    fi
    echo_warn "失败，尝试下一候选..."
  done <<EOF
$urls
EOF
  return 1
}

# 用户手输 URL
fetch_rootfs_via_manual_url() {
  local distro="$1" url="$2" target_dir
  [ -n "$url" ] || return 1
  target_dir="/data/local/chroot/$distro"
  rm -rf "$target_dir" 2>/dev/null || true
  if download_rootfs_archive "$url" "$target_dir"; then
    TARGET="$target_dir"
    ROOTFS_EXPLICIT=1
    return 0
  fi
  return 1
}

# 旧 API 保留：保持向后兼容
bootstrap_rootfs_from_termux_source() {
  fetch_rootfs_via_proot_distro "$1"
}

apply_distro_preset() {
  [ -z "$DISTRO_NAME" ] && return 0
  case "$DISTRO_NAME" in
    ubuntu|debian|arch|fedora|alpine) ;;
    *)
      echo "错误: 不支持的 --distro 值: $DISTRO_NAME" >&2
      exit 2
      ;;
  esac

  local image_rootfs="/mnt/chroot-rootfs/$DISTRO_NAME"
  local image_file="/data/local/chroot-images/${DISTRO_NAME}.img"
  local local_rootfs="/data/local/chroot/$DISTRO_NAME"
  local proot_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$DISTRO_NAME"

  [ "$ROOTFS_EXPLICIT" -eq 1 ] && return 0

  if [ -f "$image_file" ]; then
    TARGET="$image_rootfs"
  elif [ -d "$local_rootfs" ]; then
    TARGET="$local_rootfs"
  elif [ -d "$proot_rootfs" ]; then
    TARGET="$proot_rootfs"
  else
    TARGET="$image_rootfs"
  fi
}

find_existing_rootfs() {
  local distro="$1"
  local image_rootfs="/mnt/chroot-rootfs/$distro"
  local image_file="/data/local/chroot-images/${distro}.img"
  local local_rootfs="/data/local/chroot/$distro"
  local proot_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$distro"
  # proot-distro 的 arch 别名是 archlinux
  case "$distro" in
    arch) proot_rootfs="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/archlinux" ;;
  esac

  if [ -f "$image_file" ]; then
    echo "$image_rootfs"
  elif [ -d "$local_rootfs" ] && { [ -x "$local_rootfs/bin/sh" ] || [ -x "$local_rootfs/bin/bash" ]; }; then
    echo "$local_rootfs"
  elif [ -d "$proot_rootfs" ] && { [ -x "$proot_rootfs/bin/sh" ] || [ -x "$proot_rootfs/bin/bash" ]; }; then
    echo "$proot_rootfs"
  else
    echo ""
  fi
}

print_install_guide() {
  local distro="${DISTRO_NAME:-ubuntu}"
  cat <<EOF
[安装建议] 面向“高权限 + 编译能力”优先

推荐优先级:
  1) Ubuntu 24.04 / Debian 12  (兼容性最稳，工具链最全)
  2) Arch Linux                (滚动更新，新工具最快)
  3) Fedora                    (较新编译链)

一、快速拉起rootfs（纯chroot，不依赖proot）
  pkg update -y
  pkg install -y curl tar xz-utils
  su -c 'mkdir -p /data/local/chroot/$distro'
  # 将 ROOTFS_URL 替换成你要的发行版 rootfs 压缩包地址（arm64）
  ROOTFS_URL="<替换为${distro} rootfs tar包URL>"
  su -c "cd /data/local/chroot/$distro && curl -L \"\$ROOTFS_URL\" | tar -xJf -"
  su -c 'chown root:root /data/local/chroot/$distro && chmod 755 /data/local/chroot/$distro'
  su -c ./start-ubuntu-full.sh --permissive --rootfs /data/local/chroot/$distro --no-proot-fallback

  交互模式下若URL留空：脚本会自动尝试使用 Termux 内置源（proot-distro）下载同名发行版，仅用于取rootfs。

二、进入后安装常用编译工具（按发行版）
  Debian/Ubuntu:
    apt update && apt install -y build-essential clang lld cmake ninja-build git pkg-config python3 python3-pip gdb lldb rustc cargo golang

  Arch:
    pacman -Syu --noconfirm base-devel clang lld cmake ninja git pkgconf python python-pip gdb lldb rust go

  Fedora:
    dnf groupinstall -y "Development Tools" && dnf install -y clang lld cmake ninja-build git pkgconf-pkg-config python3 python3-pip gdb lldb rust cargo golang

  Alpine:
    apk add --no-cache build-base clang lld cmake ninja git pkgconf python3 py3-pip gdb lldb rust cargo go
EOF
}

show_wizard_help() {
  cat <<'EOF'

  ========================================================================
   chroot-mcp-safe 帮助说明（通俗版）
  ========================================================================

  ── 状态图标含义 ──────────────────────────────────────────────────────
   ●  running   后台 sshd 已经起来了，可以用 SFTP/SSH 连接
                （MT 管理器、VS Code Remote 等会用到）
   ◐  live(fg)  你已经在终端里 chroot 进了容器、开着前台 shell；
                但没有跑后台 sshd。退出这个 shell 容器就停了。
                （此时不能 SFTP，因为没监听端口）
   ○  ready     已经下载或解压好了，但当前没在跑
   ·  absent    根本还没装这个发行版

   pid    = 后台 sshd / 前台 shell 的进程号（kill 用得上）
   port   = 后台 sshd 监听的端口（22 太冲突，默认 8023+）
   store  = image 表示用 ext4 镜像（可扩容/可整存整删）
            dir   表示直接是目录（proot-distro 风格）

  ── 操作菜单逐项解释 ──────────────────────────────────────────────────

   [1] 进入容器
       打开一个新终端进入已经在跑的容器内部 shell。
       适用：状态是 ● running 或 ◐ live(fg) 时；
       不适用：absent / ready 时（请改用 [2]）。

   [2] 启动 / 安装容器
       下载或安装一个发行版，并把它跑起来（含后台 sshd）。
       第一次用某发行版选这个；以后只想再启动也走这里。
       下载源：proot-distro（推荐，稳定）/ LXC index（更新快）。

   [3] 终止容器
       安全停掉后台 sshd 容器：先 sync 落盘 → 杀进程 →
       remount-readonly → umount → losetup -d。
       数据安全收尾，比直接 kill 干净得多。
       前台 live(fg) 不在这里处理，直接 exit 那个 shell 即可。

   [4] 扩容镜像
       把 ext4 镜像从原大小（比如 20G）扩大到目标大小（比如 50G）。
       会自动：
         - 检测有没有进程占用（daemon 或 live(fg)）
         - 提示你确认后安全停止
         - e2fsck 校验 → 文件 truncate 增大 → resize2fs 扩展
       注意：只支持扩大，不能缩小（缩小风险高）。

   [5] 查看占用空间
       列出每个发行版在磁盘上吃了多少：
         - 镜像文件大小（image 模式）
         - 容器内已用 / 可用空间
         - rootfs 目录大小（dir 模式）
       手机存储紧张时先看这里。

   [6] 删除已下载容器
       彻底删除指定发行版的镜像 + rootfs 目录 + 状态文件。
       适合反复测试下载/安装功能时清场。
       会要求二次确认，不会误删别的。

   [7] 紧急同步刷盘
       手动把所有挂着的容器内存数据刷写到磁盘。
       手机要没电了 / 怀疑要异常重启 / 拔U盘前 — 跑这个。
       它会：
         - 对每个挂载点 sync
         - 调用 fsync 强制落盘
         - 不停容器，只保证数据安全
       平时不用每次都跑，正常 [3] 终止已经包含同步。

   [8] 查看安装建议
       打印这个发行版常用编译/开发工具的一键安装命令
       （build-essential / clang / cmake / rust / go / python 等）。
       新装容器后照着复制即可。

   [9] 查看帮助/说明
       就是当前这一页。

  ── 常见问题 ─────────────────────────────────────────────────────────

   Q: 为啥 SFTP 连不上 8024？
   A: 看状态。如果是 ◐ live(fg)，说明只有前台 shell 没后台 sshd，
      退出 shell 后选 [2] 重新启动（会自动起 sshd）即可。
      如果是 ● running 还连不上，检查端口是不是被占（脚本会自动避让），
      或者 ssh 客户端 -p 端口写错了。

   Q: 扩容时提示 "live(fg)"？
   A: 你之前在终端里手动 chroot 进过容器，那个 shell 还开着。
      退出那个 shell（exit / Ctrl-D），或者让脚本帮你安全终止。

   Q: 突然断电会不会丢数据？
   A: 已启用 ext4 journal + sync barrier。日常断电只丢最后几秒未刷盘
      的数据，不会损坏文件系统。极端情况下重新挂载会自动 e2fsck 修复。
      重要操作前可以手动跑 [7] 紧急同步刷盘。

   Q: image 和 dir 模式有啥区别？
   A: image = 单个 .img 文件（loop 挂载），整存整删、可扩容、性能好；
      dir   = 直接是目录树（proot-distro 风格），方便随时编辑文件，
              但 inode 多、删除慢、不能扩容（受限于宿主分区）。

  ========================================================================

EOF
}

interactive_wizard() {
  local action distro url existing_rootfs stop_distro stop_confirm image_size_input resize_confirm
  local enter_distro enter_file enter_rootfs enter_pids enter_pid enter_target
  local source_choice advanced advanced_choice
  local install_disto rootfs_input

  show_all_containers_status

  action=$(choose_option "选择操作" \
    "进入容器" \
    "启动 / 安装容器" \
    "终止容器" \
    "扩容镜像" \
    "查看占用空间" \
    "删除已下载容器" \
    "紧急同步刷盘" \
    "查看安装建议" \
    "查看帮助/说明")

  case "$action" in
    "查看帮助/说明")
      show_wizard_help
      exit 0
      ;;

    "查看占用空间")
      show_all_container_sizes
      exit 0
      ;;

    "紧急同步刷盘")
      emergency_sync_all
      exit 0
      ;;

    "删除已下载容器")
      local rm_distro rm_confirm
      rm_distro=$(choose_option "删除哪个发行版" ubuntu debian arch fedora alpine)
      DISTRO_NAME="$rm_distro"
      remove_distro_assets "$rm_distro"
      exit $?
      ;;

    "进入容器")
      enter_distro=$(choose_option "进入哪个发行版" ubuntu debian arch fedora alpine)
      DISTRO_NAME="$enter_distro"
      apply_distro_preset
      enter_file="$STATE_DIR/chroot-mcp-daemon-${enter_distro}.info"
      enter_rootfs="$(find_existing_rootfs "$enter_distro")"
      enter_pid=""
      enter_target=""

      if [ -f "$enter_file" ]; then
        DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
        if read_daemon_info "$enter_file" \
           && pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$enter_rootfs}"; then
          enter_pid="${DAEMON_SSHD_PID}"
          enter_target="${DAEMON_TARGET:-$enter_rootfs}"
        else
          rm -f "$enter_file" 2>/dev/null || true
        fi
      fi

      if [ -z "$enter_pid" ] && [ -n "$enter_rootfs" ]; then
        enter_pids="$(collect_pids_by_root_prefix "$enter_rootfs")"
        if [ -n "$enter_pids" ]; then
          enter_pid="$(first_pid_from_list "$enter_pids")"
          enter_target="$enter_rootfs"
        fi
      fi

      [ -n "$enter_pid" ] || { echo "错误: ${enter_distro} 没有运行中的容器，请改选 \"启动 / 安装容器\"" >&2; exit 2; }
      [ -n "$enter_target" ] || enter_target="$enter_rootfs"
      enter_existing_container "$enter_pid" "$enter_target"
      exit $?
      ;;

    "终止容器")
      stop_distro=$(choose_option "终止哪个发行版" ubuntu debian arch fedora alpine)
      DISTRO_NAME="$stop_distro"
      apply_distro_preset
      local stop_file="$STATE_DIR/chroot-mcp-daemon-${stop_distro}.info"
      local stop_rootfs stop_pids stop_pid stop_target
      stop_rootfs="$(find_existing_rootfs "$stop_distro")"

      # 路径 A：有 daemon-info（后台 sshd 模式）
      if [ -f "$stop_file" ]; then
        DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
        if read_daemon_info "$stop_file"; then
          if pid_root_matches_target "${DAEMON_SSHD_PID:-}" "${DAEMON_TARGET:-$stop_rootfs}"; then
            printf '\n  [后台模式]\n  发行版: %s\n  PID:    %s\n  Port:   %s\n  Target: %s\n  起始:   %s\n\n' \
              "$stop_distro" "${DAEMON_SSHD_PID}" "${DAEMON_PORT:-?}" "${DAEMON_TARGET:-?}" "${DAEMON_STARTED_AT:-?}" >&2
            stop_confirm=$(choose_option "确认终止并卸载?" "确认" "取消")
            if [ "$stop_confirm" = "确认" ]; then
              daemon_stop || { echo "[stop] 终止失败，请检查日志" >&2; exit 1; }
              echo "[stop] ${stop_distro} 已安全终止" >&2
            else
              echo "已取消" >&2
            fi
            exit 0
          else
            echo "[stop] 状态文件存在但 pid 已结束，清理: $stop_file" >&2
            rm -f "$stop_file" 2>/dev/null
          fi
        else
          echo "[stop] 无法读取状态文件，清理: $stop_file" >&2
          rm -f "$stop_file" 2>/dev/null
        fi
      fi

      # 路径 B：无 daemon-info，但 /proc 里仍有 chroot 进程（live(fg) 或残留）
      if [ -n "$stop_rootfs" ]; then
        stop_pids="$(collect_pids_by_root_prefix "$stop_rootfs")"
      fi
      if [ -n "${stop_pids:-}" ]; then
        stop_pid="$(first_pid_from_list "$stop_pids")"
        stop_target="$stop_rootfs"
        printf '\n  [前台/残留]\n  发行版: %s\n  PIDs:   %s\n  Target: %s\n\n' \
          "$stop_distro" "$stop_pids" "$stop_target" >&2
        stop_confirm=$(choose_option "确认强制终止这些进程并卸载?" "确认" "取消")
        if [ "$stop_confirm" = "确认" ]; then
          stop_runtime_by_pid_target "$stop_pid" "$stop_target" "" "live(fg)" \
            || { echo "[stop] 终止前台/残留容器失败" >&2; exit 1; }
          echo "[stop] ${stop_distro} 前台进程已终止并卸载" >&2
        else
          echo "已取消" >&2
        fi
        exit 0
      fi

      echo "${stop_distro} 未运行（无后台状态文件，也无前台进程）" >&2
      exit 0
      ;;

    "扩容镜像")
      distro=$(choose_option "扩容哪个发行版的镜像" ubuntu debian arch fedora alpine)
      DISTRO_NAME="$distro"
      apply_distro_preset
      set_image_paths
      [ -f "$IMAGE_FILE" ] || { echo "错误: ${distro} 没有镜像: $IMAGE_FILE" >&2; exit 2; }
      image_size_input=$(ask_text "目标大小GB（例如 50）")
      [ -z "$image_size_input" ] && { echo "错误: 未提供大小" >&2; exit 2; }
      [[ "$image_size_input" =~ ^[0-9]+$ ]] && [ "$image_size_input" -gt 0 ] \
        || { echo "错误: 必须是正整数GB" >&2; exit 2; }
      IMAGE_SIZE_GB="$image_size_input"
      resize_confirm=$(choose_option "将停止容器并执行 e2fsck/resize2fs，继续?" "确认" "取消")
      [ "$resize_confirm" = "确认" ] || { echo "已取消" >&2; exit 0; }
      RESIZE_IMAGE_MODE=1
      return 0
      ;;

    "查看安装建议")
      distro=$(choose_option "查看哪个发行版的建议" ubuntu debian arch fedora alpine)
      DISTRO_NAME="$distro"
      PRINT_INSTALL_GUIDE=1
      return 0
      ;;

    "启动 / 安装容器")
      ;;
  esac

  # ============================================
  # 启动 / 安装容器（合并了原 "启动已存在rootfs" 和 "下载rootfs后启动"）
  # ============================================
  distro=$(choose_option "选择发行版" ubuntu debian arch fedora alpine)
  DISTRO_NAME="$distro"
  apply_distro_preset
  existing_rootfs="$(find_existing_rootfs "$distro")"

  if [ -n "$existing_rootfs" ]; then
    TARGET="$existing_rootfs"
    echo "[info] 复用已有 rootfs: $TARGET" >&2
  else
    # rootfs 不存在 → 进入下载流程
    source_choice=$(choose_option "${distro} 还未安装，选择下载方式" \
      "proot-distro（推荐，最稳）" \
      "内置URL直拉" \
      "我自己提供URL")

    case "$source_choice" in
      "proot-distro（推荐，最稳）")
        ensure_proot_distro_installed || { echo "错误: proot-distro 不可用，请用其它方式" >&2; exit 2; }
        fetch_rootfs_via_proot_distro "$distro" \
          || { echo "错误: proot-distro 拉取 ${distro} 失败" >&2; exit 2; }
        ;;
      "内置URL直拉")
        fetch_rootfs_via_builtin_urls "$distro" \
          || { echo "错误: 内置URL均无法获取 ${distro} rootfs，请改用 proot-distro" >&2; exit 2; }
        ;;
      "我自己提供URL")
        url=$(ask_text "${distro} arm64 rootfs tar/tar.xz/tar.gz 下载URL")
        fetch_rootfs_via_manual_url "$distro" "$url" \
          || { echo "错误: 下载/解压失败" >&2; exit 2; }
        ;;
    esac
    AUTO_MIGRATE_IMAGE=1   # 默认搬到 ext4 镜像
  fi

  # 端口选择
  local default_port port_input
  default_port="$(get_default_distro_sshd_port)"
  port_input=$(ask_text "sshd 端口（留空使用 ${default_port}，被占用会自动重选）")
  if [ -n "$port_input" ]; then
    [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ] \
      || { echo "错误: 端口必须是 1-65535 整数" >&2; exit 2; }
    SSHD_PORT_EXPLICIT="$port_input"
  fi

  # 高级选项默认折叠
  PERMISSIVE=1
  RO_DATA=0
  SAFE_MODE=0
  FALLBACK_PROOT=0

  # 运行模式：默认后台 sshd（可 SFTP/SSH）；可切换前台交互 shell
  local run_mode_choice
  run_mode_choice=$(choose_option "运行模式" \
    "后台 sshd（推荐：可 SFTP/SSH）" \
    "前台 shell（直接进入容器，退出即停）")
  if [ "$run_mode_choice" = "后台 sshd（推荐：可 SFTP/SSH）" ]; then
    DAEMON_MODE=1
  else
    DAEMON_MODE=0
  fi

  advanced=$(choose_option "高级选项" "保持默认（推荐）" "展开调整")
  if [ "$advanced" = "展开调整" ]; then
    advanced_choice=$(choose_option "SELinux" "permissive（推荐）" "保持当前")
    [ "$advanced_choice" = "保持当前" ] && PERMISSIVE=0

    advanced_choice=$(choose_option "/data 挂载" "读写（默认）" "只读")
    [ "$advanced_choice" = "只读" ] && RO_DATA=1

    advanced_choice=$(choose_option "失败时回退 proot?" "否（纯chroot，推荐）" "是（兼容）")
    [ "$advanced_choice" = "是（兼容）" ] && FALLBACK_PROOT=1

    local pwd_input
    pwd_input=$(ask_text "root 密码（默认 123456，留空使用默认）")
    [ -n "$pwd_input" ] && MCP_ROOT_PASSWORD="$pwd_input"

    if [ "$AUTO_MIGRATE_IMAGE" -eq 1 ]; then
      image_size_input=$(ask_text "镜像大小GB（默认20，留空使用默认）")
      if [ -n "$image_size_input" ]; then
        [[ "$image_size_input" =~ ^[0-9]+$ ]] && [ "$image_size_input" -gt 0 ] \
          || { echo "错误: 必须是正整数GB" >&2; exit 2; }
        IMAGE_SIZE_GB="$image_size_input"
      fi
    fi
  fi
}

if [ "$ORIG_ARGC" -eq 0 ]; then
  DISTRO_NAME="${DISTRO_NAME:-ubuntu}"
  if [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE_MODE=1
  else
    existing_rootfs="$(find_existing_rootfs "$DISTRO_NAME")"
    if [ -n "$existing_rootfs" ]; then
      TARGET="$existing_rootfs"
      PERMISSIVE=1
      if [ "${AUTOBOOT_NOTICE_SHOWN:-0}" -eq 0 ]; then
        echo "快捷启动: 已复用现有rootfs: $TARGET (默认 --permissive)" >&2
        export AUTOBOOT_NOTICE_SHOWN=1
      fi
    fi
  fi
fi

if [ "$INTERACTIVE_MODE" -eq 1 ]; then
  interactive_wizard
  if [ "$ORIG_ARGC" -eq 0 ]; then
    ORIG_ARGS=()
    [ -n "${DISTRO_NAME:-}" ] && ORIG_ARGS+=(--distro "$DISTRO_NAME")
    [ -n "${TARGET:-}" ] && ORIG_ARGS+=(--rootfs "$TARGET")
    [ -n "${IMAGE_SIZE_GB:-}" ] && ORIG_ARGS+=(--image-size-gb "$IMAGE_SIZE_GB")
    [ -n "${SSHD_PORT_EXPLICIT:-}" ] && ORIG_ARGS+=(--sshd-port "$SSHD_PORT_EXPLICIT")
    [ -n "${MCP_ROOT_PASSWORD:-}" ] && [ "${MCP_ROOT_PASSWORD}" != "123456" ] && ORIG_ARGS+=(--root-password "$MCP_ROOT_PASSWORD")
    [ "$RESIZE_IMAGE_MODE" -eq 1 ] && ORIG_ARGS+=(--resize-image)
    [ "$AUTO_MIGRATE_IMAGE" -eq 1 ] && ORIG_ARGS+=(--auto-migrate-image)
    [ "$PERMISSIVE" -eq 1 ] && ORIG_ARGS+=(--permissive)
    [ "$RO_DATA" -eq 1 ] && ORIG_ARGS+=(--ro-data)
    if [ "$SAFE_MODE" -eq 1 ]; then
      ORIG_ARGS+=(--safe)
    else
      ORIG_ARGS+=(--full-access)
    fi
    [ "$FALLBACK_PROOT" -eq 1 ] && ORIG_ARGS+=(--proot-fallback)
    [ "$DAEMON_MODE" -eq 1 ] && ORIG_ARGS+=(--daemon)
    [ "$PRINT_INSTALL_GUIDE" -eq 1 ] && ORIG_ARGS+=(--print-install)
  fi
else
  apply_distro_preset
fi
if [ "$STATUS_MODE" -eq 1 ]; then
  daemon_status
  exit $?
fi

if [ "$EMERGENCY_SYNC_MODE" -eq 1 ]; then
  emergency_sync_all
  exit $?
fi

if [ "$SIZE_MODE" -eq 1 ]; then
  show_all_container_sizes
  exit 0
fi

if [ "$REMOVE_MODE" -eq 1 ]; then
  if [ -z "${DISTRO_NAME:-}" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      DISTRO_NAME=$(choose_option "删除哪个发行版" ubuntu debian arch fedora alpine)
    else
      echo "错误: --remove 需要 --distro <名称> 或交互式 TTY" >&2
      exit 2
    fi
  fi
  remove_distro_assets "$DISTRO_NAME"
  exit $?
fi

if [ "$STOP_MODE" -eq 1 ]; then
  daemon_stop
  exit $?
fi

if [ "$MIGRATE_MODE" -eq 1 ]; then
  migrate_rootfs
  exit $?
fi

if [ "$MIGRATE_IMAGE_MODE" -eq 1 ]; then
  migrate_rootfs_to_image
  exit $?
fi

if [ "$RESIZE_IMAGE_MODE" -eq 1 ]; then
  set_image_paths
  resize_rootfs_image
  exit $?
fi

auto_migrate_if_needed
check_residual_state
auto_migrate_image_if_needed

if [ "$PRINT_INSTALL_GUIDE" -eq 1 ]; then
  print_install_guide
  exit 0
fi


# ==============================================
# 通用挂载辅助
# ==============================================
is_mounted() {
  local dst="$1"
  grep -Fq " $dst " /proc/self/mountinfo
}

get_mount_opts() {
  local dst="$1"
  awk -v p="$dst" '$2==p {print $4; exit}' /proc/mounts
}

# 读取 mountinfo optional fields（"-" 前的字段）判断传播属性
get_propagation() {
  local dst="$1"
  local line
  line=$(grep -F " $dst " /proc/self/mountinfo | tail -1)
  [ -z "$line" ] && { echo "unknown"; return; }

  local optional
  optional=$(echo "$line" | awk -F' - ' '{print $1}' | cut -d' ' -f7-)
  case "$optional" in
    *shared:*) echo "shared" ;;
    *master:*) echo "slave" ;;
    *) echo "private" ;;
  esac
}

# ==============================================
# 预检 / SELinux / chroot 兼容
# ==============================================
check_cmds() {
  local missing=0
  local cmds=(unshare mount umount awk grep readlink)
  local c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { echo_warn "缺少命令: $c"; missing=1; }
  done
  [ ! -x "$CHROOT_BIN" ] && { echo_warn "缺少可用chroot命令: $CHROOT_BIN"; missing=1; }
  [ "$missing" -eq 1 ] && echo_err "依赖命令不完整，无法安全执行"
}

check_selinux() {
  if [ -x /system/bin/getenforce ]; then
    ORIGINAL_SELINUX_STATE=$(getenforce)
    echo_info "当前SELinux状态: $ORIGINAL_SELINUX_STATE"

    if [ "$PERMISSIVE" -eq 1 ]; then
      echo_warn "⚠️ 临时切换SELinux为Permissive，退出自动恢复"
      setenforce 0 2>/dev/null || echo_warn "setenforce 0 失败，请确认KernelSU root策略"
    elif [ "$ORIGINAL_SELINUX_STATE" = "Enforcing" ]; then
      echo_warn "SELinux Enforcing 可能限制部分路径写入（可加 --permissive）"
    fi
  fi
}

preflight_chroot() {
  local owner
  owner=$(stat -c "%u:%g" "$TARGET" 2>/dev/null || echo "unknown")
  [ "$owner" != "0:0" ] && echo_warn "rootfs目录属主不是root($owner)，可能导致chroot被拒绝"
  # alpine 等 busybox 发行版只有 /bin/sh（symlink → /bin/busybox），没有 bash。
  # 注意：从宿主侧执行 -x 会跟随软链解析到宿主路径而误判，这里需要检查 rootfs
  # 内部的真实文件（busybox 本体或非软链 sh）。
  has_shell_in_rootfs() {
    local p
    for p in /bin/sh /usr/bin/sh /bin/bash /usr/bin/bash /bin/dash /usr/bin/dash /bin/ash /usr/bin/ash /bin/busybox /usr/bin/busybox /sbin/busybox; do
      if [ -L "$TARGET$p" ] || [ -x "$TARGET$p" ]; then
        return 0
      fi
    done
    return 1
  }
  if ! has_shell_in_rootfs; then
    echo_err "rootfs缺少可执行 /bin/sh 或 /bin/bash，请检查你下载/解压的rootfs是否完整"
  fi
  if [ ! -e "$TARGET/bin/bash" ] && [ ! -e "$TARGET/usr/bin/bash" ]; then
    echo_warn "rootfs 没有 /bin/bash（典型 alpine/busybox 系），将退回到 /bin/sh"
  fi

  # 仅检测 chroot syscall 能力，避免在完成大量挂载后才失败
  local preflight_err=""
  preflight_err=$("$CHROOT_BIN" / /system/bin/sh -c "exit 0" 2>&1 1>/dev/null)
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    local seccomp_mode
    local no_new_privs
    local selctx
    seccomp_mode=$(awk '/^Seccomp:/ {print $2}' /proc/self/status 2>/dev/null || echo "unknown")
    no_new_privs=$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || echo "unknown")
    # /proc/self/attr/current 在部分内核会包含结尾 NUL，直接命令替换会触发
    # "ignored null byte in input" 警告；这里显式剔除 NUL，避免误报噪音。
    selctx=$(tr -d '\000' < /proc/self/attr/current 2>/dev/null || echo "unknown")
    preflight_err=$(echo "$preflight_err" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [ -z "$preflight_err" ] && preflight_err="(无stderr输出)"
    echo_warn "预检诊断: seccomp=$seccomp_mode no_new_privs=$no_new_privs selinux_ctx=$selctx chroot_stderr=$preflight_err"
    if echo "$preflight_err" | grep -q "cannot change root directory to '/': Operation not permitted"; then
      if [ "$FALLBACK_PROOT" -eq 1 ] && command -v proot-distro >/dev/null 2>&1; then
        USE_PROOT_FALLBACK=1
        echo_warn "检测到当前su上下文完全禁止chroot(/也被拒绝)，将自动回退到 proot-distro login ubuntu"
        return 0
      fi
      echo_err "预检失败：当前su上下文(如 u:r:ksu:s0)完全禁止chroot syscall（连 chroot / 都被拒绝）。请改用 adb shell su 0 / 更高权限shell；如你接受兼容模式，可加 --proot-fallback。"
    fi
    if [ "$seccomp_mode" = "2" ]; then
      echo_err "预检失败：当前进程受seccomp过滤(模式2)，chroot syscall被拦截。请改用不受APP seccomp限制的root shell（如 adb shell su 0）或改用proot。"
    fi
    if [ -x /system/bin/getenforce ] && [ "$(getenforce)" = "Enforcing" ] && [ "$PERMISSIVE" -eq 0 ]; then
      echo_err "预检失败：SELinux=Enforcing时chroot被拒绝，请使用 --permissive"
    fi
    if [ "$FALLBACK_PROOT" -eq 1 ] && command -v proot-distro >/dev/null 2>&1; then
      USE_PROOT_FALLBACK=1
      echo_warn "当前环境不允许chroot syscall(退出码$rc)，将自动回退到 proot-distro login ubuntu"
      return 0
    fi
    echo_err "预检失败：当前环境不允许chroot syscall(退出码$rc)，请检查KernelSU策略/SELinux/seccomp"
  fi
}

run_proot_fallback() {
  echo_warn "已进入兼容回退模式（proot），非原生chroot能力模型"
  echo_info "执行: proot-distro login ubuntu"
  exec proot-distro login ubuntu
}

prepare_chroot_compat() {
  local run_parts_wrapper="$TARGET/usr/local/bin/run-parts"
  local pidof_wrapper="$TARGET/usr/local/bin/pidof"

  if [ ! -x "$TARGET/usr/bin/run-parts" ] && [ ! -x "$TARGET/bin/run-parts" ]; then
    mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
    cat > "$run_parts_wrapper" <<'EOF'
#!/bin/sh
# minimal run-parts fallback for slim rootfs: execute executable files in directory
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) dir="$arg" ;;
  esac
done
[ -n "${dir:-}" ] || exit 0
[ -d "$dir" ] || exit 0
for f in "$dir"/*; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || continue
  "$f"
done
EOF
    chmod 755 "$run_parts_wrapper" 2>/dev/null || true
    echo_warn "rootfs缺少 run-parts，已注入最小兼容实现: /usr/local/bin/run-parts"
  fi

  if [ ! -x "$TARGET/usr/bin/pidof" ] && [ ! -x "$TARGET/bin/pidof" ] && [ ! -x "$TARGET/sbin/pidof" ]; then
    if [ -x /system/bin/pidof ]; then
      mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
      cat > "$pidof_wrapper" <<'EOF'
#!/bin/sh
exec /system/bin/pidof "$@"
EOF
      chmod 755 "$pidof_wrapper" 2>/dev/null || true
      echo_warn "rootfs缺少 pidof，已注入兼容包装器: /usr/local/bin/pidof -> /system/bin/pidof"
    elif [ -x /system/bin/toybox ]; then
      mkdir -p "$TARGET/usr/local/bin" 2>/dev/null || true
      cat > "$pidof_wrapper" <<'EOF'
#!/bin/sh
exec /system/bin/toybox pidof "$@"
EOF
      chmod 755 "$pidof_wrapper" 2>/dev/null || true
      echo_warn "rootfs缺少 pidof，已注入兼容包装器: /usr/local/bin/pidof -> /system/bin/toybox pidof"
    else
      echo_warn "rootfs缺少 pidof，且宿主 /system/bin/pidof 不存在"
    fi
  fi
}

# ==============================================
# sshd 准备 / chroot 执行与诊断
# ==============================================
_port_config_file() {
  echo "$PORT_CONFIG_DIR/$(get_rootfs_name).port"
}

_is_valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

_port_in_use() {
  local port="$1"
  [ -n "$port" ] || return 1
  # ss / netstat 任一可用即可；Android toybox netstat 没 -p 也能 grep
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}\$" -q && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}\$" -q && return 0
  fi
  # 兜底: bash /dev/tcp 探测
  if (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    return 0
  fi
  return 1
}

# 端口分配优先级:
#   1. 命令行 --sshd-port=N 指定
#   2. 持久化文件 $PORT_CONFIG_DIR/<distro>.port 中保存的端口（如未冲突直接复用）
#   3. 发行版默认端口（如未冲突）
#   4. 8023..8079 顺序扫
#   5. 49152..65000 内随机三次
# get_default_distro_sshd_port 已在文件顶部定义

resolve_sshd_port() {
  local distro_default=""
  local saved=""
  local explicit="${SSHD_PORT_EXPLICIT:-}"
  local pcfg
  pcfg="$(_port_config_file)"

  if _is_valid_port "$explicit"; then
    if _port_in_use "$explicit"; then
      echo_warn "指定端口 $explicit 已被占用，将自动选择空闲端口"
    else
      echo "$explicit"
      return 0
    fi
  fi

  if [ -f "$pcfg" ]; then
    saved=$(awk 'NR==1{print $1}' "$pcfg" 2>/dev/null)
    if _is_valid_port "$saved" && ! _port_in_use "$saved"; then
      echo "$saved"
      return 0
    fi
  fi

  distro_default="$(get_default_distro_sshd_port)"
  if _is_valid_port "$distro_default" && ! _port_in_use "$distro_default"; then
    echo "$distro_default"
    return 0
  fi

  local p
  for p in $(seq 8023 8079); do
    _port_in_use "$p" || { echo "$p"; return 0; }
  done

  local i rnd
  i=0
  while [ "$i" -lt 12 ]; do
    rnd=$(( 49152 + RANDOM % 15848 ))
    if ! _port_in_use "$rnd"; then
      echo "$rnd"
      return 0
    fi
    i=$((i+1))
  done

  echo_err "无法找到可用 sshd 端口"
}

persist_sshd_port() {
  local port="$1"
  local pcfg
  pcfg="$(_port_config_file)"
  _is_valid_port "$port" || return 1
  echo "$port" > "$pcfg" 2>/dev/null || true
}

_mcp_drop_in_path() {
  echo "$TARGET/etc/ssh/sshd_config.d/99-mcp.conf"
}

_mcp_main_includes_dropin_dir() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  [ -f "$cfg" ] || return 1
  awk '
    /^[[:space:]]*#/ {next}
    tolower($1)=="include" {
      for (i=2; i<=NF; i++) if ($i ~ /sshd_config\.d/) { found=1; exit }
    }
    END { exit (found?0:1) }
  ' "$cfg"
}

ensure_rootfs_sshd_dropin() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  local drop_dir="$TARGET/etc/ssh/sshd_config.d"
  local drop="$(_mcp_drop_in_path)"
  local want_port

  want_port="$(resolve_sshd_port)"
  [ -n "$want_port" ] || echo_err "端口分配失败"
  ROOTFS_SSHD_PORT="$want_port"
  persist_sshd_port "$want_port"

  mkdir -p "$TARGET/etc/ssh" "$drop_dir" 2>/dev/null || true

  # 部分发行版（Debian 12+ 等）apt 安装 openssh-server 时 dpkg 留下样例
  # /usr/share/openssh/sshd_config，但不会自动放到 /etc/ssh。这里兜底拷贝。
  if [ ! -f "$cfg" ]; then
    local sample
    for sample in \
      "$TARGET/usr/share/openssh/sshd_config" \
      "$TARGET/etc/ssh/sshd_config.dpkg-dist" \
      "$TARGET/usr/share/doc/openssh-server/examples/sshd_config"; do
      if [ -f "$sample" ]; then
        cp -a "$sample" "$cfg" && {
          echo_info "已从样例还原 sshd_config: $sample"
          break
        }
      fi
    done
  fi
  if [ ! -f "$cfg" ]; then
    cat > "$cfg" <<'EOF'
# Generated by chroot-mcp-safe (rootfs has no sshd_config sample)
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
    chmod 644 "$cfg" 2>/dev/null || true
    echo_warn "rootfs 缺失 sshd_config，已写入最小可用配置"
  fi

  # 一次性把脏的主配置里的 BEGIN/END 块移除（历史遗留），不再回写
  if grep -q '^# BEGIN chroot-mcp-safe sshd$' "$cfg" 2>/dev/null; then
    cp -an "$cfg" "${cfg}.mcp.bak" 2>/dev/null || true
    local tmp
    tmp=$(mktemp "$STATE_DIR/sshd_config.XXXXXX") || return 1
    sed '/^# BEGIN chroot-mcp-safe sshd$/,/^# END chroot-mcp-safe sshd$/d' "$cfg" > "$tmp"
    cat "$tmp" > "$cfg"
    rm -f "$tmp" 2>/dev/null || true
    echo_info "已从主 sshd_config 移除历史 BEGIN/END 块（迁移到 drop-in）"
  fi

  # 写入 drop-in 文件（每次启动幂等覆盖，主配置文件保持不动）
  # 注意：Subsystem sftp 已在主配置中定义（debian/ubuntu 默认即有），
  # drop-in 里再写一行会被 sshd 拒绝："Subsystem 'sftp' already defined"。
  cat > "$drop" <<EOF
# Generated by chroot-mcp-safe (do not edit; will be overwritten)
Port ${want_port}
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
  chmod 644 "$drop" 2>/dev/null || true

  # 检查主配置是否已定义 sftp Subsystem；若无则补一行（确保 SFTP 可用）
  if ! grep -qE '^[[:space:]]*Subsystem[[:space:]]+sftp\b' "$cfg" 2>/dev/null; then
    printf '\nSubsystem sftp internal-sftp\n' >> "$cfg"
    echo_info "主 sshd_config 缺少 Subsystem sftp，已追加 internal-sftp"
  fi
  echo_info "已写入 sshd drop-in: /etc/ssh/sshd_config.d/99-mcp.conf (Port ${want_port})"

  # 主配置如果没 Include 习惯（极少见的发行版），追加一行 Include 而不是覆盖
  if ! _mcp_main_includes_dropin_dir; then
    cp -an "$cfg" "${cfg}.mcp.bak" 2>/dev/null || true
    if ! grep -q '^# chroot-mcp-safe: include drop-in$' "$cfg" 2>/dev/null; then
      printf '\n# chroot-mcp-safe: include drop-in\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$cfg"
      echo_info "已为 sshd_config 追加 Include /etc/ssh/sshd_config.d/*.conf"
    fi
  fi
}

# 兼容旧调用名：现在两个旧函数都收敛到 drop-in 写入
ensure_rootfs_sshd_port()   { ensure_rootfs_sshd_dropin; }
ensure_rootfs_sshd_access() { ensure_rootfs_sshd_dropin; }

# 设置 root 密码为预约定值（默认 123456，可由 MCP_ROOT_PASSWORD 环境变量覆盖）
ensure_rootfs_root_password() {
  local password="${MCP_ROOT_PASSWORD:-123456}"
  local marker_dir="$TARGET/var/lib/chroot-mcp"
  local marker="$marker_dir/root-password-set"

  mkdir -p "$marker_dir" 2>/dev/null || true
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$password" ]; then
    return 0
  fi

  # 通过 chroot 内执行 chpasswd / busybox passwd 设定密码
  local shell_path
  shell_path="$(get_rootfs_chroot_shell)"
  local set_cmd="
    if command -v chpasswd >/dev/null 2>&1; then
      printf 'root:%s\n' '$password' | chpasswd
    elif command -v busybox >/dev/null 2>&1 && busybox passwd 2>&1 | head -1 | grep -qi password; then
      printf '%s\n%s\n' '$password' '$password' | busybox passwd root
    elif command -v passwd >/dev/null 2>&1; then
      printf '%s\n%s\n' '$password' '$password' | passwd root 2>/dev/null
    else
      echo no_chpasswd
      exit 12
    fi
  "
  if HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c "$set_cmd" >/dev/null 2>&1; then
    printf '%s' "$password" > "$marker" 2>/dev/null || true
    chmod 600 "$marker" 2>/dev/null || true
    echo_info "已设定 root 密码 (用户名: root, 密码: ${password})"
  else
    echo_warn "root 密码设置失败（rootfs 可能缺 chpasswd/passwd），可手动 chroot 后执行 'echo root:${password} | chpasswd'"
  fi
}

get_rootfs_sshd_port() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  local drop="$(_mcp_drop_in_path)"
  local port=""

  if [ -f "$drop" ]; then
    port=$(awk '
      /^[[:space:]]*#/ {next}
      tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
    ' "$drop" 2>/dev/null)
  fi

  if [ -z "$port" ] && [ -f "$cfg" ]; then
    port=$(awk '
      /^[[:space:]]*#/ {next}
      tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
    ' "$cfg" 2>/dev/null)
  fi

  [ -n "$port" ] && { echo "$port"; return 0; }
  echo "22"
}

ROOTFS_CHROOT_SHELL=""
CHROOT_LAST_OUTPUT=""

PRE_SSHD_LAST_OUTPUT=""
log_diag_block() {
  local tag="$1"
  while IFS= read -r line; do
    log "[DIAG][$tag] $line"
  done
}

resolve_rootfs_exec_path() {
  # 在宿主侧判断 rootfs 内某可执行是否可用。难点：
  # 1) 直接 readlink -f 会把 rootfs 里的绝对软链解析到宿主绝对路径（错的）
  # 2) [ -x "$TARGET/bin/sh" ] 会跟随软链到宿主，对 busybox/alpine 永远失败
  # 思路：手工解析符号链接，限定在 $TARGET 内迭代，最多 16 步
  local cand host link target_path target_inside steps
  for cand in "$@"; do
    host="$TARGET$cand"
    target_path="$cand"
    steps=0
    while :; do
      target_inside="$TARGET$target_path"
      if [ -L "$target_inside" ]; then
        link=$(readlink "$target_inside" 2>/dev/null)
        [ -z "$link" ] && break
        case "$link" in
          /*) target_path="$link" ;;
          *) target_path="$(dirname "$target_path")/$link" ;;
        esac
        steps=$((steps + 1))
        [ "$steps" -ge 16 ] && break
        continue
      fi
      if [ -f "$target_inside" ] && [ -x "$target_inside" ]; then
        echo "$cand"
        return 0
      fi
      break
    done
    # 若解析失败，再尝试直接 -x（极少情况下挂载层 fallthrough 是有效的）
    if [ -f "$host" ] && [ -x "$host" ]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

get_rootfs_chroot_shell() {
  if [ -n "${ROOTFS_CHROOT_SHELL:-}" ]; then
    echo "$ROOTFS_CHROOT_SHELL"
    return 0
  fi

  ROOTFS_CHROOT_SHELL="$(resolve_rootfs_exec_path \
    /usr/bin/dash /bin/dash \
    /usr/bin/bash /bin/bash \
    /usr/bin/ash /bin/ash \
    /usr/bin/sh /bin/sh 2>/dev/null || true)"
  [ -z "$ROOTFS_CHROOT_SHELL" ] && ROOTFS_CHROOT_SHELL="/bin/sh"
  echo "$ROOTFS_CHROOT_SHELL"
}

chroot_cmd_capture() {
  local shell_path="$1"
  local cmd="$2"
  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c "$cmd" 2>&1
}

chroot_pid_alive_retry() {
  local shell_path try rc output
  shell_path="$(get_rootfs_chroot_shell)"
  try=1
  while [ "$try" -le 3 ]; do
    sync  # 同步 I/O 缓存
    output="$(chroot_cmd_capture "$shell_path" 'test -s /run/sshd.pid && pid=$(cat /run/sshd.pid 2>/dev/null) && kill -0 "$pid" 2>/dev/null')"
    rc=$?
    CHROOT_LAST_OUTPUT="$output"
    [ "$rc" -eq 0 ] && return 0
    [ "$try" -lt 3 ] && sleep 1
    try=$((try + 1))
  done
  return 1
}

dump_chroot_exec_diagnostics() {
  local context="$1"
  local rc="$2"
  local output="$3"
  local shell_path="$4"
  local item host resolved

  {
    echo "context=$context rc=$rc target=$TARGET shell=$shell_path image_mode=$IMAGE_MODE image_file=${IMAGE_FILE:-} loop=${IMAGE_LOOPDEV:-}"
    echo "stderr=$(printf '%s' "$output" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    for item in \
      / \
      /bin /bin/sh /bin/bash \
      /usr /usr/bin /usr/bin/dash /usr/bin/bash /usr/bin/env /usr/bin/gnuenv \
      /usr/sbin /usr/sbin/sshd \
      /lib /lib/ld-linux-aarch64.so.1 /lib/aarch64-linux-gnu /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
      /run /run/sshd; do
      host="$TARGET$item"
      if [ -e "$host" ] || [ -L "$host" ]; then
        echo "--- $item ---"
        ls -ld "$host" 2>&1
        [ -L "$host" ] && echo "readlink=$(readlink "$host" 2>/dev/null || true)"
        resolved=$(readlink -f "$host" 2>/dev/null || true)
        [ -n "$resolved" ] && echo "readlink_f=$resolved"
      else
        echo "--- $item missing ---"
      fi
    done
    echo "--- mountinfo(target) ---"
    grep -F " $TARGET" /proc/self/mountinfo 2>/dev/null | sed -n '1,80p'
  } | log_diag_block "$context"
}

run_chroot_cmd_retry() {
  local context="$1"
  local cmd="$2"
  local max_try="${3:-3}"
  local sleep_s="${4:-1}"
  local diag_on_fail="${5:-1}"
  local shell_path try rc output

  shell_path="$(get_rootfs_chroot_shell)"
  try=1
  while [ "$try" -le "$max_try" ]; do
    sync  # 同步 I/O 缓存
    output="$(chroot_cmd_capture "$shell_path" "$cmd")"
    rc=$?
    CHROOT_LAST_OUTPUT="$output"

    if [ "$rc" -eq 0 ]; then
      [ "$try" -gt 1 ] && echo_info "$context 在第${try}次重试后成功 (shell=$shell_path)"
      return 0
    fi

    echo_warn "$context 第${try}/${max_try}次失败(rc=$rc, shell=$shell_path): $(printf '%s' "$output" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    [ "$diag_on_fail" = "1" ] && [ "$try" -eq "$max_try" ] && dump_chroot_exec_diagnostics "${context}#${try}" "$rc" "$output" "$shell_path"

    [ "$try" -lt "$max_try" ] && sleep "$sleep_s"
    try=$((try + 1))
  done

  return "${rc:-1}"
}

# 自动安装 openssh-server（在容器内）。返回 0 表示装好或已装；非 0 表示放弃。
ensure_rootfs_sshd_installed() {
  local cand
  for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
    [ -x "$TARGET$cand" ] && return 0
  done

  echo_info "rootfs 未发现 sshd，尝试在容器内自动安装 openssh-server..."

  local shell_path
  shell_path="$(get_rootfs_chroot_shell)"

  # DNS 自检（resolv.conf 在外层已修好；这里只验证 + 列日志）
  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c '
    echo "[probe] /etc/resolv.conf:"
    ls -la /etc/resolv.conf 2>&1 || true
    echo "[probe] resolv.conf content head:"
    head -5 /etc/resolv.conf 2>&1 || true
    if getent hosts deb.debian.org >/dev/null 2>&1 \
       || getent hosts archive.ubuntu.com >/dev/null 2>&1 \
       || getent hosts mirrors.tuna.tsinghua.edu.cn >/dev/null 2>&1; then
      echo "[probe] DNS OK"
    else
      echo "[probe] DNS FAIL: 上游解析失败"
    fi
  ' 2>&1 | log_diag_block "ensure_rootfs_sshd_installed:dns" || true

  local install_cmd=""
  # 强制在容器内使用 /tmp 作为临时目录，规避宿主 TMPDIR 残留（例如 MT 终端的
  # /data/user/0/bin.mt.plus/files/term/tmp，进 chroot 后路径不存在导致 mkstemp 失败）
  local tmp_prelude='mkdir -p /tmp /var/tmp 2>/dev/null || true
                     chmod 1777 /tmp /var/tmp 2>/dev/null || true
                     export TMPDIR=/tmp TMP=/tmp TEMP=/tmp'

  if [ -x "$TARGET/usr/bin/apt-get" ] || [ -x "$TARGET/usr/bin/apt" ]; then
    install_cmd="$tmp_prelude
                 export DEBIAN_FRONTEND=noninteractive
                 apt-get update -y || true
                 apt-get install -y --no-install-recommends openssh-server openssh-sftp-server"
  elif [ -x "$TARGET/usr/bin/dnf" ]; then
    install_cmd="$tmp_prelude
                 dnf install -y openssh-server openssh-clients"
  elif [ -x "$TARGET/usr/bin/yum" ]; then
    install_cmd="$tmp_prelude
                 yum install -y openssh-server openssh-clients"
  elif [ -x "$TARGET/usr/bin/pacman" ] || [ -x "$TARGET/sbin/pacman" ]; then
    install_cmd="$tmp_prelude
                 pacman -Sy --noconfirm openssh"
  elif [ -x "$TARGET/sbin/apk" ] || [ -x "$TARGET/usr/sbin/apk" ] || [ -x "$TARGET/bin/apk" ]; then
    install_cmd="$tmp_prelude
                 apk update >/dev/null 2>&1 || true
                 apk add --no-cache openssh openssh-sftp-server"
  else
    echo_warn "未识别 rootfs 包管理器，请手动安装 openssh-server 后再重启容器"
    return 1
  fi

  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c "$install_cmd" 2>&1 | log_diag_block "ensure_rootfs_sshd_installed" || true

  for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
    [ -x "$TARGET$cand" ] && { echo_info "openssh-server 安装完成: $cand"; return 0; }
  done
  echo_warn "openssh-server 安装失败，请检查容器内网络/源"
  echo_warn "  常见原因: (1) /etc/resolv.conf 是 dangling symlink → 已自动修复"
  echo_warn "           (2) 容器源被墙 → 进容器后改用国内镜像"
  echo_warn "           (3) 宿主网络断 → 检查手机是否联网"
  return 1
}

prepare_and_start_sshd() {
  local sshd_bin=""
  local cand
  local port
  local shell_path
  local direct_probe_out
  local start_cmd

  SSHD_PRESENT=0
  SSHD_RUNNING=0
  ROOTFS_SSHD_PORT=""
  ROOTFS_SSHD_PID=""
  ROOTFS_CHROOT_SHELL=""
  CHROOT_LAST_OUTPUT=""

  for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
    if [ -x "$TARGET$cand" ]; then
      sshd_bin="$cand"
      break
    fi
  done

  if [ -z "$sshd_bin" ]; then
    if ensure_rootfs_sshd_installed; then
      for cand in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd /bin/sshd; do
        if [ -x "$TARGET$cand" ]; then
          sshd_bin="$cand"
          break
        fi
      done
    fi
  fi
  [ -z "$sshd_bin" ] && return 0
  SSHD_PRESENT=1

  ensure_rootfs_sshd_dropin

  mkdir -p "$TARGET/run/sshd" 2>/dev/null || true
  chmod 755 "$TARGET/run/sshd" 2>/dev/null || true

  shell_path="$(get_rootfs_chroot_shell)"
  echo_info "sshd启动将使用 chroot shell: $shell_path"

  direct_probe_out="$(HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c 'true' 2>&1)"
  if [ $? -eq 0 ]; then
    echo_info "prepare_and_start_sshd直连chroot探测成功 (shell=$shell_path)"
  else
    CHROOT_LAST_OUTPUT="$direct_probe_out"
    echo_warn "prepare_and_start_sshd直连chroot探测失败 (shell=$shell_path): $(printf '%s' "$direct_probe_out" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    dump_chroot_exec_diagnostics "prepare_and_start_sshd直连探测" "127" "$direct_probe_out" "$shell_path"
  fi

  run_chroot_cmd_retry "chroot入口预热" 'true' 5 2 1 || {
    echo_err "chroot入口预热失败，最近输出: $(printf '%s' "$CHROOT_LAST_OUTPUT" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  }

  ensure_rootfs_root_password

  # 创建 sshd 特权分离用户（UsePrivilegeSeparation 默认开，缺这个用户会拒启）
  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c '
    set -e
    if ! getent passwd sshd >/dev/null 2>&1; then
      mkdir -p /var/run/sshd /run/sshd 2>/dev/null || true
      if command -v useradd >/dev/null 2>&1; then
        groupadd -r sshd 2>/dev/null || true
        useradd -r -g sshd -d /run/sshd -s /usr/sbin/nologin sshd 2>/dev/null \
          || useradd -r -g sshd -d /run/sshd -s /bin/false sshd 2>/dev/null || true
      elif command -v adduser >/dev/null 2>&1; then
        # busybox/alpine variant
        addgroup -S sshd 2>/dev/null || true
        adduser -S -D -H -h /run/sshd -s /sbin/nologin -G sshd sshd 2>/dev/null || true
      else
        # 兜底：直接追加 /etc/passwd /etc/group
        getent group sshd >/dev/null 2>&1 || echo "sshd:x:74:" >> /etc/group
        echo "sshd:x:74:74:Privilege-separated SSH:/run/sshd:/usr/sbin/nologin" >> /etc/passwd
      fi
      echo "[sshd-user] created"
    fi
  ' 2>&1 | log_diag_block "ensure_sshd_user" || true

  run_chroot_cmd_retry "sshd配置预检" "mkdir -p /run/sshd && chmod 755 /run/sshd && if command -v ssh-keygen >/dev/null 2>&1; then ssh-keygen -A >/dev/null 2>&1 || true; fi && $sshd_bin -t" 5 1 1
  if [ $? -ne 0 ]; then
    echo_warn "sshd配置预检有告警: $(printf '%s' "$CHROOT_LAST_OUTPUT" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  fi

  if ! chroot_pid_alive_retry; then
    start_cmd="rm -f /run/sshd.pid 2>/dev/null; $sshd_bin >/dev/null 2>&1"
    run_chroot_cmd_retry "启动sshd" "$start_cmd" 5 1 1 || true
  fi

  port=$(get_rootfs_sshd_port)
  [ -z "$port" ] && port="$(get_default_distro_sshd_port)"
  ROOTFS_SSHD_PORT="$port"

  if chroot_pid_alive_retry; then
    run_chroot_cmd_retry "读取sshd pid" 'cat /run/sshd.pid 2>/dev/null' 3 1 0 >/dev/null 2>&1 || true
    ROOTFS_SSHD_PID=$(printf '%s' "$CHROOT_LAST_OUTPUT" | tr -d '
')
    SSHD_RUNNING=1
    echo_info "SSH自检: 已准备 /run/sshd，sshd运行中 (Port: $port)"
  else
    SSHD_RUNNING=0
    echo_warn "SSH自检: 已尝试启动 sshd，但未确认存活 (Port: $port)，最近输出: $(printf '%s' "$CHROOT_LAST_OUTPUT" | tr '
' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  fi
}

# 安卓分区路径兼容：只在路径真实存在时返回
# ==============================================
# Android 路径解析 / 挂载实现
# ==============================================
resolve_mount_path() {
  local candidate="$1"
  [ -e "$candidate" ] && echo "$candidate" && return

  case "$candidate" in
    /system)
      [ -e /system_root/system ] && echo "/system_root/system" && return
      ;;
    /vendor)
      [ -e /system/vendor ] && echo "/system/vendor" && return
      ;;
    /product)
      [ -e /system/product ] && echo "/system/product" && return
      ;;
  esac

  echo ""
}

do_mount() {
  local src="$1" dst="$2" type="$3" opt="$4"

  [ -z "$src" ] && return 0
  if [ "$type" = "bind" ] && [ ! -e "$src" ]; then
    echo_warn "源路径不存在，跳过: $src"
    return 0
  fi

  if [ "$type" != "bind" ] && [ -e "$dst" ] && [ ! -d "$dst" ]; then
    rm -f "$dst" 2>/dev/null || echo_err "挂载点不是目录且无法修复: $dst"
  fi

  if [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if [ "$type" = "bind" ]; then
      if [ -d "$src" ]; then
        mkdir -p "$dst"
      else
        : > "$dst"
      fi
    else
      mkdir -p "$dst"
    fi
  fi

  if is_mounted "$dst"; then
    echo_warn "已挂载，跳过: $dst"
    return 0
  fi

  if [ "$type" = "bind" ]; then
    mount --bind "$src" "$dst" || echo_err "bind挂载失败: $src -> $dst"

    if [ -n "$opt" ]; then
      mount -o "remount,bind,$opt" "$dst" || {
        echo_warn "remount失败，回退只读: $dst"
        mount -o remount,bind,ro "$dst" 2>/dev/null || echo_err "回退只读失败: $dst"
      }
    fi
  elif [ "$type" = "rbind" ]; then
    mount --rbind "$src" "$dst" || echo_err "rbind挂载失败: $src -> $dst"

    if [ -n "$opt" ]; then
      mount -o "remount,bind,$opt" "$dst" || {
        echo_warn "remount失败，回退只读: $dst"
        mount -o remount,bind,ro "$dst" 2>/dev/null || echo_err "回退只读失败: $dst"
      }
    fi
  else
    mount -t "$type" -o "$opt" "$src" "$dst" || echo_err "挂载失败: $src -> $dst"
  fi

  if ! mount --make-private "$dst" 2>/dev/null; then
    local check_prop
    check_prop=$(get_propagation "$dst")
    [ "$check_prop" != "private" ] && echo_warn "make-private失败且当前非private: $dst"
  fi

  local actual_opt actual_prop
  actual_opt=$(get_mount_opts "$dst")
  actual_prop=$(get_propagation "$dst")
  echo_info "挂载成功: $src -> $dst [权限: ${actual_opt:-unknown}] [传播: ${actual_prop:-unknown}]"

  MOUNT_STACK+=("$dst")
}

chroot_pids() {
  local p link
  for p in /proc/[0-9]*; do
    [ -e "$p/root" ] || continue
    link=$(readlink "$p/root" 2>/dev/null || true)
    case "$link" in
      "$TARGET"* ) echo "${p##*/}" ;;
    esac
  done
}

kill_pid_tree() {
  local sig="$1" pid="$2" child
  kill "-$sig" "$pid" 2>/dev/null || true
  for child in $(ps -o pid= -o ppid= 2>/dev/null | awk -v p="$pid" '$2==p{print $1}'); do
    kill_pid_tree "$sig" "$child"
  done
}

quick_lazy_umount() {
  local mp="$1"
  case "$mp" in
    "$TARGET/storage/emulated/0"|"$TARGET/sdcard"|"$TARGET/apex")
      umount -l "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
      ;;
    *)
      umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
      ;;
  esac
}

cleanup() {
  [ "$CLEANUP_DONE" -eq 1 ] && return 0
  IN_CLEANUP=1
  CLEANUP_DONE=1
  echo
  echo_info "触发安全清理机制..."

  if [ -n "$ORIGINAL_SELINUX_STATE" ] && [ -x /system/bin/setenforce ]; then
    if [ "$ORIGINAL_SELINUX_STATE" = "Enforcing" ]; then
      setenforce 1 2>/dev/null || true
    else
      setenforce 0 2>/dev/null || true
    fi
    echo_info "已恢复SELinux状态: $ORIGINAL_SELINUX_STATE"
  fi

  if [ "${#MOUNT_STACK[@]}" -gt 0 ]; then
    local retry pids pid
    for retry in 1 2 3; do
      pids="$(chroot_pids | xargs 2>/dev/null || true)"
      [ -z "$pids" ] && break

      if [ "$retry" -lt 3 ]; then
        echo_info "第$retry轮优雅终止: $pids"
        for pid in $pids; do kill_pid_tree TERM "$pid"; done
        sleep 1
      else
        echo_warn "第$retry轮强制终止: $pids"
        for pid in $pids; do kill_pid_tree KILL "$pid"; done
        sleep 0.5
      fi
    done
  fi

  local i mnt
  for ((i=${#MOUNT_STACK[@]}-1; i>=0; i--)); do
    mnt="${MOUNT_STACK[$i]}"
    if is_mounted "$mnt"; then
      quick_lazy_umount "$mnt"
    fi
  done

  rm -f "$TARGET$CHROOT_MARKER" 2>/dev/null || true

  if [ "$IMAGE_MODE" -eq 1 ]; then
    if is_mounted "$TARGET"; then
      quick_lazy_umount "$TARGET"
    fi
    [ -n "$IMAGE_LOOPDEV" ] && "$LOSETUP_BIN" -d "$IMAGE_LOOPDEV" 2>/dev/null || true
    cleanup_stale_loop_devices_for_image "$IMAGE_FILE" "$IMAGE_MOUNTPOINT"
  fi

  local residual
  residual=$(grep -F " $TARGET" /proc/self/mountinfo | wc -l)
  if [ "$residual" -gt 0 ]; then
    echo_warn "检测到残留挂载: $residual"
    grep -F " $TARGET" /proc/self/mountinfo | tee -a "$LOG_FILE"
    log_mountpoint_evidence "cleanup_residual" "$TARGET"
  else
    echo_info "✅ 挂载已清理"
  fi

  log "会话结束，日志: $LOG_FILE"
}

# ==============================================
# 主流程：进入隔离 mount namespace
# ==============================================
if [ -z "${_ISOLATED_NAMESPACE:-}" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root后再进入命名空间。请用: su -c $0 [参数]" >&2
    exit 1
  fi
  cleanup_current_namespace_stale_image_mount
  export _ISOLATED_NAMESPACE=1
  if unshare --help 2>&1 | grep -q -- "--propagation"; then
    exec unshare --mount --propagation private env LOG_FILE="$LOG_FILE" _ISOLATED_NAMESPACE=1 "$0" "${ORIG_ARGS[@]}"
  fi
  exec "$UNSHARE_BIN" -m env LOG_FILE="$LOG_FILE" _ISOLATED_NAMESPACE=1 "$0" "${ORIG_ARGS[@]}"
fi
trap cleanup EXIT SIGINT SIGTERM SIGHUP QUIT

check_cmds
[ "$(id -u)" -ne 0 ] && echo_err "必须使用root权限执行（KernelSU/su）"
check_selinux
mount_rootfs_image_if_exists
if [ "$IMAGE_MODE" -eq 1 ]; then
  MOUNT_STACK+=("$TARGET")
  echo_info "已挂载镜像 rootfs: $IMAGE_FILE -> $TARGET"
fi
[ ! -d "$TARGET" ] && echo_err "rootfs目录不存在: $TARGET（可用 --rootfs 指定自定义rootfs路径）"


nested_target_mounts=0
if grep -Fq " $TARGET/proc " /proc/self/mountinfo 2>/dev/null    || grep -Fq " $TARGET/dev " /proc/self/mountinfo 2>/dev/null    || grep -Fq " $TARGET/system " /proc/self/mountinfo 2>/dev/null; then
  nested_target_mounts=1
fi

if [ -f "$TARGET$CHROOT_MARKER" ] && [ "$nested_target_mounts" -eq 0 ]; then
  rm -f "$TARGET$CHROOT_MARKER" 2>/dev/null || true
  echo_warn "检测到陈旧 chroot marker，已自动清理: $TARGET$CHROOT_MARKER"
fi

if [ -f "$TARGET$CHROOT_MARKER" ] || [ "$nested_target_mounts" -eq 1 ]; then
  echo_err "检测到疑似嵌套chroot，已拒绝执行"
fi

preflight_chroot
if [ "$USE_PROOT_FALLBACK" -eq 1 ]; then
  run_proot_fallback
fi

if ! mount --make-rprivate / 2>/dev/null; then
  root_prop=$(get_propagation "/")
  [ "$root_prop" != "private" ] && echo_warn "make-rprivate / 失败且根传播非private，隔离性可能下降"
fi
echo_info "已锁定根目录传播属性为private"

echo_info "开始构建MCP专属Chroot环境..."

do_mount "proc" "$TARGET/proc" "proc" "nosuid,noexec,nodev"
do_mount "sysfs" "$TARGET/sys" "sysfs" "nosuid,noexec,nodev,ro"

do_mount "/dev" "$TARGET/dev" "bind" "nosuid,noexec"
mkdir -p "$TARGET/dev/pts"
chmod 1777 "$TARGET/dev/shm" 2>/dev/null || true
do_mount "devpts" "$TARGET/dev/pts" "devpts" "nosuid,noexec,newinstance,ptmxmode=0666"

# 添加 binderfs 以支持 Binder IPC（am/pm/settings 等 Android 命令需要）
if [ -d "/dev/binderfs" ]; then
  mkdir -p "$TARGET/dev/binderfs"
  do_mount "/dev/binderfs" "$TARGET/dev/binderfs" "bind" "rw"
fi

do_mount "tmpfs" "$TARGET/tmp" "tmpfs" "nosuid,nodev,mode=1777"
do_mount "tmpfs" "$TARGET/run" "tmpfs" "nosuid,nodev,mode=755,size=200M"
do_mount "tmpfs" "$TARGET/dev/shm" "tmpfs" "nosuid,nodev,size=100M,mode=1777"

# ==============================================
# /data 兼容映射整理
# ==============================================
normalize_direct_android_mountpoints() {
  # 仅确保 /data 作为目录存在；不再创建任何 android_* 别名挂载点。
  if [ -L "$TARGET/data" ]; then
    case "$(readlink "$TARGET/data" 2>/dev/null || true)" in
      android_data|/android_data|android_root/data|/android_root/data)
        rm -f "$TARGET/data" 2>/dev/null || echo_err "无法移除遗留 data 符号链接"
        mkdir -p "$TARGET/data" 2>/dev/null || echo_err "无法创建目录挂载点: $TARGET/data"
        chown 0:0 "$TARGET/data" 2>/dev/null || true
        chmod 755 "$TARGET/data" 2>/dev/null || true
        echo_info "已将遗留 data 符号链接修正为目录挂载点"
        ;;
      *)
        echo_warn "检测到非标准 data 符号链接，保留原状: $(readlink "$TARGET/data" 2>/dev/null || true)"
        ;;
    esac
  elif [ ! -e "$TARGET/data" ]; then
    mkdir -p "$TARGET/data" 2>/dev/null || echo_err "无法创建目录挂载点: $TARGET/data"
    chown 0:0 "$TARGET/data" 2>/dev/null || true
    chmod 755 "$TARGET/data" 2>/dev/null || true
  fi

  # 清理任何遗留的 android_* 链接/空目录，避免对 AI agent 造成干扰
  local stale
  for stale in android_root android_data android_system android_vendor \
               android_product android_odm android_boot android_system_ext \
               android_apex android_metadata; do
    [ -e "$TARGET/$stale" ] || [ -L "$TARGET/$stale" ] || continue
    if [ -L "$TARGET/$stale" ]; then
      rm -f "$TARGET/$stale" 2>/dev/null || true
    elif [ -d "$TARGET/$stale" ] && [ -z "$(ls -A "$TARGET/$stale" 2>/dev/null)" ]; then
      rmdir "$TARGET/$stale" 2>/dev/null || true
    fi
  done
}

prepare_data_mapping() {
  if [ "$SAFE_MODE" -eq 1 ]; then
    DATA_MOUNT_OPT="ro"
    SDCARD_MOUNT_OPT="ro"
    RO_DATA=1
    echo_warn "⚠️ 已启用安全模式：/data 与 /storage/emulated/0 只读"
  fi

  if [ "$RO_DATA" -eq 1 ]; then
    DATA_MOUNT_OPT="ro"
    echo_warn "⚠️ 已启用/data只读模式"
  fi

  # rootfs 位于宿主 /data 之下时，bind /data → $TARGET/data 会出现自递归。
  # 这种情况下先把宿主原始 /data 内容保留在 /.rootfs_data，再做 bind。
  if [[ "$TARGET" == /data/* ]] && [ "$IMAGE_MODE" -eq 0 ]; then
    if [ -d "$TARGET/data" ] && [ -n "$(ls -A "$TARGET/data" 2>/dev/null)" ] \
       && [ ! -e "$TARGET/.rootfs_data" ]; then
      mv "$TARGET/data" "$TARGET/.rootfs_data" 2>/dev/null || true
      mkdir -p "$TARGET/data" 2>/dev/null || true
      echo_warn "rootfs 原始 /data 已保留为 /.rootfs_data，避免递归自绑定"
    fi
  fi

  do_mount "/data" "$TARGET/data" "bind" "$DATA_MOUNT_OPT"
}

normalize_direct_android_mountpoints

prepare_data_mapping

REAL_SYSTEM=$(resolve_mount_path "/system")
REAL_VENDOR=$(resolve_mount_path "/vendor")
REAL_PRODUCT=$(resolve_mount_path "/product")
REAL_ODM=$(resolve_mount_path "/odm")
REAL_SYSTEM_EXT=$(resolve_mount_path "/system_ext")
REAL_APEX=$(resolve_mount_path "/apex")
REAL_METADATA=$(resolve_mount_path "/metadata")

do_mount "$REAL_SYSTEM" "$TARGET/system" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_VENDOR" "$TARGET/vendor" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_PRODUCT" "$TARGET/product" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_ODM" "$TARGET/odm" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_SYSTEM_EXT" "$TARGET/system_ext" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_APEX" "$TARGET/apex" "rbind" "$SYS_MOUNT_OPT"
do_mount "$REAL_METADATA" "$TARGET/metadata" "bind" "$SYS_MOUNT_OPT"

# 添加 linkerconfig 以支持 Android 动态链接器配置
if [ -d "/linkerconfig" ]; then
  do_mount "/linkerconfig" "$TARGET/linkerconfig" "bind" "ro"
fi

if [ -d "/storage/emulated/0" ]; then
  do_mount "/storage/emulated/0" "$TARGET/storage/emulated/0" "bind" "$SDCARD_MOUNT_OPT"
  do_mount "/storage/emulated/0" "$TARGET/sdcard" "bind" "$SDCARD_MOUNT_OPT"
fi

# 修复 rootfs 内 /etc/resolv.conf：直接复制宿主 DNS 配置，不再 bind-mount。
# 理由：
#   1. resolv.conf 是静态文本，不需要随宿主变化实时同步；
#   2. bind 单文件的 remount 在嵌套 loop / 多层挂载下可能 EBUSY；
#   3. 容器内的发行版（如 debian）默认会把 /etc/resolv.conf 做成
#      systemd-resolved 的 dangling symlink，bind 时跟随会指向不存在的目标。
mkdir -p "$TARGET/etc" 2>/dev/null || true
if [ -L "$TARGET/etc/resolv.conf" ]; then
  rm -f "$TARGET/etc/resolv.conf" 2>/dev/null || true
fi
if [ -s "/etc/resolv.conf" ]; then
  cp -f "/etc/resolv.conf" "$TARGET/etc/resolv.conf" 2>/dev/null \
    || cat "/etc/resolv.conf" > "$TARGET/etc/resolv.conf" 2>/dev/null || true
else
  printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:2\n' \
    > "$TARGET/etc/resolv.conf"
  echo_warn "宿主 /etc/resolv.conf 为空，已直接写入回退 DNS 到容器 /etc/resolv.conf"
fi
chmod 644 "$TARGET/etc/resolv.conf" 2>/dev/null || true

touch "$TARGET$CHROOT_MARKER"
sync
sleep 0.3  # 等待 mount propagation 稳定
echo_info "挂载同步完成，准备执行 chroot 预检"
prepare_chroot_compat
CHROOT_EXEC_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin:/apex/com.android.runtime/bin"
ROOTFS_PRECHECK_SHELL="$(get_rootfs_chroot_shell)"
ROOTFS_PRECHECK_OUT="$(HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$ROOTFS_PRECHECK_SHELL" -c 'echo pre_sshd_ok' 2>&1 || true)"
PRE_SSHD_LAST_OUTPUT="$ROOTFS_PRECHECK_OUT"
if printf '%s' "$ROOTFS_PRECHECK_OUT" | grep -qx 'pre_sshd_ok'; then
  echo_info "sshd前 chroot 自检成功 (shell=$ROOTFS_PRECHECK_SHELL)"
else
  echo_warn "sshd前 chroot 自检失败 (shell=$ROOTFS_PRECHECK_SHELL): $(printf '%s' "$ROOTFS_PRECHECK_OUT" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  dump_chroot_exec_diagnostics "pre_sshd自检" "127" "$ROOTFS_PRECHECK_OUT" "$ROOTFS_PRECHECK_SHELL"
fi
prepare_and_start_sshd

if [ "$DAEMON_MODE" -eq 1 ]; then
  [ "$SSHD_PRESENT" -eq 1 ] || echo_err "后台模式需要 rootfs 内已安装并可执行的 sshd（请先安装 openssh-server）"
  [ "$SSHD_RUNNING" -eq 1 ] || echo_err "后台模式启动失败：未确认 chroot 内 sshd 存活，请查看日志: $LOG_FILE"
  daemon_name="${DISTRO_NAME:-$(basename "$TARGET")}" 
  DAEMON_INFO_FILE="$STATE_DIR/chroot-mcp-daemon-${daemon_name}.info"
  cat > "$DAEMON_INFO_FILE" <<EOF
TARGET=$TARGET
PORT=${ROOTFS_SSHD_PORT:-unknown}
SSHD_PID=${ROOTFS_SSHD_PID:-unknown}
LOG_FILE=$LOG_FILE
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S %z')
IMAGE_FILE=${IMAGE_FILE:-}
IMAGE_LOOPDEV=${IMAGE_LOOPDEV:-}
EOF
  echo_info "🛰 后台模式已启动，不进入交互shell"
  echo_info "   SSH: ssh root@<手机IP> -p ${ROOTFS_SSHD_PORT:-unknown}"
  echo_info "   SFTP: sftp -P ${ROOTFS_SSHD_PORT:-unknown} root@<手机IP>"
  echo_info "   用户名: root"
  echo_info "   密码: ${MCP_ROOT_PASSWORD:-123456}"
  echo_info "   sshd PID: ${ROOTFS_SSHD_PID:-unknown}"
  echo_info "   状态文件: $DAEMON_INFO_FILE"
  echo_info "   日志文件: $LOG_FILE"
  trap - EXIT SIGINT SIGTERM SIGHUP QUIT
  exit 0
fi

echo_info "✅ 环境构建完成"
echo_info "   /data            -> Android /data [默认rw；--safe 或 --ro-data 可只读]"
echo_info "   /system,/vendor,/product,/odm,/system_ext,/apex,/metadata -> Android标准路径 [默认ro]"
echo_info "   /storage/emulated/0,/sdcard -> 内置存储 [默认rw；--safe 可只读]"
echo_info "   /dev             -> 完整设备节点"
echo_info "提示: 修改系统前手动 remount,rw，用完 remount,ro；若追求稳妥可加 --safe"

echo_info "🚀 进入Ubuntu chroot，exit 可安全退出"

cd "$TARGET" || echo_err "切换到chroot根目录失败"
if [ -x "$TARGET/usr/bin/run-parts" ] || [ -x "$TARGET/bin/run-parts" ]; then
  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" /bin/bash -l
else
  echo_warn "rootfs内缺少 run-parts，跳过login shell初始化以避免报错（可在容器内安装 debianutils 后恢复 -l）"
  HOME=/root TMPDIR=/tmp TMP=/tmp TEMP=/tmp TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" /bin/bash
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ -x /system/bin/getenforce ] && [ "$(getenforce)" = "Enforcing" ] && [ "$PERMISSIVE" -eq 0 ]; then
    echo_err "chroot失败(EPERM概率高)：当前SELinux=Enforcing，请改用 --permissive 重试"
  fi
  owner_now=$(stat -c "%u:%g" "$TARGET" 2>/dev/null || echo "unknown")
  echo_err "chroot启动失败，退出码: $rc；请检查KernelSU授权、rootfs属主(当前$owner_now)及SELinux策略"
fi