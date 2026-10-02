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

2. 存储目标（rclone 统一管理）：每个 remote 由你自行 `rclone config` 增删（WebDAV/B2/S3/SFTP/NAS…均可并存），
   `config.sh` 的 `BACKUP_TARGETS` 只引用 remote 名——加第二个云端 = 加一个 remote + targets 里加一项。
   设备目录（`<SYSTEM_ID>`）自动追加到每个目标的子路径下，多设备同 remote 互不覆盖；
   旧写法 `WEBDAV_REMOTE`(+`WEBDAV_ROOT`) 仍兼容（自动转单目标）。B2 10GB 免费档亦可，成本见 research/05 §1。
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
`BACKUP_TARGETS` 里的 remote 名改成已有 remote（向导检测到已有 remote 时也会直接让你选）。

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
# 本地 timeline 暂存快照保留份数（默认 14；云端是全量历史，本地保 N 份供云端丢失时重建，0=不清理）：
echo 'export SEM_TIMELINE_KEEP=14' >> ~/.config/partiverse-backup/config.sh
# 运行日志轮转（backup.log 单轮约 10 KB，一轮一行 `run 边界: sha=… rc=… dur=…s` 写在日志末尾）：
# 现役日志超 SEM_LOG_MAX_BYTES 才切一份带时间戳的副本，副本按 mtime 留最近 SEM_LOG_KEEP 份。
# 只切 $LOG_DIR 下点名的四份（backup/rclone/sem/drill）；launchd.{out,err}.log 由 launchd 持句柄，不动。
echo 'export SEM_LOG_MAX_BYTES=4194304' >> ~/.config/partiverse-backup/config.sh
echo 'export SEM_LOG_KEEP=7' >> ~/.config/partiverse-backup/config.sh
# 云端副本自证（默认开，`SEM_CLOUD_VERIFY=0` 关）：推送全报成功之后，再按「本地对象是否
# 都在云端且尺寸一致 + 仓库 config 内容哈希」复核一次，结论写 timeline/CLOUD-VERIFY.txt。
# 判读口径见下面「再跑完整链路」那段

