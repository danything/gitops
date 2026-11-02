#!/bin/sh
# PV のデータを VolSync の restic のリポジトリ(R2)から手で戻す・取る道具。
# 取り方と戻し方は ../deploy/volsync/application.yaml(PVC ごとのリポジトリ `<bucket>/volsync/<namespace>/<pvc>`)。
#
# **入れ直したクラスタでは使わない。** 各アプリの PVC は dataSourceRef で ReplicationDestination(volsync.yaml の
# `<pvc>-dst`)を指していて、Argo CD が PVC を作ると VolSync(populator)が R2 の最新から中身を埋めてから渡す
# (recovery/README.md の 8)。ここに残すのは、今ある PVC を戻すときと、入れ直す前に取るときの道具。
#
#   tools/t.ps1 --admin sh recovery/pv.sh <namespace> <操作> [引数…]
#
#   list                       R2 にあるリポジトリを `<namespace> <pvc>` で並べる(namespace は `-`)
#   backup-all                 全部の ReplicationSource を今すぐ取って待つ(入れ直す前の最後のバックアップ。namespace は `-`)
#   argo-pause / argo-resume   Argo CD の application-controller を 0 / 1 にする。止めないと selfHeal が
#                              replicas を戻して、戻している最中にアプリが起き上がる
#   stop [残すもの…]           その namespace の Deployment / StatefulSet を 0 にする(元の数は ~/.cache に控える)
#   start                      stop で控えた数に戻す
#   pvc <pvc>                  今ある PVC を ReplicationDestination(copyMethod: Direct)で丸ごと戻す。中身は先に消す
#                              (enableFileDeletion)。アプリは先に stop。`RESTORE_BEFORE`(RFC 3339)より前の最新を戻す
#                              (無ければいちばん新しいもの)
#   shell <pvc> <コマンド>     root のヘルパー Pod で PVC(/pvc)を開いてコマンドを打つ
#
# 今ある PVC を 1 つ戻す手順: argo-pause → <ns> stop → <ns> pvc <pvc> → <ns> start → argo-resume
#
# 前提: tools/t.ps1 --admin で動かす(kubectl の管理者の資格情報。tools/README.md「クラスタの資格情報」)。
# list だけ ~/.config/restic.env が要る(R2 の資格情報。README の 6)。
# ReplicationDestination が使う Secret(`volsync-<pvc>`)は、Argo CD が各アプリの volsync.yaml の InfisicalSecret から作る。
set -eu
NS=${1:?usage: pv.sh <namespace> <操作> [引数…]}
OP=${2:?usage: pv.sh <namespace> <操作> [引数…]}
shift 2
K=kubectl
REP="$HOME/.cache/pv-replicas-$NS"

