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
   **永不出现完整文件名**（唯一例外 `rescue-test.txt`：恢复演练逐条记录抽样文件的完整
   路径，天生带文件名，所以它**只留本地、不随时间轴上云**，由 `backup.sh` 推 timeline
   时的 `SYNC_EXCLUDES` 挡住，`test_multi_target.sh` 锁行为——10-01 真机演练后才暴露）（一级目录名之外的任何细化都必须命中 known_dirs 目录证据——
   纯文件清单里二级/三级的最后一段可能就是文件名，无证据退回一级；凭据类
   目录只写数量；根级散文件聚类不显示名称）。unittest 有测试锁定，改渲染逻辑先跑测试。
2. **凭据纪律**：口令/密钥/恢复码/token 只进 `secrets.env`（600）或 age 密钥目录，
   永不入库、不进日志、不进 issue/截图；文档示例一律占位符。
   **第三方服务的响应体也算凭据**：公共 `ntfy.sh` 的回执 JSON 里有 `"topic"`，而 topic
   就是订阅密码——`notify_push` 曾把 curl 的 stdout/stderr `>>"$LOG"`，真机 10-01 的
   `backup.log` 里因此躺着整份回执。凡调用带凭据的 HTTP 接口，一律 `curl -fs -o /dev/null`
   并把 stdout/stderr 丢弃，诊断只保留「成 / 不成」；守卫见 `test_cloud_failure.sh`
   的凭据纪律段（桩按真服务那样吐回执，扫描运行日志 + 配置目录 + 明文时间轴）。
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
- **`"$( … | awk '{print $1}' )"` 是解析错误，不是运行期错误**：单引号里的 `}` 会被外层
  双引号上下文吃掉，bash 直接在 `bash -n` 阶段报语法错（10-01 写轮换脚本时炸了两次）。
  先把 `$(…)` 收进变量再拼字符串。同类：**代理内联跑的 shell 走的是 zsh 语义**
  （`${A[0]}` 恒空、多行赋值不进环境），验证一律落成 `/tmp/*.sh` 再用
  `/opt/homebrew/bin/bash` 跑（系统 `/bin/bash` 3.2 + `set -u` 会零输出静默中止）。
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
- **测试桩里的变量要在 heredoc 中转义**：写 stub 用的 `cat > "$T/bin/curl" <<CURL`（**无引号**
  定界符）会在生成那一刻展开 `${VAR:-0}`——退出码之类的开关被烤成常量，之后改环境变量永远
  切不动（10-01 第 3 轮「让推送失败」因此假通过过一次）。桩内一律 `\$VAR`，或改用 `<<'CURL'`
  再靠外部文件传值。同理：**新增一轮会覆写 `out.log`**，前一轮的证据先 `cp` 存成独立文件，
  否则新断言踩死旧断言。
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
  口令轮换同理：`key change-passphrase` **没有** `--new-passphrase`，只认
  `BORG_NEW_PASSPHRASE`；仓库是 repokey-blake2，key blob 就在各仓库 `config` 里，
  **三类仓库各换一次**，且 borg 明说换口令不动底层密钥（完整程序见 DEPLOY.md §7）。
- **时间口径**：borg info 的 start 是 **naive 本地时间**（borg 1.4.5 实测；CI 的 TZ=UTC
  环境曾误判为 naive UTC）。STORY 的 parent-time 改由归档名解析（归档名日期段=倒数第二
  字段、时间段=最后字段，时间戳内部含连字符）。bg 侧 `local_naive` 统一转本地显示；
  **demo/测试时间一律 naive**（aware 会在 UTC runner 上转出不同值导致断言失败）。
- **Python 兼容**：语义层纯 stdlib，兼容系统 python3 3.9+（launchd 受限 PATH 无
  homebrew；3.9 的 `fromisoformat` 拒绝 `+0800`——`parse_iso` 需容错 ±HHMM/Z）。
- **设备标识**：`<设备名>-<系统>` 全小写、不含 OS 版本（大小写不敏感网盘的安全交集；
  系统升级不分裂备份历史；品牌原名进时间轴根的 `timeline/profile.json`；点转连字符）。
  命名体系变更 = 破坏性变更，先与用户确认。
- **时间轴没有设备层**（2026-10-01 起，此前是 `timeline/<设备>/YYYY/…`）：快照就是
  `timeline/YYYY/MM/DD/HHMM-标签/`，`profile.json` 与 `rescue-test.txt` 落在 `timeline` 根。
  理由是本地暂存根与云端目标**各自都已经带设备名**（`<BACKUP_BASE>/timeline`、
  `<remote>/<SYSTEM_ID>/timeline`），旧形状在真机落成 `particloud-macos/timeline/particloud-macos/…`
  ——设备名在一条路径上出现两次。改的是**根参数**不是深度：快照相对暂存根仍是 4 层
  （`find -mindepth 4 -maxdepth 4`、`rescue-test.txt` 相对快照仍是上 4 层），两侧一起上移，
  谁单独改一层谁炸。`rescue.sh` 是逃生工具，**两种形状都得认**（`timeline_base()`：
  第一层是四位数年份走新形，否则退回唯一设备目录），迁移前的旧副本要能读。
  守卫：`test_init_e2e.sh` 断言 3（层级 + 根下无「非年份目录」+ 根级 profile.json）、
  `test_rescue_e2e.sh` 断言 2.5/2.6、`test_timeline_retention.sh`。
