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
   目录只写数量；根级散文件聚类不显示名称）。**任何新写的、会随时间轴上云的明文产物同受这条
   约束，包括机器报告**：`CLOUD-VERIFY.txt` 的差异样本因此只到**目录**为止（`dir_sample`），
   哪怕今天被校验的两棵树都是系统生成的名字也不行——「反正调用点选的是我们自己的目录」不是一道
   闸门，将来校验面扩到 `system-meta/` 那天它就漏了；守卫见 `test_cloud_verify.sh` 第 6 段。
   unittest 有测试锁定，改渲染逻辑先跑测试。
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
- **云端副本自证（`SEM_CLOUD_VERIFY`，默认开，10-01 落地，roadmap A6 L1）判平只认内容**：
  上一条的产品化对策。推送全报成功之后，`run_cloud_verify` 按两件事复核——①清单**单向包含**
  （本地每个对象云端都在且同尺寸；云端多出来的是本地已裁的历史副本，按红线 §1.4 只增不减
  **不计失败**，写成双向相等就每晚假报）；②仓库 `config` 的 sha256（`rclone cat … | sha256`）
  ——结论写 `$BACKUP_BASE/timeline/CLOUD-VERIFY.txt`（**先比对后落笔**，所以它随下一轮时间轴
  推送才上云，从不自指；本地那份 `rescue-test.txt` 必须在清单里摘掉，否则每晚假报云端少一份）。
  状态四档：`PASS` / `HEALED`（发现云端是陈旧那份，当场 `-I --include config` forcing 补传
  **并重新读回核对**过）/ `UNKNOWN`（网盘读不出，没证成也没证败，**不改退出码**——把抖动报成
  失败会让告警通道失去信任）/ `FAIL`（补传后仍不符，或云端缺对象/尺寸不符 → 非零退出 + 告警）。
  **`HEALED` 只能由重新读过的内容换来，`rclone copy` 退出 0 在这条 remote 上什么都没证明。**
  守卫 `test_cloud_verify.sh`（rclone 桩只伪造 `lsl`/`cat`，其余子命令转发真实二进制；15 条变异）。
  **别拿 `chmod 444` 造「云端那个文件写不进去」**：rclone 默认**非原地写**（目标目录建临时文件
  再 rename），只读的小文件本身挡不住替换，实测反而把不一致修好了 → 假 FAIL 断言踩空；要造
  「补传后仍不一致」就让桩在 `cat` 上撒谎。
- **`ls -1t "$f".*` 对目录操作数打印的是「目录的内容」，不是目录本身**——想按 mtime 排「这些
  路径」必须加 `-d`（`ls -1dt`）。10-01 日志轮转的守卫因此没被测到：同名目录压根没进删除候选，
  摘掉「必须是普通文件」那道变异**E2E 全绿**。更阴的是两个 bug 互相掩盖：不加 `-d` 时 ls 给
  目录内容带上路径前缀，形态白名单把它挡在删除之外，看着正像「守卫在起作用」。**凡是
  「列候选 → 逐个判定 → 删除/移动」的清单，变异验证要连清单一起摘一次**（本轮把 `ls -1dt`
  改回 `ls -1t` 作独立变异，才咬住）。
- **`info/warn` 只写 stdout**（`backup.sh:14-17`），`$LOG` 里只有引擎 `tee -a` 的输出和
  `run 边界` 行。所以断言「某条告警真的运作过」要取夹具的 `out.log`；取 `backup.log` 会断言
  一个恒为假的字符串（launchd 侧对应 `StandardOutPath` → `launchd.out.log`，见 §4 plist 段）。
- **日志轮转与 run 边界行**（10-01 落地，roadmap A4）：`backup.sh` 每次运行对
  `$LOG_DIR/{backup,rclone,sem,drill}.log` 按 `SEM_LOG_MAX_BYTES`（默认 4 MiB）超阈值才切，
  副本按 mtime 留 `SEM_LOG_KEEP`（默认 7）份；`launchd.*.log` 由 launchd 持句柄**不在名单内**。
  删除候选一律走「宽 glob + 形态正则 + 必须是普通文件」两道守卫并逐行 `read -r`，
  `rm -f` 对目录是 rc=1，set -e 下会把整次备份带走（旁路没资格终止本体，§1.3 同一条哲学）。
  一轮一行的 `[时间] run 边界: sha=… rc=… dur=…s` 由 EXIT trap 写，取不到 git HEAD 就退化成
  `sha=nogit`。**写这个夹具的规矩**：KEEP 窗口的种子 mtime 必须 `touch -t` 写死（同秒并列会让
  「留哪几份」变成运气），前一阶段切出的真副本要先 `rm -f` 掉（它们占名额）。守卫见
  `test_log_rotation.sh`（linux + macos 双 CI，6 条变异）。
