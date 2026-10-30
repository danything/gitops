#!/bin/sh
# machine config を作る: ./bootstrap/render.sh bootstrap/clusterconfig
# chart の値と版は bootstrap/<name>-values.yaml が正本。ここに写さない(../docs/decisions.md)。
# SOPS は自分で復号する。CI は鍵が無いので SECRETS などの env にダミーを渡す。
# 出力は秘密を含み、出力先は丸ごと作り直す。当て方は talos.md。
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
	sops -d bootstrap/talos-secrets.sops.yaml > "$SECRETS"
fi

# 手で書く部分。password の値だけ SOPS で暗号化してある(../.sops.yaml)。CI は ENC をダミーにしたものを渡す。
# `sops -d … > file` は失敗すると set -e で止まる(パイプに繋がない。pipefail が無い)。
CONTROLPLANE=${CONTROLPLANE:-}
if [ -z "$CONTROLPLANE" ]; then
	CONTROLPLANE=$WORK/controlplane.yaml
	sops -d bootstrap/talos.sops.yaml > "$CONTROLPLANE"
fi
! grep -q 'ENC\[' "$CONTROLPLANE" || { echo "ERROR: talos.sops.yaml に暗号文が残っている" >&2; exit 1; }

# キーを名前で引く(位置で数えるとブロックが増えたとき別の値を掴む)。yq は版で構文が違うので awk。
ver() { # $1=トップレベルのキー  $2=その下のキー
	awk -v top="$1:" -v key="  $2: " '$0 == top {f=1; next} /^[^ #]/ {f=0} f && index($0, key) == 1 {print substr($0, length(key)+1); exit}' bootstrap/versions.yaml
}
TALOS=$(ver talos version)
SCHEMATIC=$(ver talos schematic)
K8S=$(ver kubernetes version)
GWAPI=$(ver gatewayAPI version)
# chart の版は <name>-values.yaml の先頭の `# version:` の行(Renovate が上げる)。最初の 1 行だけ見る。
bver() { sed -n '/^# version: /{s/^# version: *//p;q;}' "bootstrap/$1-values.yaml"; }
CILIUM=$(bver cilium)
CERTMGR=$(bver cert-manager)
ARGOCD=$(bver argocd)
INFISICAL=$(bver infisical)
for v in "$TALOS" "$SCHEMATIC" "$K8S" "$GWAPI" "$CILIUM" "$CERTMGR" "$ARGOCD" "$INFISICAL"; do
	[ -n "$v" ] || { echo "ERROR: versions.yaml / *-values.yaml の # version: から版を読めなかった" >&2; exit 1; }
done
echo "talos=$TALOS k8s=$K8S gateway-api=$GWAPI"
echo "cilium=$CILIUM cert-manager=$CERTMGR argo-cd=$ARGOCD infisical-standalone=$INFISICAL"

inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

# helm の描き出しに namespace を補う(chart によっては書かず、Talos の適用では default に落ちる)。
add_namespace() { # $1=namespace  stdin=helm の描き出し
	awk -v ns="$1" '
BEGIN {
	# クラスタスコープのものには足さない(足すと API が弾く)
	split("Namespace ClusterRole ClusterRoleBinding CustomResourceDefinition " \
	      "ValidatingWebhookConfiguration MutatingWebhookConfiguration APIService " \
	      "StorageClass PriorityClass RuntimeClass IngressClass PersistentVolume " \
	      "ClusterIssuer CiliumClusterwideNetworkPolicy", a, " ")
	for (i in a) cluster[a[i]] = 1
	n = 0
}
/^---$/ { flush(); print; next }
{ buf[n++] = $0 }
END { flush() }

function flush(   i, kind, mi, hasns, inmeta) {
	if (n == 0) return
	kind = ""; mi = -1; hasns = 0; inmeta = 0
	for (i = 0; i < n; i++) {
		if (buf[i] ~ /^kind: /)     { kind = substr(buf[i], 7) }
		if (buf[i] ~ /^metadata:$/) { mi = i; inmeta = 1; continue }
		if (inmeta && buf[i] ~ /^[^ ]/) inmeta = 0
		if (inmeta && buf[i] ~ /^  namespace:/) hasns = 1
	}
	for (i = 0; i < n; i++) {
		print buf[i]
		if (i == mi && !hasns && kind != "" && !(kind in cluster))
			print "  namespace: " ns
	}
	n = 0
}'
}

