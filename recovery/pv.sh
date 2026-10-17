#!/bin/sh
# PV のデータを restic(R2)から戻す道具。手順は recovery/README.md の 8。
# 2026-10-17 の建て直しで使ったものを、namespace ごとの決め打ちを外して引数にした。
#
#   tools/t.ps1 sh recovery/pv.sh <namespace> <操作> [引数…]
#
#   argo-pause / argo-resume   Argo CD の application-controller を 0 / 1 にする。止めないと selfHeal が
#                              replicas を戻して、戻している最中にアプリが起き上がる
#   stop [残すもの…]           その namespace の Deployment / StatefulSet を 0 にする(元の数は ~/.cache に控える)
#   start                      stop で控えた数に戻す
#   folder <pvc> <snapshot>    k8up の Restore(folder)で PVC に書き戻す。終わったら件数とエラーを出す
#   sqlite <pvc> <ファイル名> <snapshot> <スナップショットの中のパス>
#                              backupcommand で取った SQLite(`/xool-xool.db` など)を PVC の直下に戻し、
#                              大きさを restic と突き合わせてから、アプリのファイル名に付け替える
#                              (-wal / -shm / -journal を消し、元の持ち主と権限に揃える)
#   untar <pvc> <snapshot> <中のパス> <先に消すファイル>
#                              tar で取ったもの(netbird)を PVC の直下で展開する
#   pgload <pvc> <snapshot> <中のパス> <deploy> <user> <db>
#                              pg_dump を Postgres のデータの PVC に置き、その Pod の psql で流す
#   shell <pvc> <コマンド>     root のヘルパー Pod で PVC(/pvc)を開いてコマンドを打つ
#
# **バイナリを `kubectl exec -i` の標準入力で流さない。** 末尾が欠ける(SQLite で 237568 → 98304
# バイト。テキストの SQL はたまたま揃っていた)。だから全部 k8up の Restore で PVC に置いてから触る。
#
# 前提: ~/.kube/config がこのクラスタを指している(README の 4)、~/.config/restic.env がある(README の 6)。
set -eu
NS=${1:?usage: pv.sh <namespace> <操作> [引数…]}
OP=${2:?usage: pv.sh <namespace> <操作> [引数…]}
shift 2
K=kubectl
REP="$HOME/.cache/pv-replicas-$NS"

restic_env() { set -a; . "$HOME/.config/restic.env"; set +a; }

stop() {
	mkdir -p "$(dirname "$REP")"
	: > "$REP"
	for w in $($K -n "$NS" get deploy,sts -o name); do
		n=${w#*/}
		for keep in "$@"; do [ "$n" = "$keep" ] && continue 2; done
		echo "$w $($K -n "$NS" get "$w" -o jsonpath='{.spec.replicas}')" >> "$REP"
		$K -n "$NS" scale "$w" --replicas=0 >/dev/null
	done
	# 止まるのを待つ(Restore とヘルパーの Pod、残したものは数えない)
	pat=$(printf '%s|' restore- '^h-' "$@" | sed 's/|$//')
	for _ in $(seq 1 40); do
		left=$($K -n "$NS" get pod --no-headers 2>/dev/null | grep -v Completed | awk '{print $1}' | grep -vcE "$pat" || true)
		[ "$left" -eq 0 ] && break
		sleep 3
	done
	echo "stopped: $(cut -d' ' -f1 "$REP" | tr '\n' ' ')"
}

start() {
	while read -r w r; do $K -n "$NS" scale "$w" --replicas="$r" >/dev/null; done < "$REP"
	echo "started: $(cut -d' ' -f1 "$REP" | tr '\n' ' ')"
}

# **root で走らせる。** 既定の nonroot(65532)だと PVC に mkdir できず、それでも `Succeeded` になる
# (Schedule の backup と同じ理由。apps/k8up/schedules.yaml)。数字だけのスナップショット ID は
# YAML で数として読まれるので必ず引用符で囲む(`95404672` で踏んだ)。
# `xattr.LRemove … security.selinux: permission denied` は害が無い(Talos は SELinux)ので数えない。
folder() { # $1=pvc $2=snapshot
	name=restore-$1
	$K -n "$NS" delete restore "$name" --ignore-not-found >/dev/null
	$K create -f - >/dev/null <<R
apiVersion: k8up.io/v1
kind: Restore
metadata: {name: $name, namespace: $NS}
spec:
  snapshot: "$2"
  podSecurityContext: {runAsUser: 0, runAsGroup: 0}
  restoreMethod: {folder: {claimName: $1}}
R
	r=
	for _ in $(seq 1 360); do
		r=$($K -n "$NS" get restore "$name" -o jsonpath='{.status.conditions[?(@.type=="Completed")].reason}')
		[ -n "$r" ] && break
		sleep 5
	done
	p=$($K -n "$NS" get pod --no-headers -o custom-columns=N:.metadata.name | grep "restore-$name-" | head -1)
	log=$($K -n "$NS" logs "$p" 2>/dev/null || true)
	echo "folder $1 <- $2: ${r:-timeout} | $(echo "$log" | grep -oE 'Restored [^)]*\)' | tail -1) | errors (selinux 以外): $(echo "$log" | grep 'ignoring error' | grep -vc 'security.selinux' || true)"
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
	folder) folder "$1" "$2" ;;
	sqlite) # $1=pvc $2=ファイル名 $3=snapshot $4=中のパス
		restic_env
		want=$(restic ls -l "$3" "$4" | awk -v p="$4" '$NF==p{print $4}')
		folder "$1" "$3"
		helper "$1"
		f=${4#/}
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc
got=\$(stat -c %s $f); [ \"\$got\" = \"$want\" ] || { echo \"size mismatch \$got != $want\"; exit 1; }
o=\$(stat -c %u:%g $2 2>/dev/null || stat -c %u:%g .); m=\$(stat -c %a $2 2>/dev/null || echo 644)
rm -f $2 $2-wal $2-shm $2-journal; mv $f $2; chown \$o $2; chmod \$m $2; ls -ln $2"
		unhelper "$1" ;;
	untar) # $1=pvc $2=snapshot $3=中のパス $4=先に消すファイル
		folder "$1" "$2"
		helper "$1"
		f=${3#/}
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc; rm -f $4; tar -xvf $f | tr '\n' ' '; echo; rm -f $f; ls -ln"
		unhelper "$1" ;;
	pgload) # $1=pvc $2=snapshot $3=中のパス $4=deploy $5=user $6=db
		folder "$1" "$2"
		f=${3#/}
		$K -n "$NS" exec "deploy/$4" -- sh -euc "psql -q -U $5 -d $6 -f /var/lib/postgresql/data/$f > /tmp/load.log 2>&1 || true
echo errors: \$(grep -c ERROR /tmp/load.log || true); grep ERROR /tmp/load.log | sort | uniq -c | head -5
rm -f /var/lib/postgresql/data/$f" ;;
	shell) # $1=pvc $2=コマンド
		helper "$1"
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc; $2"
		unhelper "$1" ;;
	*) echo "unknown: $OP" >&2; exit 1 ;;
esac