- **存储完整性校验走编排层，判定分三档**（10-01 夜落地，roadmap A2a）：`backup.sh` 每
  `INTEGRITY_DAYS`（默认 30）天对每个 borg 仓库跑一次 `borg check --verify-data`，结论写
  `timeline/INTEGRITY.txt`。**为什么必须有**：仓库里某个 chunk 腐化**不会**让 `borg create`
  失败（10-01 实测：翻掉数据段中间一个字节，备份全绿、演练照样取回），也就是说现有全部守卫
  对这类问题恒为绿——只有主动整仓读一遍才看得见。**引擎调用不进语义层、不进 `bg preflight`**
  （§1.3：Python 侧只做纯文件系统检查）。三档：rc=0 PASS；rc=1 FAIL（逐块校验真发现坏数据）；
  **rc>=2 不能一刀切判 FAIL 也不能判 UNKNOWN**——borg 把「仓库可能已毁」「用法错误」「拿不到锁」
  塞在同一档（实测并发持锁 + `BORG_LOCK_WAIT=0` 就是 rc=2），只有错误原文命中锁的才记 UNKNOWN
  且不改退出码（否则一次手工 `drill.sh --force` 就能把 nightly 报成腐化），其余按最坏情况 FAIL。
  匹配锁的 pattern 必须逐字照抄引擎原文（`lock timeout` / `failed to create/acquire the lock`）：
  写成 `failed to (create|acquire) the lock` 看着等价，实际真消息是 `create/acquire` 连着的，
  **一条都不命中**——夹具第 4 段当场把这条变异出来的假 UNKNOWN 报成 FAIL。**报告只记类别/rc/耗时，
  引擎原文一个字节都不抄**：borg 的锁错误行里带仓库绝对路径，而这份文件随时间轴上云（§1.1 同一条
  口径，`test_integrity.sh` 第 1 段按「报告里不许出现 `$BACKUP_BASE`/源码树路径/任何文件名」锁住）。
  窗口节流用**产物自身的 mtime**当标记（与 `rescue-test.txt` 同一条机制，不另养状态文件）；
  低频路径的节流本身要被测，否则「月度」只是文档里的形容词。`INTEGRITY_DAYS=0` 是人工立刻跑的入口；
  没登记任何仓库时**不写报告**（一份 checks=0 的「完整性通过」比没有更坏）。守卫 `test_integrity.sh`
  （linux + macos 双 CI；restic 侧未接入，与 `backup.ps1` 的自证同批欠账）。
