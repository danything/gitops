#!/bin/sh
# PV のデータを restic(R2)から戻す道具。手順は recovery/README.md の 8。
# 2026-10-17 の建て直しで使ったものを、namespace ごとの決め打ちを外して引数にした。
#
#   tools/t.ps1 --admin sh recovery/pv.sh <namespace> <操作> [引数…]
#
#   - plan-all / restore-all   全部(namespace は `-`)。plan は読むだけ。restore-all が README の 8 そのもの
#   plan / restore             その namespace の最新のスナップショットを経路の形で戻す(下の「まとめて戻す」)
#   fit                        folder で戻すものが PVC(LVM なので requests が上限)に入るか。plan-all と restore-all も見る
#   backup-all                 全 namespace の Backup を今すぐ作って待つ(入れ直す前の最後のバックアップ。namespace は `-`)
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

# restic.env を読む。restore-all などが自分を呼び直すとき、子は親が読んだ env を継ぐので読み直さない
# (RESTIC_REPOSITORY があれば読み終わっているとみなす。資格情報を env で直に渡すときも同じ)
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
# (Schedule の backup と同じ理由。deploy/k8up/schedules.yaml)。数字だけのスナップショット ID は
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
#   /data/<pvc>          folder
#   /<ns>-<app>.db       sqlite。PVC は <app>-db、無ければ <app>-data。ファイル名は <app>.db
#   /<ns>-postgres.sql   pgload(deploy/postgres は止めずに残す。ユーザーと DB は plan で deploy の env から)
#   /netbird-backup.tar  untar
#   /matrix-backup.tar   Tuwunel の --restore-backup(README の 8 の下)
# 順番は folder → sqlite → tar → pgload(denpa は /data/denpa-data を先に置いてから denpa.db を戻す)。
# infisical は recovery/infisical.sh、etcd は docs/talos.md で戻すので、ここでは扱わない。
#
# **namespace や PVC が無いのは飛ばさずに止める。** 「まだ Argo CD が作っていない」と「やめたアプリの残り」を
# 区別できないので。やめたアプリの残りは restic から消す(../deploy/k8up/README.md「やめたアプリの残り」)。

latest() { # $1=host → 「ID 経路」を経路ごとに 1 行(いちばん新しいもの)
	restic snapshots --host "$1" --latest 1 --json \
		| bun -e 'for (const s of JSON.parse(await Bun.stdin.text()) ?? []) for (const p of s.paths) console.log(s.id, p)'
}

pvc_exists() { $K -n "$NS" get pvc "$1" >/dev/null 2>&1; }

