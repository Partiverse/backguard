/* zcode-workflow
description: backguard 观察期收口：每轮核验昨夜 nightly（verify-nightly + STATUS.jsonl 末行）与
  CI 门禁，keep-within（判定日 ≥2026-10-07）与观察期（判定日 ≥2026-10-10）两个 gate
  按当天日期自动分支——未到期只取证挂起，到期出正式判定并经独立复核员重算；T1.3 备料；台账写 HANDOVER 续记与项目记忆（本地 commit 不
  push）。判定日后重跑即执行判定。
whenToUse: 10-07（keep-within 判定）、10-10 后（观察期满判定）或任何一天需要例行验收昨夜 nightly
  并推进观察期收口时；也可以每天跑一次作为日检。
*/
interface AcceptanceVerdict {
  /** verify-nightly 结果：pass/fail 计数、VEROK/VER-FAIL、退出码 */
  nightly: string;
  /** STATUS.jsonl 末行判读：rc、engine、有无绝对路径、快照数、与昨夜日期是否相称 */
  statusLine: string;
  /** 门禁状态：HEAD 轮 CI 结论、部署树与 origin/main 是否同指 */
  gate: string;
  /** 发现的异常，无则空数组 */
  anomalies: string[];
}

interface GateAVerdict {
  /** ripe=判定日（≥2026-10-07 的首个 nightly 后）已到、出结论；suspended=未到期只取证 */
  state: "ripe" | "suspended";
  /** 三仓归档数与最老归档日期（如 config=7(最老20260929)） */
  archives: string;
  /** 旧口径（keep-daily/weekly/monthly）dry-run 的 Would-prune 数 */
  oldPolicy: string;
  /** 新口径（加 keep-within=7d）dry-run 的 Would-prune 数 */
  newPolicy: string;
  /** 时间轴 7 天内快照数与 7 天内归档数是否对齐 */
  alignment: string;
  /** 判定结论或挂起原因，必须引用数字 */
  conclusion: string;
  /** 关键命令与原始输出摘录；绝不包含口令或 secrets 内容 */
  evidence: string[];
}

interface GateBVerdict {
  /** ripe=判定日（≥2026-10-10）已到；suspended=未到期只取证 */
  state: "ripe" | "suspended";
  /** 10-03 追平日以来 nightly 边界行清点：总数、rc=0 数、任何 rc≠0 的日期与现场 */
  streak: string;
  /** 语义层 0 中断、云端自证 FAIL=0 的证据（grep 计数与汇总行） */
  clean: string;
  /** 判定结论或挂起原因，引用数字 */
  conclusion: string;
  /** 关键命令与原始输出摘录 */
  evidence: string[];
}

interface Confirm {
  /** agree=独立重算后同意原结论；disagree=不一致，detail 写差异 */
  verdict: "agree" | "disagree";
  /** 复核者自己重跑命令得到的数字与结论 */
  detail: string;
}

interface Readiness {
  /** B 收口前 no（只给备料摘要）；B 收口后 yes（给可执行的第一刀计划） */
  ready: "yes" | "no";
  /** 数据窗口、已知问题（混合簇退级、载体根噪音）、基准位置、建议的第一刀 */
  brief: string;
}

interface Ledger {
  /** 写入 HANDOVER 的续记标题（接续文件里最后一个「续 N」编号） */
  handoverEntry: string;
  /** 本地 commit 的短 SHA（只 commit 不 push；未 commit 则说明原因） */
  committed: string;
  /** M4 前剩余事项清单，逐条 */
  m4Items: string[];
  /** 项目记忆是否已更新及更新了哪个文件 */
  memoryUpdated: string;
}

interface ReaderFindings {
  /** 台账与报告草稿的事实性/清晰度问题，无则空数组 */
  issues: string[];
}

// 今天的 ISO 日期（判定成熟度的唯一时钟来源）
const today = (await world.run("date", ["+%Y-%m-%d"])).stdout.trim();
log(`观察期收口 workflow 启动，今天是 ${today}。gate A 判定日 ≥2026-10-07，gate B 判定日 ≥2026-10-10。`);

