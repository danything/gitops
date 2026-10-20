#!/bin/sh
# PV のデータを restic(R2)から戻す道具。手順は recovery/README.md の 8。
# 2026-10-17 の建て直しで使ったものを、namespace ごとの決め打ちを外して引数にした。
#
#   tools/t.ps1 --admin sh recovery/pv.sh <namespace> <操作> [引数…]
#
#   - plan-all / restore-all   全部(namespace は `-`)。plan は読むだけ。restore-all が README の 8 そのもの
#   plan / restore             その namespace の最新のスナップショットを経路の形で戻す(下の「まとめて戻す」)
#
#   以下は restore が使う部品。手で続けるときにも使う
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
# 前提: tools/t.ps1 --admin で動かす(kubectl の管理者の資格情報。tools/README.md「クラスタの資格情報」)、
# ~/.config/restic.env がある(README の 6)。
set -eu
NS=${1:?usage: pv.sh <namespace> <操作> [引数…]}
OP=${2:?usage: pv.sh <namespace> <操作> [引数…]}
shift 2
K=kubectl
REP="$HOME/.cache/pv-replicas-$NS"

# env にもう入っていれば(RESTIC_REPOSITORY)読まない
restic_env() { [ -n "${RESTIC_REPOSITORY:-}" ] && return 0; set -a; . "$HOME/.config/restic.env"; set +a; }

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
	[ -s "$REP" ] || { echo "控え $REP が無い(stop を先に)" >&2; exit 1; }
	while read -r w r; do $K -n "$NS" scale "$w" --replicas="$r" >/dev/null; done < "$REP"
	echo "started: $(cut -d' ' -f1 "$REP" | tr '\n' ' ')"
	rm -f "$REP"
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

# --- まとめて戻す(plan / restore / plan-all / restore-all) ---
# スナップショットの経路の形で操作が決まる(README の 8 の表)。namespace = restic の host。
#   /data/<pvc>          folder(PVC が無ければ飛ばす。やめたアプリの残り)
#   /<ns>-<app>.db       sqlite。PVC は <app>-db、無ければ <app>-data。ファイル名は <app>.db
#   /<ns>-postgres.sql   pgload(deploy/postgres は止めずに残す。ユーザーと DB はその Pod の env から)
#   /netbird-backup.tar  untar
#   /matrix-backup.tar   Tuwunel の --restore-backup(README の 8 の下)
# 順番は folder → sqlite → tar → pgload(denpa は /data/denpa-data を先に置いてから denpa.db を戻す)。
# infisical は recovery/infisical.sh、etcd は docs/talos.md で戻すので、ここでは扱わない。

latest() { # $1=host → 「ID 経路」を経路ごとに 1 行(いちばん新しいもの)
	restic snapshots --host "$1" --latest 1 --json \
		| bun -e 'for (const s of JSON.parse(await Bun.stdin.text()) ?? []) for (const p of s.paths) console.log(s.id, p)'
}

pvc_exists() { $K -n "$NS" get pvc "$1" >/dev/null 2>&1; }

