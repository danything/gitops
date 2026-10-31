#!/bin/sh
# PV のデータを VolSync の restic のリポジトリ(R2)から戻す道具。手順は recovery/README.md の 8。
# 取り方は ../deploy/volsync/application.yaml(PVC ごとのリポジトリ `<bucket>/volsync/<namespace>/<pvc>`)。
#
#   tools/t.ps1 --admin sh recovery/pv.sh <namespace> <操作> [引数…]
#
#   - plan-all / restore-all   全部(namespace は `-`)。plan は読むだけ。restore-all が README の 8 そのもの
#   plan / restore             その namespace の PVC を、それぞれのスナップショットから戻す
#   fit                        戻すものが PVC(LVM なので requests が上限)に入るか。plan-all と restore-all も見る
#   backup-all                 全部の ReplicationSource を今すぐ取って待つ(入れ直す前の最後のバックアップ。namespace は `-`)
#
#   以下は restore が使う部品。手で続けるときにも使う
#   argo-pause / argo-resume   Argo CD の application-controller を 0 / 1 にする。止めないと selfHeal が
#                              replicas を戻して、戻している最中にアプリが起き上がる
#   stop [残すもの…]           その namespace の Deployment / StatefulSet を 0 にする(元の数は ~/.cache に控える)
#   start                      stop で控えた数に戻す
#   pvc <pvc>                  1 つの PVC を ReplicationDestination(copyMethod: Direct)で戻す。アプリは先に stop
#   shell <pvc> <コマンド>     root のヘルパー Pod で PVC(/pvc)を開いてコマンドを打つ
#
# **PVC は丸ごと戻す。** スナップショットから取っているので、DB(Postgres・SQLite・RocksDB)も crash-consistent な
# ファイルのまま戻り、アプリが起きるときに自分で立ち直る(k8up の頃の pg_dump・SQLite・tar の戻し分けは要らない)。
# 戻す前の PVC の中身は消す(`enableFileDeletion`。新しいクラスタでアプリが先に作ったもの、Postgres の initdb など)。
#
# 前提: tools/t.ps1 --admin で動かす(kubectl の管理者の資格情報。tools/README.md「クラスタの資格情報」)、
# ~/.config/restic.env がある(README の 6。plan と fit が restic でスナップショットを見る)、
# リポジトリのルート(このファイルが deploy/volsync/ を読む)で打つ。
# ReplicationDestination が使う Secret(`volsync-<pvc>`)は Argo CD が deploy/volsync/ の InfisicalSecret から作る(README の 7 のあと)。
set -eu
NS=${1:?usage: pv.sh <namespace> <操作> [引数…]}
OP=${2:?usage: pv.sh <namespace> <操作> [引数…]}
shift 2
K=kubectl
REP="$HOME/.cache/pv-replicas-$NS"

# restic.env を読む。restore-all などが自分を呼び直すとき、子は親が読んだ env を継ぐので読み直さない
# (VOLSYNC_BASE があれば読み終わっているとみなす)。restic.env の RESTIC_REPOSITORY はバケットの根
# (`s3:<endpoint>/<bucket>`。k8up の頃と同じ)で、PVC ごとのリポジトリはその下の `volsync/<namespace>/<pvc>`
restic_env() {
	[ -n "${VOLSYNC_BASE:-}" ] && return 0
	set -a; . "$HOME/.config/restic.env"; set +a
	VOLSYNC_BASE=${RESTIC_REPOSITORY%/}/volsync
	export VOLSYNC_BASE
}
repo() { echo "$VOLSYNC_BASE/$NS/$1"; } # $1=pvc

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

# --- まとめて戻す(plan / restore / plan-all / restore-all) ---
# 戻す PVC は git の deploy/volsync/<namespace>.yaml の ReplicationSource(sourcePVC)。クラスタの中のものは見ない
# (建て直した直後は Argo CD がまだ作っていないことがある)。
#
# **namespace や PVC が無いのは飛ばさずに止める。** 「まだ Argo CD が作っていない」と「やめたアプリの残り」を
# 区別できないので。やめたアプリは deploy/volsync/ から消す。

# **このクラスタができる前のものだけを戻す。** ReplicationSource は Argo CD が作るとすぐ時刻を待ちはじめ、
# 戻すより先に空の PVC を取ったスナップショットが「いちばん新しい」になりうる(2026-10-31 の Z440 への移行で、k8up で踏んだ)。
# 境目は kube-system の namespace ができた時刻。`RESTORE_BEFORE`(RFC 3339)で上書きできる
before() {
	[ -n "${RESTORE_BEFORE:-}" ] && { echo "$RESTORE_BEFORE"; return; }
	$K get ns kube-system -o jsonpath='{.metadata.creationTimestamp}'
}

