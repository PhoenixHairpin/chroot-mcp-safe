# chroot-mcp-safe.sh

**Android chroot 容器管理脚本 — 完整 Android 视图 + Agent 调试就绪**

## 📌 当前版本

**v2.2 (Agent-Enhanced Edition)**
**日期**: 2026-04-27
**状态**: ✅ 生产可用，已实测验证（281 条挂载 / 防变砖 10/10 / Agent 能力齐全）

---

## ✨ v2.2 与 v2.1.1 的核心差异

v2.2 在 v2.1.1 的 Android 二进制 + Binder 能力之上，进一步打通了 **AI Agent / 逆向调试 / 内核探测** 全链路。

### 1. 🎯 完整 Android 文件系统视图

之前 `chroot` 内的 `/data/user/0/<pkg>` 看不见、`/storage/emulated/0/Android/data` 是空的，因为单层 `bind` 不会带子挂载进容器。本版改成 `rbind`，宿主侧任何子挂载（包括 Android 多用户机制创建的 bind mount）都会原样进入容器。

```
之前:  /data/user/0          → 空目录（看不到 com.tencent.mm 等）
现在:  /data/user/0/<any-pkg> → 完全可达，inode 与宿主一致
```

### 2. 🛡️ 多挂载点 Agent 增强区

| 路径 | 类型 | 作用 |
|------|------|------|
| `/data_mirror` | rbind rw | Android 11+ 多用户镜像（FBE 加密分层） |
| `/mnt` | rbind rw | 完整多用户视图（user/0、pass_through/0、installer/0、androidwritable/0） |
| `/mi_ext` | bind ro | 小米厂商扩展分区（其它厂商对应字段也能看） |
| `/sys/kernel/debug` | debugfs rw | BPF / kprobe / uprobe / 内核调试 |
| `/sys/kernel/tracing` | tracefs rw | ftrace / perf_event / stackplz |

### 3. 🚫 高危区主动加固（防变砖核心）

宿主上 `/mnt/vendor/persist`（IMEI/序列号/校准）、`/mnt/vendor/qmcs`（高通 QMCS 认证）默认是 rw 的。直接 rbind 进容器后这些区域写一笔就可能变砖。本版在挂载完 `/mnt` 后**自动 remount,bind,ro 强制只读**：

```
[INFO] 🛡 已强制只读: /mnt/vendor/persist（变砖防护）
[INFO] 🛡 已强制只读: /mnt/vendor/qmcs（变砖防护）
```

### 4. 🔒 rbind 子树传播隔离

`do_mount` 的 rbind 分支在挂载后立即执行 `mount --make-rprivate $dst`，把整棵子树的传播属性切成 `private`，确保容器内对子挂载点的任何后续操作（包括 lazy umount）都不会反向传播到宿主。这是 v2.1.1 没有的关键加固。

### 5. ⚙️ 卸载完整性

- `daemon_stop` / `stop_runtime_by_pid_target` / `quick_lazy_umount` 三处的 lazy-umount 白名单加入 `/data` `/data_mirror` `/mnt` `/dev`（rbind 挂载必须 lazy 否则 EBUSY）
- 卸载列表新增 `/sys/kernel/tracing` `/sys/kernel/debug` `/mi_ext` `/mnt` `/data_mirror`（顺序：先内层后外层）

### 6. 🔧 微调

- `sysfs` 从 `ro` 改 `rw` —— 让容器内能 `mkdir` 子挂载点；sysfs 节点本身的写权限受内核保护，不会因此放大风险
- `/dev` 去掉 `noexec` —— 让 frida / stackplz 等需要在 ashmem/dev 节点 mmap 可执行映射的工具能跑
- 取消 v2.1.1 的 `/android_root /android_data /android_*` 别名挂载（脚本已主动清理）—— 避免对 AI Agent 形成路径噪音

---

## 🔧 完整挂载点列表

