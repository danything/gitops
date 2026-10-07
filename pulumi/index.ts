// restic の置き場(R2 の doany-restic)の設定。**ここが正本。**
//
// 変えるときはこのファイルを直して PR を出す。PR に preview の差分が付き、main に入ると up が当たる。
// Cloudflare の画面や `cf` で直接いじると、次の週次の preview(--refresh)がずれとして落ちる。
//
// 持っているのは「壊れると restic のリポジトリが黙って壊れる / 外に漏れる」設定だけ。
// Pulumi で表せない残り(カスタムドメインが付いていないこと、容量)は report.ts。

import * as cloudflare from "@pulumi/cloudflare";

// Entra のアプリ登録のリダイレクト URI(entra.ts)
import "./entra.ts";
// Cloudflare の通知を Matrix に(notifications.ts)
import "./notifications.ts";
// doany.io の DNS(ExternalDNS が作らないもの)とゾーンの設定(dns.ts)
import "./dns.ts";
// NetBird の DNS・ネットワーク・ルート・ポリシー(netbird.ts)
import "./netbird.ts";

// アカウント ID は git に置かない(endpoint と同じ扱い。apps/k8up/README.md)。CI は secrets から渡す
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
if (!accountId) throw new Error("CLOUDFLARE_ACCOUNT_ID が要る");

const name = "doany-restic";

// バケット本体。**protect を外さないこと** ── 外すとコードの間違い 1 つでバックアップが丸ごと消える。
// 2026-09-06 に手で作ったものを import で取り込んだ(import は取り込み済みなら何もしない)。
const bucket = new cloudflare.R2Bucket(
  name,
  {
    accountId,
    name,
    // decisions.md「リモートは Cloudflare R2 のバケット doany-restic(APAC、Standard)」
    location: "apac",
    storageClass: "Standard",
  },
  { protect: true, import: `${accountId}/${name}/default` },
);

// **消す・移すルールは 1 本も置かない。** restic の pack が消えるとリポジトリが壊れ、
// `restic check` までは誰も気づかない。保持は restic の forget/prune だけで決める。
// Infrequent Access への移行も同じ扱い ── 最低保存期間の課金と、check/prune の読み出し課金が乗る。
// 残すのは R2 の既定ルール(失敗したマルチパートの残骸を 7 日で掃除する)だけ。
new cloudflare.R2BucketLifecycle(name, {
  accountId,
  bucketName: bucket.name,
  rules: [
    {
      id: "Default Multipart Abort Rule",
      enabled: true,
      conditions: { prefix: "" },
      abortMultipartUploadsTransition: { condition: { type: "Age", maxAge: 7 * 24 * 60 * 60 } },
    },
  ],
});

// **ロックも置かない。** `prune` が消せなくなり、k8up の Prune が毎週失敗する
new cloudflare.R2BucketLock(name, { accountId, bucketName: bucket.name, rules: [] });

// **公開しない。** restic の中身は暗号化されているが、置き場の一覧は見える
new cloudflare.R2ManagedDomain(name, { accountId, bucketName: bucket.name, enabled: false });
