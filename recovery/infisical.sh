#!/bin/sh
# Infisical を戻す道具。手順は recovery/README.md の 6・7。2026-10-17 の建て直しで使ったもの。
#
#   tools/t.ps1 --admin sh recovery/infisical.sh db              DB の PVC を VolSync のスナップショットから戻して Infisical を起こす
#   tools/t.ps1 --admin sh recovery/infisical.sh ca [apply]      Kubernetes auth の CA を見る / 新しいクラスタのものにする
#
# **Infisical だけは populator で戻せない。** VolSync の Secret が Infisical から来るので、Secret を
# 手元の ~/.config/restic.env(README の 6)から作って戻す。
set -eu
K=kubectl
# Infisical の chart の Postgres(bitnami)。資格情報は Pod の env にある
PSQL='export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE"'
pg() { $K -n infisical exec postgresql-0 -- sh -c "$PSQL $*"; }

case ${1:-} in
	db)
		# **PVC(data-postgresql-0)を丸ごと戻す**(VolSync のスナップショット)。ほかの PVC は populator で作るときに埋まるが、
		# ここは bootstrap の chart の StatefulSet が作る PVC で dataSourceRef を書けないので、ReplicationDestination(Direct)で上から書く。
		# Secret は、ほかの namespace と違って InfisicalSecret から作れない(戻すのが Infisical そのもの)ので、
		# 手元の restic.env から作る。あとで deploy/infisical/volsync.yaml の InfisicalSecret が同じ名前で上書きする(中身は同じ)
		set -a; . "$HOME/.config/restic.env"; set +a
		repo=${RESTIC_REPOSITORY%/}/volsync/infisical/data-postgresql-0
		$K -n infisical create secret generic volsync-data-postgresql-0 \
			--from-literal=RESTIC_REPOSITORY="$repo" --from-literal=RESTIC_PASSWORD="$RESTIC_PASSWORD" \
			--from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
			--from-literal=AWS_DEFAULT_REGION=auto --dry-run=client -o yaml | $K apply -f - >/dev/null
		# 書いている最中に Postgres が起きないよう止める(ほかは Postgres を待つだけなので止めなくてよい)
		$K -n infisical scale sts/postgresql --replicas=0 >/dev/null
		$K -n infisical wait --for=delete pod/postgresql-0 --timeout=120s >/dev/null 2>&1 || true
		# **このクラスタができる前の最新**を戻す。ReplicationSource は Argo CD が作るとすぐ時刻を待ちはじめ、戻す前の空の PVC を
		# 取ったものが「いちばん新しい」になりうる。境目は kube-system の namespace ができた時刻(RESTORE_BEFORE で上書きできる)
		before=${RESTORE_BEFORE:-$($K get ns kube-system -o jsonpath='{.metadata.creationTimestamp}')}
		t=restore-$(date -u +%Y%m%d%H%M%S)
		$K -n infisical delete replicationdestination restore-db --ignore-not-found >/dev/null
		$K create -f - >/dev/null <<R
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata: {name: restore-db, namespace: infisical}
spec:
  trigger: {manual: $t}
  restic:
    repository: volsync-data-postgresql-0
    destinationPVC: data-postgresql-0
    copyMethod: Direct
    restoreAsOf: "$before"
    enableFileDeletion: true
    moverSecurityContext: {runAsUser: 0, runAsGroup: 0}
R
		for _ in $(seq 1 180); do
			[ "$($K -n infisical get replicationdestination restore-db -o jsonpath='{.status.lastManualSync}')" = "$t" ] && break
			sleep 10
		done
		res=$($K -n infisical get replicationdestination restore-db -o jsonpath='{.status.latestMoverStatus.result}')
		$K -n infisical get replicationdestination restore-db -o jsonpath='{.status.latestMoverStatus.logs}' | tail -5
		[ "$res" = Successful ] || { echo "戻せなかった(kubectl -n infisical describe replicationdestination restore-db)" >&2; exit 1; }
		$K -n infisical delete replicationdestination restore-db --wait=false >/dev/null
		$K -n infisical scale sts/postgresql --replicas=1 >/dev/null
		$K -n infisical rollout status sts/postgresql --timeout=300s
		users=$(pg "-Atc 'select count(*) from public.users'" 2>/dev/null || echo 0)
		echo "users: $users / projects: $(pg "-Atc 'select count(*) from public.projects'" 2>/dev/null || echo 0)"
		[ "${users:-0}" -gt 0 ] || { echo "users が 0。戻したスナップショットを見直す(RESTORE_BEFORE)" >&2; exit 1; }
		$K -n infisical rollout restart deploy/infisical >/dev/null
		$K -n infisical rollout status deploy/infisical --timeout=300s ;;
	ca)
		# operator の Machine Identity は Kubernetes auth で、Infisical が TokenReview を呼ぶときに
		# **古いクラスタの CA を持ったまま**になる(DB を戻すと設定も戻るため)。InfisicalSecret が
		# `SSL certificate verification failed … self-signed certificate` で全部止まる。
		# 管理者のトークン(`infisical login` 済みであること)で CA だけ差し替える。
		CA=$($K config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
		[ -n "$CA" ] || { echo "kubeconfig から CA を読めなかった" >&2; exit 1; }
		TOKEN=$(infisical user get token --plain 2>/dev/null || true)
		[ -n "$TOKEN" ] || { echo "infisical のトークンが無い。tools/t.ps1 infisical login --domain https://il.doany.io/api" >&2; exit 1; }
		# 18080 はこのコンテナの中だけのポート(t.ps1 は実行ごとに新しいコンテナ)なので、ほかとは取り合わない
		$K -n infisical port-forward svc/infisical 18080:8080 > /tmp/pf.log 2>&1 &
		PF=$!
		trap 'kill $PF 2>/dev/null || true' EXIT
		for _ in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:18080/api/status 2>/dev/null && break; sleep 1; done
		curl -fsS -o /dev/null http://127.0.0.1:18080/api/status || { cat /tmp/pf.log >&2; echo "port-forward が繋がらない" >&2; exit 1; }
		CA="$CA" TOKEN="$TOKEN" bun "$(dirname "$0")/infisical-ca.mjs" "${2:-}"
		if [ "${2:-}" = apply ]; then
			# operator は失敗が続くと間を空けるので、蹴り直さないとしばらく戻らない
			$K -n infisical-operator rollout restart deploy/infisical-secre-controller-manager
			$K -n infisical-operator rollout status deploy/infisical-secre-controller-manager --timeout=120s
		fi ;;
	*) echo "usage: infisical.sh db | ca [apply]" >&2; exit 1 ;;
esac
