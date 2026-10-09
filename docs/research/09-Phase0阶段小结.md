# 09 · Phase 0 阶段小结（2026-09-30 时点）：已完成项、剩余项与 go/no-go 前置

> 盘点 [08 章](08-Phase0执行计划.md) 的执行进度。结论先行：**Phase 0 的核心功能面已全部落地并在一台真实设备上实战运行**（particloud-macos → 123Pan WebDAV）；剩余工作以「被动积累」为主——代码侧只剩 polish。验证假设所需的不是更多代码，而是 14 周里的真实使用数据。

## 1. 已完成（对照 08 章任务编号）

### M0 原型工程化（全部 ✅，提前完成）
- T0.1–T0.5：bg CLI（zipapp 36KB）、backup.sh/ps1 接入、run JSON 留档、CI 三平台矩阵、真实引擎 E2E（borg 1.4.5 / restic 0.19.1，抓出 4 个格式级 bug）

### M1 语义层 v0.1（T1.1/T1.2/T1.4/T1.5 ✅；T1.3/T1.6 待真实数据）
- T1.1 manifest.json.enc：age 双 X25519 recipient（主身份 + 恢复码救援身份），init-keys.exp 恢复码闭环验证；**已在用户设备实战**（双路径解封演练通过）
- T1.2 时段标签（日历启发部分顺延）；T1.4 ntfy 推送（SEM_NTFY_URL sidecar）；T1.5 断档提醒 + 时区口径统一
- T1.3 聚类调优、T1.6 dogfood：**依赖真实数据积累**——已记两个调优素材（混合簇退级、载体根噪音）

### M2 覆盖审计（T2.1/T2.2/T2.3/T2.4 ✅；T2.5 ✅ 基础版）
- T2.2 preflight 预检器（占位文件/.git 排除/磁盘/引擎/凭据链/remote 存在性，error 中止 warning 放行）
- T2.1+T2.3+T2.4：exclusions.json 导出 → COVERAGE.txt 每次必产（排除明示 + 规则变更主动告知）
- T2.5（本次）：预检发现（半真文件计数）进 COVERAGE 报告
- 用户设备实测：15 条排除规则正确明示；WebDAV 500 事故反哺出 remote 能力探测（test_remote_caps.sh）与 05 §1.5 台账

### M3 逃生恢复（T3.1–T3.4 核心全部 ✅）
- 密钥初始化 + 强制恢复码（用户已抄写）；rescue 双路径指引写入 restore.md
- **bg drill 已产品化并在真实数据上通过**（5 PASS / 0 FAIL，含简历库文件实取）；30 天节流自动运行
- 待补：`bg drill` 的独立 CLI 入口（现挂于备份流程内 + 手动函数调用）；rescue 单文件脚本（T3.2 的 bash+PowerShell 独立版）

### 基础设施
- CI：7 job（3 平台真实备份 + semantic 测试矩阵 + multi-target/init E2E），shellcheck 全量 0 告警
- 命名体系定稿（用户驱动迭代 3 轮）：`<设备名>-<系统>` 小写、无 OS 版本、timeline 单层
- 存储层定案：rclone 统一管理（BACKUP_TARGETS 多目标）
- rbw（Bitwarden）集成方案定案并落文档（05 §7 / 03 §2.3 / 08 T2.2+T3.4 / PRD FR-R6）

## 2. 真实设备状态（particloud-macos）

| 项 | 状态 |
|---|---|
| 数据 | 9.9GB（3 档案仓库 + timeline），含 Downloads 24987 项 |
| 调度 | launchd 每日 02:34（2026-09-30 起全自动） |
| 密钥 | age 双路径就绪；恢复码已交付用户抄写 |
| 演练 | drill 5 PASS；rescue-test.txt 设备级留档 |
| 每次备份产物 | MANIFEST.txt / STORY.md / restore.md / COVERAGE.txt / manifest.json.enc / exclusions.json |

## 3. 剩余项与 go/no-go 前置条件

### 代码侧（小项，可随时做）
1. rescue 单文件脚本独立版（T3.2，bash+PowerShell）+ `bg drill` 独立 CLI 入口
2. T1.3 聚类调优——**等一周真实数据**（已记：混合簇、载体根噪音）
3. Windows 密钥初始化交互版（init-keys.ps1，对齐 init-keys.exp）

### 验证侧（Phase 0 的真正主体，不可压缩）
1. **被动观察 ≥1 周**：全自动备份/演练/推送的稳定性（中断、500 重试、preflight 误报率）
2. **T1.6 dogfood**：按 DEPLOY.md 部署 2 台以上设备（Windows/Linux 各一，验证跨平台矩阵），第 7/14 天问卷
3. **M4 决策门输入**：go/no-go 判据（08 §4）全部依赖 dogfood 数据——**现在起进入不可压缩的观察期**，代码迭代降速

### go/no-go 之前必须回答的三个问题
1. 用户是否**未被提示**地主动查看 STORY/时间轴？（北极星）
2. 覆盖报告是否真实改变了用户行为（调整排除/接线盘）？
3. 非致命哲学经受住了吗——语义层故障从未中断过备份本身？（目前记录：0 次中断）

## 4. 风险登记更新

- **单设备样本**：当前所有「验证」都是开发者自用（n=1），dogfood 扩到 3 设备前不构成证据
- **WebDAV 500 长尾**：123Pan 大文件偶发失败未做自动重试（rclone 内建 3 次）；多 remote（B2+R2 双写）是结构性解法，Phase 1 再上
- **secret 管理分散**：secrets.env（仓库口令）/ age 密钥 / rclone pass 三套并存；Phase 1 统一进 OS 钥匙串或 rbw
