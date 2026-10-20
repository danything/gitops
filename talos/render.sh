#!/bin/sh
# machine config を作る: ./talos/render.sh talos/clusterconfig
# chart の値は bootstrap/*/values.yaml が正本。ここに写さない(../docs/decisions.md)。
# SOPS は自分で復号する。CI は鍵が無いので SECRETS などの env にダミーを渡す。
# 出力は秘密を含み、出力先は丸ごと作り直す。当て方は talos/README.md。
set -eu

OUT=${1:?usage: render.sh <output-dir>}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
OWN_SECRETS=
# 最後を `[ -n ... ] &&` で終えない。トラップの戻り値が終了コードになり、空だと 1 で落ちる。
cleanup() {
	rm -rf "$WORK"
	if [ -n "$OWN_SECRETS" ]; then rm -f "$OWN_SECRETS"; fi
	return 0
}
trap cleanup EXIT INT TERM

SECRETS=${SECRETS:-}
if [ -z "$SECRETS" ]; then
	OWN_SECRETS=$WORK/secrets.yaml
	SECRETS=$OWN_SECRETS
	sops -d talos/secrets.yaml > "$SECRETS"
fi

# controlplane.yaml の `"${名前}"` を secrets.yaml の値で埋める。値は ENVIRON で渡す(sed だと値の / や & が壊す)。
# 印は二重引用符で囲んで書き、埋めるときに \ と " をエスケープする(値の # や : で YAML が壊れないように)。
# 埋め残しがあれば止まる(そのまま当てると `${…}` が文字どおりパスワードになる)。
# 値は 1 行で読み、外側の引用符だけ外す(中の引用符は値の一部)。
secret() { # $1=secrets.yaml のトップレベルのキー
	sed -n "s/^$1: *//p" "$SECRETS" | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
FJ_REGISTRY_PASSWORD=$(secret fjRegistryPassword)
[ -n "$FJ_REGISTRY_PASSWORD" ] || { echo "ERROR: secrets.yaml に fjRegistryPassword が無い" >&2; exit 1; }
FJ_REGISTRY_PASSWORD=$FJ_REGISTRY_PASSWORD awk '/^[[:space:]]*#/ {print; next} {
	while (match($0, /\$\{[A-Z_]+\}/)) {
		k = substr($0, RSTART + 2, RLENGTH - 3)
		if (!(k in ENVIRON)) { print "ERROR: controlplane.yaml の ${" k "} を埋める値が無い" > "/dev/stderr"; exit 1 }
		# gsub の置換文字列の \ は awk の実装で解釈が違うので、1 文字ずつ組む
		v = ""
		for (i = 1; i <= length(ENVIRON[k]); i++) {
			c = substr(ENVIRON[k], i, 1)
			v = v (c == "\\" || c == "\"" ? "\\" : "") c
		}
		$0 = substr($0, 1, RSTART - 1) v substr($0, RSTART + RLENGTH)
	}
	print
}' talos/controlplane.yaml > "$WORK/controlplane.yaml"

# キーを名前で引く(位置で数えるとブロックが増えたとき別の値を掴む)。yq は版で構文が違うので awk。
ver() { # $1=トップレベルのキー  $2=その下のキー
	awk -v top="$1:" -v key="  $2: " '$0 == top {f=1; next} /^[^ #]/ {f=0} f && index($0, key) == 1 {print substr($0, length(key)+1); exit}' talos/versions.yaml
}
TALOS=$(ver talos version)
SCHEMATIC=$(ver talos schematic)
K8S=$(ver kubernetes version)
GWAPI=$(ver gatewayAPI version)
bver() { sed -n 's/^version: //p' "bootstrap/$1/version.yaml"; }
CILIUM=$(bver cilium)
CERTMGR=$(bver cert-manager)
ARGOCD=$(bver argocd)
INFISICAL=$(bver infisical)
for v in "$TALOS" "$SCHEMATIC" "$K8S" "$GWAPI" "$CILIUM" "$CERTMGR" "$ARGOCD" "$INFISICAL"; do
	[ -n "$v" ] || { echo "ERROR: versions.yaml / version.yaml から版を読めなかった" >&2; exit 1; }