- **macOS 撞名**：系统自带 `/usr/bin/bg`，接入层只用 `$BG` 或 vendored 路径，不做 PATH 查找。
- **WebDAV/123Pan 特性**：大小写不敏感；DirMove 500（目录迁移 = copy 逐文件 + 验证 +
  purge）；大文件偶发 500。**这条 remote 上 rclone 拿不到 modtime/hash，比较退化成「只比
  大小」**（日志 `Sizes identical` → `Unchanged, skipping`）——所以**原地同长度重写永远推不上
  云**，而 `rclone copy` 照样报成功。10-01 真机实测：borg 换口令后 `config` 从 700 B 变
  700 B，nightly 说同步完成，云端三个 `config` 全是轮换前那份。任何「文件被就地改写、
  尺寸没变」的状态（key blob、`profile.json`、`exclusions.json` 都算）要传播得显式 forcing：
  `rclone copy -I <本地> <目标> --include <那个文件>`，判平用 `rclone cat … | shasum`
  对比本地——**别拿「copy 退出 0」当云端有新版**。新 remote 接入先跑 `test_remote_caps.sh`
  并登记能力台账（research/05 §1.5，本地），台账里要记「比较依据是 size 还是 hash」。
- **age 密封**：age 只读 /dev/tty 不吃管道——密钥初始化必须 expect 驱动
  （`init-keys.exp`）；passphrase stanza 独占，双恢复路径用双 X25519 recipient 实现。
- **权限面**：备份产物没有任何需要同机可读的东西——入口脚本（`backup.sh` / `init.sh` /
  `drill.sh`）一律 `umask 077`，`$CONF_DIR`（secrets.env + age 私钥）与 `$LOG_DIR`（backup.log /
  rclone.log / launchd.*.log / sem.log / drill.log / preflight-latest.json）700、其中文件 600。
  清单别只数 `*.log`：`$LOG_DIR/runs/run-*.json` 是渲染前的**全量文件名清单**（真机单个 22 MB）、
  `system-meta/` 是 mounts/crontab 转储、`$BACKUP_BASE` 与 `$BACKUP_BASE/timeline` 是时间轴根，
  10-01 真机实测这三处当时全是 0644/0755，只靠 `LOG_DIR` 已 700 才没被同机遍历读到——目录闸门
  会回退（重装、手工 `chmod -R`、新设备首备前），所以文件层必须自己站住。
  **但点名式清单注定还要漏，别再去补 glob**：补齐那次之后同一天 09:36 的 nightly 把
  `$CONF_DIR` 收紧成 700，`$CONF_DIR/age` **子目录本身**仍是 0755、`recipients.txt` 仍 0644，
  因为清单里只写了 `*.log`（凭据目录的年龄比日志更短，漏一项就是私钥目录可遍历）。所以
  `backup.sh` 每次运行对 `$CONF_DIR` / `$LOG_DIR` / `$BACKUP_BASE/timeline` 三棵树 `find`
  **整棵归一化**（目录 700、文件 600），`test_init_e2e.sh` 断言 6 是逐节点通则而非文件清单——
  新增子目录/新深度自动在守卫内。`$BACKUP_BASE/borg-*` 不递归（引擎自建即 600，仓库根已被
  `base_dir` 700 挡住，为几千 chunk 每轮全扫不划算）。
  两层缺一不可：`umask` 只管新建，已存在的 0755 目录与 0644 日志（父目录 `~/.config`、
  `~/.local/share` 常被 `mkdir -p` 建成 755）靠 `backup.sh` 每次运行的幂等 `chmod` 修复，所以
  老设备只要 nightly 跑到新提交就自动收紧，不必改 plist。日志里是引擎输出的**完整路径**，
  这是隐私红线之外没人管过的一面。