phase("核验昨夜备份与门禁");
const verify = await world.run("bash", ["v0/verify-nightly.sh"], { timeoutMs: 600000 });
const statusTail = await world.run("tail", ["-n", "1", "/Users/nebulaboratories/PartiverseBackup/timeline/STATUS.jsonl"]);
const ghRuns = await world.run("gh", ["run", "list", "-R", "Partiverse/backguard", "--limit", "3", "--json", "headSha,conclusion,status"]);
const headRev = await world.run("git", ["-C", "v0", "rev-parse", "--short", "HEAD"]);
const originRev = await world.run("git", ["-C", "v0", "rev-parse", "--short", "origin/main"]);
log("verify-nightly、STATUS 末行、CI 门禁三组证据已取齐，交给验收判读员。");
const acceptance = await agent("验收判读员", {
  system:
    "你是 backguard 项目的夜间验收判读员。只判读证据，不改任何文件。生产目录 " +
    "(~/.config/partiverse-backup、~/PartiverseBackup) 只读。可读文件补证（如 STATUS.jsonl 全文、" +
    "~/.local/share/partiverse-backup/launchd.out.log），但绝不输出任何口令或 secrets 内容。",
}).ask<AcceptanceVerdict>(
  "判读昨晚 02:34 nightly 的验收证据。判据：verify-nightly 须 pass>0 且 fail=0；" +
    "STATUS.jsonl 末行须 rc=0、engine 为 borg|restic、无绝对路径（形如 \":/ 的片段）、" +
    "ts 日期与昨夜相称；CI 门禁看 HEAD 轮是否 completed/success、部署树 HEAD 与 origin/main 是否同指。\n\n" +
    `verify-nightly 退出码 ${verify.exitCode}，输出：\n${verify.stdout}\n${verify.stderr}\n\n` +
    `STATUS.jsonl 末行：\n${statusTail.stdout}\n\n` +
    `最近三轮 CI：\n${ghRuns.stdout}\n\n` +
    `部署树 HEAD=${headRev.stdout.trim()}，origin/main=${originRev.stdout.trim()}。\n\n` +
    "anomalies 里写所有值得人看一眼的异常（含 verify 的 fail 行与 STATUS 形状偏离），没有就空数组。",
);

phase("keep-within 取证与判定");
const gateARipe = today >= "2026-10-07";
const gateA = await agent("keep-within 取证员", {
  system:
    "你是 backguard 的 keep-within 保留策略取证员。生产 borg 仓库在 ~/PartiverseBackup/borg-{config,files,system}，" +
    "口令只从 `set -a; source ~/.config/partiverse-backup/secrets.env; set +a` 获得——" +
    "绝不把口令或 secrets 的任何内容写进输出，只允许输出计数、日期与仓库清单。所有 borg 操作只读：" +
    "borg list 与 borg prune 的 dry-run（-n）。仓库的事实口径：borg 的 --keep-within 与 restic 不同名不同义，" +
    "10-03 落地的新口径是 --keep-within=7d --keep-daily=7 --keep-weekly=4 --keep-monthly=6。",
}).ask<GateAVerdict>(
  `今天是 ${today}。${gateARipe ? "判定日已到（≥2026-10-07 的 nightly 已跑过），请给出正式判定结论。" : "判定日未到（<2026-10-07），state=suspended，只取证挂起，禁止下判定结论。"}` +
    " 取证步骤：①borg list 三仓，数归档、记最老归档日期；②对 borg-config 仓各跑一次 prune dry-run：" +
    "旧口径 `borg prune -n --stats --keep-daily=7 --keep-weekly=4 --keep-monthly=6 <repo>` 与" +
    "新口径（再加 --keep-within=7d），各数 Would-prune 行数；③数时间轴" +
    " ~/PartiverseBackup/timeline 下 7 天内的快照目录数（YYYY/MM/DD/HHMM-标签 第 4 层），" +
    "与 7 天内归档数对齐。conclusion 里写清判定或挂起原因，全部引用你数出来的数字。",
);
report({ gate: "keep-within", state: gateA.state, conclusion: gateA.conclusion, alignment: gateA.alignment });
if (gateARipe) {
  phase("keep-within 结论独立复核");
  const confirmA = await agent("keep-within 复核员", {
    system:
      "你是独立复核员：不看别人的结论，只按自己的重算结果说话。同样的只读纪律：" +
      "口令只从 secrets.env 取、绝不写入输出；borg 只跑 list 与 prune -n。" +
      "如果重算结果与给出的结论不一致，直接 disagree 并写明差异。" +
      "若发现指令互相矛盾或判据无法执行，escalate 说明，不要硬编一个结论。",
  }).ask<Confirm>(
    `独立重算 keep-within 判定（今天是 ${today}）：borg list 三仓归档数与最老日期；对 borg-config 跑两次 prune dry-run（旧口径 vs 加 --keep-within=7d 的新口径），数 Would-prune；数时间轴 7 天内快照并和归档对齐。\n\n待核结论：${gateA.conclusion}\n取证员数字：archives=${gateA.archives}；old=${gateA.oldPolicy}；new=${gateA.newPolicy}；alignment=${gateA.alignment}`,
  );
  report({ gate: "keep-within 复核", verdict: confirmA.verdict, detail: confirmA.detail });
  log(`keep-within 复核：${confirmA.verdict}`);
}

