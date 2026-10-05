# r2

restic の置き場(Cloudflare R2 の `doany-restic`)の設定を git で持つ。
**あるべき姿は [drift.mjs](drift.mjs) の先頭**にあり、CI([r2-drift](../.github/workflows/r2-drift.yml))が
毎週と `r2/` を触ったときに実物と突き合わせる。**読むだけで、当てはしない。**

道具は Cloudflare の [`cf`](https://blog.cloudflare.com/cloudflare-cf-cli-launch/)(2026-09-28 に open beta)。
版は [package-lock.json](package-lock.json) で固定してあり、Renovate が追う。

## なぜ「見るだけ」か

- **R2 を書ける鍵はバックアップを消せる鍵。** 公開リポジトリの CI に置けば、ワークフローを書き換えられる
  人がバックアップを消せる。CI に `delete` を渡さないのは `bootstrap-apply` と同じ方針
  (cilium-drift が ClusterRoleBinding を書かないのと同じ理由)
- **`cf` には R2 を宣言的に書く口が無い。** `cloudflare.config.ts` が持てるのは Workers だけで、
  R2 はバインディングとして参照できるだけ(cloudflare/cf#61)。バケットの設定は
  `cf r2 buckets lifecycle update` のような命令でしか変えられないので、「git を当てる」形にすると
  差分計算を自前で書くことになる。**変えるのは年に一度あるかどうか**なので割に合わない
- **API トークンは管理対象にしない。** トークンを発行できる権限は、事実上何でもできる権限

## 何を見ているか

**壊れると restic のリポジトリが黙って壊れる、または外に漏れる設定だけ。**

| | あるべき姿 | ずれるとどうなるか |
| --- | --- | --- |
| 場所 / クラス | APAC / Standard | 作り直された(= 中身が別物)ことに気づける |
| lifecycle | **消すルール・移すルールが 0 本**、マルチパートの残骸を消すルールは有る | 消すルールがあると restic の pack が消え、`restic check` まで誰も気づかない。IA への移行は最低保存期間と読み出しの課金が乗る |
| ロック | 0 本 | `prune` が消せず、k8up の Prune が毎週落ちる |
| 公開 | r2.dev もカスタムドメインも無し | 置き場の一覧が外から見える(中身は暗号化されている) |
| 容量 | ─(**記録だけ**。落とさない) | ROADMAP Phase 3「R2 の容量をもう一度見る」の材料。ジョブの Summary に出る |

## 手元で流す

```shell
cd r2 && npm ci
CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… node drift.mjs
```

トークンは CI と同じ読み取り専用のもので足りる。

## ずれていたら

1. **Cloudflare 側が正しい**(わざと変えた)なら、`drift.mjs` の `BUCKETS` を直す PR を出す
2. **git 側が正しい**なら、手元から `cf` で直す。**書ける鍵はその場で作ってその場で捨てる**
   (`cf auth login` のブラウザ認証で済む。保存しない)

```shell
cf r2 buckets lifecycle get doany-restic        # まず今の姿を見る
cf r2 buckets lifecycle update doany-restic …   # 引数は `--help`。--dry-run がある
```

## 最初にやること(2026-10-05 時点で未実施)

- [ ] Cloudflare で Account API token を作る。権限は **Workers R2 Storage: Read だけ**
- [ ] リポジトリの Actions secrets に `R2_READ_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を入れる
- [ ] `r2 drift` を `workflow_dispatch` で 1 回流す。**実物の応答ではまだ一度も流していない** ──
      応答の形(キー名)は Cloudflare API の文書から書いたので、初回に `取れなかった` やキーの
      食い違いが出たら drift.mjs のほうを直す。容量(metrics)だけ別の権限が要るかもしれない
      (そのときは warning で済み、落ちない)
