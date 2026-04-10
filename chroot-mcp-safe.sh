#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

TERMUX_PREFIX="/data/data/com.termux/files/usr"
export PATH="$TERMUX_PREFIX/bin:$TERMUX_PREFIX/sbin:$PATH"
CHROOT_BIN="/system/bin/chroot"
[ -x "$CHROOT_BIN" ] || CHROOT_BIN="$TERMUX_PREFIX/sbin/chroot"
[ -x "$CHROOT_BIN" ] || CHROOT_BIN="$(command -v chroot 2>/dev/null || echo /system/bin/chroot)"

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
LOG_FILE="/data/data/com.termux/files/usr/tmp/chroot-mcp-$(date +%s).log"

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
AUTO_MIGRATE=0
MIGRATE_IMAGE_MODE=0
AUTO_MIGRATE_IMAGE=0
IMAGE_MODE=0
IMAGE_FILE=""
IMAGE_MOUNTPOINT=""
IMAGE_LOOPDEV=""
ROOTFS_EXPLICIT=0
ORIG_ARGC=$#
ORIG_ARGS=("$@")


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
    --auto-migrate-image)
      AUTO_MIGRATE_IMAGE=1
      shift
      ;;
    --help|-h)
      cat <<USAGE
用法: $0 [--interactive] [--daemon] [--status] [--stop] [--migrate] [--auto-migrate] [--migrate-image] [--auto-migrate-image] [--safe|--full-access] [--permissive] [--ro-data] [--distro <名称>] [--rootfs <目录>] [--proot-fallback] [--print-install]
  --interactive     交互式向导（选择发行版/下载rootfs/启动参数）
  --daemon          后台模式：挂载并启动 chroot 内 sshd 后立即返回，不进入交互shell
  --status          查看后台模式状态（不新建挂载）
  --stop            停止后台模式并清理其挂载（不影响宿主SSH）
  --migrate         将当前 rootfs 迁移到 /data/local/chroot/<distro> 并修正权限/属主
  --auto-migrate    启动前若发现 rootfs 位于 /data/..termux.. 内，则自动迁移到 /data/local/chroot/<distro>
  --migrate-image   将当前 rootfs 迁移为 ext4 镜像，并在运行时挂载到 /mnt/chroot-rootfs/<distro>
  --auto-migrate-image  启动前若 rootfs 位于 /data 子树内且镜像不存在，则自动迁移为 ext4 镜像，以实现 /data 真1:1 映射
  --safe            安全模式：/data 与 /storage/emulated/0 只读；系统分区保持只读
  --full-access     全权限模式：/data 与 /storage/emulated/0 可写（默认）
  --permissive      临时 setenforce 0，退出自动恢复
  --ro-data         将 /data 以只读方式挂载到 chroot
  --distro <名称>   使用预设rootfs路径: ubuntu/debian/arch/fedora/alpine
  --rootfs <目录>   指定要进入的Linux rootfs目录（不依赖proot-distro）
  --proot-fallback  仅在你主动启用时，chroot失败回退到proot-distro
  --print-install   输出对应发行版的安装/编译环境建议命令
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
  echo "/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-${name}.info"
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

# 扫描所有发行版并显示运行状态概览

# 扫描所有发行版并显示运行状态概览
show_all_containers_status() {
  local distros="ubuntu debian arch fedora alpine"
  local name file alive port pid target started
  local running_count=0

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║              容器运行状态概览                                ║"
  echo "╠══════════════════════════════════════════════════════════════╣"

  for name in $distros; do
    file="/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-${name}.info"
    alive="no"
    port="-"
    pid="-"
    target="-"
    started="-"

    if [ -f "$file" ]; then
      DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
      if read_daemon_info "$file" 2>/dev/null; then
        pid="${DAEMON_SSHD_PID:-}"
        port="${DAEMON_PORT:-}"
        target="${DAEMON_TARGET:-}"
        started="${DAEMON_STARTED_AT:-}"
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
          alive="yes"
          running_count=$((running_count + 1))
        fi
      fi
    fi

    if [ "$alive" = "yes" ]; then
      printf "║  🟢 %-8s 运行中  PID=%-6s Port=%-5s %-20s ║\n" "$name" "$pid" "$port" "$started"
    else
      printf "║  ⚪ %-8s 未运行                                              ║\n" "$name"
    fi
  done

  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

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
  if [ -n "${DAEMON_SSHD_PID:-}" ] && [ -d "/proc/${DAEMON_SSHD_PID}" ]; then
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

cleanup_current_namespace_stale_image_mount() {
  set_image_paths
  [ -f "$IMAGE_FILE" ] || return 0
  grep -Fq " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null || return 0

  local users loopdev
  users=$(collect_mountpoint_users_in_current_ns "$IMAGE_MOUNTPOINT" | xargs 2>/dev/null || true)
  if [ -n "$users" ]; then
    echo_warn "检测到当前命名空间已有镜像挂载且仍被进程使用，保留: $IMAGE_MOUNTPOINT users=$users"
    return 0
  fi

  loopdev=$(grep -F " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
  case "$loopdev" in
    /dev/loop*|/dev/block/loop*) ;;
    *) loopdev="" ;;
  esac

  echo_warn "检测到当前命名空间残留镜像挂载，执行清理: $IMAGE_MOUNTPOINT ${loopdev:+($loopdev)}"
  umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  [ -n "$loopdev" ] && /data/data/com.termux/files/usr/bin/losetup -d "$loopdev" 2>/dev/null || true
}