phase("观察期 streak 取证与判定");
const gateBRipe = today >= "2026-10-10";
const gateB = await agent("观察期取证员", {
  system:
    "你是 backguard 观察期 streak 取证员。只读：~/.local/share/partiverse-backup/ 下的 backup.log、" +
    "launchd.out.log 与 ~/PartiverseBackup/timeline/CLOUD-VERIFY.txt。不写任何文件。grep 时记住 " +
    "BSD grep 不认 BRE 的 \\|，交替一律 -E。绝不输出任何口令或 secrets 内容。",
}).ask<GateBVerdict>(
  `今天是 ${today}。${gateBRipe ? "判定日已到（≥2026-10-10），请给出观察期满的正式判定。" : "判定日未到（<2026-10-10），state=suspended，只取证挂起。"}` +
    " 取证步骤：①backup.log 里 grep -a「run 边界」取 2026-10-03（部署点追平日）以来的全部行，" +
    "数总数、rc=0 数，列出任何 rc≠0 的日期；②grep -a「语义层异常」launchd.out.log 数语义层中断次数；" +
    "③timeline/CLOUD-VERIFY.txt 的汇总行（checks/FAIL/HEALED）。判定标准：观察期 = 追平日 +7 天内 " +
    "nightly 全 rc=0、语义层 0 中断、自证 FAIL=0。全部引用数字。",
);
report({ gate: "观察期", state: gateB.state, conclusion: gateB.conclusion, streak: gateB.streak });
if (gateBRipe) {
  phase("观察期结论独立复核");
  const confirmB = await agent("观察期复核员", {
    system:
      "你是独立复核员：只按自己的重算说话，同样只读、绝不输出 secrets 内容。" +
      "不一致就 disagree 写差异；判据无法执行就 escalate。",
  }).ask<Confirm>(
    `独立重算观察期判定（今天是 ${today}）：10-03 以来 run 边界行总数与 rc=0 数、语义层异常计数、CLOUD-VERIFY 汇总行。\n\n待核结论：${gateB.conclusion}\n取证员数字：streak=${gateB.streak}；clean=${gateB.clean}`,
  );
  report({ gate: "观察期 复核", verdict: confirmB.verdict, detail: confirmB.detail });
  log(`观察期复核：${confirmB.verdict}`);
}

phase("T1.3 备料");
const bClosed = gateB.state === "ripe" && gateB.conclusion.indexOf("通过") >= 0;
const readiness = await agent("T1.3 备料员", {
  system:
    "你是 backguard 的 T1.3 聚类调优备料员。只读：本地 research/ 目录（仓库上一级" +
    " /Users/nebulaboratories/leisure/Codebase-Driven-by-AI/backguard/research/）、v0/semantic/bg_semantic.py 的" +
    "聚类函数、项目记忆索引。不写任何文件。已知问题：混合簇退级、载体根噪音；" +
    "已知基准：0303-night 快照与真机 run JSON（$LOG_DIR/runs/run-*.json，内含全量文件名，绝不把文件名写进输出）。",
}).ask<Readiness>(
  bClosed
    ? `观察期已收口（${gateB.conclusion}），数据窗口已满。给 T1.3 的可执行第一刀计划：ready=yes，` +
        "写明改哪个函数、回归测试怎么建（真机 run JSON 当夹具）、变异怎么落、哪些套件必须绿。"
    : `观察期未收口（${gateB.conclusion}），按纪律 T1.3 还不准动代码。ready=no，只给备料摘要：` +
        "数据窗口现状、两个已知问题的素材位置、基准在哪、B 收口后第一刀建议砍哪里。",
);
report({ gate: "T1.3 备料", ready: readiness.ready, brief: readiness.brief });

