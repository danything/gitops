// R2 のバケット設定が「あるべき姿」のままかを見る。**読むだけ。** 直すのは人が手で `cf` を打つ。
//
//   cd r2 && npm ci && CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… node drift.mjs
//
// CI(../.github/workflows/r2-drift.yml)も同じものを流す。一致 0 / ズレ 1。
// 当てるところまで自動化しない理由は README.md(**R2 を書ける鍵はバックアップを消せる鍵**)。
//
// 見ているのは「壊れると restic のリポジトリが黙って壊れる / 外に漏れる」設定だけ。
// 見た目の設定(CORS・イベント通知)は持っていないし、持つ予定も無いので見ない。

import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

// ---- あるべき姿 ---------------------------------------------------------------
// ここが正本。変えるときは先に Cloudflare 側を `cf` で直し、同じ PR でここを直す。
const BUCKETS = {
  "doany-restic": {
    // decisions.md「リモートは Cloudflare R2 のバケット doany-restic(APAC、Standard)」
    location: "apac",
    storageClass: "Standard",
    // 失敗したマルチパートの残骸を掃除する R2 の既定ルール。無いと残骸が容量に積もる
    requireAbortMultipart: true,
    // **消す・移すルールは 1 本も置かない。** restic の pack が消えるとリポジトリが壊れ、
    // `restic check` までは誰も気づかない。保持は restic の forget/prune だけで決める。
    // Infrequent Access への移行も同じ扱い ── 最低保存期間の課金と、check/prune の読み出し課金が乗る
    // **ロックも置かない。** `prune` が消せなくなり、k8up の Prune が毎週失敗する
    // **公開しない。** r2.dev もカスタムドメインも無し(restic の中身は暗号化されているが、置き場の一覧は見える)
  },
};

// ---- ここから下は道具 -----------------------------------------------------------
const CF = new URL("./node_modules/.bin/cf", import.meta.url).pathname;
const GHA = !!process.env.GITHUB_ACTIONS;
const errors = [];
const summary = [];

const err = (msg) => {
  errors.push(msg);
  console.log(GHA ? `::error::${msg}` : `ズレ: ${msg}`);
};

// `cf` は API の応答を JSON で出す(既定)。封筒(`{success, result}`)ごと出す版と
// `result` だけ出す版のどちらでも読めるようにしておく(beta なので形が動きうる)。
function cf(...args) {
  let out;
  try {
    out = execFileSync(CF, args, {
      encoding: "utf8",
      env: { ...process.env, DO_NOT_TRACK: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e) {
    throw new Error(`cf ${args.join(" ")} が失敗した:\n${e.stderr || e.stdout || e.message}`);
  }
  let v;
  try {
    v = JSON.parse(out);
  } catch {
    throw new Error(`cf ${args.join(" ")} の出力が JSON ではない(cf の版で形が変わった?):\n${out.slice(0, 500)}`);
  }
  return v && typeof v === "object" && "result" in v ? v.result : v;
}

for (const [name, want] of Object.entries(BUCKETS)) {
  console.log(`== ${name}`);

  const b = cf("r2", "buckets", "get", name);
  const loc = String(b.location ?? "").toLowerCase();
  if (loc !== want.location) err(`${name}: location が ${b.location} (想定 ${want.location})`);
  if (b.storage_class !== want.storageClass)
    err(`${name}: storage_class が ${b.storage_class} (想定 ${want.storageClass})`);

  const rules = cf("r2", "buckets", "lifecycle", "get", name).rules ?? [];
  for (const r of rules.filter((r) => r.enabled !== false)) {
    if (r.deleteObjectsTransition)
      err(`${name}: オブジェクトを消す lifecycle ルールがある (${r.id})。restic の pack が消える`);
    if (r.storageClassTransitions?.length)
      err(`${name}: ストレージクラスを移す lifecycle ルールがある (${r.id})`);
  }
  const abort = rules.some((r) => r.enabled !== false && r.abortMultipartUploadsTransition);
  if (want.requireAbortMultipart && !abort)
    err(`${name}: マルチパートの残骸を消すルールが無い`);

  const locks = (cf("r2", "buckets", "locks", "get", name).rules ?? []).filter((r) => r.enabled !== false);
  if (locks.length) err(`${name}: バケットロックがある (${locks.map((r) => r.id).join(", ")})。prune が消せなくなる`);

  const managed = cf("r2", "buckets", "domains", "managed", "list", "--bucket-name", name);
  if (managed.enabled) err(`${name}: r2.dev で公開されている (${managed.domain})`);
  const custom = cf("r2", "buckets", "domains", "custom", "list", "--bucket-name", name).domains ?? [];
  if (custom.length) err(`${name}: カスタムドメインが付いている (${custom.map((d) => d.domain).join(", ")})`);

  summary.push(
    `| ${name} | ${b.location} / ${b.storage_class} | ${rules.length} 本 (${rules.map((r) => r.id).join(", ") || "なし"}) | ${locks.length} | ${managed.enabled ? "**公開**" : "非公開"} |`,
  );
}

// 容量はアカウント単位でしか取れない。ズレではないので落とさず、記録として出すだけ
// (ROADMAP Phase 3「移行して 1〜2 か月してから R2 の容量をもう一度見る」の材料)。
let size = "取れなかった";
try {
  const m = cf("r2", "buckets", "metrics", "list");
  const gib = (c) => ((c?.published?.payloadSize ?? 0) + (c?.published?.metadataSize ?? 0)) / 2 ** 30;
  size = `Standard ${gib(m.standard).toFixed(2)} GiB / IA ${gib(m.infrequentAccess).toFixed(2)} GiB`;
} catch (e) {
  console.log(GHA ? `::warning::${e.message.split("\n")[0]}` : e.message);
}
console.log(`容量(アカウント全体): ${size}`);

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    [
      "| バケット | 場所 / クラス | lifecycle | ロック | 公開 |",
      "| --- | --- | --- | --- | --- |",
      ...summary,
      "",
      `容量(アカウント全体、R2 の課金と同じ物差し): **${size}**`,
      "",
    ].join("\n"),
  );
}

if (errors.length) {
  console.log(`${errors.length} 件のズレ。直し方は r2/README.md`);
  process.exit(1);
}
console.log("一致");