- **调度模板不写 `RunAtLoad`**：`launchctl load`（装机、改配置后重载）会因它立刻再跑
  一发全量上传，而向导本身已经跑过首次备份；错过的排程 launchd 唤醒时本会补跑，
  不需要 RunAtLoad。真机旧 plist 已于 2026-10-01 10:40 对齐（`bootout` → 装件 →
  `bootstrap`，重载后 45 s 无进程拉起、归档计数不变）。**别手改 plist**：从部署树
  `init.sh` 的 heredoc 重渲染（`sed -n '/<<PLIST/,/^PLIST$/p'` 后绑
  `SCRIPT_DIR/LOG_DIR/LAUNCH_BASH/SCHED_H/SCHED_M/PLIST_DIR` 求值到临时目录），
  再拿 `plutil -p` **按键比较**而不是 diff 文本——模板是紧凑单行，现存件被 launchd
  重排过缩进，纯文本 diff 会显示「整份都变了」而看不出只有一个真实差异。

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
   `timeline/rescue-test.txt` 存在且结论为「≥1 PASS / 0 FAIL」：没有密钥时
   `run_drill` 走 rc=20 静默跳过、产物根本不存在，演练这条生产面就等于没测——10-01
   的跨类别取回错配正是藏在这层遮罩下。**「CI 绿」≠「跑过」，先确认守卫那条 step 真的执行了。**
   新增生产面脚本就把它加进上面的 shellcheck 清单与 CI；`test_portable_stat.sh` 的断言 4
   会扫全仓 `*.sh` 的变量紧贴非 ASCII——新脚本自动在守卫内，别指望只测本机。
   **改目录形状时 `.github/workflows/ci.yml` 里那些硬编码路径也是被测面**——本机九条 E2E
   全绿也看不见它：10-01 时间轴去设备层那一改，`semantic (linux/macos/windows)` 三条一起红在
   `base=demo_output/<dev>/YYYY/…` 这行。改完先 `grep -n 'timeline\|demo_output' .github/workflows/ci.yml`
   把所有形状相关断言找齐，再逐字节复刻那条 step 的命令跑一次（**日期路径在转录里会被显示成连字符**，
   `test -f` 手敲必错——用 python 数 `chr(47)` 或直接 `find` 定位）。
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
  `RunAtLoad` 也已于 10-01 10:40 去掉（重渲染件，改动前副本 `*.bak-20261001-runatload`）。
- **borg 口令已于 2026-10-01 10:19 轮换**（config/files/system 三仓库各一次，随机 40 字符，
  只落 `secrets.env`）。回滚对在 `~/.config/partiverse-backup/key-rotation-20261001-keyrot/`
  （旧口令 + 旧 key blob **成对**，等于旧口令仍能开仓库）——轮换价值取决于它何时退役，
  清理属不可逆、待用户确认，代理不自行删除。程序与云端对平陷阱见 DEPLOY.md §7。
- **运行中的代码不是你的工作树**：plist 执行 `~/leisure/Codebase-Driven-by-AI/backguard/v0/backup.sh`，
  它是本仓库的**纯部署 checkout**（不在上面开发）。提交进 main 后必须
  `git -C <部署目录> fetch && merge --ff-only origin/main` 才会被 nightly 用到——
  2026-09-30 就是漏了这步导致部署点落后 14 个提交、观察期数据一度无效（HANDOVER §4.1）。
- 云端：rclone remote `Backguard:`（123Pan WebDAV）。**记体量要按前缀记，别按 remote 记**：
  10-01 05:25 `rclone size Backguard:` = 329 objects / 30.79 GiB，但其中 **24.8 GiB 是本仓库无关的
  既有文件**（remote 根下两个 2026-08-17 的 Acronis 镜像 `Windows11_Initialization_*.tibx` 15.89 GiB、
  `Ubuntu_Jammy_for_Dev_Initialization_*.tibx` 8.94 GiB）；backguard 自己（`Backguard:particloud-macos/`）
  实测 7.6 GiB / 327 objects，与本地 `~/PartiverseBackup` 逐项对平（config 71 MiB / files 7.5 GiB /
  system 327 KiB / timeline 69 MiB）——也就是说 09-30 记的「约 8–10GB」量级没错，
  是 `rclone size` 整仓口径把它读成了增长。实测目录形状
  `Backguard:/<SYSTEM_ID>/{config,files,system,timeline}`，timeline 下**直接是日期树**
  `YYYY/MM/DD/HHMM-标签/`（10-01 去掉设备层；迁移前留下的 `timeline/<dev>/…` 旧副本仍躺在云上，
  由 `rescue.sh` 的 `timeline_base()` 两种形状都认）。
  云端**没有** `age/`——**已定（2026-10-01 用户拍板）：`recovery-identity.enc` 不上云**，凭据
  纪律优先，这不是缺口而是设计。所以「干净机器 + 云端目录 + 纸质恢复码」的盲恢复**硬性要求**
  密钥目录另有第二处离线副本（`DEPLOY.md` 步骤 ③ + `rescue.sh --guide` §4）；将来若要改主意，
  走的是一次凭据面变更决策，不是顺手往推送清单里加一行。
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
   （旧语义连渲染一起跳，调度产物从没被测过；新语义只跳注册）。模板另去掉 `RunAtLoad`
   （§2「调度模板不写 RunAtLoad」）；本机旧 plist 已于 10-01 10:40 重渲染对齐
5. T1.3 聚类调优（等 ≥1 周真实数据；已知素材：混合簇退级、载体根噪音。STORY 逐簇
   「新增 -2」不是聚类问题，是计数口径混用，10-01 已修）
6. T1.6 dogfood 扩 2 台设备（Windows/Linux 各一，按 `DEPLOY.md` 流程）