- **恢复演练按内容校验（roadmap A2b，10-02 落地）**：旧口径取回后**只比 size**，「同长度不同
  内容」永远 PASS——它是「rclone 只比大小」那一课在取回侧的镜像，也是 10-01 跨类别错配（取回
  了错仓库的文件）能被放过去的缘故。现在备份期 `seal_manifest` 给**当晚抽中的那几条**样本记
  源文件 sha256（`bg manifest --hash-drill-samples`），演练期比内容；结果逐条标注依据
  （`(内容哈希一致)` / `(仅比大小：清单未记内容哈希)`），汇总行带两类的计数。**三条口径规矩**：
  ①只记样本、不给全量文件算哈希（否则每晚多读一遍盘，取证却只用于 5 个文件——成本理由要写进
  注释）；②哈希记在**备份期的源文件**上，不记在演练期（30 天后源早变了＝假失败）也不记在归档里
  （取回时组装一致照样遮得住）；记之前必须验「存在＋是普通文件＋尺寸与归档条目一致」，
  任一条不满足就**不记**（宁缺毋滥，绝不拿 size 冒充内容）；③**记哈希的抽样与 drill 的抽样
  必须共用 `select_drill_samples`**（同 count 同种子），两处各算各的就是「记了没人用」，
  而 stderr 那行 `[manifest] 演练样本内容哈希：n/picked` 是唯一的现场信号，`0/N` 意味着这层
  证据整段退化（分母是当晚**实际抽中**的条数，count 只是上限，写 `0/99` 等于没信息）。
  `sha256` 只进**密封**清单（和演练期解封的临时件），run.json 与一切明文产物不许出现它
  （`hash_drill_samples` 先 `dict(e)` 逐项复制，回灌进 run 就是漏；`MANIFEST_FORMAT` 保持
  `backguard/manifest/1`，rescue.sh 逐字比对，它的 awk 状态机忽略未知键所以向后兼容）。
  **夹具的两处死法**（都实测踩过）：`borg create` 必须用**绝对路径** include——相对 include
  让归档路径变成 `src/…`，`/ + raw` 指向不存在的位置，记哈希静默记成 0 条而全链路仍全绿；
  `BG` 要指 `semantic/bg.pyz`（可执行入口），直跑 `bg_semantic.py` 在 `semantic_bg()` 里
  Permission denied。守卫 `test_drill_e2e.sh`（调**生产** `seal_manifest` 而非夹具自拼参数，
  否则「生产与 drill 口径不一致」这一类测不到；断言 6 把 note.txt 的哈希换成等长另一段内容，
  要求判红 + 恰好 1 条 FAIL + 报错写明「大小倒是一致」）与 `test_bg_semantic.py::TestDrillContentHash`。
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
- **交替模式一律 `grep -E 'a|b'`**：BSD grep（macOS / CI 的 macos runner）**不支持** BRE 的
  `\|`——它按字面量找，匹配不到就返回空。用它判断「文档里有没有这段话」会得出「文件被人改过」
  的假结论（10-01 就是这样误判了一次 AGENTS.md 被改动，而 `git status` 其实是干净的）。
- **PowerShell 侧同样受 §1.4 约束，且有三个反直觉的坑**：`backup.ps1` 的云端推送此前只
  `Write-Warning` 就照打 `FULLY COMPLETE`（bash 侧 a1ad332 修过的那发没移植过来），现在
  两处 `rclone copy`（引擎仓库 + timeline）的 rc 都汇进 `$cloudFailed` 并驱动结论行
  `(engine=… cloud=…)`。写这条守卫时踩到的：**①脚本内的 `exit` 会终结宿主会话**——CI 里用
  `& "$PWD\backup.ps1"` 直调产品脚本，产品一 exit 整个 step 跟着死，「判红」与「没断言」撞成
  同一件事（正好把守卫自己变成假绿），必须 `& pwsh.exe -File …` 起子进程拿 `$LASTEXITCODE`；
  **②`Start-PartiverseBackup` 顶部 `$ErrorActionPreference = "Stop"`**，那里 `Write-Error` 是
  终止性异常、会被类别循环的 `catch` 接走，把「云端没副本」混计成「引擎失败」，所以告警行走
  `Write-Host`（GH Actions 的注解流，且不被改写）。
  **③宿主自己会漏产品的退出码**：`pwsh -Command` 在脚本末尾**没有 `exit` 语句**时，拿「最后一条
  原生命令的退出码」当宿主退出码——8eddf05 那轮实测：四条断言全过、`=== 云端失败可见性 OK (rc=1) ===`
  都打印了，step 仍然红，因为被测产品**本该**返回 1，那个 1 直接漏成了守卫的 rc。不显式
  `exit 0` 这条守卫永远不可能绿（而「守卫恒红」在 CI 里长得和「产品坏了」一模一样）。成功路径
  末尾写 `exit 0`，让结论只由断言给出。
- **`gh ... --jq '.[0].a + "/" + .[0].b'` 会当场报错**（`expected an object but got: array`），
  而 `--jq '.[0].headSha'` 同一份输出却不报错——别拿 `--jq` 的字符串拼接版当可用查询。
  迁移驱动的门禁改成「取原始 JSON + `python3` 解析」，并**逐 job、逐 step 读 conclusion**：
  整轮 `success` 不等于 E2E 那几步跑过（§3「CI 绿 ≠ 跑过」的机器化形态）。