daemon_stop() {
  local file
  file="$(get_daemon_info_file)"
  if ! read_daemon_info "$file"; then
    echo "[stop] 未找到后台状态文件: $file"
    return 1
  fi

  [ -n "${DAEMON_TARGET:-}" ] || { echo "[stop] 状态文件缺少 TARGET"; return 1; }
  [ -n "${DAEMON_SSHD_PID:-}" ] || { echo "[stop] 状态文件缺少 SSHD_PID"; return 1; }
  [ -d "/proc/${DAEMON_SSHD_PID}" ] || { echo "[stop] sshd pid 不存在: ${DAEMON_SSHD_PID}"; rm -f "$file"; return 1; }

  echo "[stop] 进入 mount namespace 清理: pid=${DAEMON_SSHD_PID} target=${DAEMON_TARGET}"
  nsenter -t "$DAEMON_SSHD_PID" -m /data/data/com.termux/files/usr/bin/bash -s -- "$DAEMON_TARGET" "$DAEMON_SSHD_PID" "${DAEMON_IMAGE_LOOPDEV:-}" <<'EOS'
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
kill "$PID" 2>/dev/null || true
sleep 1
for p in $(collect_target_pids); do kill "$p" 2>/dev/null || true; done
sleep 1
kill -9 "$PID" 2>/dev/null || true
for p in $(collect_target_pids); do kill -9 "$p" 2>/dev/null || true; done
for m in \
  "$TARGET/etc/resolv.conf" \
  "$TARGET/storage/emulated/0" \
  "$TARGET/sdcard" \
  "$TARGET/metadata" \
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
  "$TARGET/dev/pts" \
  "$TARGET/dev" \
  "$TARGET/sys" \
  "$TARGET/proc"
  do
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
rm -f "$TARGET/.chroot_marker" 2>/dev/null || true
umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
[ -n "$LOOPDEV" ] && /data/data/com.termux/files/usr/bin/losetup -d "$LOOPDEV" 2>/dev/null || true
EOS
  local rc=$?

  if [ -n "${DAEMON_IMAGE_FILE:-}" ] && grep -Fq " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null; then
    local host_loopdev host_users
    host_users=$(collect_mountpoint_users_in_current_ns "${DAEMON_TARGET}" | xargs 2>/dev/null || true)
    if [ -n "$host_users" ]; then
      echo "[stop] 当前命名空间仍有进程使用挂载点，跳过宿主残留清理: ${DAEMON_TARGET} users=$host_users"
    else
      host_loopdev=$(grep -F " ${DAEMON_TARGET} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
      case "$host_loopdev" in
        /dev/loop*|/dev/block/loop*) ;;
        *) host_loopdev="" ;;
      esac
      echo "[stop] 清理当前命名空间残留镜像挂载: ${DAEMON_TARGET} ${host_loopdev}"
      umount "${DAEMON_TARGET}" 2>/dev/null || umount -l "${DAEMON_TARGET}" 2>/dev/null || true
      [ -n "$host_loopdev" ] && /data/data/com.termux/files/usr/bin/losetup -d "$host_loopdev" 2>/dev/null || true
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

  # 使用 /system/bin/chroot 确保 namespace 内可找到 chroot 命令
  nsenter -t "$ns_pid" -m /data/data/com.termux/files/usr/bin/sh -c     "cd '$target' && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /system/bin/chroot . /bin/bash -i"
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
  nsenter -t "$ns_pid" -m /data/data/com.termux/files/usr/bin/bash -s -- "$target" "$ns_pid" "$loopdev" <<'EOS'
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
kill "$PID" 2>/dev/null || true
sleep 1
for p in $(collect_target_pids); do kill "$p" 2>/dev/null || true; done
sleep 1
kill -9 "$PID" 2>/dev/null || true
for p in $(collect_target_pids); do kill -9 "$p" 2>/dev/null || true; done
for m in \
  "$TARGET/etc/resolv.conf" \
  "$TARGET/storage/emulated/0" \
  "$TARGET/sdcard" \
  "$TARGET/metadata" \
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
  "$TARGET/dev/pts" \
  "$TARGET/dev" \
  "$TARGET/sys" \
  "$TARGET/proc"
  do
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
rm -f "$TARGET/.chroot_marker" 2>/dev/null || true
umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
[ -n "$LOOPDEV" ] && /data/data/com.termux/files/usr/bin/losetup -d "$LOOPDEV" 2>/dev/null || true
EOS
  local rc=$?

  if grep -Fq " ${target} " /proc/self/mountinfo 2>/dev/null; then
    local host_loopdev host_users
    host_users=$(collect_mountpoint_users_in_current_ns "${target}" | xargs 2>/dev/null || true)
    if [ -n "$host_users" ]; then
      echo "[stop] 当前命名空间仍有进程使用挂载点，跳过宿主残留清理: ${target} users=$host_users"
    else
      host_loopdev=$(grep -F " ${target} " /proc/self/mountinfo 2>/dev/null | tail -1 | awk -F' - ' '{print $2}' | awk '{print $2}')
      case "$host_loopdev" in
        /dev/loop*|/dev/block/loop*) ;;
        *) host_loopdev="$loopdev" ;;
      esac
      echo "[stop] 清理当前命名空间残留挂载: ${target} ${host_loopdev}"
      umount "${target}" 2>/dev/null || umount -l "${target}" 2>/dev/null || true
      [ -n "$host_loopdev" ] && /data/data/com.termux/files/usr/bin/losetup -d "$host_loopdev" 2>/dev/null || true
    fi
  fi

  return $rc
}

