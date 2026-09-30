# AGENTS.md — Partiverse Backup（backguard v0）代理协作规则

> 面向 AI 编码代理（Qoder / ZCode / 其他）与本仓库人类协作者。
> 开发状态、进展、环境与协作习惯的完整交接见 [docs/HANDOVER-2026-09-30.md](docs/HANDOVER-2026-09-30.md)。

## 0. 项目一句话

三平台（Linux/macOS/Windows）个人备份系统：borg/restic 引擎 + rclone 多目标云端 +
**语义层**（每次备份产出裸文件管理器可读的 `MANIFEST.txt` / `STORY.md` / `restore.md` /
`COVERAGE.txt`，完整文件名单独密封进 `manifest.json.enc`）。
当前处于 **Phase 0 验证期观察阶段（2026-09-30 起）**：核心功能面已落地并在真实设备
实战运行，代码迭代降速，重心是被动观察稳定性与 dogfood 数据积累。

## 1. 不可妥协红线（改动前先读）

1. **明文层隐私红线**：`MANIFEST.txt` / `STORY.md` / `COVERAGE.txt` 等一切明文产物
   **永不出现完整文件名**（一级目录名之外的任何细化都必须命中 known_dirs 目录证据——
   纯文件清单里二级/三级的最后一段可能就是文件名，无证据退回一级；凭据类
   目录只写数量；根级散文件聚类不显示名称）。unittest 有测试锁定，改渲染逻辑先跑测试。
2. **凭据纪律**：口令/密钥/恢复码/token 只进 `secrets.env`（600）或 age 密钥目录，
   永不入库、不进日志、不进 issue/截图；文档示例一律占位符。
3. **非致命分层**：语义层是引擎旁路——语义层任何故障不得中断备份本体（接入点全部
   告警降级，`backup.sh` 的 `generate_semantic` 调用点也带 `|| warn` 兜底）。
   `bg preflight` 等 Python 侧只做纯文件系统检查，**不做变量子进程调用**；
   引擎/凭据/网络检查一律放 bash 编排层。
4. **云端只增不减**：云端用 `rclone copy` 不用 `sync`；timeline 云端永不删除；
   本地 timeline 保留策略（`SEM_TIMELINE_KEEP`，默认 14）只清理本地暂存。
   反过来「本地成功」不等于「云端有副本」：任一目标推送失败必须非零退出并告警，
   不得宣布 `FULLY COMPLETE`（`test_cloud_failure.sh` 锁定）。
5. **不可逆操作先确认**：删除、force-push、改 CI/分支保护、覆盖未读文件——先问用户。

## 2. 工程约束（实测教训速查，违反必炸）

- **bash 双轨兼容**：macOS 系统 bash 3.2 与用户态 5.x 都要跑（CI 双环境验证）。
  `config.sh` 的 includes/excludes 是索引数组，每路径/模式一元素（禁止空格拼接单字符串）。
- **`set -euo pipefail` 陷阱**：管道任一段 rc≠0 会炸整个赋值语句——可容忍失败用
  `(…; true)` 中和（borg prune rc=1 是 warning 级，与 create 同等容忍；
  `notify_story` 里 `grep -m2 '^- '` 无命中曾炸掉整次备份）；
  `local a="$1" b="$a/x"` 取不到值（SC2318：声明与赋值拆两行，或 `declare -n`）。
- **shellcheck 门禁文件 0 告警**（CI `-S warning` 卡 `backup.sh restore.sh semantic/semantic.sh`；
  `init.sh` / `test_init_e2e.sh` 的既有告警不在清单内）：`[[ ]]` 内数组测试用 `[*]` 加引号
  （`[@]` 在 `[[ ]]` 报 SC2199、在 `[ ]` 报 SC2198）；SC2154 的 disable 注释必须贴引用行；
  `set -u` 下数组 resolve 后必须恒定义（否则 `${#arr[@]}` unbound 静默退出）。
- **变量紧贴非 ASCII 一律写 `${VAR}`**：`$RCLONE_LOG）` 中 bash 可能把 `）` 的首字节 0xEF
  吃进变量名，查的是 `RCLONE_LOG<0xEF>`——`set -u` 下 unbound 直接退出。macos CI 曾在
  「云端失败必须非零退出」的告警分支（backup.sh:377）被它炸掉，等于红线守卫自己判崩。
  实测口径：/bin/bash 3.2 只要 **LC_CTYPE 是多字节 locale** 必炸（`LC_ALL=C` 与
  `LC_CTYPE=C LANG=en_US.UTF-8` 都正常）；CI 的 homebrew bash 5.3.15 同样炸，本机 5.3.20
  不炸——版本相关，**别拿本机行为当保证**。静态守卫见 `test_portable_stat.sh` 断言 4。
