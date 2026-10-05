// Pulumi では表せない 2 つを見る。毎週の preview と一緒に CI が流す。**読むだけ。**
//
//   - カスタムドメインが付いていないこと(R2CustomDomain は「付いているもの」しか持てず、
//     「付いていない」を宣言できない)
//   - 容量(アカウント全体。ズレではないので落とさず、Summary に記録するだけ)
//
//   cd pulumi && bun install && CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… bun report.ts

import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const BUCKETS = ["doany-restic"];

// cf は自分と同じランタイム(bun)で起動する。cf の bin は `#!/usr/bin/env node` なので、
// そのまま起動すると node を探しに行く。bun の上で cf が動くことは 2026-10-05 に確認済み。
const CF = new URL("./node_modules/.bin/cf", import.meta.url).pathname;
const GHA = !!process.env.GITHUB_ACTIONS;

type Obj = Record<string, unknown>;

interface StorageMetrics {
  published?: { payloadSize?: number; metadataSize?: number };
}

// `cf` は API の応答の封筒(`{success, result}`)を外して出す(beta.12)。どちらでも読めるようにする
function cf(...args: string[]): Obj {
  let out: string;
  try {
    out = execFileSync(process.execPath, [CF, ...args], {
      encoding: "utf8",
      env: { ...process.env, DO_NOT_TRACK: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e) {
    const x = e as { stderr?: string; stdout?: string; message: string };
    throw new Error(`cf ${args.join(" ")} が失敗した:\n${x.stderr || x.stdout || x.message}`);
  }
  let v: unknown = JSON.parse(out);
  if (v && typeof v === "object" && "result" in v) v = (v as { result: unknown }).result;
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : { _raw: v };
}

let failed = false;
for (const name of BUCKETS) {
  const res = cf("r2", "buckets", "domains", "custom", "list", "--bucket-name", name);
  // 形が変わっていたら「無い」と読まずに落とす(素通りさせない)
  if (!Array.isArray(res.domains)) {
    console.log(`${GHA ? "::error::" : ""}${name}: 応答に domains が無い(cf の版で形が変わった?): ${JSON.stringify(res).slice(0, 300)}`);
    failed = true;
    continue;
  }
  const domains = res.domains as { domain: string }[];
  if (domains.length) {
    console.log(`${GHA ? "::error::" : ""}${name}: カスタムドメインが付いている (${domains.map((d) => d.domain).join(", ")})`);
    failed = true;
  }
}

let size = "取れなかった";
try {
  const m = cf("r2", "buckets", "metrics", "list") as { standard?: StorageMetrics; infrequentAccess?: StorageMetrics };
  const gib = (c?: StorageMetrics): number =>
    ((c?.published?.payloadSize ?? 0) + (c?.published?.metadataSize ?? 0)) / 2 ** 30;
  size = `Standard ${gib(m.standard).toFixed(2)} GiB / IA ${gib(m.infrequentAccess).toFixed(2)} GiB`;
} catch (e) {
  const msg = (e as Error).message;
  console.log(GHA ? `::warning::${msg.split("\n")[0]}` : msg);
}
console.log(`容量(アカウント全体): ${size}`);
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\nR2 の容量(アカウント全体、課金と同じ物差し): **${size}**\n`);
}

process.exit(failed ? 1 : 0);