pvcs() { sed -n 's/^  sourcePVC: *//p' "deploy/volsync/$NS.yaml"; }

snap() { # $1=pvc → 境目より前でいちばん新しいスナップショットの ID(無ければ空)
	RESTIC_REPOSITORY=$(repo "$1") restic snapshots --json 2>/dev/null \
		| B="$(before)" bun -e '
const before = Date.parse(process.env.B);
const s = (JSON.parse(await Bun.stdin.text() || "[]") ?? []).filter((x) => Date.parse(x.time) < before)
	.sort((a, b) => Date.parse(b.time) - Date.parse(a.time))[0];
if (s) console.log(s.id);'
}

# 「PVC スナップショット」を 1 行ずつ。決められないものは止める(黙って飛ばさない)
plan() {
	[ -f "deploy/volsync/$NS.yaml" ] || { echo "ERROR: $NS: deploy/volsync/$NS.yaml が無い" >&2; exit 2; }
	$K get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: $NS: namespace が無い" >&2; exit 1; }
	for pvc in $(pvcs); do
		$K -n "$NS" get pvc "$pvc" >/dev/null 2>&1 || { echo "ERROR: $NS: PVC $pvc が無い" >&2; exit 1; }
		id=$(snap "$pvc")
		[ -n "$id" ] || { echo "ERROR: $NS: $pvc の $(before) より前のスナップショットが無い($(repo "$pvc"))" >&2; exit 2; }
		echo "$pvc $id"
	done
}

# PVC の大きさ(requests)をバイトに。使っている単位(Ki・Mi・Gi・Ti と単位なし)だけ読む
bytes() { # $1=量
	case $1 in
		*Ki) echo $((${1%Ki} * 1024)) ;;
		*Mi) echo $((${1%Mi} * 1048576)) ;;
		*Gi) echo $((${1%Gi} * 1073741824)) ;;
		*Ti) echo $((${1%Ti} * 1099511627776)) ;;
		*[!0-9]*) echo "ERROR: $NS: PVC の大きさ $1 を読めない" >&2; return 1 ;;
		*) echo "$1" ;;
	esac
}

# 戻すものが PVC に入るか。**PVC は LVM の LV で、requests の大きさが本当の上限**。
# xfs の分を見込んで 9 割を超えたら止める
fit() {
	_f=$(mktemp)
	plan > "$_f"
	bad=0
	while read -r pvc id; do
		need=$(RESTIC_REPOSITORY=$(repo "$pvc") restic stats --mode restore-size --json "$id" | sed -n 's/.*"total_size":\([0-9]*\).*/\1/p')
		req=$($K -n "$NS" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}')
		have=$(bytes "$req") || exit 1
		[ -n "$need" ] || { echo "ERROR: $NS: restic stats $id が読めない" >&2; exit 1; }
		if [ "$need" -gt $((have / 10 * 9)) ]; then
			echo "ERROR: $NS: $pvc は $req、戻すものは $((need / 1048576)) MiB(9 割を超える)。PVC を大きくするか、restic から要らないものを消す" >&2
			bad=1
		else
			echo "$NS: $pvc $((need / 1048576)) MiB / $req"
		fi
	done < "$_f"
	rm -f "$_f"
	[ "$bad" = 0 ]
}

# 1 つの PVC を戻す。Secret は deploy/volsync/ の InfisicalSecret が作った `volsync-<pvc>`
# (infisical の namespace だけは Infisical がまだ無いので recovery/infisical.sh が restic.env から作る)。
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

restore() {
	steps=$(plan)
	echo "== $NS"; echo "$steps" | sed 's/^/  /'
	stop
	echo "$steps" | while read -r pvc _; do restore_pvc "$pvc"; done
	start
}