# 「順番 操作 引数…」を出す。決められないものは止める(黙って飛ばさない)
# パイプの中の while で exit しても外に伝わらないので、一覧はファイルに取ってから読む
plan() {
	$K get ns "$NS" >/dev/null 2>&1 || { echo "ERROR: $NS: namespace が無い" >&2; exit 1; }
	_l=$(mktemp); _o=$(mktemp)
	trap 'rm -f "$_l" "$_o"' EXIT
	latest "$NS" > "$_l"
	while read -r id p; do
		case $p in
			/data/*)
				pvc=${p#/data/}
				pvc_exists "$pvc" || { echo "ERROR: $NS: $p を戻す PVC $pvc が無い" >&2; exit 1; }
				echo "1 folder $pvc $id" ;;
			/"$NS"-postgres.sql)
				# ユーザーと DB は deploy/postgres の env(値で書いてあるもの)。触る前に決めておく
				pe() { $K -n "$NS" get deploy postgres -o "jsonpath={.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}" 2>/dev/null; }
				u=$(pe POSTGRES_USER); db=$(pe POSTGRES_DB)
				[ -n "$u" ] && [ -n "$db" ] || { echo "ERROR: $NS: deploy/postgres の POSTGRES_USER / POSTGRES_DB が読めない" >&2; exit 1; }
				echo "4 pgload postgres-data $id $p $u $db" ;;
			/"$NS"-*.db)
				app=${p#/"$NS"-}; app=${app%.db}
				if pvc_exists "$app-db"; then echo "2 sqlite $app-db $app.db $id $p"
				elif pvc_exists "$app-data"; then echo "2 sqlite $app-data $app.db $id $p"
				else echo "ERROR: $NS: $p を戻す PVC($app-db / $app-data)が無い" >&2; exit 1; fi ;;
			/netbird-backup.tar) echo "3 untar netbird-data $id $p store.db*,idp.db*,events.db*" ;;
			/matrix-backup.tar) echo "3 matrix tuwunel-data $id $p" ;;
			# 終了コード 2 = 待っても直らない(restore-all はこれを Forgejo を戻す前に見る)
			*) echo "ERROR: $NS: $p の戻し方が決まっていない(README の 8 の表に足す)" >&2; exit 2 ;;
		esac
	done < "$_l" > "$_o"
	sort -n "$_o"
}

# PVC の大きさ(requests)をバイトに。使っている単位(Ki・Mi・Gi・Ti と単位なし)だけ読む
bytes() { # $1=量
	case $1 in
		*.*) echo "ERROR: $NS: PVC の大きさ $1 は小数なので読めない(整数の Gi などに)" >&2; return 1 ;;
		*Ki) echo $((${1%Ki} * 1024)) ;;
		*Mi) echo $((${1%Mi} * 1048576)) ;;
		*Gi) echo $((${1%Gi} * 1073741824)) ;;
		*Ti) echo $((${1%Ti} * 1099511627776)) ;;
		*[!0-9]*) echo "ERROR: $NS: PVC の大きさ $1 を読めない" >&2; return 1 ;;
		*) echo "$1" ;;
	esac
}

# folder で戻すものが PVC に入るか。**PVC は LVM の LV で、requests の大きさが本当の上限**(local-path の頃は
# ディスクの残り全部が使えたので、小さく書いた PVC に大きなデータが入っていた。2026-10 の adguardhome-work は 5Gi に 68 GB)。
# xfs の分を見込んで 9 割を超えたら止める。restic の stats は 1 つずつ R2 を読むので、plan(待つ間に何度も呼ぶ)とは分ける
fit() {
	_f=$(mktemp)
	plan > "$_f"
	bad=0
	# plan の行は「順番 操作 引数…」で、folder の引数は「PVC スナップショット」(plan の folder の行と揃える)
	while read -r _ op pvc id _; do
		[ "$op" = folder ] || continue
		need=$(restic stats --mode restore-size --json "$id" | sed -n 's/.*"total_size":\([0-9]*\).*/\1/p')
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

restore() {
	steps=$(plan)
	[ -n "$steps" ] || { echo "$NS: 戻すものが無い"; return 0; }
	echo "== $NS"; echo "$steps" | sed 's/^/  /'
	keep=; echo "$steps" | grep -q ' pgload ' && keep=postgres
	stop $keep
	# 一覧は fd 3 で読む(標準入力に流すと、中で呼ぶコマンドが残りの行を食いうる)
	while read -r _ op a b c d <&3; do
		case $op in
			folder) folder "$a" "$b" ;;
			sqlite) sh "$0" "$NS" sqlite "$a" "$b" "$c" "$d" ;;
			untar) sh "$0" "$NS" untar "$a" "$b" "$c" "$(echo "$d" | tr , ' ')" ;;
			pgload)
				set -- $d   # plan が足したユーザーと DB
				sh "$0" "$NS" pgload "$a" "$b" "$c" postgres "$1" "$2" ;;
			matrix)
				folder "$a" "$b"
				helper "$a"
				$K -n "$NS" exec "h-$a" -- sh -euc "cd /pvc; rm -rf db backups media; tar -xf ${c#/}; rm -f ${c#/}; chown -R 65532:65532 .; ls backups"
				unhelper "$a"
				# 1 回だけ。Argo CD を戻すと selfHeal が引数を消す
				$K -n "$NS" patch sts tuwunel -p '{"spec":{"template":{"spec":{"containers":[{"name":"tuwunel","args":["--restore-backup"]}]}}}}' >/dev/null ;;
		esac
	done 3<<STEPS
$steps
STEPS
	start
}

# 戻す namespace = restic の host(forgejo は先に別で戻す。infisical・etcd は別の手順)
hosts() {
	restic snapshots --json \
		| bun -e 'console.log([...new Set(JSON.parse(await Bun.stdin.text()).map(s => s.hostname))].sort().join("\n"))' \
		| { grep -vxE 'forgejo|infisical|etcd' || true; }
}