done
echo "talos=$TALOS k8s=$K8S gateway-api=$GWAPI"
echo "cilium=$CILIUM cert-manager=$CERTMGR argo-cd=$ARGOCD infisical-standalone=$INFISICAL"

inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

# chart と repo は version.yaml の `# renovate:` 行から読む。namespace.yaml は先頭に付ける(最初は誰も作らない)。
# `updatedAt` は infisical の chart が付ける時刻(values で消せない)。残すと当て直すたびに再起動する。
chart() { # $1=name  $2=namespace  残り=helm template に足す引数
	_n=$1 _ns=$2
	shift 2
	_d=bootstrap/$_n
	_repo=$(sed -n 's/.* registryUrl=\([^ ]*\).*/\1/p' "$_d/version.yaml")
	_chart=$(sed -n 's/.* depName=\([^ ]*\).*/\1/p' "$_d/version.yaml")
	[ -n "$_repo" ] && [ -n "$_chart" ] \
		|| { echo "ERROR: $_d/version.yaml の # renovate: の行から chart と repo を読めなかった" >&2; exit 1; }
	helm repo add --force-update "$_n" "$_repo" >/dev/null
	{
		if [ -f "$_d/namespace.yaml" ]; then cat "$_d/namespace.yaml"; echo ---; fi
		helm template "$_n" "$_n/$_chart" \
			--version "$(bver "$_n")" -n "$_ns" -f "$_d/values.yaml" "$@" --kube-version "$K8S" \
			| sed '/^ *updatedAt: "/d' \
			| awk -v ns="$_ns" -f talos/add-namespace.awk
	} | inline "$_n" > "$WORK/inline-$_n.yaml"
	echo "  $_n -> $(wc -c < "$WORK/inline-$_n.yaml") バイト"
}

# `--api-versions` が無いと helm template は GatewayClass を黙って描かず、公開経路が全部死ぬ。
chart cilium kube-system --api-versions gateway.networking.k8s.io/v1/GatewayClass

inline local-path < talos/local-path.yaml > "$WORK/inline-local-path.yaml"

# CI と人の RBAC。締め出されても直せるよう ArgoCD に載せない(repos.yaml の bootstrap は apiserver/ を外す)。
inline apiserver-rbac < bootstrap/apiserver/rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

# 秘密の値は secret-values.sops.yaml を values.yaml に重ねる。infisical は chart がパスワードを
# 平文 env に焼くので ArgoCD に置けない(../docs/decisions.md)。
secret_values() { # $1=name  $2=env の上書き
	if [ -n "$2" ]; then echo "$2"; return 0; fi
	sops -d "bootstrap/$1/secret-values.sops.yaml" > "$WORK/$1-secret-values.yaml"
	echo "$WORK/$1-secret-values.yaml"
}
# 先に変数に取る。`chart … -f "$(secret_values …)"` だと復号の失敗を `set -e` が拾わない
ARGOCD_SV=$(secret_values argocd "${ARGOCD_SECRET_VALUES:-}")
INFISICAL_SV=$(secret_values infisical "${INFISICAL_SECRET_VALUES:-}")
chart argocd argocd -f "$ARGOCD_SV"
chart infisical infisical -f "$INFISICAL_SV"

# CRD は URL で渡す(理由は values.yaml の `crds`)。版は chart の appVersion から取る。
ARGOCD_APP=$(helm show chart argocd/argo-cd --version "$ARGOCD" 2>/dev/null \
	| sed -n 's/^appVersion: *//p' | tr -d "\"'")
[ -n "$ARGOCD_APP" ] || { echo "ERROR: argo-cd の appVersion を読めなかった" >&2; exit 1; }
echo "  argocd の CRD: $ARGOCD_APP"
for c in application applicationset appproject; do
	cat >> "$WORK/external-crds.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: argocd-$c-crd
url: https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_APP}/manifests/crds/$c-crd.yaml
---
PATCH
done

chart cert-manager cert-manager

