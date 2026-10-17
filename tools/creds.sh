#!/bin/sh
# kubectl / talosctl / helm の入口(tools/README.md「クラスタの資格情報」)。本物は /usr/local/libexec/gitops/ にあり、
# このスクリプトがその名前で呼ばれる。クラスタに繋ぐときだけ資格情報をコンテナの /dev/shm(tmpfs)に作り、
# KUBECONFIG / TALOSCONFIG で渡す。**平文はディスクに書かない。** /dev/shm はコンテナと一緒に消える(t.ps1 は --rm)。
#
# 既定は読み取り用。管理者は `tools/t.ps1 --admin …`(GITOPS_ADMIN=1)のときだけ。
#   kubectl / helm  読み取り用は talos/secrets.yaml の CA でその場で証明書を作る(1 日で切れる)。
#                   管理者は talos/kubeconfig.yaml(SOPS 済み。talosctl kubeconfig の出力)を復号する
#   talosctl        同じく CA でその場で作る(os:reader / os:admin)。talosconfig は保存しない
#                   (docs/decisions.md「手で持つもの」)
set -eu
tool=${0##*/}
real=/usr/local/libexec/gitops/$tool
shm=/dev/shm/gitops

die() { echo "$tool: $*" >&2; exit 1; }

# 最初の引数らしいもの(フラグを飛ばす)。`kubectl -n x get` だと x を拾うが、そのときは「繋ぐ」側に倒れるだけ
# (helm も「繋がないと分かっているもの」以外は繋ぐ側にしてある)。`--` より後ろはコマンドの引数なので見ない
sub=
for a in "$@"; do case $a in --) break ;; -*) ;; *) sub=$a; break ;; esac; done

# 繋がないもの(版を見る・描くだけ)と、資格情報を自分で渡しているものはそのまま通す。CI(tools.yml)もここを通る
pass() { exec "$real" "$@"; }
for a in "$@"; do
	case $a in
	--) break ;;
	-h | --help | --client | --kubeconfig | --kubeconfig=* | --talosconfig | --talosconfig=* | -s | --server | --server=*) pass "$@" ;;
	esac
done
case $tool in
kubectl)
	[ -z "${KUBECONFIG:-}" ] || pass "$@"
	case $sub in '' | kustomize | completion | help | plugin | options) pass "$@" ;; esac
	;;
helm)
	[ -z "${KUBECONFIG:-}" ] || pass "$@"
	case $sub in '' | template | lint | package | create | show | inspect | pull | fetch | push | repo | registry | search | dependency | dep | plugin | env | version | completion | verify | help) pass "$@" ;; esac
	;;
talosctl)
	[ -z "${TALOSCONFIG:-}" ] || pass "$@"
	case $sub in '' | gen | completion | help | docs | validate) pass "$@" ;; esac
	;;
esac

if [ "${GITOPS_ADMIN:-}" = 1 ]; then role=admin; else role=readonly; fi
mkdir -p -m 700 "$shm"
cd /repo
nokey() { [ -s ~/.config/sops/age/keys.txt ] || die "age の鍵が無い(README「Infisical より下の層」の 1 行目で .home に置く)"; }

