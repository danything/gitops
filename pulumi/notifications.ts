// Cloudflare の通知を Matrix の notify-server に流す(hookshot の汎用の受け口 `cloudflare`。apps/matrix/hookshot.yaml)。
//
// 受け口の URL は ID を含むので git に置かない。CI は secrets の CLOUDFLARE_NOTIFY_WEBHOOK_URL から渡す
// (値は Infisical /matrix/matrix の hook-cloudflare から作った https://m.doany.io/webhook/<ID>)。
// Cloudflare の通知の本文は `text` に来るので、hookshot の slack のスクリプトがそのまま読む。

import * as cloudflare from "@pulumi/cloudflare";
import * as pulumi from "@pulumi/pulumi";

const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
if (!accountId) throw new Error("CLOUDFLARE_ACCOUNT_ID が要る");
const url = process.env.CLOUDFLARE_NOTIFY_WEBHOOK_URL;
if (!url) throw new Error("CLOUDFLARE_NOTIFY_WEBHOOK_URL が要る");

const matrix = new cloudflare.NotificationPolicyWebhooks("matrix-notify-server", {
  accountId,
  name: "Matrix notify-server (hookshot)",
  url: pulumi.secret(url),
});

// 自宅のサーバーに関係するものだけ。種類の一覧は `tools/t cf alerting available-alerts list`
const alerts: [type: string, name: string][] = [
  ["universal_ssl_event_type", "証明書(Universal SSL)の発行・更新の問題"],
  ["dos_attack_l7", "HTTP の DDoS を止めた"],
  ["real_origin_monitoring", "Cloudflare からオリジン(自宅)に届かない"],
  ["abuse_report_alert", "不正利用の報告が来た"],
  ["security_insights_alert", "Security Insights の指摘"],
];

for (const [alertType, description] of alerts) {
  new cloudflare.NotificationPolicy(alertType, {
    accountId,
    name: `Matrix: ${alertType}`,
    description,
    alertType,
    enabled: true,
    mechanisms: { webhooks: [{ id: matrix.id }] },
  });
}
