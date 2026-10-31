// restic の置き場(R2 の doany-restic)の設定の正本。直接いじると週次の preview(--refresh)が落ちる。
// Pulumi で表せない残り(カスタムドメイン・容量)は report.ts。

import * as cloudflare from "@pulumi/cloudflare";

import "./entra.ts";
import "./entra-ci.ts";
export * from "./entra-smtp.ts";
import "./notifications.ts";
import "./dns.ts";
import "./netbird.ts";

const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
if (!accountId) throw new Error("CLOUDFLARE_ACCOUNT_ID が要る");

const name = "doany-restic";

// protect を外さないこと(コードの間違い 1 つでバックアップが丸ごと消える)
const bucket = new cloudflare.R2Bucket(
  name,
  {
    accountId,
    name,
    location: "apac",
    storageClass: "Standard",
  },
  { protect: true, import: `${accountId}/${name}/default` },
);

// 消す・移すルールは置かない(pack が消えるとリポジトリが黙って壊れる。IA は課金が乗る)。
// 残すのは失敗したマルチパートの掃除だけ。
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

// **ロックも置かない。** `prune` が消せなくなり、restic の prune(VolSync・etcd のスナップショット)が失敗する
new cloudflare.R2BucketLock(name, { accountId, bucketName: bucket.name, rules: [] });

// **公開しない。** restic の中身は暗号化されているが、置き場の一覧は見える
new cloudflare.R2ManagedDomain(name, { accountId, bucketName: bucket.name, enabled: false });
