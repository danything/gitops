#!/bin/sh
# kubectl / talosctl / helm の入口(tools/README.md「クラスタの資格情報」)。繋ぐときだけ bootstrap/talos-secrets.sops.yaml の CA で
# 1 日で切れる証明書を作り、/dev/shm(tmpfs)に置いて渡す。平文はディスクに書かない。
# 既定は読み取り用。管理者は `tools/t.ps1 --admin …`(GITOPS_ADMIN=1)のときだけ。
set -eu
tool=${0##*/}
real=/usr/local/libexec/gitops/$tool
shm=/dev/shm/gitops

die() { echo "$tool: $*" >&2; exit 1; }

# 最初の引数らしいもの。`kubectl -n x get` だと x を拾うが、そのときは「繋ぐ」側に倒れるだけ
sub=
for a in "$@"; do case $a in --) break ;; -*) ;; *) sub=$a; break ;; esac; done

# 繋がないものと、資格情報を自分で渡しているものはそのまま通す(CI の tools.yml もここを通る)
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
nokey() { [ -s ~/.config/sops/age/keys.txt ] || die "age の鍵が無い(README「秘密の扱い」の 1 行目で .home に置く)"; }

# CA($1 = os か k8s)で件名 $2・鍵 $4(ed25519 / EC)の証明書を作り $3.crt / $3.key / $3.ca に置く。
# ノードの時計の遅れを見て 5 分前から有効にする。CA の鍵が出る $w はすぐ消す。
mint() {
	nokey
	w=$(mktemp -d "$shm/w.XXXXXX")
	# `( … ) || …` だと中の set -e が効かない。パイプは失敗を拾わないので復号はファイルに出す
	set +e
	(
		set -e
		umask 077
		for k in crt key; do
			sops -d --extract "[\"certs\"][\"$1\"][\"$k\"]" bootstrap/talos-secrets.sops.yaml >"$w/ca.$k.b64"
			base64 -d "$w/ca.$k.b64" >"$w/ca.$k"
		done
		# Talos の ed25519 は独自の見出し。中身は PKCS#8 なので見出しだけ直す
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
	[ $rc = 0 ] || { rm -f "$3".*; die "証明書を作れなかった(bootstrap/talos-secrets.sops.yaml を age の鍵で開けるか)"; }
}

# 作業用 PC の LAN 側のノードの口(10.0.0.2 は手元から届かず、NetBird はクラスタが落ちると使えない)
ep=10.10.0.4

# talosconfig を作って置き場所を返す($1 = admin / readonly)
talosconfig() {
	t=$shm/talosconfig-$1
	if [ ! -s "$t" ]; then
		if [ "$1" = admin ]; then os=os:admin; else os=os:reader; fi
		mint os "/O=$os" "$t.c.$$" ed25519
		(umask 077 && printf 'context: doany\ncontexts:\n  doany:\n    endpoints: [%s]\n    nodes: [%s]\n    ca: %s\n    crt: %s\n    key: %s\n' \
			"$ep" "$ep" "$(cat "$t.c.$$.ca")" "$(cat "$t.c.$$.crt")" "$(cat "$t.c.$$.key")" >"$t.$$" && mv "$t.$$" "$t")
		rm -f "$t.c.$$".*
	fi
	echo "$t"
}

if [ "$tool" = talosctl ]; then
	TALOSCONFIG=$(talosconfig $role)
	export TALOSCONFIG
	exec "$real" "$@"
fi

out=$shm/kubeconfig-$role
if [ ! -s "$out" ]; then
	if [ $role = admin ]; then
		# talosctl kubeconfig は 1 年もつ証明書を出すので使わない
		subj=/O=system:masters/CN=tools-admin
	else
		# Headlamp の Entra の viewer と同じ権限(bootstrap/apiserver-rbac.yaml)
		subj=/O=entra:viewer/CN=tools-readonly
	fi
	mint k8s "$subj" "$out.c.$$" ec
	(umask 077 && printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: doany\n  cluster:\n    server: https://%s:6443\n    certificate-authority-data: %s\ncontexts:\n- name: %s@doany\n  context:\n    cluster: doany\n    user: %s\ncurrent-context: %s@doany\nusers:\n- name: %s\n  user:\n    client-certificate-data: %s\n    client-key-data: %s\n' \
		"$ep" "$(cat "$out.c.$$.ca")" $role $role $role $role "$(cat "$out.c.$$.crt")" "$(cat "$out.c.$$.key")" >"$out.$$" && mv "$out.$$" "$out")
	rm -f "$out.c.$$".*
fi
export KUBECONFIG="$out"
exec "$real" "$@"