- **文件属性跨平台**：GNU `stat -f` 是「文件系统状态」——它把跟在前面的「格式串」当文件系统名，
  coreutils 9.4 实测（ubuntu:24.04 容器）：`stat -f '%m %N' f` 打真实文件的文件系统状态块到 stdout、stderr 报
  `cannot read file system information`、**rc=1**（pipefail 下会直接带崩整条流水线，
  非致命调用点则把状态块并着 epoch 收成多行垃圾值）；BSD `stat` 又没有 `-c`——语义层取
  mtime/尺寸一律走 `file_mtime`(`date -r`) / `file_size`(`wc -c`)；新增裸 `stat -c/-f`
  会被 `test_portable_stat.sh`（顶在 PATH 前的 GNU 语义 stat shim）抓住。修复前
  `latest_prev_exclusions` 的裸 `stat -f` 流水线在 GNU 上 rc=1、被 pipefail 中断，而
  `backup.sh` 当时无兜底地调用 `generate_semantic`——Linux 设备第二次起的备份会整条退出 1；
  CI 每轮新建仓库只跑首备（stage 里没有 exclusions.json，流水线空转），所以一直没暴露。
- **borg 1.4 取回面**：`extract` **没有** `--destination/-C`（解包路径相对 cwd，要取回就先 `cd`
  进目标目录），**`extract --list` 也会真解包**——`--list` 只是顺带把解出的路径报告出来，
  在仓库 cwd 里跑它等于往工作树里落文件（列路径请改用 `borg list --short`）；
  归档选择也不支持 `::--last 1` 这类通配——用 `borg list --short` 前缀过滤后取尾；
  `/tmp`→`/private/tmp` 软链会触发 "repository was previously located at" 交互中止。
- **时间口径**：borg info 的 start 是 **naive 本地时间**（borg 1.4.5 实测；CI 的 TZ=UTC
  环境曾误判为 naive UTC）。STORY 的 parent-time 改由归档名解析（归档名日期段=倒数第二
  字段、时间段=最后字段，时间戳内部含连字符）。bg 侧 `local_naive` 统一转本地显示；
  **demo/测试时间一律 naive**（aware 会在 UTC runner 上转出不同值导致断言失败）。
- **Python 兼容**：语义层纯 stdlib，兼容系统 python3 3.9+（launchd 受限 PATH 无
  homebrew；3.9 的 `fromisoformat` 拒绝 `+0800`——`parse_iso` 需容错 ±HHMM/Z）。
- **设备标识**：`<设备名>-<系统>` 全小写、不含 OS 版本（大小写不敏感网盘的安全交集；
  系统升级不分裂备份历史；品牌原名进 `timeline/<设备>/profile.json`；点转连字符）。
  命名体系变更 = 破坏性变更，先与用户确认。
- **macOS 撞名**：系统自带 `/usr/bin/bg`，接入层只用 `$BG` 或 vendored 路径，不做 PATH 查找。
- **WebDAV/123Pan 特性**：大小写不敏感；DirMove 500（目录迁移 = copy 逐文件 + 验证 +
  purge）；大文件偶发 500。新 remote 接入先跑 `test_remote_caps.sh` 并登记能力台账
  （research/05 §1.5，本地）。
- **age 密封**：age 只读 /dev/tty 不吃管道——密钥初始化必须 expect 驱动
  （`init-keys.exp`）；passphrase stanza 独占，双恢复路径用双 X25519 recipient 实现。
- **权限面**：备份产物没有任何需要同机可读的东西——入口脚本（`backup.sh` / `init.sh` /
  `drill.sh`）一律 `umask 077`，`$CONF_DIR`（secrets.env + age 私钥）与 `$LOG_DIR`（backup.log /
  rclone.log / launchd.*.log / sem.log / drill.log / preflight-latest.json）700、其中文件 600。
  两层缺一不可：`umask` 只管新建，已存在的 0755 目录与 0644 日志（父目录 `~/.config`、
  `~/.local/share` 常被 `mkdir -p` 建成 755）靠 `backup.sh` 每次运行的幂等 `chmod` 修复，所以
  老设备只要 nightly 跑到新提交就自动收紧，不必改 plist。日志里是引擎输出的**完整路径**，
  这是隐私红线之外没人管过的一面。
- **调度模板不写 `RunAtLoad`**：`launchctl load`（装机、改配置后重载）会因它立刻再跑
  一发全量上传，而向导本身已经跑过首次备份；错过的排程 launchd 唤醒时本会补跑，
  不需要 RunAtLoad。真机旧 plist 仍带这个键，留给下次计划内重载对齐——观察期中间
  不折腾调度。

## 3. 改动与验证流程

