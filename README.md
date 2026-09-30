# Partiverse Backup System

三平台统一备份系统：Linux · macOS · Windows，自动检测安装依赖、交互初始化、三档案语义化加密备份到 WebDAV。

---

## 快速开始

**Linux / macOS**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Partiverse/backguard/main/init.sh)"
```

**Windows** (PowerShell) —— 克隆后初始化：
```powershell
git clone https://github.com/Partiverse/backguard.git
cd backguard
.\backup.ps1 -Task Init
```

或手动克隆：
```bash
git clone https://github.com/Partiverse/backguard.git ~/partiverse-backup
cd ~/partiverse-backup
./init.sh                # Linux / macOS
# Windows 用 .\backup.ps1 -Task Init（init.ps1 尚未提供）
```

---

## 三档案语义

三个档案类别在**所有平台上语义一致**，但具体路径因 OS 而异。界定原则：

- **config** = 丢了会很痛、难以从头重建的东西（凭证、密钥、应用配置）。体量小，同步频率最高。
- **files** = 用户自己产生的数据（文档、图片、视频）。丢失不可再生，是备份的核心目标。
- **system** = 操作系统层面的"图纸"（元数据、清单、布局）。不追求还原整个 OS，只保证**可照着图纸重建**。
- **dotfiles** 是 config 的子集：config 档案备份的是**实际部署的文件**（即使 dotfiles 仓库丢了也能恢复）；若使用 dotfiles 仓库管理，则在 `config.sh` 中设置 `DOTFILES_REPO`，其地址会记入 system-meta（恢复时知道去哪 clone，但仓库本身不承担备份职责）。

### 各平台明细

| 档案 | Linux (borg) | macOS (borg) | Windows (restic) |
|------|-------------|--------------|------------------|
| **config** | `~/.config/`、`~/.ssh/`、`~/.gnupg/`、Bitwarden/kwalletd/konsole 数据 | `~/.ssh/`、`~/.gnupg/`、`~/Library/Keychains/`、`~/Library/Preferences/` | `%USERPROFILE%\.ssh\`、`%APPDATA%`（选定性） |
| **files** | `~/Documents`、`~/Desktop`、`~/Pictures` | `~/Documents`、`~/Desktop`、`~/Pictures`、`~/Movies`、`~/Music` | Documents、Desktop、Pictures、Videos（Known Folders） |
| **system** | `/etc/` + 采集元数据：包清单(dpkg/flatpak/snap)、`lsblk`、`findmnt`、`fstab`、`efibootmgr`、crontab、工具版本 | `system_profiler`、`launchctl list`、`brew list`、软件更新历史 | winget 程序清单、服务列表、硬件/驱动信息、`bcdedit /v` |

### 档案命名

设备标识自动生成：`<设备名>-<系统>`，**统一小写、不含 OS 版本**（大小写是跨云厂商的
安全交集——不少 WebDAV 大小写不敏感；系统升级不分裂备份历史，版本信息进 system-meta）：

```
particloud-macos     # macOS（hostname 短名，去 .local）
particloud-windows   # Windows
partiverse-kubuntu   # Linux（/etc/os-release 的 ID）
```

品牌原名（macOS / Windows / 发行版全名）记录在 `timeline/<设备>/profile.json`；
路径中的点统一转连字符。

归档格式：`<device-id>-<class>-<YYYYMMDD-HHMMSS>`

### 云端目录结构

```
<remote:子路径>/              ← BACKUP_TARGETS 可配多个 remote，结构一致
  particloud-macos/
    config/     ← borg/restic repo
    files/      ← borg/restic repo
    system/     ← borg/restic repo
  partiverse-kubuntu/
    config/  files/  system/
  timeline/                   ← 语义层，只增不减
    particloud-macos/
      profile.json            ← 设备品牌原名等元数据
      2026/09/30/0234-morning/
        MANIFEST.txt · STORY.md · restore.md · COVERAGE.txt · exclusions.json · manifest.json.enc