# 「順番 操作 引数…」を出す。決められない経路は止める(黙って飛ばさない)
# パイプの中の while で exit しても外に伝わらないので、一覧はファイルに取ってから読む
plan() {
	_l=$(mktemp); _o=$(mktemp)
	latest "$NS" > "$_l"
	while read -r id p; do
		case $p in
			/data/*)
				pvc=${p#/data/}
				if pvc_exists "$pvc"; then echo "1 folder $pvc $id"; else echo "# 飛ばす: $p(PVC $pvc が無い)" >&2; fi ;;
			/"$NS"-postgres.sql) echo "4 pgload postgres-data $id $p" ;;
			/"$NS"-*.db)
				app=${p#/"$NS"-}; app=${app%.db}
				if pvc_exists "$app-db"; then echo "2 sqlite $app-db $app.db $id $p"
				elif pvc_exists "$app-data"; then echo "2 sqlite $app-data $app.db $id $p"
				else echo "ERROR: $p を戻す PVC($app-db / $app-data)が無い" >&2; exit 1; fi ;;
			/netbird-backup.tar) echo "3 untar netbird-data $id $p store.db*,idp.db*,events.db*" ;;
			/matrix-backup.tar) echo "3 matrix tuwunel-data $id $p" ;;
			*) echo "ERROR: $p の戻し方が決まっていない(README の 8 の表に足す)" >&2; exit 1 ;;
		esac
	done < "$_l" > "$_o"
	sort -n "$_o"; rm -f "$_l" "$_o"
}

restore() {
	steps=$(plan)
	[ -n "$steps" ] || { echo "$NS: 戻すものが無い"; return 0; }
	echo "== $NS"; echo "$steps" | sed 's/^/  /'
	keep=; echo "$steps" | grep -q ' pgload ' && keep=postgres
	stop $keep
	echo "$steps" | while read -r _ op a b c d; do
		case $op in
			folder) folder "$a" "$b" ;;
			sqlite) sh "$0" "$NS" sqlite "$a" "$b" "$c" "$d" ;;
			untar) sh "$0" "$NS" untar "$a" "$b" "$c" "$(echo "$d" | tr , ' ')" ;;
			pgload)
				u=$($K -n "$NS" exec deploy/postgres -- printenv POSTGRES_USER)
				db=$($K -n "$NS" exec deploy/postgres -- printenv POSTGRES_DB)
				sh "$0" "$NS" pgload "$a" "$b" "$c" postgres "$u" "$db" ;;
			matrix)
				folder "$a" "$b"
				helper "$a"
				$K -n "$NS" exec "h-$a" -- sh -euc "cd /pvc; rm -rf db backups media; tar -xf ${c#/}; rm -f ${c#/}; chown -R 65532:65532 .; ls backups"
				unhelper "$a"
				# 1 回だけ。Argo CD を戻すと selfHeal が引数を消す
				$K -n "$NS" patch sts tuwunel -p '{"spec":{"template":{"spec":{"containers":[{"name":"tuwunel","args":["--restore-backup"]}]}}}}' >/dev/null ;;
		esac
	done
	start
}

# 戻す namespace(restic の host のうち、クラスタに namespace があるもの。forgejo・infisical・etcd を除く)
hosts() {
	restic snapshots --json | bun -e 'console.log([...new Set(JSON.parse(await Bun.stdin.text()).map(s => s.hostname))].sort().join("\n"))' \
		| while read -r h; do
			case $h in forgejo|infisical|etcd) continue ;; esac
			if $K get ns "$h" >/dev/null 2>&1; then echo "$h"; else echo "# 飛ばす: host $h(namespace が無い)" >&2; fi
		done
}

wait_appsets() { # Forgejo が戻って ApplicationSet のエラーが消えるまで(非公開アプリの Application と PVC が出てくる)
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
	restore) restic_env; restore ;;
	plan-all) # 読むだけ。forgejo と各 namespace で何をするかを出す
		restic_env
		for h in forgejo $(hosts); do echo "== $h"; sh "$0" "$h" plan | sed 's/^/  /'; done ;;
	restore-all) # README の 8 を通しで。Forgejo を先に戻し、非公開アプリが出てくるのを待ってから残り
		restic_env
		sh "$0" - argo-pause
		sh "$0" forgejo restore
		sh "$0" - argo-resume
		wait_appsets
		sh "$0" - argo-pause
		for h in $(hosts); do sh "$0" "$h" restore; done
		sh "$0" - argo-resume ;;
	folder) folder "$1" "$2" ;;
	sqlite) # $1=pvc $2=ファイル名 $3=snapshot $4=中のパス
		restic_env
		want=$(restic ls -l "$3" "$4" | awk -v p="$4" '$NF==p{print $4}')
		[ -n "$want" ] || { echo "スナップショット $3 に $4 が無い(restic ls $3 で経路を見る)" >&2; exit 1; }
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
		# PVC は apps/{forgejo,rybbit}/postgres.yaml で /var/lib/postgresql/data に付いている。
		# psql が落ちたらダンプは消さずに残す(流し直せるように)
		$K -n "$NS" exec "deploy/$4" -- sh -euc "rc=0; psql -q -U $5 -d $6 -f /var/lib/postgresql/data/$f > /tmp/load.log 2>&1 || rc=\$?
echo errors: \$(grep -c ERROR /tmp/load.log || true); grep ERROR /tmp/load.log | sort | uniq -c | head -5
[ \$rc = 0 ] || { echo \"psql が \$rc で終わった。/var/lib/postgresql/data/$f は残してある\"; exit \$rc; }
rm -f /var/lib/postgresql/data/$f" ;;
	shell) # $1=pvc $2=コマンド
		helper "$1"
		$K -n "$NS" exec "h-$1" -- sh -euc "cd /pvc; $2"
		unhelper "$1" ;;
	*) echo "unknown: $OP" >&2; exit 1 ;;
esac