1. 改代码 → `python3 -m unittest discover -s semantic -p "test_*.py"`（49 项全绿，
   3.9/3.14 双版本已验证）→ `shellcheck -S warning backup.sh restore.sh
   semantic/semantic.sh drill.sh rescue.sh` 0 告警 → 相关 shell E2E（均可本机跑，隔离临时目录不触真实配置）：
   `test_init_e2e.sh` / `test_multi_target.sh` / `test_timeline_retention.sh` /
   `test_restore_e2e.sh`（恢复链路四条路径实取）/ `test_cloud_failure.sh`（云端失败可见性）/
   `test_portable_stat.sh`（GNU/BSD 文件属性）/ `test_cloud_copy_only.sh`（云端只增不减红线）/
   `test_drill_e2e.sh`（演练独立入口 + 结论判定不误报）/
   `test_rescue_e2e.sh`（逃生恢复：两种布局 + borg/restic 搜取 + age 双路径）。九个都已挂 CI
   （linux job 全跑；macos job 跑 restore/cloud_failure/drill/rescue/init），
   `test_remote_caps.sh` 是手工能力探测，不入 CI。
   （可选依赖缺失的分支必须打 SKIP 并在末行如实标注「未测」，不得只报 E2E-OK）。
   CI 的 linux/macos 真实备份 job 另配一次性 age 主身份，并断言
   `timeline/<dev>/rescue-test.txt` 存在且结论为「≥1 PASS / 0 FAIL」：没有密钥时
   `run_drill` 走 rc=20 静默跳过、产物根本不存在，演练这条生产面就等于没测——10-01
   的跨类别取回错配正是藏在这层遮罩下。**「CI 绿」≠「跑过」，先确认守卫那条 step 真的执行了。**
   新增生产面脚本就把它加进上面的 shellcheck 清单与 CI；`test_portable_stat.sh` 的断言 4
   会扫全仓 `*.sh` 的变量紧贴非 ASCII——新脚本自动在守卫内，别指望只测本机。
   shell 夹具（`test_*.sh` 的 `mktemp -d`）清理一律 `trap 'rm -rf "$T"' EXIT`：
   末行 `rm -rf` 在 `fail()` 的 exit 1 下不执行，含 age 私钥/明文账本的夹具就留在 /tmp。
   **夹具必须与生产同形**：三类仓库齐（只建 files 就测不到跨类别错配）、抽样/计数类断言
   把全集拉满（`SEM_DRILL_COUNT=99`）而非依赖当天种子。断言「跑通了」之前先问：
   生产上真长这样吗？
   **新断言必须变异验证**（把被测实现摘掉，确认断言真报错）；若断言被**另一处冗余实现
   救场**，看着就像「没咬住」——本次删掉 `init.sh` 的 chmod 后权限仍是 700，因为
   `backup.sh` 也 chmod（两条路都要给老部署和新部署各自兜底，是有意的冗余），变异要
   把同源实现一起摘。变异树还要连测试文件一起从工作树拷进去（`git archive HEAD` 出来
   的是旧测试，会假打 E2E-OK）。
2. 提交信息：中文 conventional commits，`feat(scope): 描述` / `fix(scope): 描述`（看 git log）。
3. push 前自查新增代码注入面（变量子进程、eval、递归删除命令作用于变量路径——删除前
   必须有白名单守卫并按行读入，如 `prune_local_timeline` 的 `^[0-9]{4}-[a-z0-9-]+$`、
   `prune_run_jsons` 的 `^run-[0-9]{8}-[0-9]{6}\.json$`；`ls | xargs rm` 这类按空白拆词
   的写法在路径含空格时会把删除目标指到别处，一律禁用）。
4. main 分支保护：禁 update/delete/force-push、要求线性历史；admin 凭据直推放行。
   push 后盯 CI（6 runs：semantic 三平台矩阵 + linux/macos/windows 真实备份与断言；
   CI **不推云端**（`SKIP_WEBDAV=1`），windows job 仍要下载 restic/rclone 依赖）。
   工作流带 `concurrency`（同分支只留最新一轮，`cancel-in-progress`）：免费 macOS
   runner 池很小，连推 8 个提交＝16 个 macOS job 互相顶死，实测最早的 run 排队 36 分钟
   一个 job 都没开跑，而**唯一需要绿灯的 HEAD 排在最后**。所以别拿「CI 没有这个 run」
   当异常——被取消的是被 HEAD 覆盖的旧提交，部署点只认 HEAD 那一轮的结论。

## 4. 本机与真实设备事实（开发机 = 用户 Mac，设备 particloud-macos）

- 部署配置：`~/.config/partiverse-backup/`（`config.sh` / `secrets.env` / `age/`），
  **不在本仓库内，勿动**；恢复码已由用户抄写纸质留存。