# ArgoCD が復号できない Secret(infisical の起動用と DNS-01 用)。`sops -d … | inline` と繋がない:
# pipefail が無いので復号に失敗しても空の manifest が黙って出て、needle(name: だけ)も通る。
inline_secret() { # $1=inline の名前  $2=SOPS ファイル  $3=env の上書き
	if [ -n "$3" ]; then
		inline "$1" < "$3" > "$WORK/inline-$1.yaml"
		return 0
	fi
	sops -d "$2" > "$WORK/plain-$1.yaml"
	inline "$1" < "$WORK/plain-$1.yaml" > "$WORK/inline-$1.yaml"
}
inline_secret infisical-secrets bootstrap/infisical/secrets.sops.yaml "${INFISICAL_SECRET:-}"
inline_secret cloudflare-secret bootstrap/cert-manager/cloudflare-secret.sops.yaml "${CLOUDFLARE_SECRET:-}"

# cert-manager の CRD も URL(理由は values.yaml の `crds`)。
cat >> "$WORK/external-crds.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: cert-manager-crds
url: https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR}/cert-manager.crds.yaml
---
PATCH

# Gateway API の CRD。Cilium の chart は同梱しない。standard で足りる。
cat > "$WORK/gateway-api.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: gateway-api
url: https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI}/standard-install.yaml
PATCH

set -- --with-secrets "$SECRETS" \
	--kubernetes-version "$K8S" \
	--install-image "factory.talos.dev/installer/${SCHEMATIC}:${TALOS}"
for f in "$WORK/controlplane.yaml" "$WORK/gateway-api.yaml" "$WORK/external-crds.yaml" "$WORK"/inline-*.yaml; do
	set -- "$@" --config-patch "@$f"
done

rm -rf "$OUT"
talosctl gen config doany https://10.0.0.2:6443 "$@" --output-dir "$OUT" >/dev/null
echo "wrote $OUT/controlplane.yaml ($(wc -l < "$OUT/controlplane.yaml") 行)"

# 描いたものが入ったか。controlplane.yaml のキーは gen config が知らないキーで落とすので見ない(helm は黙って捨てる)。
# 生成物の manifest は 1 行のエスケープ文字列なので、引用符は \" で探す。
for n in "kube-apiserver:$K8S" "ghcr.io/siderolabs/kubelet:$K8S" \
	'name: cilium' cilium-operator KUBERNETES_SERVICE_PORT 'value: \"7445\"' 'cgroup-root: \"/sys/fs/cgroup\"' \
	'kind: GatewayClass' io.cilium/gateway-controller \
	'name: local-path' rancher.io/local-path /var/mnt/local-path \
	hubble-generate-certs \
	'name: apiserver-rbac' 'name: cilium-drift' \
	"gateway-api/releases/download/$GWAPI/standard-install.yaml" \
	'name: argocd' argocd-server 'name: argocd-application-crd' manifests/crds/applicationset-crd.yaml \
	'kind: Namespace\nmetadata:\n  name: argocd' \
	'name: infisical' infisical-standalone 'metadata:\n  namespace: infisical' \
	'kind: Namespace\nmetadata:\n  name: infisical' \
	'name: cert-manager' cert-manager-webhook 'name: cert-manager-crds' \
	"cert-manager/releases/download/$CERTMGR/cert-manager.crds.yaml" \
	'kind: Namespace\nmetadata:\n  name: cert-manager' \
	'name: infisical-secrets' 'name: cloudflare-secret'; do
	grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done
# 無いことを見る側(flannel はドキュメントが在るだけで有効になる)
for n in KubeFlannelCNIConfig /var/local-path-provisioner; do
	! grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に残っている" >&2; exit 1; }
done
# CRD は inline に入れない(入ると MB 単位で増える)。包む前のファイルを見る。
for c in argocd cert-manager; do
	! grep -q 'kind: CustomResourceDefinition' "$WORK/inline-$c.yaml" \
		|| { echo "ERROR: $c の CRD が inline に入っている" >&2; exit 1; }
done
# Hubble の証明書はクラスタ内で作る(cilium/values.yaml の `hubble.tls`)
! grep -q '^    kind: Secret$' "$WORK/inline-cilium.yaml" \
	|| { echo "ERROR: cilium の inline に Secret(Hubble の証明書)が入っている" >&2; exit 1; }
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