# ==============================================
# rootfs 选择 / 迁移 / 镜像挂载
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

set_image_paths() {
  local name
  name="$(get_rootfs_name)"
  IMAGE_FILE="/data/local/chroot-images/${name}.img"
  IMAGE_MOUNTPOINT="/mnt/chroot-rootfs/${name}"
}

mount_rootfs_image_if_exists() {
  set_image_paths
  [ -f "$IMAGE_FILE" ] || return 0

  mkdir -p /data/local/chroot-images "$IMAGE_MOUNTPOINT" || echo_err "无法创建镜像目录/挂载点"

  if grep -Fq " $IMAGE_MOUNTPOINT " /proc/self/mountinfo 2>/dev/null; then
    echo_warn "检测到当前命名空间已有镜像挂载，先在本命名空间卸载后重新挂载，以确保 loop 设备由本实例独占管理"
    umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  fi

  IMAGE_LOOPDEV=$(/data/data/com.termux/files/usr/bin/losetup -f --show "$IMAGE_FILE" 2>/dev/null) || { echo "错误: 镜像 loop 绑定失败: $IMAGE_FILE" >&2; exit 1; }
  mount -t ext4 "$IMAGE_LOOPDEV" "$IMAGE_MOUNTPOINT" || {
    /data/data/com.termux/files/usr/bin/losetup -d "$IMAGE_LOOPDEV" 2>/dev/null || true
    echo "错误: 镜像挂载失败: $IMAGE_FILE -> $IMAGE_MOUNTPOINT" >&2
    exit 1
  }

  TARGET="$IMAGE_MOUNTPOINT"
  IMAGE_MODE=1
}