- 备份仓库：`~/PartiverseBackup/`（config/files/system 三个 borg 仓库，本地事实源）。
- 调度：launchd 每日 02:34（`~/Library/LaunchAgents/com.partiverse.backup.plist`）。
  plist 的 `EnvironmentVariables`（内嵌明文 BORG_PASSPHRASE）已于 2026-10-01 删除，
  口令现在**只**来自 `secrets.env`；改动前的副本在同目录 `*.bak-20261001`。
- **运行中的代码不是你的工作树**：plist 执行 `~/leisure/Codebase-Driven-by-AI/backguard/v0/backup.sh`，
  它是本仓库的**纯部署 checkout**（不在上面开发）。提交进 main 后必须
  `git -C <部署目录> fetch && merge --ff-only origin/main` 才会被 nightly 用到——
  2026-09-30 就是漏了这步导致部署点落后 14 个提交、观察期数据一度无效（HANDOVER §4.1）。
- 云端：rclone remote `Backguard:`（123Pan WebDAV），约 8–10GB。实测目录形状
  `Backguard:/<SYSTEM_ID>/{config,files,system,timeline}`，timeline 下即
  `<dev>/YYYY/MM/DD/HHMM-标签/`（与 `rescue.sh --base <云端目录>` 认的布局一致）。
  云端**没有** `age/`——`recovery-identity.enc` 从不推送，盲恢复目前要求密钥目录另有副本
  （已写进 `rescue.sh --guide` §4，是否推送待用户定夺，属凭据红线不擅自改）。
- `~/leisure/Codebase-Driven-by-AI/backguard/`（即部署树 v0 的上一级）下的 `research/`、
  `PRD.md`、`prototype/`、`pitch/` 是本地工件，**不在任何 git 仓库内**；
  关键结论已内联进 docs/HANDOVER。换机或移动开发树时，这些工件不随本仓库 clone 走。

## 5. 已知待办（代码小项；优先级与验证期安排见 HANDOVER §6）

1. ~~rescue 单文件脚本独立版~~ bash 版已完成：`rescue.sh`（08 章 T3.2，无 Python 依赖，
   两种目录布局 + 引擎自动判定 + age 双路径；`test_rescue_e2e.sh` 锁行为）。
   **PowerShell 版 `rescue.ps1` 仍待做**——只在能挂上 CI 验证时写（本机无 pwsh）
2. ~~`bg drill` 独立 CLI 入口~~ 已完成：`drill.sh`（复用 `run_drill`，不复制判定逻辑）；
   顺带修掉演练结论误报——判定式 `grep 'RESULT: .*FAIL'` 会匹配汇总行的字面「0 FAIL」，
   全通过也报失败；30 天节流让这个 bug 在生产里从未露头（现由 `drill_has_failure` 只认
   逐条 FAIL 行 + 计数，结论行缺失一律判失败）。**同一处第二次露头**（10-01 真机
   `--force`）：`bg sample` 按占比跨类别抽样，而 run_drill 只拿到 files 仓库，
   config/system 样本 100% 报「取回或大小不符」的**假失败**——现在 run_drill 收
   `类别:仓库:归档` 列表并按样本类别查仓库。教训：**节流/低频路径的判定与数据面
   都要在真机或跨类别夹具上跑一次**，单类别 E2E 测不出这类错配
   （夹具规矩：三类仓库各存自己的子树，路径互不重叠，否则写死仓库也能 PASS）。
   抽样条数由 `SEM_DRILL_COUNT`（默认 5）控制，E2E 拉满它以求确定性
3. Windows 密钥初始化交互版 `init-keys.ps1`（对齐 `init-keys.exp`）
4. ~~launchd plist 明文口令~~ 已删（2026-10-01 01:35）：**不需要 wrapper**——`backup.sh`
   自己 `set -a; source secrets.env`，plist 里那份 `BORG_PASSPHRASE` 与 secrets.env 同值、
   删除后重载 launchd 并手动触发了完整一次备份（退出 0、产物齐全）作为验证。
   模板同修（0dc7211）：`init.sh` 的 plist 不再写口令，并补 `StandardOutPath`/
   `StandardErrorPath` → `$LOG_DIR/launchd.{out,err}.log`——不写时 launchd 把 stdout
   丢进 os_log，夜间跑挂只剩一个退出码。`INIT_SKIP_SCHEDULER` → `INIT_SCHED_NO_REGISTER`
   （旧语义连渲染一起跳，调度产物从没被测过；新语义只跳注册）
5. T1.3 聚类调优（等 ≥1 周真实数据；已知素材：混合簇退级、载体根噪音。STORY 逐簇
   「新增 -2」不是聚类问题，是计数口径混用，10-01 已修）
6. T1.6 dogfood 扩 2 台设备（Windows/Linux 各一，按 `DEPLOY.md` 流程）
