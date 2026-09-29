# dogfood 部署清单（research/08 T1.6 · 3 台设备 × 2 周）

> 目标：验证「看得懂的备份」假设（06 章）。原则：**语义层全部非致命**——装不上、推不出、
> 密封失败都不影响备份本体；dogfood 期间不主动提醒用户看 STORY（避免诱导），第 7/14 天才回收问卷。
> 凭据纪律：口令/恢复码/token 全部走 `secrets.env` 或密钥服务，任何截图/issue/日志先脱敏。

## 0. 共同前置（每台设备）

1. 依赖矩阵：

| 设备 | 引擎 | 同步 | 语义层依赖 |
|---|---|---|---|
| macOS | `brew install borgbackup rclone age` | rclone | Python 3.10+（系统自带） |
| Linux | `apt install borgbackup rclone` + age（[安装](https://github.com/FiloSottile/age#installation)） | rclone | Python 3.10+ |
| Windows | restic + rclone（`backup.ps1 -Task Init` 自动装） | rclone | [Python](https://python.org) 勾选 Add to PATH + age.exe（可选，未装则跳过密封） |

2. 存储目标：本地盘 / NAS / WebDAV 任一（BYO；B2 10GB 免费档亦可，成本见 research/05 §1）。
3. 每人一个 ntfy topic（可选但强烈建议）：自托管优先；用 ntfy.sh 则 topic 必须高熵随机串
   （`openssl rand -hex 8` 拼进 topic 名），topic 即订阅密码。

### 从旧机器迁移 rclone 配置（WebDAV 已在别处配置时）

向导默认新建名为 `Universal Backups` 的 remote；若 WebDAV 凭证只在旧机器上，直接迁移配置文件免重输：

```bash
mkdir -p ~/.config/rclone
scp 旧机:~/.config/rclone/rclone.conf ~/.config/rclone/
rclone listremotes        # 记下已有 remote 名
rclone lsd "已有remote名": # 验证可连
```

两种接法任选：①把已有 remote 改名为 `Universal Backups`（rclone.conf 里段名改一行）；
②保留原名，跑完 init.sh 后把 `~/.config/partiverse-backup/config.sh` 里的
`WEBDAV_REMOTE="Universal Backups"` 改成已有 remote 名。

## 1. macOS / Linux 接入（borg 路径）

```bash
git clone https://github.com/Partiverse/backguard.git ~/partiverse-backup
cd ~/partiverse-backup && ./init.sh          # 交互配置三档案 includes/excludes + secrets.env
```

语义层初始化（交互终端，一次性）：

```bash
# ① age 密钥 + 恢复码（打印一次，抄到纸上——这是第一恢复路径）
expect semantic/init-keys.exp "$(command -v age)" ~/.config/partiverse-backup/age

# ② 可选配置（config.sh 追加）
echo 'export SEM_NTFY_URL="https://<你的-ntfy>/backguard-<设备名>"' >> ~/.config/partiverse-backup/config.sh
# 密码管理器集成（可选，rbw；见 research/05 §7）：
echo 'export BORG_PASSCOMMAND="rbw get backguard-仓库口令"' >> ~/.config/partiverse-backup/config.sh
```

首次备份与验收：

```bash
SKIP_WEBDAV=1 ./backup.sh        # 先本地验证，不触云（备份前会自动跑 preflight 预检）
# 验收 checklist：
#  [ ] preflight 无 ✗（error 会中止备份；⚠ 警告按提示处理或确认忽略）
#  [ ] $BACKUP_BASE/timeline/<设备>/timeline/.../ 四件套齐全
#  [ ] MANIFEST.txt 用「文本编辑/手机文件 App」打开不乱版（CJK 对齐）
#  [ ] STORY.md 说的和你知道的最近改动对得上
#  [ ] ntfy 手机收到推送（配置了 SEM_NTFY_URL 时）
#  [ ] manifest.json.enc 可解：age -d -i ~/.config/partiverse-backup/age/identity.txt -o /tmp/m.json <enc>
./backup.sh                      # 再跑完整链路（含 WebDAV）
launchctl list | grep partiverse # 调度在位（init.sh 已注册，每日 02:34）
```

## 2. Windows 接入（restic 路径）

```powershell
git clone https://github.com/Partiverse/backguard.git
cd backguard
.\backup.ps1 -Task Init          # restic/rclone 自动装；交互配置 + Task Scheduler 02:34
```

语义层：`semantic\semantic.ps1` 自动生效（dot-source）。可选配置（`config.ps1` 追加）：

```powershell
$env:SEM_NTFY_URL = "https://<你的-ntfy>/backguard-<设备名>"
```

验收同上（四件套 / 推送 / Task Scheduler）；密封需装 age.exe 并手动生成
`%APPDATA%\PartiverseBackup\age\recipients.txt`（Windows 密钥初始化交互版在 M1 后续补齐）。

## 3. dogfood 行为契约（2 周）

- **不主动提醒**：组织者不在群里发「记得看 STORY」；通知只有备份系统自己的 ntfy 推送。
- **不加功能**：期间发现的问题记 issue，不现场改代码（保持被验证版本不变）。
- 第 7 / 14 天各回收一次问卷（两个核心问题 + 三个追问）：

| # | 问题 |
|---|---|
| Q1 | **这周你看过备份内容吗（STORY/MANIFEST/时间轴目录）？能说出上次备份了什么吗？** |
| Q2 | ntfy 推送到达后你的反应是什么（点开/忽略/烦躁）？ |
| Q3 | 看到的目录名/统计粒度有没有让你不舒服的地方（隐私体感）？ |
| Q4 | 断档警示（如有）出现时你做了什么？ |
| Q5 | 如果明天这个功能消失，你会在意吗？ |

指标侧（组织者回收）：备份连续天数中断 >72h 的人次、preflight/密封失败率、
盲恢复抽查（第 14 天每人随机抽 1 个文件走 rescue 路径，计时）。

## 4. 退出与决策

- 数据进 08 章 M4 的 go/no-go 判据（≥7/10 未提示即主动提及语义层价值）；
- 任一设备的语义层连续失败 3 次即记 defect（非致命哲学的检验：备份本身必须从未因此中断）；
- 2 周后组织者写 dogfood 复盘（含原始问卷），发布到 repo discussions。