# ③ 救援身份的密文另存第二处（第二台设备 / 加密 U 盘）
#    云端副本里**没有** age/ 目录：recovery-identity.enc 从不推送，所以「干净机器 +
#    云端备份目录 + 纸上恢复码」目前还缺一块料。拷法是人工搬运，不经本仓库、不触云
cp ~/.config/partiverse-backup/age/recovery-identity.enc <第二处目录>/
```

首次备份与验收：

```bash
SKIP_WEBDAV=1 ./backup.sh        # 先本地验证，不触云（备份前会自动跑 preflight 预检）
# 验收 checklist：
#  [ ] preflight 无 ✗（error 会中止备份；⚠ 警告按提示处理或确认忽略）
#  [ ] $BACKUP_BASE/timeline/<年>/<月>/<日>/<时分-标签>/ 四件套齐全（时间轴根下没有设备层）
#  [ ] MANIFEST.txt 用「文本编辑/手机文件 App」打开不乱版（CJK 对齐）
#  [ ] STORY.md 说的和你知道的最近改动对得上
#  [ ] ntfy 手机收到推送（配置了 SEM_NTFY_URL 时）
#  [ ] manifest.json.enc 可解：age -d -i ~/.config/partiverse-backup/age/identity.txt -o /tmp/m.json <enc>
#  [ ] 逃生面自证：./rescue.sh --base $BACKUP_BASE --class files --find <一个你知道的文件名>
#      能列出、--get 到临时目录能取回（rescue.sh 不依赖本仓库其它文件，见 --guide）
#  [ ] recovery-identity.enc 已按 ③ 另存第二处（云端没有它）
#  [ ] 权限面（整棵扫，一条命令判完）：
#      find ~/.config/partiverse-backup ~/.local/share/partiverse-backup \
#           ~/PartiverseBackup/timeline \( -type d ! -perm 700 \) -o \( -type f ! -perm 600 \)
#      → 无输出即合格（目录 700、文件 600）。**别只 ls -ld 两个根目录就算过**：真机 10-01
#      实测根目录已 700，而根下的 age/ 仍是 0755、runs/run-*.json（渲染前的**全量文件名清单**，
#      单个几十 MB 级）与 system-meta/ 转储仍是 0644。backup.sh 每次运行幂等地整树收紧，
#      老设备跑到新提交即自动修好，无需改 plist（日志里是引擎输出的完整路径，同机用户不该可读）。
./backup.sh                      # 再跑完整链路（含 WebDAV）
# 云端副本自证（A6 L1）判读：$BACKUP_BASE/timeline/CLOUD-VERIFY.txt 每轮重写一次，汇总行
# `# 汇总: checks=N FAIL=0 UNKNOWN=0 HEALED=0`。四种状态：
#   PASS    —— 本地每个对象云端都在且尺寸一致；仓库 config 的内容哈希两端相同
#   HEALED  —— 发现云端那份是陈旧的，已当场 forcing 补传那一个文件并**重新读回核对**过。
#             这类不一致推送永远不会自己带走（网盘只比大小，原地同长度重写被判「已同步」），
#             出现一次是对的，天天出现说明推送清单有问题
#   UNKNOWN —— 这一轮网盘读不出清单/内容：没证成也没证败，**不改退出码**（把抖动报成失败
#             会让告警通道失去信任）
#   FAIL    —— 补传之后仍对不上，或云端缺对象/尺寸不符 → 整轮非零退出 + ntfy 告警
# 这份报告自己也随下一轮时间轴推送上云（比对发生在落笔之前，所以它从不自指），
# 异机排查时云端就能看到上一轮的结论。
# 存储完整性校验（A2a）判读：$BACKUP_BASE/timeline/INTEGRITY.txt 每 **30 天**重写一次
# （`INTEGRITY_DAYS=0` 立刻跑一遍），汇总行 `# 汇总: checks=N FAIL=0 UNKNOWN=0`。
# 它跑的是 `borg check --verify-data`——把整仓每个 chunk 解密+解压+校验一遍，所以：
#   PASS    —— 这一类仓库的字节全都读得出来、解得开（7.6 GB 量级是分钟级）
#   UNKNOWN —— 拿不到仓库锁（多半是你同时在手工跑 drill），或本地仓库目录读不到；不改退出码
#   FAIL    —— rc=1 是真发现坏数据；rc>=2 且错误里没提锁的按最坏情况算（borg 把「仓库可能
#             已毁」和用法错误塞在同一档）。→ 整轮非零退出 + ntfy 告警，**别再等下一次演练**：
#             损坏不会自己修好，取回路径也永远碰不到那几个块
# 为什么单列：仓库里某个 chunk 腐化**不会**让 borg create 失败（10-01 实测翻掉一个字节后
# 备份全绿），恢复演练也只抽样取回几个文件——不主动整仓读一遍，这类问题可以躺几年。
# 引擎原文只在本地 backup.log（600、不上云），报告里一个字节都不抄：那是明文产物。
# 恢复演练（A2b）判读：$BACKUP_BASE/timeline/rescue-test.txt 每 **30 天**真跑一次
# （`./drill.sh --force` 立刻跑），逐条形如
# `PASS [files] /Users/x/Documents/note.txt (8 B, 内容哈希一致)`，汇总行
# `RESULT: 6 PASS / 0 FAIL（抽样 6；内容哈希 5，仅比大小 1）`。两种依据：
#   内容哈希一致 —— 取回的文件与**备份期**记在密封清单里的源文件 sha256 相同，
#                   这条才叫「备份的内容就是磁盘上当初的内容」
#   仅比大小     —— 清单没记下哈希（样本超过 8 MiB、备份后源文件被改过或已删除），
#                   只证明了尺寸。**没验过的不会被说成验过了**：依据逐条写在行尾
# 两条计数之和必须等于 PASS 数（对不上账就是有条目的依据没写进报告）。
# FAIL 行会说清坏在哪一步：`（内容哈希不符：清单 … ≠ 取回 …；大小倒是一致（8 B）
# ——只比大小看不见这一类）`。见到这句别当成抖动：同长度不同内容=取回的字节就是错的，
# 走 restore.sh 全量取回那个文件人工核对，并按 A2a 那次一样留证。
# 为什么单列：网盘那侧「rclone 只比大小」这一课（见上 A6）在取回这侧有镜像——旧口径
# 只比 size，「内容错了但长度没变」永远 PASS。哈希只在**密文**清单里，明文产物一个都不写。
launchctl list | grep partiverse # 调度在位（init.sh 已注册，每日 02:34）
# launchd 那一次的现场在 ~/.local/share/partiverse-backup/launchd.{out,err}.log
# （plist 的 StandardOut/ErrorPath 指过去；不配的话 stdout 落进 os_log，跑挂只剩退出码）
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

验收同上（四件套 / 推送 / Task Scheduler）。

**密封还需要 age 密钥，Windows 上由 `init-keys.ps1` 生成**（10-03 起；在此之前 Windows 的
时间轴**从来没有密封出过 `manifest.json.enc`**——`semantic.ps1` 的密封那一步只在
`%APPDATA%\PartiverseBackup\age\recipients.txt` 存在时才跑，而本机没有任何东西生成它）。
分两档，第二档必须人坐在键盘前：