```

---

## 保留策略（两层差异化）

| 层 | 策略 | 原理 |
|----|------|------|
| **本地**（备份盘） | borg/restic prune：保留最近 **7 天每日 + 4 周每周 + 6 个月每月** | 本地空间有限，只留周期性快照，超出自动清理 |
| **云端**（WebDAV/123Pan） | **永不删除**，只增不减 | 云端空间充裕（20TB+），保留全部历史作为最终防线 |

实现方式：本地每次备份后执行 `borg prune`（或 restic forget）；云端用 `rclone copy` 而非 `sync`——`sync` 会把本地 prune 掉的归档同步删除到云端，`copy` 则只增不删，云端历史完整保留。

> 若云端空间将来吃紧，可对云端仓库单独执行低频 prune（如 `--keep-monthly=24`），但脚本默认不做。

云端推送失败**不再被算作完成**：任一目标 `rclone copy` 失败时，`backup.sh` 打出
「本地完成，云端同步失败 X/Y」并以非零退出（配置 `SEM_NTFY_URL` 时同时推送告警）。
本地仓库不受影响，失败的目标下次运行自动补传。

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
├── init.sh             交互式初始化（Linux / macOS；Windows 走 backup.ps1 -Task Init）
├── backup.sh           主备份脚本（跨平台）
├── backup.ps1          Windows 备份脚本
├── restore.sh          恢复脚本（Linux / macOS）
├── drill.sh            恢复演练独立入口（解封→抽样→实取→校验，30 天节流可 --force 绕开）
├── semantic/           语义层（每次备份自动生成可读时间轴）
│   ├── semantic.sh     编排：清单导出 → convert → generate → 密封 → 推送（borg）
│   ├── semantic.ps1    同上（restic / Windows）
│   ├── init-keys.exp   密钥初始化（expect 驱动 age，恢复码闭环验证）
│   ├── bg_semantic.py  语义核心（MANIFEST.txt / STORY.md / restore.md / manifest）
│   └── bg.pyz          上述单文件打包
├── test_*.sh           隔离环境 E2E（本机与 CI 同源：多目标 / 恢复 / 云端失败 / 跨平台属性）
└── .gitignore          忽略 secrets.env 和本地缓存
```

---

## 语义层配置（可选，全部非致命：缺依赖只跳过不影响备份）

备份成功后自动生成语义快照（本地暂存 `<BACKUP_BASE>/timeline/<设备>/年/月/日/时分-标签/`，
随内容池上传到每个 `BACKUP_TARGETS` 的 `timeline/<设备>/` 下）：

| 文件 | 说明 |
|---|---|
| `MANIFEST.txt` | 明文摘要卡（文件数/体积/目录分布），裸文件管理器可读 |
| `STORY.md` | 中文叙事：「新增 214 张照片，日本旅行-0926」；断档 >48h 置顶警示 |
| `restore.md` | 本快照恢复指引（含 manifest.json.enc 双路径解密命令） |
| `manifest.json.enc` | 完整文件清单（age 加密账本，完整文件名只存在这里） |

配置项（写入 `config.sh` / `config.ps1`）：

| 变量 | 作用 |
|---|---|
| `BACKUP_TARGETS` | 备份目标数组，`"remote:子路径"` 格式，设备目录自动追加；**rclone 统一管理**，可配多个（WebDAV/B2/S3/SFTP/NAS…），例：`BACKUP_TARGETS=("webdav-main:backups" "b2-backup:backups")`。旧变量 `WEBDAV_REMOTE`(+`WEBDAV_ROOT`) 仍兼容（自动转为单目标） |
| `SEM_NTFY_URL` | ntfy 推送（STORY 摘要 + 云端同步失败告警，如自托管 `https://ntfy.example.com/backguard-设备名`）；推荐自托管，公共服务 topic 请用高熵随机串 |
| `SEM_LABEL` | 覆盖自动时段标签（morning/noon/afternoon/evening/night） |
| `SEM_KEYS_DIR` | 密钥目录（默认 `~/.config/partiverse-backup/age` / `%APPDATA%\PartiverseBackup\age`） |
| `SEM_PREFLIGHT` | 设 `0` 关闭备份前预检（默认开；预检 error 中止备份，warning 继续并留日志） |
| `SEM_TIMELINE_KEEP` | 本地 timeline 暂存保留最近 N 份快照（默认 14，`0`=不清理；云端全量历史不受影响） |

备份前预检（`bg preflight`）会检查：include 路径有效性、iCloud/OneDrive 占位文件
（未真正落盘的"半真文件"）、.git 被静默排除、磁盘空间、引擎版本下限、
备份目标 remote 是否存在于 rclone 配置、凭据外部化状态（`BORG_PASSCOMMAND`
引用的 CLI 在位、rbw-agent 解锁）。

密钥初始化（交互终端运行一次，恢复码抄写到纸上）：

```bash
expect semantic/init-keys.exp "$(command -v age)" ~/.config/partiverse-backup/age
```

依赖：Python 3（渲染）、age（清单密封）；二者缺失时对应产物自动跳过。
隐私红线：明文层永不出现完整文件名（凭据目录只写数量）；`manifest.json.enc` 用
主身份或恢复码任一路径解密，命令见每个快照的 `restore.md`。

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

# 恢复指定档案的最新快照到指定路径（--latest 与 --id 必须二选一）
./restore.sh --archive config --latest --target ~/.restore/
./restore.sh --archive files --id <设备名>-files-20260930-023400 --target ~/.restore/

# 随时验证恢复链路真的通（不必等夜间那次的 30 天节流）
./drill.sh --force

# Windows：暂用 restic 命令行（rescue 独立脚本待补，见 docs/HANDOVER §6）
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
