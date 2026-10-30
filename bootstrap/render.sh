#!/bin/sh
# machine config を作る: ./bootstrap/render.sh bootstrap/clusterconfig
# chart の値と版は bootstrap/<name>-values(.sops).yaml、Talos などの版は talos.sops.yaml の先頭のコメントが正本。ここに写さない(../docs/decisions.md)。
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

# 版はどれもコメントの `# renovate:` の次の `# version:` の行(Renovate が上げる)。
# Talos・Kubernetes・Gateway API は talos.sops.yaml の先頭。depName で引く(位置で数えると行が増えたとき別の版を掴む)。
tver() { # $1=depName
	awk -v dep="depName=$1" 'f {if (sub(/^# version: */, "")) print; exit} /^# renovate: / && $NF == dep {f=1}' bootstrap/talos.sops.yaml
}
TALOS=$(tver siderolabs/talos)
SCHEMATIC=$(sed -n '/^# schematic: /{s/^# schematic: *//p;q;}' bootstrap/talos.sops.yaml)
K8S=$(tver kubernetes/kubernetes)
GWAPI=$(tver kubernetes-sigs/gateway-api)
# chart の値は <name>-values.yaml、秘密を含むものは <name>-values.sops.yaml(秘密のキーだけ SOPS)。
vfile() { # $1=name
	if [ -f "bootstrap/$1-values.sops.yaml" ]; then echo "bootstrap/$1-values.sops.yaml"; else echo "bootstrap/$1-values.yaml"; fi
}
# chart の版はその先頭の `# version:`。最初の 1 行だけ見る。
bver() { sed -n '/^# version: /{s/^# version: *//p;q;}' "$(vfile "$1")"; }
CILIUM=$(bver cilium)
CERTMGR=$(bver cert-manager)
ARGOCD=$(bver argocd)
INFISICAL=$(bver infisical)
for v in "$TALOS" "$SCHEMATIC" "$K8S" "$GWAPI" "$CILIUM" "$CERTMGR" "$ARGOCD" "$INFISICAL"; do
	[ -n "$v" ] || { echo "ERROR: talos.sops.yaml / <name>-values(.sops).yaml の # version: から版を読めなかった" >&2; exit 1; }
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

# <name>-values.sops.yaml は先に復号して $WORK/<name>-values.yaml に置く。2 つめのドキュメントがあれば、それは
# machine config に別に載せる Secret(ArgoCD は復号できない)なので $WORK/<name>-secret.yaml に分ける。
# CI は鍵が無いので <NAME>_VALUES に平文(ENC[…] をダミーにしたもの)を渡す。
# `sops -d … | awk` と繋がない: pipefail が無いので、復号に失敗しても空のまま黙って進む。
decrypt() { # $1=name  $2=env の上書き
	if [ -n "$2" ]; then
		cp "$2" "$WORK/$1-all.yaml"
	else
		sops -d "bootstrap/$1-values.sops.yaml" > "$WORK/$1-all.yaml"
	fi
	! grep -q 'ENC\[' "$WORK/$1-all.yaml" || { echo "ERROR: $1-values.sops.yaml に暗号文が残っている" >&2; exit 1; }
	awk -v v="$WORK/$1-values.yaml" -v s="$WORK/$1-secret.yaml" \
		'NR == 1 && $0 == "---" {next} !d && $0 == "---" {d=1; next} {print > (d ? s : v)}' "$WORK/$1-all.yaml"
}
decrypt argocd "${ARGOCD_VALUES:-}"
decrypt infisical "${INFISICAL_VALUES:-}"
decrypt cert-manager "${CERT_MANAGER_VALUES:-}"

# chart と repo は <name>-values(.sops).yaml の `# renovate:` の行から読む。
# kube-system 以外は Namespace を先頭に付ける(chart は描かず、最初は誰も作らない)。
# `updatedAt` は infisical の chart が付ける時刻(values で消せない)。残すと当て直すたびに再起動する。
chart() { # $1=name  $2=namespace  残り=helm template に足す引数
	_n=$1 _ns=$2
	shift 2
	_f=$(vfile "$_n")
	_v=$_f
	case $_f in *.sops.yaml) _v=$WORK/$_n-values.yaml ;; esac
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
			--version "$(bver "$_n")" -n "$_ns" -f "$_v" "$@" --kube-version "$K8S" \
			| sed '/^ *updatedAt: "/d' \
			| add_namespace "$_ns"
	} | inline "$_n" > "$WORK/inline-$_n.yaml"
	echo "  $_n -> $(wc -c < "$WORK/inline-$_n.yaml") バイト"
}

# `--api-versions` が無いと helm template は GatewayClass を黙って描かず、公開経路が全部死ぬ。
chart cilium kube-system --api-versions gateway.networking.k8s.io/v1/GatewayClass

inline local-path < bootstrap/local-path.yaml > "$WORK/inline-local-path.yaml"

# CI と人の RBAC。締め出されても直せるよう ArgoCD に載せない(ArgoCD は bootstrap/ を argocd-repos.yaml しか見ない)。
inline apiserver-rbac < bootstrap/apiserver-rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

chart argocd argocd
# infisical は chart がパスワードを平文 env に焼くので ArgoCD に置けない(../docs/decisions.md)。
chart infisical infisical

# CRD は URL で渡す(理由は argocd-values.sops.yaml の `crds`)。版は chart の appVersion から取る。
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

# ArgoCD が復号できない Secret(infisical の起動用と DNS-01 用)。<name>-values.sops.yaml の 2 つめのドキュメント
# (上の decrypt が分けたもの。無ければ `<` が失敗して止まる)。
inline infisical-secrets < "$WORK/infisical-secret.yaml" > "$WORK/inline-infisical-secrets.yaml"
inline cloudflare-secret < "$WORK/cert-manager-secret.yaml" > "$WORK/inline-cloudflare-secret.yaml"

# cert-manager の CRD も URL(理由は cert-manager-values.sops.yaml の `crds`)。
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
