#!/bin/sh
# Infisical を戻す道具。手順は recovery/README.md の 6・7。2026-10-17 の建て直しで使ったもの。
#
#   tools/t.ps1 --admin sh recovery/infisical.sh db              DB の PVC を VolSync のスナップショットから戻して Infisical を起こす
#   tools/t.ps1 --admin sh recovery/infisical.sh ca [apply]      Kubernetes auth の CA を見る / 新しいクラスタのものにする
#
# **Infisical だけは pv.sh の restore で戻せない。** VolSync の Secret が Infisical から来るので、Secret を
# 手元の ~/.config/restic.env(README の 6)から作って戻す。
set -eu
K=kubectl
# Infisical の chart の Postgres(bitnami)。資格情報は Pod の env にある
PSQL='export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE"'
pg() { $K -n infisical exec postgresql-0 -- sh -c "$PSQL $*"; }

case ${1:-} in
	db)
		# **PVC(data-postgresql-0)を丸ごと戻す**(VolSync のスナップショット。pv.sh の pvc と同じ)。
		# ReplicationDestination の Secret は、ほかの namespace と違って InfisicalSecret から作れない(戻すのが Infisical そのもの)ので、
		# 手元の restic.env から作る。あとで deploy/volsync/infisical.yaml の InfisicalSecret が同じ名前で上書きする(中身は同じ)
		set -a; . "$HOME/.config/restic.env"; set +a
		repo=${RESTIC_REPOSITORY%/}/volsync/infisical/data-postgresql-0
		$K -n infisical create secret generic volsync-data-postgresql-0 \
			--from-literal=RESTIC_REPOSITORY="$repo" --from-literal=RESTIC_PASSWORD="$RESTIC_PASSWORD" \
			--from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
			--from-literal=AWS_DEFAULT_REGION=auto --dry-run=client -o yaml | $K apply -f - >/dev/null
		sh "$(dirname "$0")/pv.sh" infisical stop
		sh "$(dirname "$0")/pv.sh" infisical pvc data-postgresql-0
		sh "$(dirname "$0")/pv.sh" infisical start
		$K -n infisical rollout status sts/postgresql --timeout=300s
		users=$(pg "-Atc 'select count(*) from public.users'" 2>/dev/null || echo 0)
		echo "users: $users / projects: $(pg "-Atc 'select count(*) from public.projects'" 2>/dev/null || echo 0)"
		[ "${users:-0}" -gt 0 ] || { echo "users が 0。戻したスナップショットを見直す(RESTORE_BEFORE)" >&2; exit 1; }
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