```powershell
.\init-keys.ps1                      # Primary：两把 X25519 身份 + recipients.txt（两行）+ 恢复码
.\init-keys.ps1 -Stage Rescue        # Rescue：用恢复码封存 .recovery-identity.enc（要终端）
.\init-keys.ps1 -Status              # 只数文件，不开任何加密件（可被脚本调）
```

- 装 age 本身：`backup.ps1 -Task Init` 的 `Install-Deps`（或手工放 `age.exe` / `age-keygen.exe`
  后用 `-Age` / `-AgeKeygen` 指路径；也认 `BACKGUARD_AGE` / `BACKGUARD_AGE_KEYGEN` 两个环境变量）。
- 恢复码 **只在屏幕上显示一次** 并落 `recovery-code.txt`（8 组 4 位十六进制，与 `init-keys.exp`
  同形）：抄到纸上，核对无误后 `Remove-Item` 掉那份文件。它不进日志、不进机器契约行。
- `Primary` 落盘前自己验一遍闭环（拿 recipients.txt 封一件探针、再用两把身份分别解开比内容）；
  `Rescue` 落盘后拿**你抄的那串恢复码**把 `.enc` 真解一遍并核对公钥在册——这一步必须是终端，
  因为 age 的 passphrase 形态只认 tty，而它的提示原文是
  `Enter passphrase (leave empty to autogenerate a secure one)`：**按空回车会封进一个谁都没见过的
  随机口令**，`age -p` 照样退出 0、`.enc` 照样落盘，那张纸从此解不开它。重验抓的就是这一手。
- `recipients.txt` 一旦存在就必须**恰好两行**（主身份 + 救援身份）；单行意味着只剩一条恢复路径。
- 恢复身份封好的 `recovery-identity.enc` 按设计**不上云**（凭据纪律），所以密钥目录必须有
  第二处离线副本（见下面 `rescue.ps1 -Recovery` 那段与 §5 验收清单）。

逃生面自证（Windows 侧，10-02 起有 `rescue.ps1`）：

```powershell
.\rescue.ps1 -Base <备份根> -List                                   # 三类仓库 + 时间轴看得见
.\rescue.ps1 -Base <备份根> -Class files -Find <一个你知道的文件名>   # 只搜；取回路径在 row| 第 5 段
.\rescue.ps1 -Base <备份根> -Class files -Get '<那一行>' -To <空目录>
.\rescue.ps1 -Base <备份根> -Ledger -Identity <age\identity.txt>     # 解封密封账本（路径 A）
```

它只读 restic 仓库：撞到 borg 仓库报 `BORG_REPO_ON_WINDOWS` 并指回 `rescue.sh`（那一份仍要在
Linux/macOS 上跑）。只有纸质恢复码时走路径 B（`-Recovery <age\recovery-identity.enc>`，age 现场
要口令，得人在键盘前）；`recovery-identity.enc` 按设计不上云，所以密钥目录必须有第二处离线副本。

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

## 4. 第一周复盘模板（组织者用，第 7 天填写）

> 数据来源：备份日志（连续性）+ rescue-test.txt（演练）+ 问卷（体感）。
> 原则：只陈述事实与原话，不做解释性总结——解释留给第 14 天的 go/no-go。

```markdown
# dogfood W1 复盘 — <日期> · 参与者 N 人

## 硬指标（从脚本/云端取数）
| 设备 | 备份次数 | 中断>72h | preflight 阻断 | drill 结果 |
|---|---|---|---|---|
| 例：particloud-macos | 7 | 0 | 0 | 5 PASS（rescue-test.txt） |

## 问卷回收（Q1–Q5，见上）
- Q1 主动查看备份内容的比例：_/N；原话摘录（逐字）：
- Q2 推送反应：
- Q3 隐私体感：
- Q4 断档警示（如有）：
- Q5 「功能消失你会在意吗」：

## 缺陷与观察（issue 链接）
| # | 设备 | 现象 | 严重度 | issue |
|---|---|---|---|---|

## 第 7 天不做的事
- 不调整 includes/excludes（保持被验证版本）
- 不向参与者解释设计意图（避免诱导正面反馈）
```

## 5. 退出与决策

- 数据进 08 章 M4 的 go/no-go 判据（≥7/10 未提示即主动提及语义层价值）；
- 任一设备的语义层连续失败 3 次即记 defect（非致命哲学的检验：备份本身必须从未因此中断）；
- 2 周后组织者写 dogfood 复盘（含原始问卷），发布到 repo discussions。