migrate_rootfs_to_image() {
  local src="$TARGET"
  local tmpimg loopdev bytes need_bytes size_mib

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
  size_mib=$(( (need_bytes + 1048575) / 1048576 ))
  tmpimg="${IMAGE_FILE}.tmp"

  echo "[migrate-image] 源: $src"
  echo "[migrate-image] 镜像: $IMAGE_FILE"
  echo "[migrate-image] 申请大小: ${size_mib} MiB"

  rm -f "$tmpimg" 2>/dev/null || true
  truncate -s "${size_mib}M" "$tmpimg" || return 1
  /system/bin/mkfs.ext4 -F "$tmpimg" >/dev/null 2>&1 || { rm -f "$tmpimg"; echo "[migrate-image] mkfs.ext4 失败"; return 1; }

  loopdev=$(/data/data/com.termux/files/usr/bin/losetup -f --show "$tmpimg" 2>/dev/null) || { rm -f "$tmpimg"; echo "[migrate-image] loop 绑定失败"; return 1; }
  mount -t ext4 "$loopdev" "$IMAGE_MOUNTPOINT" || {
    /data/data/com.termux/files/usr/bin/losetup -d "$loopdev" 2>/dev/null || true
    rm -f "$tmpimg"
    echo "[migrate-image] ext4 镜像挂载失败"
    return 1
  }

  (cd "$src" && tar --numeric-owner --xattrs --acls -cpf - .) | (cd "$IMAGE_MOUNTPOINT" && tar --numeric-owner --xattrs --acls -xpf -) || {
    umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
    /data/data/com.termux/files/usr/bin/losetup -d "$loopdev" 2>/dev/null || true
    rm -f "$tmpimg"
    echo "[migrate-image] rootfs 复制失败"
    return 1
  }

  chown 0:0 "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  chmod 755 "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  sync
  umount "$IMAGE_MOUNTPOINT" 2>/dev/null || umount -l "$IMAGE_MOUNTPOINT" 2>/dev/null || true
  /data/data/com.termux/files/usr/bin/losetup -d "$loopdev" 2>/dev/null || true
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
    if [ -n "${DAEMON_SSHD_PID:-}" ] && [ -d "/proc/${DAEMON_SSHD_PID}" ]; then
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
    read -r -p "请输入编号: " idx
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
    read -r -p "$prompt: " val
  fi
  echo "$val"
}

download_rootfs_archive() {
  local url="$1"
  local rootfs_dir="$2"
  local archive="/data/data/com.termux/files/usr/tmp/rootfs-$(date +%s).tar"

  mkdir -p "$rootfs_dir" || return 1
  curl -fL "$url" -o "$archive" || return 1
  tar -xf "$archive" -C "$rootfs_dir" || return 1
  chown root:root "$rootfs_dir" 2>/dev/null || true
  chmod 755 "$rootfs_dir" 2>/dev/null || true
  rm -f "$archive" 2>/dev/null || true
}

