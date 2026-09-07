# gateway-routes

**ここは畳んでいる途中。** 公開経路(HTTPRoute / GRPCRoute)は**アプリと同じ場所**に置く方針に変えた
(2026-09-07)。ArgoCD は `sourcePath` 配下を recurse で拾い、追跡は
`argocd.argoproj.io/tracking-id` 注釈(GVK + namespace + 名前)で行うので、
**ファイルがどこにあるかは挙動に影響しない**。

| 元の場所 | 移した先 |
| --- | --- |
| adguardhome / erpnext / infisical / mattermost / netbird / portainer | このリポジトリの `apps/<name>/httproute.yaml` |
| blog / yosegaki / lgtm / tamasagashi / worklog / xool / yuzuriha | 各アプリのリポジトリの `deploy/httproute.yaml` |
| argocd / auth ×3 / redirect-https | `bootstrap/`(**次の PR**) |

## ここに残っている 5 本について

`argocd` と `auth` は `bootstrap/` にあり、**そこは ArgoCD が同期していない**。
つまり ArgoCD が「ArgoCD 自身を公開している経路」を握っている状態で、層が逆になっている。
`redirect-https` も Gateway そのものの設定なので `bootstrap/gateway/` が本来の場所。

**ただし `apps/` から消えた瞬間に ArgoCD が prune して公開経路が落ちる。**
そこで先に `argocd.argoproj.io/sync-options: Prune=false` を効かせて
「git から消しても消さない」状態を作ってある。次の PR で `bootstrap/` に移し、
live の tracking-id 注釈を剥がしてから、この注釈も外す。