# 戻す namespace = deploy/volsync/ のファイル(forgejo は先に別で戻す。infisical は recovery/infisical.sh)
hosts() {
	for f in deploy/volsync/*.yaml; do
		n=$(basename "$f" .yaml)
		case $n in application | forgejo | infisical) ;; *) echo "$n" ;; esac
	done
}

# 全部の plan が通るか。通らなければ 1(何も触らない)
plan_all() {
	rc=0
	for h in "$@"; do
		echo "== $h"
		if out=$(sh "$0" "$h" plan); then echo "$out" | sed 's/^/  /'; else rc=1; fi
	done
	return $rc
}

wait_appsets() { # Forgejo が戻って ApplicationSet のエラーが消えるまで(非公開アプリの Application が出てくる)
	for _ in $(seq 1 60); do
		e=$($K -n argocd get applicationset -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="ErrorOccurred")].status}{"\n"}{end}' | grep -c True || true)
		[ "$e" -eq 0 ] && { echo "applicationset: エラーなし"; return 0; }
		sleep 10
	done
	echo "applicationset のエラーが 10 分で消えない(kubectl -n argocd get applicationset で見る)" >&2; exit 1
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
	plan) restic_env; plan ;;
	fit) restic_env; fit ;;
	pvc) restore_pvc "${1:?pvc}" ;;
	restore) restic_env; restore ;;
	plan-all) # 読むだけ。forgejo と各 namespace で何を戻すかと、PVC に入るかを出す。1 つでも決められない・入らなければ 1
		restic_env
		H=$(hosts)
		rc=0
		plan_all forgejo $H || rc=1
		echo "== PVC に入るか"
		for h in forgejo $H; do sh "$0" "$h" fit || rc=1; done
		exit $rc ;;
	restore-all) # README の 8 を通しで。Forgejo を先に戻し、非公開アプリが出てくるのを待ってから残り
		restic_env
		plan_all forgejo >/dev/null || { echo "forgejo の plan が通らない(plan-all で見る)" >&2; exit 1; }
		sh "$0" forgejo fit || { echo "forgejo の PVC に入らない" >&2; exit 1; }
		# 待っても直らないもの(スナップショットが無い・ファイルが無い。plan の終了コード 2)も、触る前に止める
		bad=
		for h in $(hosts); do
			rc=0; sh "$0" "$h" plan >/dev/null 2>&1 || rc=$?
			[ "$rc" = 2 ] && bad="$bad $h"
		done
		[ -z "$bad" ] || { echo "スナップショットが無いものがある:$bad(sh recovery/pv.sh <ns> plan で見る)" >&2; exit 1; }
		trap 'rc=$?; [ $rc = 0 ] || echo "restore-all が途中で止まった($rc)。Argo CD は止まったままかもしれない(sh recovery/pv.sh - argo-resume で戻す)。止めた namespace は sh recovery/pv.sh <ns> start で起こせる。流し直すと Forgejo からやり直すので、続きは <ns> restore を 1 つずつ" >&2' EXIT
		sh "$0" - argo-pause
		sh "$0" forgejo restore
		sh "$0" - argo-resume
		wait_appsets
		# 残りの namespace と PVC が全部出そろうまで待つ(Argo CD は動かしたまま)。1 つでも欠けていれば、どこも上書きする前に止まる
		H=$(hosts); ok=
		for _ in $(seq 1 30); do
			plan_all $H >/dev/null 2>&1 && { ok=1; break; }
			sleep 20
		done
		[ -n "$ok" ] || { plan_all $H >/dev/null || true; echo "10 分待っても上の plan が通らない。forgejo だけ戻した状態で止めた(Argo CD は動いている)" >&2; exit 1; }
		big=
		for h in $H; do sh "$0" "$h" fit >/dev/null || big="$big $h"; done
		[ -z "$big" ] || { echo "PVC に入らないものがある:$big(forgejo だけ戻した状態で止めた。Argo CD は動いている)" >&2; exit 1; }
		sh "$0" - argo-pause
		for h in $H; do sh "$0" "$h" restore; done
		sh "$0" - argo-resume ;;
	backup-all) # 入れ直す前の最後のバックアップ。全部の ReplicationSource を手動で 1 回ずつ取り、全部終わるまで待つ。
		# 時刻(schedule)を手動(manual)に置き換えるので、Argo CD を止めておく(戻すと selfHeal が schedule に戻す)
		t=final-$(date -u +%Y%m%d%H%M)
		sh "$0" - argo-pause
		trap 'sh "$0" - argo-resume' EXIT
		rs=$($K get replicationsource -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
		[ -n "$rs" ] || { echo "ReplicationSource が 1 つも無い(kubectl get replicationsource -A で見る)" >&2; exit 1; }
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
	shell) # $1=pvc $2=コマンド
		helper "$1"
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc; $2"
		unhelper "$1" ;;
	*) echo "unknown: $OP" >&2; exit 1 ;;
esac