bootstrap_rootfs_from_termux_source() {
  local distro="$1"
  local pd_root="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/$distro"
  if ! command -v proot-distro >/dev/null 2>&1; then
    # 交互模式兜底：自动安装 proot-distro（仅用于获取内置rootfs源）
    if command -v pkg >/dev/null 2>&1; then
      pkg install -y proot-distro >/dev/null 2>&1 || return 1
    fi
    command -v proot-distro >/dev/null 2>&1 || return 1
  fi
  # 若已存在可用rootfs，直接复用（避免 "already installed" 触发失败）
  if [ -x "$pd_root/bin/bash" ]; then
    TARGET="$pd_root"
    return 0
  fi

  proot-distro install "$distro" >/dev/null 2>&1 || true

  # 某些机型/环境下 proot-distro 会返回非0，但rootfs可能已成功落盘
  if [ -x "$pd_root/bin/bash" ]; then
    TARGET="$pd_root"
    return 0
  fi

  return 1
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

  if [ -f "$image_file" ]; then
    echo "$image_rootfs"
  elif [ -d "$local_rootfs" ]; then
    echo "$local_rootfs"
  elif [ -d "$proot_rootfs" ]; then
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

interactive_wizard() {
  local action distro url permissive_choice ro_choice fallback_choice rootfs_input existing_rootfs stop_choice stop_distro stop_confirm
  
  # 显示容器运行状态概览
  show_all_containers_status
  
  action=$(choose_option "选择操作" "启动已存在rootfs" "下载rootfs后启动" "安全终止卸载容器" "只打印安装建议")
  
  # 处理"安全终止卸载容器"选项
  if [ "$action" = "安全终止卸载容器" ]; then
    stop_distro=$(choose_option "选择要终止的发行版" ubuntu debian arch fedora alpine)
    DISTRO_NAME="$stop_distro"
    
    # 检查该发行版是否正在运行
    local stop_file="/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-${stop_distro}.info"
    if [ ! -f "$stop_file" ]; then
      echo "该发行版未运行（无状态文件）" >&2
      exit 0
    fi
    
    # 清空之前读取的变量
    DAEMON_TARGET="" DAEMON_PORT="" DAEMON_SSHD_PID="" DAEMON_STARTED_AT=""
    if read_daemon_info "$stop_file"; then
      if [ -n "${DAEMON_SSHD_PID:-}" ] && [ -d "/proc/${DAEMON_SSHD_PID}" ]; then
        echo "" >&2
        echo "发行版: $stop_distro" >&2
        echo "PID: ${DAEMON_SSHD_PID}" >&2
        echo "Port: ${DAEMON_PORT:-unknown}" >&2
        echo "Target: ${DAEMON_TARGET:-unknown}" >&2
        echo "启动时间: ${DAEMON_STARTED_AT:-unknown}" >&2
        echo "" >&2
        
        stop_confirm=$(choose_option "确认终止并卸载?" "确认终止" "取消操作")
        if [ "$stop_confirm" = "确认终止" ]; then
          echo "[stop] 正在终止 ${stop_distro} 容器..." >&2
          daemon_stop || { echo "[stop] 终止失败，请检查日志" >&2; exit 1; }
          echo "[stop] ✅ ${stop_distro} 容器已安全终止并卸载" >&2
        else
          echo "已取消终止操作" >&2
        fi
      else
        echo "该发行版状态文件存在但进程已结束，清理状态文件" >&2
        rm -f "$stop_file" 2>/dev/null
        echo "状态文件已清理" >&2
      fi
    else
      echo "无法读取状态文件" >&2
      rm -f "$stop_file" 2>/dev/null
    fi
    exit 0
  fi
  
  distro=$(choose_option "选择发行版" ubuntu debian arch fedora alpine)
  DISTRO_NAME="$distro"
  apply_distro_preset

  if [ "$action" = "只打印安装建议" ]; then
    PRINT_INSTALL_GUIDE=1
    return 0
  fi

  if [ "$action" = "启动已存在rootfs" ]; then
    existing_rootfs=$(find_existing_rootfs "$distro")
    if [ -n "$existing_rootfs" ]; then
      TARGET="$existing_rootfs"
      echo "已复用现有rootfs: $TARGET" >&2
    else
      echo "错误: 未找到 ${distro} 的现有rootfs，请改选“下载rootfs后启动”或使用 --rootfs 指定路径。" >&2
      exit 2
    fi
  fi

  if [ "$action" = "下载rootfs后启动" ]; then
    rootfs_input=$(ask_text "输入rootfs目录(默认 /data/local/chroot/$distro)")
    [ -z "$rootfs_input" ] && rootfs_input="/data/local/chroot/$distro"
    TARGET="$rootfs_input"
    url=$(ask_text "输入${distro} rootfs下载URL(arm64 tar包)")
    if [ -z "$url" ]; then
      echo "未提供URL，尝试使用Termux内置发行版源(proot-distro)下载: $distro" >&2
      if bootstrap_rootfs_from_termux_source "$distro"; then
        echo "已通过Termux内置源完成rootfs准备: $TARGET" >&2
      else
        echo "错误: 无URL且无法使用proot-distro内置源。请先执行 'pkg install proot-distro' 或提供rootfs URL。" >&2
        exit 2
      fi
    else
      echo "开始下载并解压rootfs到: $TARGET" >&2
      download_rootfs_archive "$url" "$TARGET" || { echo "错误: rootfs下载/解压失败" >&2; exit 2; }
    fi
  fi

  permissive_choice=$(choose_option "SELinux模式" "permissive(推荐)" "保持当前")
  [ "$permissive_choice" = "permissive(推荐)" ] && PERMISSIVE=1

  ro_choice=$(choose_option "/data挂载模式" "读写" "只读")
  [ "$ro_choice" = "只读" ] && RO_DATA=1

  fallback_choice=$(choose_option "chroot失败回退proot?" "否(纯原生chroot)" "是(兼容)")
  [ "$fallback_choice" = "是(兼容)" ] && FALLBACK_PROOT=1 || FALLBACK_PROOT=0
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
    [ "$PERMISSIVE" -eq 1 ] && ORIG_ARGS+=(--permissive)
    [ "$RO_DATA" -eq 1 ] && ORIG_ARGS+=(--ro-data)
    if [ "$SAFE_MODE" -eq 1 ]; then
      ORIG_ARGS+=(--safe)
    else
      ORIG_ARGS+=(--full-access)
    fi
    [ "$FALLBACK_PROOT" -eq 1 ] && ORIG_ARGS+=(--proot-fallback)
    [ "$PRINT_INSTALL_GUIDE" -eq 1 ] && ORIG_ARGS+=(--print-install)
  fi
else
  apply_distro_preset
fi
if [ "$STATUS_MODE" -eq 1 ]; then
  daemon_status
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
  [ ! -x "$TARGET/bin/bash" ] && echo_err "rootfs缺少可执行 /bin/bash，请检查你下载/解压的rootfs是否完整"

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
get_default_distro_sshd_port() {
  case "$(get_rootfs_name)" in
    ubuntu) echo "8023" ;;
    debian) echo "8024" ;;
    arch) echo "8025" ;;
    fedora) echo "8026" ;;
    alpine) echo "8027" ;;
    *) echo "8023" ;;
  esac
}

