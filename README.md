# chroot-mcp-safe

Android/Termux 下安全、可靠的 chroot 容器管理脚本。

## 功能特性

### 核心能力
- **原生 chroot**：不依赖 proot，直接使用 Linux chroot syscall
- **mount namespace 隔离**：独立的挂载命名空间，不影响宿主系统
- **ext4 镜像支持**：rootfs 可存储为 ext4 镜像文件，实现 `/data` 真 1:1 映射
- **后台 daemon 模式**：支持后台启动 SSH 服务，不占用交互终端

### 交互式管理
- **状态概览显示**：启动时显示所有发行版容器运行状态
- **安全终止卸载**：主菜单提供一键安全终止并卸载容器选项
- **智能检测**：自动检测运行中容器、残留进程，提供多种操作选项

### 支持的发行版
- Ubuntu (默认端口 8023)
- Debian (端口 8024)
- Arch Linux (端口 8025)
- Fedora (端口 8026)
- Alpine (端口 8027)

## 快速开始

### 无参数启动（交互式向导）
```bash
su -c /path/to/chroot-mcp-safe.sh
```

启动时会显示容器状态概览：
```
╔══════════════════════════════════════════════════════════════╗
║              容器运行状态概览                                ║
╠══════════════════════════════════════════════════════════════╣
║  🟢 ubuntu   运行中  PID=3488   Port=8023  2026-04-11 03:55:19 ║
║  ⚪ debian   未运行                                              ║
║  ⚪ arch     未运行                                              ║
║  ⚪ fedora   未运行                                              ║
║  ⚪ alpine   未运行                                              ║
╚══════════════════════════════════════════════════════════════╝
```

主菜单选项：
1. 启动已存在rootfs
2. 下载rootfs后启动
3. **安全终止卸载容器** ← 一键终止并清理
4. 只打印安装建议

### 后台模式启动
```bash
# 启动 Ubuntu 后台容器
su -c /path/to/chroot-mcp-safe.sh --daemon --distro ubuntu --full-access --permissive

# SSH 连接
ssh root@<手机IP> -p 8023
# 密码: 123456
```

### 查看状态
```bash
su -c /path/to/chroot-mcp-safe.sh --status --distro ubuntu
```

### 停止容器
```bash
# 命令行方式停止
su -c /path/to/chroot-mcp-safe.sh --stop --distro ubuntu

# 或在交互菜单选择「安全终止卸载容器」
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--interactive` | 强制进入交互式向导 |
| `--daemon` | 后台模式：挂载并启动 SSH 后立即返回 |
| `--status` | 查看后台容器状态 |
| `--stop` | 停止后台容器并清理挂载 |
| `--distro <名称>` | 指定发行版 (ubuntu/debian/arch/fedora/alpine) |
| `--rootfs <目录>` | 指定自定义 rootfs 路径 |
| `--full-access` | 全权限模式：/data 和存储可写（默认） |
| `--safe` | 安全模式：/data 和存储只读 |
| `--permissive` | 临时设置 SELinux 为 Permissive |
| `--ro-data` | /data 只读挂载 |
| `--proot-fallback` | chroot 失败时回退到 proot |
| `--migrate` | 将 rootfs 迁移到标准路径 |
| `--migrate-image` | 将 rootfs 迁移为 ext4 镜像 |

## 镜像模式优势

当 rootfs 位于 `/data` 子树下时，通过 ext4 镜像可实现：
- `/data` 目录的真 1:1 映射（避免递归自绑定问题）
- 更好的隔离性和稳定性
- 镜像文件可独立备份和迁移

镜像存储路径：`/data/local/chroot-images/<distro>.img`
挂载点：`/mnt/chroot-rootfs/<distro>`

## 安全特性

- **宿主 SSH 保护**：停止容器时不会误停 Termux SSH (端口 8022)
- **SELinux 处理**：自动检测并可选临时切换到 Permissive
- **挂载传播锁定**：所有挂载点设置为 private，避免泄漏到宿主
- **优雅终止**：先 TERM 再 KILL，确保进程正确退出
- **残留检测**：自动检测并处理残留挂载和进程

## 已修复问题

### "假性 ENOENT" 问题
- **现象**：chroot 命令间歇性报 "No such file or directory"，但文件实际存在
- **根因**：mount propagation 未完全稳定时，动态链接器找不到库文件
- **修复**：
  1. 强制使用系统 chroot (`/system/bin/chroot`)
  2. 挂载完成后执行 `sync` + `sleep 0.3` 等待稳定
  3. retry 等待时间增加到 2 秒

## 环境要求

- Android 设备，已 root (KernelSU/Magisk)
- Termux 环境
- 已安装的 Linux rootfs（可通过 proot-distro 或手动下载）

## 文件路径

| 文件 | 路径 |
|------|------|
| 主脚本 | `/data/user/0/com.termux/files/home/chroot-mcp-safe.sh` |
| 状态文件 | `/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-<distro>.info` |
| 日志文件 | `/data/data/com.termux/files/usr/tmp/chroot-mcp-<timestamp>.log` |
| 镜像文件 | `/data/local/chroot-images/<distro>.img` |

## License

MIT