before() { echo "${RESTORE_BEFORE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

stop() {
	mkdir -p "$(dirname "$REP")"
	# 控えがもうあれば書き直さない。流し直したときに「元は 0」と控えてしまい、start で何も起きなくなる
	# (start が控えを消す)
	keep_rep=
	[ -s "$REP" ] && keep_rep=1 && echo "控え $REP があるので使う(前の stop のぶん)"
	[ -n "$keep_rep" ] || : > "$REP"
	for w in $($K -n "$NS" get deploy,sts -o name); do
		n=${w#*/}
		for keep in "$@"; do [ "$n" = "$keep" ] && continue 2; done
		[ -n "$keep_rep" ] || echo "$w $($K -n "$NS" get "$w" -o jsonpath='{.spec.replicas}')" >> "$REP"
		$K -n "$NS" scale "$w" --replicas=0 >/dev/null
	done
	# 止まるのを待つ(VolSync の mover とヘルパーの Pod、残したものは数えない)
	pat=$(printf '%s|' volsync- '^h-' "$@" | sed 's/|$//')
	for _ in $(seq 1 40); do
		left=$($K -n "$NS" get pod --no-headers 2>/dev/null | grep -v Completed | awk '{print $1}' | grep -vcE "$pat" || true)
		[ "$left" -eq 0 ] && break
		sleep 3
	done
	echo "stopped: $(cut -d' ' -f1 "$REP" | tr '\n' ' ')"
}

start() {
	[ -s "$REP" ] || { echo "控え $REP が無い(stop を先に)" >&2; exit 1; }
	while read -r w r; do $K -n "$NS" scale "$w" --replicas="$r" >/dev/null; done < "$REP"
	echo "started: $(cut -d' ' -f1 "$REP" | tr '\n' ' ')"
	rm -f "$REP"
}

helper() { # $1=pvc
	$K -n "$NS" delete pod "h-$1" --ignore-not-found --wait >/dev/null
	$K create -f - >/dev/null <<P
apiVersion: v1
kind: Pod
metadata: {name: h-$1, namespace: $NS}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0, runAsGroup: 0}
  containers:
    - {name: h, image: busybox:1.38, command: [sleep, "3600"], volumeMounts: [{name: v, mountPath: /pvc}]}
  volumes: [{name: v, persistentVolumeClaim: {claimName: $1}}]
P
	$K -n "$NS" wait --for=condition=Ready "pod/h-$1" --timeout=120s >/dev/null
}
unhelper() { $K -n "$NS" delete pod "h-$1" --wait=false >/dev/null; }

# R2 の `volsync/` の下を 2 段(namespace と PVC)一覧する。1 行に `<namespace> <pvc>`
r2() {
	bun -e '
const m = process.env.RESTIC_REPOSITORY.match(/^s3:(https?:\/\/[^/]+)\/([^/]+)/);
if (!m) throw new Error("RESTIC_REPOSITORY を s3:<endpoint>/<bucket> として読めない");
const s3 = new Bun.S3Client({ endpoint: m[1], bucket: m[2], region: "auto",
	accessKeyId: process.env.AWS_ACCESS_KEY_ID, secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY });
const dirs = async (prefix) => {
	const out = [];
	let token;
	do {
		const r = await s3.list({ prefix, delimiter: "/", continuationToken: token });
		for (const p of r.commonPrefixes ?? []) out.push(p.prefix.slice(prefix.length, -1));
		token = r.isTruncated ? r.nextContinuationToken : undefined;
	} while (token);
	return out;
};
for (const ns of await dirs("volsync/")) for (const pvc of await dirs(`volsync/${ns}/`)) console.log(ns, pvc);'
}

# 1 つの PVC を戻す。Secret は各アプリの volsync.yaml の InfisicalSecret が作った `volsync-<pvc>`。
# mover は root(namespace の privileged-movers の注釈)、境目より前の最新(restoreAsOf)、PVC の中は先に消す(enableFileDeletion)
restore_pvc() { # $1=pvc
	name=restore-$1
	t=restore-$(date -u +%Y%m%d%H%M%S)
	$K -n "$NS" get secret "volsync-$1" >/dev/null 2>&1 \
		|| { echo "ERROR: $NS: Secret volsync-$1 が無い(Argo CD と InfisicalSecret を見る)" >&2; exit 1; }
	$K -n "$NS" delete replicationdestination "$name" --ignore-not-found >/dev/null
	$K create -f - >/dev/null <<R
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata: {name: $name, namespace: $NS}
spec:
  trigger: {manual: $t}
  restic:
    repository: volsync-$1
    destinationPVC: $1
    copyMethod: Direct
    restoreAsOf: "$(before)"
    enableFileDeletion: true
    moverSecurityContext: {runAsUser: 0, runAsGroup: 0}
R
	got=
	for _ in $(seq 1 360); do
		got=$($K -n "$NS" get replicationdestination "$name" -o jsonpath='{.status.lastManualSync}')
		[ "$got" = "$t" ] && break
		sleep 10
	done
	res=$($K -n "$NS" get replicationdestination "$name" -o jsonpath='{.status.latestMoverStatus.result}')
	echo "pvc $1: ${res:-timeout}"
	$K -n "$NS" get replicationdestination "$name" -o jsonpath='{.status.latestMoverStatus.logs}' | tail -5 | sed 's/^/  /'
	[ "$got" = "$t" ] && [ "$res" = Successful ] || { echo "ERROR: $NS: $1 を戻せなかった(kubectl -n $NS describe replicationdestination $name)" >&2; exit 1; }
	$K -n "$NS" delete replicationdestination "$name" --wait=false >/dev/null
}

case $OP in
	argo-pause)
		$K -n argocd scale sts/argocd-application-controller --replicas=0 >/dev/null
		$K -n argocd wait --for=delete pod/argocd-application-controller-0 --timeout=120s >/dev/null 2>&1 || true
		echo "argo paused" ;;
	argo-resume)
		$K -n argocd scale sts/argocd-application-controller --replicas=1 >/dev/null
		echo "argo resumed" ;;
	stop) stop "$@" ;;
	start) start ;;
	list) set -a; . "$HOME/.config/restic.env"; set +a; r2 ;;
	pvc) restore_pvc "${1:?pvc}" ;;
	shell) # $1=pvc $2=コマンド
		helper "$1"
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc; $2"
		unhelper "$1" ;;
	backup-all) # 入れ直す前の最後のバックアップ。全部の ReplicationSource を手動で 1 回ずつ取り、全部終わるまで待つ。
		# 時刻(schedule)を手動(manual)に置き換えるので、Argo CD を止めておく(戻すと selfHeal が schedule を戻す)。
		# **manual は終わったら自分で消す。** Argo CD は ServerSideApply なので、自分が書いていない manual は消さない。
		# 残ると VolSync は schedule を見ず、二度と取らない(2026-11-01 に 22 本が 1 日止まった)
		t=final-$(date -u +%Y%m%d%H%M)
		sh "$0" - argo-pause
		rs=$($K get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
		[ -n "$rs" ] || { sh "$0" - argo-resume; echo "ReplicationSource が 1 つも無い(kubectl get replicationsource -A で見る)" >&2; exit 1; }
		unmanual() {
			for r in $rs; do
				$K -n "${r%/*}" patch replicationsource "${r#*/}" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null 2>&1 || true
			done
			sh "$0" - argo-resume
		}
		trap unmanual EXIT
		for r in $rs; do
			$K -n "${r%/*}" patch replicationsource "${r#*/}" --type merge -p "{\"spec\":{\"trigger\":{\"schedule\":null,\"manual\":\"$t\"}}}" >/dev/null
		done
		echo "$(echo "$rs" | wc -l) 個を取りはじめた($t)"
		# VolSync は並べて流すが、スナップショットと R2 への送りに時間がかかる。60 分で切る
		for _ in $(seq 1 360); do
			left=$($K get replicationsource -A -o jsonpath='{range .items[*]}{.status.lastManualSync}{"\n"}{end}' | grep -cvx "$t" || true)
			[ "$left" -eq 0 ] && break
			sleep 10
		done
		$K get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.lastManualSync} {.status.latestMoverStatus.result}{"\n"}{end}'
		! $K get replicationsource -A -o jsonpath='{range .items[*]}{.status.lastManualSync} {.status.latestMoverStatus.result}{"\n"}{end}' \
			| awk -v t="$t" '$1 != t || $2 != "Successful" {f=1} END {exit !f}' \
			|| { echo "終わっていないか、Successful でないものがある(kubectl get replicationsource -A で見る)" >&2; exit 1; } ;;
	*) echo "unknown: $OP" >&2; exit 1 ;;
esac