ensure_rootfs_sshd_port() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  local current_port=""
  local want_port=""

  [ -f "$cfg" ] || return 0
  want_port="$(get_default_distro_sshd_port)"
  current_port=$(awk '''
    /^[[:space:]]*#/ {next}
    tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
  ''' "$cfg" 2>/dev/null)

  if [ -z "$current_port" ] || [ "$current_port" = "22" ]; then
    cp -an "$cfg" "${cfg}.mcp.bak" 2>/dev/null || true
    if grep -qiE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$cfg"; then
      sed -i -E "0,/^[[:space:]]*Port[[:space:]]+[0-9]+/s//Port ${want_port}/" "$cfg" 2>/dev/null || true
    else
      printf '
# added by chroot-mcp-safe
Port %s
' "$want_port" >> "$cfg"
    fi
    echo_info "已将 rootfs sshd 端口规范为: $want_port ($(get_rootfs_name))"
  fi
}

get_rootfs_sshd_port() {
  local cfg="$TARGET/etc/ssh/sshd_config"
  if [ -f "$cfg" ]; then
    awk '
      /^[[:space:]]*#/ {next}
      tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}
    ' "$cfg" 2>/dev/null
    return 0
  fi
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
  local cand host resolved
  for cand in "$@"; do
    host="$TARGET$cand"
    if [ -e "$host" ] || [ -L "$host" ]; then
      resolved=$(readlink -f "$host" 2>/dev/null || true)
      if [ -n "$resolved" ] && [ "${resolved#\"$TARGET\"}" != "$resolved" ] && [ -x "$resolved" ]; then
        echo "${resolved#$TARGET}"
        return 0
      fi
      if [ -x "$host" ]; then
        echo "$cand"
        return 0
      fi
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
  HOME=/root PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c "$cmd" 2>&1
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

  [ -z "$sshd_bin" ] && return 0
  SSHD_PRESENT=1

  ensure_rootfs_sshd_port

  mkdir -p "$TARGET/run/sshd" 2>/dev/null || true
  chmod 755 "$TARGET/run/sshd" 2>/dev/null || true

  shell_path="$(get_rootfs_chroot_shell)"
  echo_info "sshd启动将使用 chroot shell: $shell_path"

  direct_probe_out="$(HOME=/root PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$shell_path" -c 'true' 2>&1)"
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
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    fi
  done

  rm -f "$TARGET$CHROOT_MARKER" 2>/dev/null || true

  if [ "$IMAGE_MODE" -eq 1 ]; then
    if is_mounted "$TARGET"; then
      umount "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
    fi
    [ -n "$IMAGE_LOOPDEV" ] && /data/data/com.termux/files/usr/bin/losetup -d "$IMAGE_LOOPDEV" 2>/dev/null || true
  fi

  local residual
  residual=$(grep -F " $TARGET" /proc/self/mountinfo | wc -l)
  if [ "$residual" -gt 0 ]; then
    echo_warn "检测到残留挂载: $residual"
    grep -F " $TARGET" /proc/self/mountinfo | tee -a "$LOG_FILE"
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
    exec unshare --mount --propagation private env _ISOLATED_NAMESPACE=1 "$0" "${ORIG_ARGS[@]}"
  fi
  exec unshare -m env _ISOLATED_NAMESPACE=1 "$0" "${ORIG_ARGS[@]}"
fi

trap cleanup EXIT SIGINT SIGTERM SIGHUP QUIT

check_cmds
[ "$(id -u)" -ne 0 ] && echo_err "必须使用root权限执行（KernelSU/su）"
mount_rootfs_image_if_exists
if [ "$IMAGE_MODE" -eq 1 ]; then
  MOUNT_STACK+=("$TARGET")
  echo_info "已挂载镜像 rootfs: $IMAGE_FILE -> $TARGET"
fi
[ ! -d "$TARGET" ] && echo_err "rootfs目录不存在: $TARGET（可用 --rootfs 指定自定义rootfs路径）"

nested_target_mounts=0
if grep -Fq " $TARGET/proc " /proc/self/mountinfo 2>/dev/null    || grep -Fq " $TARGET/dev " /proc/self/mountinfo 2>/dev/null    || grep -Fq " $TARGET/system " /proc/self/mountinfo 2>/dev/null    || grep -Fq " $TARGET/android_root " /proc/self/mountinfo 2>/dev/null; then
  nested_target_mounts=1
fi

if [ -f "$TARGET$CHROOT_MARKER" ] && [ "$nested_target_mounts" -eq 0 ]; then
  rm -f "$TARGET$CHROOT_MARKER" 2>/dev/null || true
  echo_warn "检测到陈旧 chroot marker，已自动清理: $TARGET$CHROOT_MARKER"
fi