# 全 host の plan が通るか。通らなければ 1(何も触らない)
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
	restore) restic_env; restore ;;
	plan-all) # 読むだけ。forgejo と各 namespace で何をするかと、PVC に入るかを出す。1 つでも決められない・入らなければ 1
		restic_env
		H=$(hosts)
		rc=0
		plan_all forgejo $H || rc=1
		echo "== PVC に入るか(folder のもの)"
		for h in forgejo $H; do sh "$0" "$h" fit || rc=1; done
		exit $rc ;;
	restore-all) # README の 8 を通しで。Forgejo を先に戻し、非公開アプリが出てくるのを待ってから残り
		restic_env
		# Forgejo の plan が通らなければ何も触らない
		plan_all forgejo >/dev/null || { echo "forgejo の plan が通らない(plan-all で見る)" >&2; exit 1; }
		sh "$0" forgejo fit || { echo "forgejo の PVC に入らない" >&2; exit 1; }
		# 待っても直らないもの(戻し方が決まっていない経路。plan の終了コード 2)も、触る前に止める。
		# namespace がまだ無いものはここでは見えない(Forgejo の後でしか出てこない)
		bad=
		for h in $(hosts); do
			rc=0; sh "$0" "$h" plan >/dev/null 2>&1 || rc=$?
			[ "$rc" = 2 ] && bad="$bad $h"
		done
		[ -z "$bad" ] || { echo "戻し方が決まっていない経路がある:$bad(sh recovery/pv.sh <ns> plan で見る)" >&2; exit 1; }
		# ここから先で落ちたら、Argo CD が止まったままかもしれないことと続け方を出す
		trap 'rc=$?; [ $rc = 0 ] || echo "restore-all が途中で止まった($rc)。Argo CD は止まったままかもしれない(sh recovery/pv.sh - argo-resume で戻す)。止めた namespace は sh recovery/pv.sh <ns> start で起こせる。流し直すと Forgejo からやり直すので、続きは <ns> restore を 1 つずつ" >&2' EXIT
		sh "$0" - argo-pause
		sh "$0" forgejo restore
		sh "$0" - argo-resume
		wait_appsets
		# 残りの namespace と PVC が全部出そろうまで待つ(Argo CD は動かしたまま)。
		# 1 つでも欠けていれば、どこも上書きする前に止まる
		H=$(hosts); ok=
		for _ in $(seq 1 30); do
			plan_all $H >/dev/null 2>&1 && { ok=1; break; }
			sleep 20
		done
		[ -n "$ok" ] || { plan_all $H >/dev/null || true; echo "10 分待っても上の plan が通らない。forgejo だけ戻した状態で止めた(Argo CD は動いている)" >&2; exit 1; }
		# どこも上書きする前に、全部が PVC に入るかを見る
		big=
		for h in $H; do sh "$0" "$h" fit >/dev/null || big="$big $h"; done
		[ -z "$big" ] || { echo "PVC に入らないものがある:$big(上の ERROR。forgejo だけ戻した状態で止めた。Argo CD は動いている)" >&2; exit 1; }
		sh "$0" - argo-pause
		for h in $H; do sh "$0" "$h" restore; done
		sh "$0" - argo-resume ;;
	backup-all) # 入れ直す前の最後のバックアップ。Schedule に backup のある namespace ごとに Backup を作り、全部終わるまで待つ
		t=final-$(date -u +%Y%m%d%H%M)
		nss=$($K get schedule -A -o jsonpath='{range .items[?(@.spec.backup)]}{.metadata.namespace}{"\n"}{end}')
		[ -n "$nss" ] || { echo "backup のある Schedule が 1 つも無い(kubectl get schedule -A で見る)" >&2; exit 1; }
		for ns in $nss; do
			# Schedule と同じ形(tags は prune の歯止め、root は 0600 のファイルを読むため。deploy/k8up/schedules.yaml)
			$K create -f - >/dev/null <<B
apiVersion: k8up.io/v1
kind: Backup
metadata: {name: $t, namespace: $ns}
spec: {tags: [k8up], podSecurityContext: {runAsUser: 0, runAsGroup: 0}}
B
			echo "backup $ns/$t"
		done
		# operator が 1 つずつ流す(リポジトリのロック)。30 分で切る
		st=
		for _ in $(seq 1 180); do
			st=$($K get backup -A --field-selector "metadata.name=$t" \
				-o jsonpath='{range .items[*]}{.metadata.namespace} {.status.conditions[?(@.type=="Completed")].reason}{"\n"}{end}')
			echo "$st" | awk 'NF < 2 {n++} END {exit (n > 0)}' && break
			sleep 10
		done
		echo "$st"
		! echo "$st" | awk 'NF < 2 || $2 != "Succeeded" {f=1} END {exit !f}' \
			|| { echo "終わっていないか、Succeeded でないものがある(kubectl get backup -A で見る)" >&2; exit 1; } ;;
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
		# **ダンプを置く間は Postgres も止める。** OpenEBS LVM の PV は 2 つの Pod から同時にマウントできず、
		# Restore の Pod が `verifyMount: device already mounted` で ContainerCreating のまま止まる
		# (local-path の頃は通っていた。2026-10-31 の Z440 への移行で踏んだ)
		$K -n "$NS" scale "deploy/$4" --replicas=0 >/dev/null
		for _ in $(seq 1 40); do
			$K -n "$NS" get pod --no-headers 2>/dev/null | grep -v Completed | grep -q "^$4-" || break
			sleep 3
		done
		folder "$1" "$2"
		$K -n "$NS" scale "deploy/$4" --replicas=1 >/dev/null
		$K -n "$NS" rollout status "deploy/$4" --timeout=5m >/dev/null
		f=${3#/}
		# PVC は deploy/{forgejo,rybbit}/postgres.yaml で /var/lib/postgresql/data に付いている。
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
