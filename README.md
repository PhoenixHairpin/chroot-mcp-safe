# chroot-mcp-safe.sh

**Android chroot 容器管理脚本 - 生产可用版本**

## 📌 当前版本

**v2.1.0 (Android Binary Support Edition)**  
**日期: 2026-04-11**  
**状态: ✅ 生产可用 (已验证稳定运行)**

---

## ✨ 本版本新功能

相比 v2.0 版本，本版本新增以下重要功能：

### 1. ✅ Android 二进制支持

**问题**: 之前 chroot 内无法运行 `/system/bin/toybox`、`getprop`、`pm`、`am` 等原生 Android 命令，报错 "not found" 或 linker 警告。

**解决方案**:
- **apex 使用 `rbind` 递归挂载** - Android APEX 模块使用多层挂载结构，普通 `bind` 只能挂载顶层，`rbind` 可递归挂载所有子挂载点
- **挂载 `/linkerconfig`** - 解决 Android 动态链接器的配置文件找不到问题，消除警告

**效果**:
```
# 现在可以直接运行 Android 原生命令
/system/bin/toybox --help      # 211 个内置命令
/system/bin/getprop ro.product.model
/system/bin/pm list packages   # 435 个应用
/system/bin/logcat -d
```

### 2. ✅ Binder IPC 支持

**问题**: `pm`、`am`、`settings`、`input` 等命令依赖 Binder IPC，报错 "Binder driver could not be opened"。

**解决方案**:
- **挂载 `/dev/binderfs`** - Binder 是 Android 的核心 IPC 机制，通过挂载 binderfs 使 chroot 内可以访问 Binder 设备

**效果**:
```bash
# Binder 相关命令现在可正常运行
/system/bin/pm list packages -3
/system/bin/am start -a android.intent.action.VIEW
/system/bin/settings get system screen_brightness
```

### 3. ✅ do_mount 函数新增 rbind 类型

```bash
# 支持新的挂载类型
do_mount "$REAL_APEX" "$TARGET/apex" "rbind" "$SYS_MOUNT_OPT"
```

### 4. ✅ cleanup 函数完善

新增卸载点：
- `$TARGET/linkerconfig`
- `$TARGET/dev/binderfs`

---

## 🔧 挂载点列表

本脚本会挂载以下路径到 chroot 环境：

| 源路径 | 目标路径 | 类型 | 说明 |
|--------|---------|------|------|
| `/` | `/android_root` | bind ro | 完整根目录视角 |
| `/system` | `/system`, `/android_system` | bind ro | 系统分区 |
| `/vendor` | `/vendor`, `/android_vendor` | bind ro | 厂商分区 |
| `/product` | `/product`, `/android_product` | bind ro | 产品分区 |
| `/odm` | `/odm`, `/android_odm` | bind ro | ODM 分区 |
| `/system_ext` | `/system_ext` | bind ro | 系统扩展分区 |
| `/data` | `/data`, `/android_data` | bind rw | 用户数据分区 |
| `/apex` | `/apex` | **rbind ro** | APEX 模块 (递归) |
| `/linkerconfig` | `/linkerconfig` | **bind ro** | 动态链接器配置 |
| `/dev/binderfs` | `/dev/binderfs` | **bind rw** | Binder IPC |
| `/metadata` | `/metadata` | bind ro | 元数据分区 |
| `/storage/emulated/0` | `/sdcard`, `/storage/emulated/0` | bind rw | 内置存储 |

---

## 🚀 使用方法

### 镜像容量（新增）

```bash
# 迁移为镜像时，默认创建 20GB（未指定时）
./chroot-mcp-safe.sh --migrate-image --distro ubuntu --rootfs /data/local/chroot/ubuntu

# 指定镜像目标容量（单位 GB）
./chroot-mcp-safe.sh --migrate-image --image-size-gb 40 --distro ubuntu --rootfs /data/local/chroot/ubuntu
```

交互模式选择“下载rootfs后启动”时，也会询问镜像大小（留空默认 20GB）。

行为说明：
- 仅在“新建镜像”时使用该容量参数
- 如果填写值小于最小所需空间，会自动上调到可用最小值
- 已存在的镜像文件不会因为该参数被自动缩容或改写

### 启动容器
```bash
# 后台启动 Ubuntu
./chroot-mcp-safe.sh --daemon --distro ubuntu --full-access --permissive

# SSH 连接 (端口 8023, 用户 root, 密码 123456)
ssh root@<手机IP> -p 8023
```

### 查看状态
```bash
./chroot-mcp-safe.sh --status --distro ubuntu
```

### 停止容器
```bash
./chroot-mcp-safe.sh --stop --distro ubuntu
```

### 运行 Android 命令
```bash
# 进入 chroot 后
/system/bin/getprop ro.build.version.release  # 获取 Android 版本
/system/bin/pm list packages                   # 列出所有应用
/system/bin/logcat -d                          # 查看日志
```

### 绕过 root 检测运行程序
```bash
# 使用 runuser 切换到普通用户
runuser -u testuser -- /path/to/program

# 或创建普通用户后使用
useradd -m -s /bin/bash myuser
runuser -u myuser -- python3 /tmp/some_script.py
```

---

## ✅ 验证测试

### Android 命令测试
| 命令 | 状态 | 说明 |
|------|------|------|
| `toybox` | ✅ | 211 个内置命令全部可用 |
| `getprop` | ✅ | 无警告，正常输出 |
| `pm` | ✅ | 可列出 435 个应用 |
| `am` | ✅ | 可启动 Activity |
| `settings` | ✅ | 可读写系统设置 |
| `logcat` | ✅ | 可查看日志 |
| `screenrecord` | ✅ | 可录制屏幕 |

### 用户切换测试
| 方法 | 状态 | 说明 |
|------|------|------|
| `su` | ❌ | 密码验证受限 |
| `runuser` | ✅ | 推荐，可切换用户 |
| `unshare --user` | ❌ | Android 内核不支持 |

### 网络测试
| 功能 | 状态 |
|------|------|
| DNS 解析 | ✅ (8.8.8.8) |
| wget | ✅ |
| apt update | ✅ |

---

## 📋 已修复的历史问题

1. **假性 ENOENT 间歇性失败** - mount propagation 未完全稳定导致动态链接器找不到库文件
   - 修复: 使用系统 chroot + sync + sleep 等待
2. **Android 二进制无法运行** - apex/linkerconfig 未正确挂载
   - 修复: rbind 递归挂载 apex + 挂载 linkerconfig
3. **Binder 命令失败** - 缺少 binderfs 挂载
   - 修复: 挂载 /dev/binderfs

---

## 📂 文件位置

- **脚本**: `/data/user/0/com.termux/files/home/chroot-mcp-safe.sh`
- **镜像**: `/data/local/chroot-images/ubuntu.img` (容量按创建参数，例如默认 20GB)
- **挂载点**: `/mnt/chroot-rootfs/ubuntu`
- **状态文件**: `/data/data/com.termux/files/usr/tmp/chroot-mcp-daemon-ubuntu.info`
- **日志**: `/data/data/com.termux/files/usr/tmp/chroot-mcp-*.log`

---

## ⚠️ 重要约束

- 宿主 SSH 端口 **8022** 必须始终可用，脚本不会影响此端口
- chroot SSH 端口 **8023** 用于容器访问
- 设备重启/断电后 runtime mount 自动消失，需重新启动

---

## 🔗 GitHub 仓库

https://github.com/PhoenixHairpin/chroot-mcp-safe

