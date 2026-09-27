# Partiverse Backup System

三平台统一备份系统：Linux · macOS · Windows，自动检测安装依赖、交互初始化、三档案语义化加密备份到 WebDAV。

---

## 快速开始

**Linux / macOS**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Partiverse/backguard/main/init.sh)"
```

**Windows** (PowerShell)
```powershell
irm https://raw.githubusercontent.com/Partiverse/backguard/main/init.ps1 | iex
```

或手动克隆：
```bash
git clone git@github.com:Partiverse/backguard.git ~/partiverse-backup
cd ~/partiverse-backup
./init.sh        # Linux / macOS
# 或
.\init.ps1       # Windows
```

---

## 三档案语义

| 档案 | 内容 | 工具 | 备份频率 |
|------|------|------|----------|
| `config` | 敏感配置：SSH 密钥、GPG 密钥、密码管理器、KDE 配置 | borg / restic | 每 6h |
| `files` | 用户数据：Documents、Desktop、Pictures 等 | borg / restic | 每 6h |
| `system` | 系统元数据：软件包清单、磁盘布局、fstab、EFI 启动项 | borg / restic | 每 6h |

### 档案命名

设备系统标识自动生成，格式：

```
<hostname>-<OS><version>

# 示例
partiverse-Kubuntu26.04    # 本机
MacBook-Pro-macOS15.0      # macOS
DESKTOP-WIN11-Windows11    # Windows
```

归档格式：`<device-id>-<class>-<YYYYMMDD-HHMMSS>`

### WebDAV 目录结构

```
<WebDAV root>/
  partiverse-Kubuntu26.04/
    config/     ← borg/restic repo
    files/      ← borg/restic repo
    system/     ← borg/restic repo
  MacBook-Pro-macOS15.0/
    config/
    files/
    system/
  DESKTOP-WIN11-Windows11/
    config/
    files/
    system/
```

---

## 保留策略（两层差异化）

| 层 | 策略 | 原理 |
|----|------|------|
| **本地**（备份盘） | borg/restic prune：保留最近 **7 天每日 + 4 周每周 + 6 个月每月** | 本地空间有限，只留周期性快照，超出自动清理 |
| **云端**（WebDAV/123Pan） | **永不删除**，只增不减 | 云端空间充裕（20TB+），保留全部历史作为最终防线 |

实现方式：本地每次备份后执行 `borg prune`（或 restic forget）；云端用 `rclone copy` 而非 `sync`——`sync` 会把本地 prune 掉的归档同步删除到云端，`copy` 则只增不删，云端历史完整保留。

> 若云端空间将来吃紧，可对云端仓库单独执行低频 prune（如 `--keep-monthly=24`），但脚本默认不做。

---

## 平台支持

| 平台 | 备份工具 | 调度 | 凭证存储 |
|------|---------|------|---------|
| Linux | borgbackup | systemd user timer | `~/.config/partiverse-backup/secrets.env` |
| macOS | borgbackup | launchd | `~/.config/partiverse-backup/secrets.env` |
| Windows | restic + rclone | Task Scheduler | `%APPDATA%\PartiverseBackup\secrets.env` |

---

## 目录结构

```
backup/
├── README.md           本文件
├── init.sh             交互式初始化（Linux / macOS）
├── init.ps1            交互式初始化（Windows）
├── backup.sh           主备份脚本（跨平台）
├── backup.ps1          Windows 备份脚本
├── restore.sh          恢复脚本（Linux / macOS）
├── platform/
│   ├── linux.sh        Linux 平台配置（依赖安装、元数据、调度）
│   ├── macos.sh        macOS 平台配置
│   └── windows.ps1     Windows 平台配置
└── .gitignore          忽略 secrets.env 和本地缓存
```

---

## 依赖

| 工具 | Linux | macOS | Windows | 用途 |
|------|-------|-------|---------|------|
| borgbackup | apt/dnf/pacman | brew | — | 备份引擎（Linux/macOS） |
| restic | — | — | GitHub releases | 备份引擎（Windows） |
| rclone | apt/brew | brew | rclone.org | WebDAV 同步 |
| btrfs-progs | apt | — | — | system 档案磁盘元数据 |
| efibootmgr | apt | — | — | EFI 启动项备份（Linux） |

**自动安装**：首次运行 `init.sh` / `init.ps1` 时自动检测并安装缺失依赖。

---

## 恢复

```bash
# Linux / macOS — 列出归档
./restore.sh --list

# 恢复指定档案到指定路径
./restore.sh --archive config --target ~/.restore/

# Windows
.\restore.ps1 -List
.\restore.ps1 -Archive config -Target C:\Restore
```

---

## 手动触发

```bash
./backup.sh              # Linux / macOS
.\backup.ps1             # Windows
```

---

## 更新

```bash
cd ~/partiverse-backup
git pull                 # 拉取最新脚本
./backup.sh             # 用新脚本跑一次备份
```

---

## 撤销

```bash
# Linux — 停止并删除 timer
systemctl --user stop partiverse-backup.timer
systemctl --user disable partiverse-backup.timer
rm ~/.config/systemd/user/partiverse-backup.{service,timer}
rm -rf ~/.config/partiverse-backup

# macOS
launchctl unload ~/Library/LaunchAgents/com.partiverse.backup.plist
rm ~/Library/LaunchAgents/com.partiverse.backup.plist
rm -rf ~/.config/partiverse-backup

# Windows — Task Scheduler
Unregister-ScheduledTask -TaskName PartiverseBackup -Confirm:$false
Remove-Item -Recurse -Force "$env:APPDATA\PartiverseBackup"
```

---

## 设计原则

1. **平台一致性**：三端目录结构、归档命名、WebDAV 路径格式完全统一
2. **零手动安装**：init 脚本自动装依赖、配调度、建仓库
3. **凭证安全**：密码存本地文件（600/700 权限），永不明文上网
4. **幂等恢复**：init 可重复运行，已初始化则跳过
5. **透明恢复**：每份归档均有元数据，可完整重建系统环境