| 源路径 | 目标路径 | 类型 | 权限 | 说明 |
|--------|---------|------|------|------|
| `proc` | `/proc` | proc | rw | 进程信息 |
| `sysfs` | `/sys` | sysfs | rw | 内核/设备信息（节点本身受内核保护） |
| `/dev` | `/dev` | **rbind** | rw,nosuid | 含 binderfs/cgroup/usb-ffs/ashmem 等全部子设备 |
| `devpts` | `/dev/pts` | devpts | rw | 独立 pts 实例 |
| `tmpfs` | `/tmp /run /dev/shm` | tmpfs | rw | 容器内临时区 |
| `/data` | `/data` | **rbind** | rw | **含 `/data/user/0` 等所有子挂载** |
| `/system` | `/system` | bind | **ro** | 系统分区 |
| `/vendor` | `/vendor` | bind | **ro** | 厂商分区 |
| `/product` | `/product` | bind | **ro** | 产品分区 |
| `/odm` | `/odm` | bind | **ro** | ODM 分区 |
| `/system_ext` | `/system_ext` | bind | **ro** | 系统扩展 |
| `/apex` | `/apex` | rbind | **ro** | APEX 模块（递归） |
| `/metadata` | `/metadata` | bind | **ro** | **变砖高危区，强制只读** |
| `/linkerconfig` | `/linkerconfig` | bind | ro | 动态链接器配置 |
| `/storage/emulated/0` | `/storage/emulated/0`, `/sdcard` | **rbind** | rw | **含 Android/data, Android/obb 子挂载** |
| `/data_mirror` | `/data_mirror` | **rbind** | rw | Android 11+ 多用户镜像 |
| `/mnt` | `/mnt` | **rbind** | rw | 完整 mnt 视图（含强制 ro 加固） |
| ↳ `/mnt/vendor/persist` | 同名 | remount | **ro** | **强制变砖防护**（IMEI/校准） |
| ↳ `/mnt/vendor/qmcs` | 同名 | remount | **ro** | **强制变砖防护**（高通认证） |
| `/mi_ext` | `/mi_ext` | bind | ro | 厂商扩展（小米机型） |
| `/sys/kernel/debug` | 同名 | debugfs | rw | 内核调试（BPF/kprobe） |
| `/sys/kernel/tracing` | 同名 | tracefs/bind | rw | ftrace / perf |

**统计**: 容器内 `mount | wc -l` ≈ 280+ 条（与宿主完整等价）

---

## 🛡️ 防变砖三层保险

1. **Namespace 隔离**: `unshare --mount --propagation private` 把整个容器挂载操作放进独立 mount namespace
2. **传播隔离**:
   - 根目录 `mount --make-rprivate /` 切断容器→宿主传播
   - 每个 rbind 后立即 `mount --make-rprivate $dst` 切断子树传播
3. **强制 ro 加固**: 高危区即便挂进来也是只读
   - `/system /vendor /product /odm /system_ext /apex /metadata /mi_ext` — 8 项分区
   - `/mnt/vendor/persist /mnt/vendor/qmcs` — 2 项主动 remount

**断电安全**:
- 容器异常退出 / 系统重启 → namespace ref=0 → 内核自动 GC 所有副本挂载 → **宿主分区零影响**
- daemon_stop 三段式: `sync → kill → remount,ro → umount → losetup -d`
- `--emergency-sync` 急救命令，断电前手动刷盘

---

## 🚀 使用方法

### 启动容器（后台 sshd）
```bash
# 默认 Ubuntu，端口 8023，root / 123456
./chroot-mcp-safe.sh --daemon --distro ubuntu --full-access --permissive

# 指定端口
./chroot-mcp-safe.sh --daemon --distro ubuntu --sshd-port 8024 --full-access --permissive
```

### SSH/SFTP 连接
```bash
ssh root@<手机IP> -p 8023        # 默认密码 123456
sftp -P 8023 root@<手机IP>
```

### 状态 / 停止
```bash
./chroot-mcp-safe.sh --status --distro ubuntu
./chroot-mcp-safe.sh --stop   --distro ubuntu
./chroot-mcp-safe.sh --emergency-sync     # 紧急刷盘
```

### 交互式向导
```bash
./chroot-mcp-safe.sh -i          # 推荐首次使用
```

### 镜像扩容
```bash
./chroot-mcp-safe.sh --resize-image --distro ubuntu --image-size-gb 50
```

---

## ✅ 验证测试（v2.2 实测）