phase("写台账与收口报告");
const ledgerAgent = agent("台账记录员", {
  system:
    "你是 backguard 的台账记录员。往 docs/HANDOVER-2026-09-30.md 追加一节「续 N」续记" +
    "（N 接续文件里最后一个续记编号），并在项目记忆目录" +
    " /Users/nebulaboratories/.zcode/cli/memories/projects/backguard-0d41b5fea98c1d3c/memory/ 更新" +
    " project-session-handoff-20261003.md 与 MEMORY.md 索引行。行文规范看 HANDOVER 现有续记。" +
    "写完后只本地 commit docs 与记忆（git -C v0 add docs/... && git -C v0 commit），**绝不 push**。" +
    "明文台账里零文件名（run JSON 路径只写目录级），口令与 secrets 内容一个字都不出现。",
});
const ledger = await ledgerAgent.ask<Ledger>(
  `把今天的观察期收口工作写成台账。今天是 ${today}；verify-nightly 判读：${acceptance.nightly}；` +
    `STATUS 末行：${acceptance.statusLine}；门禁：${acceptance.gate}；异常：${JSON.stringify(acceptance.anomalies)}。\n` +
    `keep-within（${gateA.state}）：${gateA.conclusion}\n观察期（${gateB.state}）：${gateB.conclusion}\n` +
    `T1.3 备料（ready=${readiness.ready}）：${readiness.brief}\n\n` +
    "M4 前剩余事项清单（写进续记末尾）：dogfood 硬件（Windows/Linux 各一台）、A3 心跳 URL（等用户提供）、" +
    "webui 多设备聚合拍板、外部验证材料（10-15 人招募 + 问卷）。证据引用你从上面材料里读到的数字，" +
    "不要发明新数字。committed 写本地 commit 的短 SHA。",
);
report({ gate: "台账", entry: ledger.handoverEntry, committed: ledger.committed });
log(`台账已写：${ledger.handoverEntry}（本地 commit ${ledger.committed}，未 push）`);

const draftReport = [
  `# 观察期收口 · ${today}`,
  "",
  `## 昨夜验收`,
  `- verify-nightly：${acceptance.nightly}`,
  `- STATUS.jsonl 末行：${acceptance.statusLine}`,
  `- CI 门禁：${acceptance.gate}`,
  acceptance.anomalies.length > 0 ? `- 异常：${acceptance.anomalies.join("；")}` : "- 异常：无",
  "",
  `## keep-within（判定日 ≥2026-10-07）`,
  `- 状态：${gateA.state === "ripe" ? "已判定" : "挂起（未到期）"}`,
  `- 归档：${gateA.archives}`,
  `- 旧口径 Would-prune：${gateA.oldPolicy}；新口径：${gateA.newPolicy}`,
  `- 对齐：${gateA.alignment}`,
  `- 结论：${gateA.conclusion}`,
  "",
  `## 观察期（判定日 ≥2026-10-10，起点=10-03 部署点追平）`,
  `- 状态：${gateB.state === "ripe" ? "已判定" : "挂起（未到期）"}`,
  `- streak：${gateB.streak}`,
  `- 干净面：${gateB.clean}`,
  `- 结论：${gateB.conclusion}`,
  "",
  `## T1.3 备料（ready=${readiness.ready}）`,
  readiness.brief,
  "",
  `## 台账`,
  `- HANDOVER：${ledger.handoverEntry}（本地 commit ${ledger.committed}，未 push）`,
  `- 项目记忆：${ledger.memoryUpdated}`,
  "",
  `## M4 前剩余事项`,
  ...ledger.m4Items.map((i) => `- ${i}`),
].join("\n");

