#!/bin/sh
# Infisical を戻す道具。手順は recovery/README.md の 6・7。2026-10-17 の建て直しで使ったもの。
#
#   tools/t.ps1 --admin sh recovery/infisical.sh db <snapshot>   pg_dump で DB を置き換えて Infisical を起こす
#   tools/t.ps1 --admin sh recovery/infisical.sh drop-old        db で退けた old_public を消す(起きたのを見てから)
#   tools/t.ps1 --admin sh recovery/infisical.sh ca [apply]      Kubernetes auth の CA を見る / 新しいクラスタのものにする
#
# **k8up では戻せない。** k8up の資格情報(k8up-global)が Infisical から来るので、Infisical だけは
# 手元の restic で戻す(~/.config/restic.env。README の 6)。
set -eu
K=kubectl
# Infisical の chart の Postgres(bitnami)。資格情報は Pod の env にある
PSQL='export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE"'
pg() { $K -n infisical exec postgresql-0 -- sh -c "$PSQL $*"; }

case ${1:-} in
	db)
		snap=${2:?snapshot}
		set -a; . "$HOME/.config/restic.env"; set +a
		$K -n infisical scale deploy/infisical --replicas=0
		$K -n infisical wait --for=delete pod -l app.kubernetes.io/name=infisical-standalone --timeout=120s 2>/dev/null || sleep 20
		# **`DROP SCHEMA public CASCADE` は通らない。** テーブルがパーティション込みで約 750 あり、
		# max_locks_per_transaction=64 の 1 トランザクションに収まらず `out of shared memory` で落ちる。
		# 名前を変えて退け、空の public にダンプを流す(退けたものは drop-old で少しずつ消す)。
		pg "-v ON_ERROR_STOP=1 -c 'ALTER SCHEMA public RENAME TO old_public' -c 'CREATE SCHEMA public'"
		# テキストの SQL なので標準入力で流してよい(バイナリは欠ける。pv.sh の冒頭)
		restic dump "$snap" /infisical-postgresql.sql > "$HOME/infisical.sql"
		wc -c "$HOME/infisical.sql"
		$K -n infisical exec -i postgresql-0 -- sh -c "$PSQL -q" < "$HOME/infisical.sql" > "$HOME/infisical-load.log" 2>&1 || true
		rm -f "$HOME/infisical.sql"
		echo "errors: $(grep -c ERROR "$HOME/infisical-load.log" || true)"
		grep ERROR "$HOME/infisical-load.log" | sort | uniq -c | sort -rn | head -10 || true
		pg "-Atc 'select count(*) from public.users' -c 'select count(*) from public.projects'"
		$K -n infisical scale deploy/infisical --replicas=1
		$K -n infisical rollout status deploy/infisical --timeout=300s ;;
	drop-old)
		# CASCADE 一発ではロックが足りないので、外部キー → 末端のパーティション → 残り、の順に分けて消す
		pg "-Atc \"select format('ALTER TABLE %s DROP CONSTRAINT %I;', c.conrelid::regclass, c.conname) from pg_constraint c join pg_namespace n on n.oid = c.connamespace where n.nspname = 'old_public' and c.contype = 'f'\" > /tmp/fk.sql; $PSQL -q -f /tmp/fk.sql 2>&1 | grep -c ERROR || true"
		pg "-Atc \"select format('DROP TABLE IF EXISTS old_public.%I;', c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'old_public' and c.relkind = 'r' and c.relispartition\" > /tmp/p.sql; $PSQL -q -f /tmp/p.sql 2>&1 | grep -c ERROR || true"
		pg "-Atc \"select format('DROP TABLE IF EXISTS old_public.%I CASCADE;', c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'old_public' and c.relkind in ('r','p')\" > /tmp/t.sql; $PSQL -q -f /tmp/t.sql 2>&1 | grep -c ERROR || true"
		pg "-v ON_ERROR_STOP=1 -c 'DROP SCHEMA old_public CASCADE'"
		pg "-Atc \"select count(*) from pg_namespace where nspname = 'old_public'\"" ;;
	ca)
		# operator の Machine Identity は Kubernetes auth で、Infisical が TokenReview を呼ぶときに
		# **古いクラスタの CA を持ったまま**になる(DB を戻すと設定も戻るため)。InfisicalSecret が
		# `SSL certificate verification failed … self-signed certificate` で全部止まる。
		# 管理者のトークン(`infisical login` 済みであること)で CA だけ差し替える。
		CA=$($K config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
		[ -n "$CA" ] || { echo "kubeconfig から CA を読めなかった" >&2; exit 1; }
		TOKEN=$(infisical user get token --plain 2>/dev/null || true)
		[ -n "$TOKEN" ] || { echo "infisical のトークンが無い。tools/t.ps1 infisical login --domain https://il.doany.io/api" >&2; exit 1; }
		$K -n infisical port-forward svc/infisical 18080:8080 > /tmp/pf.log 2>&1 &
		PF=$!
		trap 'kill $PF 2>/dev/null || true' EXIT
		sleep 3
		CA="$CA" TOKEN="$TOKEN" bun "$(dirname "$0")/infisical-ca.mjs" "${2:-}"
		if [ "${2:-}" = apply ]; then
			# operator は失敗が続くと間を空けるので、蹴り直さないとしばらく戻らない
			$K -n infisical-operator rollout restart deploy/infisical-secre-controller-manager
			$K -n infisical-operator rollout status deploy/infisical-secre-controller-manager --timeout=120s
		fi ;;
	*) echo "usage: infisical.sh db <snapshot> | drop-old | ca [apply]" >&2; exit 1 ;;
esac