| 测试项 | 结果 |
|--------|------|
| 容器内访问 `/data/user/0/com.tencent.mm/...` | ✅ 完全可达 |
| 容器内 `/sdcard/Android/data` 子挂载可见 | ✅ |
| 容器内 binderfs 完整（binder/hwbinder/vndbinder） | ✅ |
| ftrace 145 个事件可写（启用/禁用 sched_switch） | ✅ |
| debugfs 143 个内核接口 | ✅ |
| `/proc/kallsyms` 可读 | ✅ |
| 写 `/metadata` | ❌ Read-only file system（防护生效） |
| 写 `/mnt/vendor/persist` | ❌ Read-only file system（防护生效） |
| 写 `/mnt/vendor/qmcs` | ❌ Read-only file system（防护生效） |
| 写 `/system /vendor /odm /product /system_ext /apex /mi_ext` | ❌ 全部只读 |
| 写 `/data /data/user/0 /sdcard /tmp` | ✅ 可写 |
| 容器异常退出后宿主分区状态 | ✅ 无残留挂载 |

---

## 🔬 Agent / 逆向调试就绪

v2.2 专门为 AI Agent 和逆向调试场景设计，以下工具开箱即用：

| 类型 | 工具 | 依赖 | 状态 |
|------|------|------|------|
| **eBPF** | stackplz, bcc, libbpf | debugfs, tracefs | ✅ |
| **Hook** | frida, frida-server | /dev/ashmem (rw exec) | ✅ |
| **Trace** | strace, ltrace | /proc, /dev/pts | ✅ |
| **逆向** | radare2, ghidra | /data, /system 只读访问 | ✅ |
| **Binder** | dumpsys, service, am, pm | /dev/binderfs | ✅ |
| **内存** | /proc/<pid>/mem | /proc 完整视图 | ✅ |
| **Java Hook** | xposed-bridge user-space | binderfs + /data/user/0 | ✅ |

---

## 📂 文件位置

- **脚本**: `/data/user/0/com.termux/files/home/chroot-mcp-safe.sh`
- **镜像**: `/data/local/chroot-images/<distro>.img` (默认 20GB)
- **挂载点**: `/mnt/chroot-rootfs/<distro>`
- **状态文件**: `/data/local/tmp/chroot-mcp/chroot-mcp-daemon-<distro>.info`
- **日志**: `/data/local/tmp/chroot-mcp/chroot-mcp-*.log`
- **端口配置**: `/data/local/chroot-config/<distro>.port`

---

## ⚠️ 重要约束

- 宿主 SSH 端口默认 **8022**，容器 sshd 默认 **8023**（自动避让冲突）
- 容器内 root 密码默认 **123456**（可用 `--root-password` 或环境变量 `MCP_ROOT_PASSWORD` 覆盖）
- 设备重启后 runtime mount 自动消失，需重新执行启动命令（可加入 KernelSU/Magisk boot 脚本自动启动）
- 镜像模式 (`--auto-migrate-image`) 推荐用于性能/可扩容/整存整删；rootfs 目录模式更便于直接编辑
- 推荐发行版优先级: **Ubuntu 24.04 / Debian 12 > Arch > Fedora > Alpine**

---

## 📋 历史版本变化

### v2.2 (2026-04-27) — 当前版本
- ✅ 完整 Android 视图（rbind 子挂载 + 多挂载点增强）
- ✅ Agent 调试就绪（debugfs/tracefs/binderfs）
- ✅ 高危区强制 ro 加固
- ✅ rbind 子树 make-rprivate 传播隔离

### v2.1.1 (2026-04-11) — Android Binary Support
- ✅ APEX rbind 递归挂载（toybox/getprop/pm/am 可用）
- ✅ Binder IPC 支持（pm/am/settings/input）
- ✅ linkerconfig 挂载（消除 linker 警告）

### v2.0 — Safe Edition 基线
- ✅ 独立 mount namespace
- ✅ 双路径(/data + /android_data) 兼容
- ✅ 默认安全模式 + 显式 --full-access

---

## 🔗 GitHub

https://github.com/PhoenixHairpin/chroot-mcp-safe

历史归档保留在 [`.archive/`](./.archive/) 目录，方便对比早期实现。

---

## 📜 License

继承原仓库 license（未指定时默认私有，欢迎附 MIT/Apache-2.0）。
