# chroot-mcp-safe.sh 发布说明

## 版本: 20260411-enter-container-fixed

## 本次修复内容

### 修复问题: "直接进入容器"功能失败

**错误现象**:
```
chroot: failed to run command '/bin/bash': No such file or directory
```

**根因分析**:
- Daemon 运行在私有 mount namespace
- 宿主 namespace 无法访问 rootfs（只存在于 daemon namespace）
- 在 namespace 内执行 `chroot` 时 PATH 不包含 `/system/bin`
- Android 的 chroot 位于 `/system/bin/chroot`，而非标准 Linux 路径

**解决方案**:
```bash
enter_existing_container() {
  local ns_pid="$1"
  local target="$2"

  [ -n "$ns_pid" ] || echo_err "直接进入失败：缺少目标 pid"
  [ -n "$target" ] || echo_err "直接进入失败：缺少目标 rootfs"
  [ -d "/proc/$ns_pid" ] || echo_err "直接进入失败：目标 pid 不存在: $ns_pid"

  echo_info "直接进入已运行容器: pid=$ns_pid target=$target"

  # 关键：使用 /system/bin/chroot 确保 namespace 内可找到 chroot 命令
  nsenter -t "$ns_pid" -m /data/data/com.termux/files/usr/bin/sh -c \
    "cd '$target' && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /system/bin/chroot . /bin/bash -i"
}
```

## 已验证功能

| 功能 | 状态 |
|------|------|
| daemon 启动 (--daemon) | ✅ |
| 状态查询 (--status) | ✅ |
| 停止清理 (--stop) | ✅ |
| 直接进入容器 | ✅ |
| 停止后再进入 | 待用户验证 |
| 宿主 SSH 8022 | ✅ 保持正常 |
| chroot SSH 8023 | ✅ |

## 使用方法

```bash
# 启动交互向导
/data/user/0/com.termux/files/home/chroot-mcp-safe.sh

# 后台启动 Ubuntu
./chroot-mcp-safe.sh --daemon --distro ubuntu --full-access --permissive

# 查看状态
./chroot-mcp-safe.sh --status --distro ubuntu

# 停止
./chroot-mcp-safe.sh --stop --distro ubuntu

# 直接进入已运行容器（修复后的功能）
# 运行脚本后选择：启动已存在rootfs → ubuntu → 选择"直接进入容器"
```

## 默认端口配置

| 发行版 | SSH 端口 |
|--------|----------|
| ubuntu | 8023 |
| debian | 8024 |
| arch | 8025 |
| fedora | 8026 |
| alpine | 8027 |

## 重要提醒

- 宿主 Termux SSH 端口 **8022** 必须始终可用，脚本不会影响它
- 镜像 rootfs 位于 `/data/local/chroot-images/<distro>.img`
- 挂载点 `/mnt/chroot-rootfs/<distro>` 在 daemon 的私有 namespace 内
- 设备重启后需要重新启动 daemon