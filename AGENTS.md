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
  进目标目录），归档选择也不支持 `::--last 1` 这类通配——用 `borg list --short` 前缀过滤后取尾；
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

## 3. 改动与验证流程

1. 改代码 → `python3 -m unittest discover -s semantic -p "test_*.py"`（46 项全绿，
   3.9/3.14 双版本已验证）→ `shellcheck -S warning backup.sh restore.sh
   semantic/semantic.sh` 0 告警 → 相关 shell E2E（均可本机跑，隔离临时目录不触真实配置）：
   `test_init_e2e.sh` / `test_multi_target.sh` / `test_timeline_retention.sh` /
   `test_restore_e2e.sh`（恢复链路四条路径实取）/ `test_cloud_failure.sh`（云端失败可见性）/
   `test_portable_stat.sh`（GNU/BSD 文件属性）/ `test_cloud_copy_only.sh`（云端只增不减红线）。
   后四个已挂 CI。
2. 提交信息：中文 conventional commits，`feat(scope): 描述` / `fix(scope): 描述`（看 git log）。
3. push 前自查新增代码注入面（变量子进程、eval、递归删除命令作用于变量路径——删除前
   必须有白名单守卫并按行读入，如 `prune_local_timeline` 的 `^[0-9]{4}-[a-z0-9-]+$`、
   `prune_run_jsons` 的 `^run-[0-9]{8}-[0-9]{6}\.json$`；`ls | xargs rm` 这类按空白拆词
   的写法在路径含空格时会把删除目标指到别处，一律禁用）。
4. main 分支保护：禁 update/delete/force-push、要求线性历史；admin 凭据直推放行。
   push 后盯 CI（6 runs：semantic 三平台矩阵 + linux/macos/windows 真实备份与断言；
   CI **不推云端**（`SKIP_WEBDAV=1`），windows job 仍要下载 restic/rclone 依赖）。

## 4. 本机与真实设备事实（开发机 = 用户 Mac，设备 particloud-macos）

- 部署配置：`~/.config/partiverse-backup/`（`config.sh` / `secrets.env` / `age/`），
  **不在本仓库内，勿动**；恢复码已由用户抄写纸质留存。
- 备份仓库：`~/PartiverseBackup/`（config/files/system 三个 borg 仓库，本地事实源）。
- 调度：launchd 每日 02:34（`~/Library/LaunchAgents/com.partiverse.backup.plist`；
  内嵌明文 BORG_PASSPHRASE 已 chmod 600，彻底修法 = wrapper 读 secrets.env，见待办）。
- 云端：rclone remote `Backguard:`（123Pan WebDAV），约 8–10GB。
- 本仓库上一级目录的 `research/`、`PRD.md`、`prototype/`、`pitch/` 是本地工件，
  **不在任何 git 仓库内**；关键结论已内联进 docs/HANDOVER。

## 5. 已知待办（代码小项；优先级与验证期安排见 HANDOVER §6）

1. rescue 单文件脚本独立版（bash + PowerShell 各一份，无 Python 依赖；08 章 T3.2）
2. `bg drill` 独立 CLI 入口（现挂于 `semantic.sh` 的 `run_drill` 函数）
3. Windows 密钥初始化交互版 `init-keys.ps1`（对齐 `init-keys.exp`）
4. launchd plist 明文口令 → wrapper 读 0600 `secrets.env`
5. T1.3 聚类调优（等 ≥1 周真实数据；已知素材：混合簇退级、载体根噪音、STORY 逐簇「新增 -2」渲染疑点）
6. T1.6 dogfood 扩 2 台设备（Windows/Linux 各一，按 `DEPLOY.md` 流程）