const reader = await agent("独立读者", {
  system:
    "你是独立读者：只读给你的文本，以普通读者视角挑毛病——哪里含糊、哪里文本自己撑不住、" +
    "哪里读者会追问。不要去仓库里核对事实（那是复核员的活），只判断文字本身撑不撑得起它说的话。",
}).ask<ReaderFindings>(
  "下面是 backguard 观察期收口的台账与报告草稿。挑出：事实性错误（前后矛盾、数字对不上）、" +
    "含糊到读者无法行动的句子、以及读者接下来必然会问但文本没答的问题。没有就返回空数组。\n\n" +
    `HANDOVER 续记标题：${ledger.handoverEntry}\n\n${draftReport}`,
);
if (reader.issues.length > 0) {
  log(`独立读者提出 ${reader.issues.length} 条问题，交台账记录员修正。`);
  const fixList = reader.issues.map((i, n) => `${n + 1}. ${i}`).join("\n");
  await ledgerAgent.ask<string>(
    `独立读者对你的台账与报告草稿提出以下问题，逐条修正（改 docs 与记忆，仍然不 push）：\n${fixList}`,
  );
} else {
  log("独立读者未发现问题。");
}

await artifact.markdown(
  "report",
  draftReport + (reader.issues.length > 0 ? `\n\n## 独立读者备注\n\n${reader.issues.map((i) => `- ${i}`).join("\n")}（已交台账记录员修正）` : ""),
  { title: `观察期收口状态 · ${today}`, description: "昨夜验收、keep-within 与观察期判定状态、T1.3 备料与 M4 剩余清单", primary: true },
);

return {
  conclusion:
    `${today}：昨夜验收 ${acceptance.nightly}；keep-within ${gateA.state === "ripe" ? "已判定" : "挂起（判定日 ≥10-07）"}，` +
    `观察期 ${gateB.state === "ripe" ? "已判定" : "挂起（判定日 ≥10-10）"}；T1.3 备料 ready=${readiness.ready}。` +
    `台账 ${ledger.handoverEntry} 已本地提交（${ledger.committed}，未 push）。` +
    (reader.issues.length > 0 ? `独立读者提出 ${reader.issues.length} 条问题，已交台账记录员修正。` : "独立读者未发现问题。"),
  findings: [
    {
      where: "~/PartiverseBackup/timeline/STATUS.jsonl",
      what: `昨夜 STATUS 末行判读：${acceptance.statusLine}`,
      evidence: statusTail.stdout.trim(),
      status: "verified",
      severity: "low",
    },
    {
      where: "gate A（keep-within）",
      what: gateA.conclusion,
      evidence: gateA.evidence.join(" | "),
      status: "verified",
      severity: "low",
    },
    {
      where: "gate B（观察期）",
      what: gateB.conclusion,
      evidence: gateB.evidence.join(" | "),
      status: "verified",
      severity: "low",
    },
  ],
  verified: [
    "world.run 实跑 v0/verify-nightly.sh（含云端自证只读核验）",
    "world.run 读取 STATUS.jsonl 末行、gh run list、部署树 HEAD 与 origin/main",
    "keep-within 取证员对生产仓只读取证（borg list + prune -n 双口径 dry-run）" + (gateARipe ? "，并经独立复核员重算" : "（判定挂起，未到判定日）"),
    "观察期取证员清点 run 边界行与自证汇总" + (gateBRipe ? "，并经独立复核员重算" : "（判定挂起，未到判定日）"),
    "台账由台账记录员写入 HANDOVER 与项目记忆并本地 commit，经独立读者冷读",
  ],
  notCovered: [
    gateA.state === "suspended" ? "keep-within 正式判定：判定日 ≥2026-10-07，届时重跑本 workflow 的该阶段" : "",
    gateB.state === "suspended" ? "观察期正式判定：判定日 ≥2026-10-10，届时重跑本 workflow" : "",
    "T1.3 代码改动：观察期收口前按纪律不动代码",
    "部署树 ff 与 push：workflow 只读生产面，台账仅本地 commit，push 与追平由主会话按门禁执行",
  ].filter((s) => s.length > 0),
};