# chart と repo は <name>-values.yaml の `# renovate:` の行から読む。
# kube-system 以外は Namespace を先頭に付ける(chart は描かず、最初は誰も作らない)。
# `updatedAt` は infisical の chart が付ける時刻(values で消せない)。残すと当て直すたびに再起動する。
chart() { # $1=name  $2=namespace  残り=helm template に足す引数
	_n=$1 _ns=$2
	shift 2
	_f=bootstrap/$_n-values.yaml
	_repo=$(sed -n 's/^# renovate:.* registryUrl=\([^ ]*\).*/\1/p' "$_f")
	_chart=$(sed -n 's/^# renovate:.* depName=\([^ ]*\).*/\1/p' "$_f")
	[ -n "$_repo" ] && [ -n "$_chart" ] \
		|| { echo "ERROR: $_f の # renovate: の行から chart と repo を読めなかった" >&2; exit 1; }
	helm repo add --force-update "$_n" "$_repo" >/dev/null
	{
		if [ "$_ns" != kube-system ]; then
			printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n---\n' "$_ns"
		fi
		helm template "$_n" "$_n/$_chart" \
			--version "$(bver "$_n")" -n "$_ns" -f "$_f" "$@" --kube-version "$K8S" \
			| sed '/^ *updatedAt: "/d' \
			| add_namespace "$_ns"
	} | inline "$_n" > "$WORK/inline-$_n.yaml"
	echo "  $_n -> $(wc -c < "$WORK/inline-$_n.yaml") バイト"
}

# `--api-versions` が無いと helm template は GatewayClass を黙って描かず、公開経路が全部死ぬ。
chart cilium kube-system --api-versions gateway.networking.k8s.io/v1/GatewayClass

inline local-path < bootstrap/local-path.yaml > "$WORK/inline-local-path.yaml"

# CI と人の RBAC。締め出されても直せるよう ArgoCD に載せない(ArgoCD は bootstrap/ を repos.yaml しか見ない)。
inline apiserver-rbac < bootstrap/apiserver-rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

# 秘密の値は <name>-secret-values.sops.yaml を <name>-values.yaml に重ねる。infisical は chart がパスワードを
# 平文 env に焼くので ArgoCD に置けない(../docs/decisions.md)。
secret_values() { # $1=name  $2=env の上書き
	if [ -n "$2" ]; then echo "$2"; return 0; fi
	sops -d "bootstrap/$1-secret-values.sops.yaml" > "$WORK/$1-secret-values.yaml"
	echo "$WORK/$1-secret-values.yaml"
}
# 先に変数に取る。`chart … -f "$(secret_values …)"` だと復号の失敗を `set -e` が拾わない
ARGOCD_SV=$(secret_values argocd "${ARGOCD_SECRET_VALUES:-}")
INFISICAL_SV=$(secret_values infisical "${INFISICAL_SECRET_VALUES:-}")
chart argocd argocd -f "$ARGOCD_SV"
chart infisical infisical -f "$INFISICAL_SV"

# CRD は URL で渡す(理由は argocd-values.yaml の `crds`)。版は chart の appVersion から取る。
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
inline_secret infisical-secrets bootstrap/infisical-secrets.sops.yaml "${INFISICAL_SECRET:-}"
inline_secret cloudflare-secret bootstrap/cert-manager-cloudflare-secret.sops.yaml "${CLOUDFLARE_SECRET:-}"

# cert-manager の CRD も URL(理由は cert-manager-values.yaml の `crds`)。
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
for f in "$CONTROLPLANE" "$WORK/gateway-api.yaml" "$WORK/external-crds.yaml" "$WORK"/inline-*.yaml; do
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
# Hubble の証明書はクラスタ内で作る(cilium-values.yaml の `hubble.tls`)
! grep -q '^    kind: Secret$' "$WORK/inline-cilium.yaml" \
	|| { echo "ERROR: cilium の inline に Secret(Hubble の証明書)が入っている" >&2; exit 1; }
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