- **`set -u` 下未绑定的数组是**致命**错误，不是可捕获的非零**：`${#arr[@]}` 直接终止整个
  shell，调用点的 `|| warn` 兜不住它，而错误消息常被上层的 `2>&1` 吞进日志文件——表面症状是
  「脚本静默退出 1」。语义层碰 `BORG_EXCLUDES_<cls>` 前先用
  `eval "[[ \${BORG_EXCLUDES_${cls}[0]+x} == x ]]" || continue` 探测（`${arr[0]+x}` 在
  bash 3.2/5.x 都安全；写 `$cls[0]` 会被 shellcheck 报 SC1087，必须 `${cls}[0]`）。
  同理：E2E 里直接 source `semantic.sh` 调 `generate_semantic` 时，`SCRIPT_DIR`/`LOG_DIR`/`LOG`
  三个全局都得备好（生产由 `backup.sh` 备好），少一个就死，且死得没有声音——
  现由 `test_restore_e2e.sh` 断言 6c 锁住「缺一个排除数组不得终止备份」这条非致命分层。
- **`.ps1` 的逻辑先在 Linux 容器里收敛，再交给 windows job 谈接线**：本机没有 pwsh，但
  `docker run --rm -v "$PWD":/repo:ro mcr.microsoft.com/powershell:lts pwsh -NoProfile -File
  /repo/test_prune_logic.ps1` 几秒就能把 `semantic.ps1` 的纯逻辑面跑完（同一份 pwsh 7 实现：
  语法、cmdlet 绑定、排序键、白名单、级联、KEEP 的各分支）。**它不覆盖**反斜杠路径/大小写
  不敏感（Linux 上造不出来）与 `powershell.exe` 5.1 那台宿主，所以替代不了 CI 的
  `Assert local timeline retention`；两发分工＝「逻辑 here，接线与环境在 CI」。10-02 就是靠它
  在**没烧 CI 轮**的情况下抓出移植偏差：PS 侧空壳级联是「先筛空、再统一删」，一趟只收掉日期
  这一层，月份/年壳照旧留着，而两侧守卫都没测到（bash 12 份种子全挤在同一个月）。补法：
  bash `test_timeline_retention.sh` 加 2b 段（跨年种子 + 月/年壳，变异 `-empty -print0 | xargs
  rmdir` 当场咬住），PS 侧改成「排序后再判空」（管道是流式的，子壳先删父壳才可能空，等价于
  `find -delete` 隐含的 `-depth`），`test_prune_logic.ps1` 与 windows job 那两段守卫同时补跨年断言。
  同一条容器路还能**只查语法**地验 CI 里那段盲写的 PowerShell：把 step 的 `run:` 块用 python
  的 `yaml.safe_load` 抽成 `.ps1`，再
  `[System.Management.Automation.Language.Parser]::ParseFile(path,[ref]$null,[ref]$errs)`——
  括号配错、`-Parent` 那种半截子表达式当场报出来，不用等 25 分钟。**别拿它跑整段守卫**：
  `Seed-Snap` 用反斜杠拼路径、`. "$PWD\semantic\semantic.ps1"` 在 Linux 上是找不到的文件名，
  把分隔符改掉就不再是被测的那份脚本了。
- **`ConvertFrom-Json` 交回什么类型是宿主版本相关的，凡把引擎 JSON 的字段送上命令行都过
  `Format-IsoTime`**（10-02 windows 集成段的真凶）：pwsh 7.2 给 String（容器实测），Windows
  PowerShell 5.1 与 pwsh 7.4+ 给 `[datetime]`——后者一旦拼进参数就是**文化相关**的
  `10/02/2026 06:31:11`，`bg` 的 `parse_iso` 读不动。它只在「存在上一份归档」的那一轮露头
  （首备没有 `--parent-time`），而 CI 每轮新建仓库只跑首备，所以真机 nightly 从第二天起就一直在
  静默降级：`convert` 只存不解析照报成功，`generate` 才崩，而语义层是非致命旁路（§1.3）——
  表面症状＝**第二次起时间轴整段不产出、备份仍 FULLY COMPLETE**。两侧一起修：PS 边界
  `Format-IsoTime`（`[datetime]/[datetimeoffset]` → `ToUniversalTime()` + 固定 `yyyy-MM-ddTHH:mm:ss'Z'`，
  String 原样透传），Python 侧 `parse_iso` 把小数秒补齐/截断到 6 位（restic 是 Go 的 RFC3339Nano，
  1/4/7/9 位都会出现，而 py3.9 只认 3/6 位——§2「Python 兼容」同一条约束的另一面）。守卫：
  `test_prune_logic.ps1` 场景 7（变异＝摘掉 datetime 分支，四条当场报出那条文化串）+
  `test_bg_semantic.py::TestParsers.test_parse_iso_fraction_digits`（变异＝摘掉补齐那行，3.9 上
  `ValueError` 复现）。**通则：类型/格式随宿主版本漂移的输入，必须在自己的边界上归一，
  而不是假定上游那台机器给的是原文。**