if [ -f "$TARGET$CHROOT_MARKER" ] || [ "$nested_target_mounts" -eq 1 ]; then
  echo_err "检测到疑似嵌套chroot，已拒绝执行"
fi

check_selinux
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

do_mount "tmpfs" "$TARGET/tmp" "tmpfs" "nosuid,nodev,mode=1777"
do_mount "tmpfs" "$TARGET/run" "tmpfs" "nosuid,nodev,mode=755,size=200M"
do_mount "tmpfs" "$TARGET/dev/shm" "tmpfs" "nosuid,nodev,size=100M,mode=1777"

# ==============================================
# /data 兼容映射整理
# ==============================================
normalize_direct_android_mountpoints() {
  if [[ "$TARGET" == /data/* ]] && [ "$IMAGE_MODE" -eq 0 ]; then
    return 0
  fi

  if [ -L "$TARGET/android_data" ]; then
    case "$(readlink "$TARGET/android_data" 2>/dev/null || true)" in
      android_root/data|/android_root/data|android_data|/android_data)
        rm -f "$TARGET/android_data" 2>/dev/null || echo_err "无法移除遗留 android_data 符号链接"
        mkdir -p "$TARGET/android_data" 2>/dev/null || echo_err "无法创建目录挂载点: $TARGET/android_data"
        chown 0:0 "$TARGET/android_data" 2>/dev/null || true
        chmod 755 "$TARGET/android_data" 2>/dev/null || true
        echo_info "已将遗留 android_data 符号链接修正为目录挂载点"
        ;;
      *)
        echo_warn "检测到非标准 android_data 符号链接，保留原状: $(readlink "$TARGET/android_data" 2>/dev/null || true)"
        ;;
    esac
  elif [ ! -e "$TARGET/android_data" ]; then
    mkdir -p "$TARGET/android_data" 2>/dev/null || echo_err "无法创建目录挂载点: $TARGET/android_data"
    chown 0:0 "$TARGET/android_data" 2>/dev/null || true
    chmod 755 "$TARGET/android_data" 2>/dev/null || true
  fi

  if [ -L "$TARGET/data" ]; then
    case "$(readlink "$TARGET/data" 2>/dev/null || true)" in
      android_data|/android_data)
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

  if [[ "$TARGET" == /data/* ]] && [ "$DATA_MOUNT_OPT" = "ro" ]; then
    rm -rf "$TARGET/android_data" 2>/dev/null || true
    ln -snf android_root/data "$TARGET/android_data"
    rm -rf "$TARGET/data" 2>/dev/null || true
    ln -snf android_data "$TARGET/data"
    echo_warn "为避免 rootfs 位于 /data 下导致的递归自绑定风险，安全模式下 /data 与 /android_data 已只读映射到 /android_root/data"
    return 0
  fi

  do_mount "/data" "$TARGET/android_data" "bind" "$DATA_MOUNT_OPT"

  if [[ "$TARGET" == /data/* ]]; then
    if [ -L "$TARGET/data" ] || [ ! -e "$TARGET/data" ]; then
      rm -f "$TARGET/data" 2>/dev/null || true
      ln -snf android_data "$TARGET/data"
    elif [ -d "$TARGET/data" ]; then
      if [ -z "$(ls -A "$TARGET/data" 2>/dev/null)" ]; then
        rmdir "$TARGET/data" 2>/dev/null || true
        ln -snf android_data "$TARGET/data"
      elif [ ! -e "$TARGET/.rootfs_data" ]; then
        mv "$TARGET/data" "$TARGET/.rootfs_data" 2>/dev/null || true
        ln -snf android_data "$TARGET/data"
      else
        echo_warn "rootfs 原始 /data 已保留在 /.rootfs_data；当前 /data 使用安全等效映射 -> /android_data"
        rm -rf "$TARGET/data" 2>/dev/null || true
        ln -snf android_data "$TARGET/data"
      fi
    else
      rm -f "$TARGET/data" 2>/dev/null || true
      ln -snf android_data "$TARGET/data"
    fi
    echo_warn "为避免 rootfs 位于 /data 下导致的递归自绑定风险，chroot 内 /data 已安全等效映射到 /android_data"
  else
    do_mount "/data" "$TARGET/data" "bind" "$DATA_MOUNT_OPT"
  fi
}

do_mount "/" "$TARGET/android_root" "bind" "$HOST_ROOT_OPT"
normalize_direct_android_mountpoints

prepare_data_mapping

REAL_SYSTEM=$(resolve_mount_path "/system")
REAL_VENDOR=$(resolve_mount_path "/vendor")
REAL_PRODUCT=$(resolve_mount_path "/product")
REAL_ODM=$(resolve_mount_path "/odm")
REAL_BOOT=$(resolve_mount_path "/boot")
REAL_SYSTEM_EXT=$(resolve_mount_path "/system_ext")
REAL_APEX=$(resolve_mount_path "/apex")
REAL_METADATA=$(resolve_mount_path "/metadata")

do_mount "$REAL_SYSTEM" "$TARGET/system" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_SYSTEM" "$TARGET/android_system" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_VENDOR" "$TARGET/vendor" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_VENDOR" "$TARGET/android_vendor" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_PRODUCT" "$TARGET/product" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_PRODUCT" "$TARGET/android_product" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_ODM" "$TARGET/odm" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_ODM" "$TARGET/android_odm" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_BOOT" "$TARGET/android_boot" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_SYSTEM_EXT" "$TARGET/system_ext" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_APEX" "$TARGET/apex" "bind" "$SYS_MOUNT_OPT"
do_mount "$REAL_METADATA" "$TARGET/metadata" "bind" "$SYS_MOUNT_OPT"

if [ -d "/storage/emulated/0" ]; then
  do_mount "/storage/emulated/0" "$TARGET/storage/emulated/0" "bind" "$SDCARD_MOUNT_OPT"
  do_mount "/storage/emulated/0" "$TARGET/sdcard" "bind" "$SDCARD_MOUNT_OPT"
fi

if [ -s "/etc/resolv.conf" ]; then
  do_mount "/etc/resolv.conf" "$TARGET/etc/resolv.conf" "bind" "ro"
fi

touch "$TARGET$CHROOT_MARKER"
sync
sleep 0.3  # 等待 mount propagation 稳定
echo_info "挂载同步完成，准备执行 chroot 预检"
prepare_chroot_compat
CHROOT_EXEC_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin:/apex/com.android.runtime/bin:/android_root/system/bin:/android_root/system/xbin:/android_root/apex/com.android.runtime/bin"
ROOTFS_PRECHECK_SHELL="$(get_rootfs_chroot_shell)"
ROOTFS_PRECHECK_OUT="$(HOME=/root PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" "$ROOTFS_PRECHECK_SHELL" -c 'echo pre_sshd_ok' 2>&1 || true)"
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
  DAEMON_INFO_FILE="/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-${daemon_name}.info"
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
  echo_info "   SSH: root@<手机IP> -p ${ROOTFS_SSHD_PORT:-unknown}"
  echo_info "   sshd PID: ${ROOTFS_SSHD_PID:-unknown}"
  echo_info "   状态文件: $DAEMON_INFO_FILE"
  echo_info "   日志文件: $LOG_FILE"
  trap - EXIT SIGINT SIGTERM SIGHUP QUIT
  exit 0
fi

echo_info "✅ 环境构建完成"
echo_info "   /data            -> Android /data [默认rw；若 rootfs 位于 /data 下则安全等效映射到 /android_data；--safe 或 --ro-data 可只读]"
echo_info "   /system,/vendor,/product,/odm,/system_ext,/apex,/metadata -> Android标准路径 [默认ro]"
echo_info "   /storage/emulated/0 -> 内置存储 [默认rw；--safe 可只读]"
echo_info "   /android_root    -> 宿主 / [兼容别名，默认ro]"
echo_info "   /android_data,/android_system... -> 兼容别名，建议优先使用标准Android路径"
echo_info "   /dev             -> 完整设备节点"
echo_info "提示: 修改系统前手动 remount,rw，用完 remount,ro；若追求稳妥可加 --safe"

echo_info "🚀 进入Ubuntu chroot，exit 可安全退出"

cd "$TARGET" || echo_err "切换到chroot根目录失败"
if [ -x "$TARGET/usr/bin/run-parts" ] || [ -x "$TARGET/bin/run-parts" ]; then
  HOME=/root TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" /bin/bash -l
else
  echo_warn "rootfs内缺少 run-parts，跳过login shell初始化以避免报错（可在容器内安装 debianutils 后恢复 -l）"
  HOME=/root TERM="${TERM:-xterm-256color}" PATH="$CHROOT_EXEC_PATH" "$CHROOT_BIN" "$TARGET" /bin/bash
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ -x /system/bin/getenforce ] && [ "$(getenforce)" = "Enforcing" ] && [ "$PERMISSIVE" -eq 0 ]; then
    echo_err "chroot失败(EPERM概率高)：当前SELinux=Enforcing，请改用 --permissive 重试"
  fi
  owner_now=$(stat -c "%u:%g" "$TARGET" 2>/dev/null || echo "unknown")
  echo_err "chroot启动失败，退出码: $rc；请检查KernelSU授权、rootfs属主(当前$owner_now)及SELinux策略"
fi
