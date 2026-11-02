#!/bin/sh
# 入れ直す前の最後のバックアップ。全部の ReplicationSource を今すぐ 1 回ずつ取り、全部終わるまで待つ(recovery/README.md の手前)。
#
#   tools/t.ps1 --admin sh recovery/backup-all.sh
#
# 時刻(schedule)を手動(manual)に置き換えるので、Argo CD を止めておく(戻すと selfHeal が schedule を戻す)。
# **manual は終わったら自分で消す。** Argo CD は ServerSideApply なので、自分が書いていない manual は消さない。
# 残ると VolSync は schedule を見ず、二度と取らない(2026-11-01 に 22 本が 1 日止まった)
set -eu
K=kubectl
argo() { $K -n argocd scale sts/argocd-application-controller --replicas="$1" >/dev/null; }
t=final-$(date -u +%Y%m%d%H%M)
argo 0
rs=$($K get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
[ -n "$rs" ] || { argo 1; echo "ReplicationSource が 1 つも無い(kubectl get replicationsource -A で見る)" >&2; exit 1; }
unmanual() {
	for r in $rs; do
		$K -n "${r%/*}" patch replicationsource "${r#*/}" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null 2>&1 || true
	done
	argo 1
}
trap unmanual EXIT
for r in $rs; do
	$K -n "${r%/*}" patch replicationsource "${r#*/}" --type merge -p "{\"spec\":{\"trigger\":{\"schedule\":null,\"manual\":\"$t\"}}}" >/dev/null
done
echo "$(echo "$rs" | wc -l) 個を取りはじめた($t)"
# VolSync は並べて流す(2026-11-02 に 22 本で 5 分ほど)。60 分で切る
for _ in $(seq 1 360); do
	left=$($K get replicationsource -A -o jsonpath='{range .items[*]}{.status.lastManualSync}{"\n"}{end}' | grep -cvx "$t" || true)
	[ "$left" -eq 0 ] && break
	sleep 10
done
$K get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.lastManualSync} {.status.latestMoverStatus.result}{"\n"}{end}'
! $K get replicationsource -A -o jsonpath='{range .items[*]}{.status.lastManualSync} {.status.latestMoverStatus.result}{"\n"}{end}' \
	| awk -v t="$t" '$1 != t || $2 != "Successful" {f=1} END {exit !f}' \
	|| { echo "終わっていないか、Successful でないものがある(kubectl get replicationsource -A で見る)" >&2; exit 1; }