- **E2E 夹具要与生产同形**：夹具桩只返回「脚本想要的那种形状」时，会把真 bug 遮掉——
  迁移门禁的 `gh --jq` 版在本机真实 gh 上炸、在桩上却一直「通过」，因为桩直接 echo 结论字符串。
  桩要么吐原始 JSON，要么连被调对象的返回形状一起复刻。
- **同一处调用点喂多个分支时，每个分支都要各调一次**：`cmd_convert.load()` 用一句
  `parser(text, args.strip, known_dirs)` 喂 restic/borg/generic 三个 parser，前两个后来加过
  参数、generic 没跟——`--engine generic` 从来没有跑通过（`TypeError: takes 1 positional
  argument but 3 were given`），而生产只走 borg/restic，所以一直没露头（10-02 最小夹具复现）。
  修的时候同形不只是 arity：不剥盘符与反斜杠的路径会原样落进清单，所以也过 `_norm_path`。
  守卫 `test_bg_semantic.py::TestParsers` 的两条新用例，两条变异各摘一处（签名 / 归一化）
  都各自咬住——只测「返回对不对」测不到「这条分支根本没被调过」。

## 3. 改动与验证流程

1. 改代码 → `python3 -m unittest discover -s semantic -p "test_*.py"`（56 项全绿，
   3.9/3.14 双版本已验证）→ `shellcheck -S warning backup.sh restore.sh
   semantic/semantic.sh drill.sh rescue.sh` 0 告警 → 相关 shell E2E（均可本机跑，隔离临时目录不触真实配置）：
   `test_init_e2e.sh` / `test_multi_target.sh` / `test_timeline_retention.sh` /
   `test_restore_e2e.sh`（恢复链路四条路径实取）/ `test_cloud_failure.sh`（云端失败可见性）/
   `test_portable_stat.sh`（GNU/BSD 文件属性）/ `test_cloud_copy_only.sh`（云端只增不减红线）/
   `test_drill_e2e.sh`（演练独立入口 + 结论判定不误报 + 内容哈希这一维）/
   `test_rescue_e2e.sh`（逃生恢复：两种布局 + borg/restic 搜取 + age 双路径）/
   `test_log_rotation.sh`（日志轮转 + run 边界行）/
   `test_cloud_verify.sh`（云端副本自证：单向包含 + config 内容哈希 + HEALED/UNKNOWN 分档）/
   `test_integrity.sh`（存储完整性：窗口节流 + 锁 flake 记 UNKNOWN / 非锁 fatal 判 FAIL / 真损坏）/
   `test_month_jump.sh`（把时间推过一个月：两个 30 天窗口同夜重开 + 真实保留策略裁出的云端
   单向包含 + 报告晚一轮上云 + 轮转，四条低频路径的**组合面**）/
   `test_bsd_probe.sh`（零备份轮探针：把纯函数从生产文件里**切**出来对着 python3 现算的真相
   断言——哈希轮流域 / 本地清单摘除与排序 / `rclone lsl` 含空格路径 / 目录级脱敏 / `date -r` /
   演练 fail-closed）。
   十四套都已挂 CI，**车道按实测墙钟分，不是按「谁新谁排前面」分**
   （linux job 全跑，23 步 ≈5 分钟；macos job 只留 backup+三条 assert / restore / rescue /
   init / log_rotation / bsd_probe，其余四套重夹具 integrity/cloud_verify/cloud_failure/drill
   退回 linux-only）。缘故写在 docs/HANDOVER §11 的 10-02 午后块：免费 macos runner 上一个整轮
   `backup.sh` 要 6–13 分钟（本机 9 秒），一个 step 里放六个整轮的 `test_integrity.sh`
   正好撞满 step 级 `timeout-minutes: 40`，那一轮 macos 跑了 126 分钟仍红，而它后面三步
   一秒没执行——**这条 runner 上没有一步是便宜的，重排清单救不了，只能分车道**。
   `test_remote_caps.sh` 是手工能力探测，不入 CI。
   （可选依赖缺失的分支必须打 SKIP 并在末行如实标注「未测」，不得只报 E2E-OK）。
   CI 的 linux/macos 真实备份 job 另配一次性 age 主身份，并断言
   `timeline/rescue-test.txt` 存在且结论为「≥1 PASS / 0 FAIL」：没有密钥时
   `run_drill` 走 rc=20 静默跳过、产物根本不存在，演练这条生产面就等于没测——10-01
   的跨类别取回错配正是藏在这层遮罩下。**「CI 绿」≠「跑过」，先确认守卫那条 step 真的执行了。**
   新增生产面脚本就把它加进上面的 shellcheck 清单与 CI；**写文档说「已挂 CI（linux + macos
   各一步）」之前必须 `grep -n <脚本名> .github/workflows/ci.yml` 核对**——10-01 那条就是这么
   写串的：macos 一步从没加过，而 HANDOVER 已经把它记成既成事实；
   **但 grep 到 ≠ 跑过：先读 `timeout-minutes` 和这一步里有几个整轮**。
   `test_portable_stat.sh` 的断言 4
   会扫全仓 `*.sh` 的变量紧贴非 ASCII——新脚本自动在守卫内，别指望只测本机。
   **改目录形状时 `.github/workflows/ci.yml` 里那些硬编码路径也是被测面**——本机 E2E
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
   的是旧测试，会假打 E2E-OK）。**变异脚本自身也必须 `set -e`，并且要验证变异真的落上了**
   （`grep -q <变异标记>`）：10-01 迁移驱动的变异用整段字符串匹配，没匹配上时 python 抛
   AssertionError，而 runner 没 `set -e` 就继续拿**未变异的驱动**跑完夹具，得出「新断言
   咬不住」的假结论；改成按行号替换 + 落上校验后，同一条断言当场报错。
   **一条主张配一个专属变异，断言的先后顺序就是诊断本身**：同一轮里「某条检查没判 FAIL」
   和「FAIL 不改退出码」是两种坏法，若退出码那条写在前面，两种坏法会撞成同一句报错，读的人
   分不清坏在哪一步——A6 首轮变异 m2/m10/m11 三个都报「仍宣布 FULLY COMPLETE」，把
   **「哪条检查抓到了它」挪到「它改了退出码」之前**才各自报对自己的原因（`test_cloud_verify.sh`
   §4/§5a/§7 的注释记着这条规矩）。同理，**新增一类校验对象要先确认它真进了清单**：自证第一版
   borg 分支漏登记 `repo_pairs`，三类仓库根本没被校验，而 E2E 全绿——是报告头部的
   `checks=2` 暴露的，所以**汇总计数行值得单独断言**，别只看「有没有 FAIL」。
   **变异报「没咬住」有三种成因，别一律当成实现的问题**：①断言被冗余实现救场（上面那条）；
   ②**断言自己是死的**——10-02 的 m04：夹具取证据计数写成了
   `basis="$(grep -o '内容哈希 [0-9]*，仅比大小 [0-9]*' "$RT" | head -1)"`，「无命中」正是这条断言
   要抓的情形，而 grep 的 rc=1 在 `set -euo pipefail` 下让夹具在那一行就退出，后面的
   `[[ -n "$basis" ]] || fail` 永远轮不到；改成 `{ grep … || true; } | head -1` 之后当场咬住。
   推论：**`X="$(grep …)"` 里「空结果」是被测情形时必须显式中和退出码**，否则它是一条死断言，
   而它的死法与「变异没落上」长得一模一样；③同一组用例里多条跳过/失败理由**互相顶掉**——
   A2b 的单测把「超大 / 缺失 / 被改过」三条写成 size=999，999 先被超大规则拦下，摘掉尺寸闸门
   仍全绿；要写成每条理由各自的数值都过得了别的闸门。
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
   **PowerShell 版 `rescue.ps1` 仍待做**——只在能挂上 CI 验证时写（本机无 pwsh）。
   **10-02 起的 Windows 差距清单**（对着 `backup.sh` 逐条读出来的，T1.6 上真机前先补这几发）：
   ①`backup.ps1` 顶部 `$ErrorActionPreference = "Stop"` 是**在 powershell.exe 5.1 下的未验证面**——
   Task Scheduler 注册的正是 powershell.exe，而 5.1 里原生命令的 stderr 一旦重定向
   （`restic … 2>&1 | Tee-Object`、`rclone mkdir … 2>$null`）会变成终止性异常，把成功的类别
   记成失败；CI 的 windows job 跑的是 pwsh 7，所以这条永远不会在 CI 现形，**上真机前先手用
   powershell.exe 跑一轮**——**10-02 已把它编成 CI step**（`Windows PowerShell 5.1 host probe`，
   `shell: powershell` 就是那台宿主，不必等真机）：报四件事——两份 .ps1 在 5.1 解析器下的语法错数、
   `ConvertFrom-Json` 交回的类型（§4.17 的争议点）、`$EAP=Stop` 下三种 stderr 形态
   （`2>&1 | Tee-Object` / `2>$null` / `2>&1 | Out-Null`，正是 `backup.ps1:97/179/22` 用的那三种）
   各自抛不抛、`Format-IsoTime` 在 5.1 上交回的是不是 ISO。**只有第二条和第三条是「先报后断」**
   （要断什么取决于答案），第一、四条是硬断言。它排在 windows job 所有产品断言**之后**：
   新探针红的时候不该把同一轮「保留策略修好了没」那条结论带走（runner 一轮一小时起，
   §3「步骤顺序就是优先级」）。（另一发：云端失败守卫的子进程特意用 `pwsh.exe`，
   就是为了不把「宿主 5.1」与「被测脚本」两件事混在一起——那条不变。）
   ②没有 A4 日志轮转/run 边界行、③没有 A6 云端自证、④没有 A2a 完整性（restic `check --read-data`
   同形）、⑤没有恢复演练（A2b 的内容哈希这一维更无从谈起：`secrets.env` 里没有 age）、
   ⑥~~`semantic.ps1` 侧没有 `SEM_TIMELINE_KEEP`（本地时间轴只增不减）~~ **10-02 写了，两轮 CI 各抓到一条真缺陷**
   （`semantic.ps1` 的 `Prune-LocalTimeline`，四条口径与 `prune_local_timeline` 逐条对齐：第 4 层
   才算快照、按相对路径排序取除最后 N 份、叶子形态白名单不匹配就告警跳过、腾空日期壳自深向浅收）。
   那一轮报「KEEP=1 却一份都没裁」，而**四种坏法在产物目录上长得一模一样**：函数没被调用（语义层在
   generate 之前就 return 了）、`SEM_TIMELINE_KEEP` 没读到（回落 14 → 5 份 ≤ 14 早退）、第 4 层一个
   没认出（同样早退）、函数内抛终止性异常（`backup.ps1` 的 catch 降成 warning，结论照打 FULLY
   COMPLETE）。对策是**让函数自己报现场**：`timeline-retention window: keep=N snaps=M` 一行三事实。
   第二轮证据行兑现：报的是第一种，而 `--- 子进程 [semantic] 行 ---` 打出 `generate 失败`——
   真实成因是 `ConvertFrom-Json` 把 restic 的 `time` 交回成 `[datetime]`（pwsh 7.4+ 与 5.1），
   拼进命令行即文化格式串，而这条分支**只在有上一份归档的第二轮才走到**（见 §2 的
   `Format-IsoTime` 一条与 HANDOVER §4.17）。
   **纯 ASCII 是故意的**——守卫在父进程里匹配子进程的 stdout，中文要先过 `[Console]::OutputEncoding`
   那道解码，编码不匹配时中文行糊成乱码，守卫会红得毫无道理（同一理由见 §3 的告警行取 `out.log`）。
   守卫同时改成两段：第一段 dot-source `semantic.ps1` 只调函数本身（先把「逻辑坏了」单独证掉），
   第二段才跑整轮产品（谈「接线」）——两段的失败面不重叠，才分得开上面那四种。**只用 `-First` 这类
   5.1 就有的写法**（没碰 6.0+ 的 `-SkipLast`），并去掉 `-Culture ''`、`StartsWith(…, [StringComparison])`
   与 `string + [IO.Path]::DirectorySeparatorChar` 这三处 5.1 未验证面。**同一天还借 Linux 容器里的 pwsh 7 抓出发移植时真坏了的那一发**：PS 侧级联写成「先筛空、再统一删」，一趟只收掉日期壳，月份/年壳照旧留着（bash 侧 `find -empty -delete` 隐含 `-depth` 天然收干净，两侧守卫却都没测到——种子全挤在同一个月）。详见 §3「`.ps1` 的逻辑先在容器里收敛」那条）、⑦`restic forget` 不带
   `--prune`（仓库只 compact 不了）、⑧权限面靠 NTFS 继承，bash 侧那套整树归一化没有对应实现。
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