## 6. 代码更新（部署树追平）

设备跑的是**部署 checkout**（launchd/Task Scheduler 里的路径），不是开发树：
提交进 `main` 后不让部署树追平，当晚用的仍是旧代码——观察期数据因此作废
（2026-09-30 就漏过一次，落后 14 个提交，见 `docs/HANDOVER-2026-09-30.md` §4.1）。

```bash
DEPLOY_DIR=<部署目录>          # launchd plist / 计划任务里 ProgramArguments 指向的那个目录
git -C "$DEPLOY_DIR" fetch origin
git -C "$DEPLOY_DIR" merge --ff-only origin/main
# 验证：两处 HEAD 必须一致
git -C "$DEPLOY_DIR" rev-parse --short HEAD
```

- **只允许 ff**：部署树出现本地改动就是有人在上面开发，先查 `git -C "$DEPLOY_DIR" status`
  弄清来源再动，别 `reset --hard` 抹掉。
- 追平后跑一次 `./drill.sh --force`（macOS/Linux）确认新代码的恢复链路仍通。
- 观察期内的节奏：CI 全绿 → 部署树追平 → 当晚 nightly 就是免费的验收场。追平前先确认
  没有备份在跑（`pgrep -fl "backup.sh|borg|restic|rclone"`）——09-30 那次「部署点落后 14 个
  提交、观察期数据作废」是漏了追平，不是代码问题。

## 7. Borg 口令轮换（真机 2026-10-01 走过一次，三类仓库各一次）

**先认清爆炸半径**：仓库是 `repokey-blake2`（`key-type = 3`），密钥 blob 就存在每个仓库自己的
`config` 里，口令只是它的包裹。所以：

- 轮换 = **每个仓库各跑一次** `borg key change-passphrase`（config/files/system 三次；restic 侧另是一套）；
- borg 自己声明：**换口令不改底层加密/MAC 密钥，也不改 chunker seed**——它防的是「口令被猜到」，
  不防「key blob 已泄露」。要连密钥一起走得新建仓库重灌，那是另一量级的操作；
- `change-passphrase` **没有** `--new-passphrase` 选项，但认 `BORG_NEW_PASSPHRASE` 环境变量
  （免交互，别拿 expect 硬塞）。

```bash
CFG=~/.config/partiverse-backup
ROLL="$CFG/keyrot-$(date +%Y%m%d)"   # 回滚对：旧口令 + 旧 key blob，验证通过前是唯一退路
mkdir -p "$ROLL" && chmod 700 "$ROLL"
cp -p "$CFG/secrets.env" "$ROLL/secrets.env.old"
for c in config files system; do
    cp -p "$HOME/PartiverseBackup/borg-$c/config" "$ROLL/config.$c"
    set -a; source "$CFG/secrets.env"; set +a
    BORG_NEW_PASSPHRASE=<新口令> borg key change-passphrase "$HOME/PartiverseBackup/borg-$c"
done
# 双向验证：新口令开得动 + 旧口令开不动（后半句才算真轮换成功）
for c in config files system; do
    borg list "$HOME/PartiverseBackup/borg-$c" >/dev/null && echo "$c 新口令 OK"
done
```

**云端要逐项对平，不能只看「同步完成」**：这条 WebDAV 取不到 modtime/hash，rclone 退化成
**只比大小**（日志 `Sizes identical` → `Unchanged, skipping`）。而 `borg key change` 重写
`config` 是**原地同长度替换**（700 B 换 700 B），云端于是静悄悄留着轮换前那份 key——真机
10-01 就是 nightly 报了同步完成、云端三个 `config` 却全是旧的：

```bash
for c in config files system; do
    d="Backguard:<设备目录>/$c"
    rclone copy -I "$HOME/PartiverseBackup/borg-$c/" "$d/" --include config   # -I = 无视大小比较
done
# 对平证据 = 本地与云端的 config 逐类同哈希（哈希先算进变量再拼 echo，见下）
```

取哈希别写成 `echo "local=$(sha256sum f | awk '{print $1}')"` 这种嵌套——`awk '{print $1}'`
套在 `"$( … )"` 里是 bash **解析错误**（不是运行期报错，`bash -n` 才抓得住），
先把 `$(…)` 的结果收进变量再拼字符串。

跑完接一遍完整备份（含云端）确认口令面没伤到本体，然后**回滚对必须退役**：
`$ROLL` 里旧口令与旧 key blob 成对存在，等于旧口令仍能开仓库，留着就把轮换的价值抹掉了。
删它不可逆，先过用户确认；同时提醒用户把新口令抄进密码管理器/纸上，旧记录作废。