# talos/secrets.yaml の CA($1 = os か k8s)で、件名 $2 のクライアント証明書をその場で作り、$3 に置く。
# 鍵 $4(ed25519 / EC)。1 日で切れる。ノードの時計が少し遅れていても通るように 5 分前から有効にする。
# 作業中は CA の鍵も $w(tmpfs)に出るので、作り終えたらすぐ消す。結果は $3.crt / $3.key / $3.ca
mint() {
	nokey
	w=$(mktemp -d "$shm/w.XXXXXX")
	# `( … ) || …` だと中の set -e が効かないので、終了コードを受けてから見る。パイプは最後の終了コードしか
	# 返さないので、復号したものは一度ファイルに出す
	set +e
	(
		set -e
		umask 077
		for k in crt key; do
			sops -d --extract "[\"certs\"][\"$1\"][\"$k\"]" talos/secrets.yaml >"$w/ca.$k.b64"
			base64 -d "$w/ca.$k.b64" >"$w/ca.$k"
		done
		# Talos は ed25519 の鍵に独自の見出しを付けている。中身は PKCS#8 なので見出しだけ直せば openssl が読める
		sed -i 's/ED25519 PRIVATE KEY/PRIVATE KEY/' "$w/ca.key"
		case $4 in
		ed25519) openssl genpkey -algorithm ed25519 -out "$w/c.key" ;;
		*) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$w/c.key" ;;
		esac
		printf 'keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >"$w/ext"
		openssl req -new -key "$w/c.key" -subj "$2" -out "$w/c.csr" 2>/dev/null
		openssl x509 -req -in "$w/c.csr" -CA "$w/ca.crt" -CAkey "$w/ca.key" -extfile "$w/ext" \
			-not_before "$(date -u -d '-5 min' +%Y%m%d%H%M%SZ)" -days 1 -out "$w/c.crt" 2>/dev/null
		for k in crt key; do base64 -w0 "$w/c.$k" >"$3.$k"; done
		base64 -w0 "$w/ca.crt" >"$3.ca"
		[ -s "$3.crt" ] && [ -s "$3.key" ] && [ -s "$3.ca" ]
	)
	rc=$?
	set -e
	rm -rf "$w"
	[ $rc = 0 ] || { rm -f "$3".*; die "証明書を作れなかった(talos/secrets.yaml を age の鍵で開けるか)"; }
}

# 名前と行き先は talos/render.sh の gen config と同じ(doany、https://10.0.0.2:6443)
if [ "$tool" = talosctl ]; then
	out=$shm/talosconfig-$role
	if [ ! -s "$out" ]; then
		if [ $role = admin ]; then os=os:admin; else os=os:reader; fi
		mint os "/O=$os" "$out.c.$$" ed25519
		(umask 077 && printf 'context: doany\ncontexts:\n  doany:\n    endpoints: [10.0.0.2]\n    nodes: [10.0.0.2]\n    ca: %s\n    crt: %s\n    key: %s\n' \
			"$(cat "$out.c.$$.ca")" "$(cat "$out.c.$$.crt")" "$(cat "$out.c.$$.key")" >"$out.$$" && mv "$out.$$" "$out")
		rm -f "$out.c.$$".*
	fi
	export TALOSCONFIG="$out"
	exec "$real" "$@"
fi

out=$shm/kubeconfig-$role
if [ ! -s "$out" ] && [ $role = readonly ]; then
	# 読み取り用は bootstrap/apiserver/rbac.yaml の entra:viewer(組み込みの view + readonly-extra。Secret は読めない)。
	# Headlamp で Entra の viewer が持つ権限と同じにするため、同じグループ名を使う
	mint k8s "/O=entra:viewer/CN=tools-readonly" "$out.c.$$" ec
	(umask 077 && printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: doany\n  cluster:\n    server: https://10.0.0.2:6443\n    certificate-authority-data: %s\ncontexts:\n- name: readonly@doany\n  context:\n    cluster: doany\n    user: readonly\ncurrent-context: readonly@doany\nusers:\n- name: readonly\n  user:\n    client-certificate-data: %s\n    client-key-data: %s\n' \
		"$(cat "$out.c.$$.ca")" "$(cat "$out.c.$$.crt")" "$(cat "$out.c.$$.key")" >"$out.$$" && mv "$out.$$" "$out")
	rm -f "$out.c.$$".*
elif [ ! -s "$out" ]; then
	f=talos/kubeconfig.yaml
	[ -f $f ] || die "$f が無い。作り方は tools/README.md「クラスタの資格情報」"
	grep -q '^sops:' $f || die "$f が暗号化されていない。git に入れる前に tools/README.md の手順で暗号化する"
	nokey
	(umask 077 && sops -d $f >"$out.$$" && mv "$out.$$" "$out") || { rm -f "$out.$$"; die "$f を復号できなかった"; }
fi
export KUBECONFIG="$out"
exec "$real" "$@"
