#!/bin/sh
# machine config を作る。手で書く部分(patches/)と、他から描いてくる部分
# (Cilium・local-path-provisioner)を 1 か所で組む。
#
# 値を二度書かないための道具。Cilium の設定は bootstrap/cilium/values.yaml が
# 正本で、machine config はそこから描いた派生物にする。手で合わせない
# (../docs/decisions.md「machine config と Cilium の chart をどう連動させるか」)。
#
#   ./talos/render.sh talos/clusterconfig
#
# SOPS ファイルは自分で復号する(age の鍵が要る)。CI は鍵を持たないので SECRETS / REGISTRIES などの
# env にダミーを渡し、そのときは復号しない。出力は秘密を含む。出力先は丸ごと消して作り直す。
# 当て方は talos/README.md「上げ方 / 当て直し方」。
set -eu

OUT=${1:?usage: render.sh <output-dir>}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
# 呼び出し側から渡された SECRETS は消さない。自分で作ったものだけ片付ける。
OWN_SECRETS=
# 最後を `[ -n ... ] &&` で終えないこと。EXIT トラップの戻り値がスクリプトの
# 終了コードになるので、`OWN_SECRETS` が空だとテストが偽になって 1 で落ちる
# (CI が `SECRETS` を渡す場合がまさにそれ。実際に踏んだ)。
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

# fj.doany.io のイメージ取得の資格情報(talos/README.md「fj.doany.io の資格情報」)。
# CI には age の鍵を渡さないので、`REGISTRIES` にダミーを入れて経路だけ通す。
REGISTRIES=${REGISTRIES:-}
if [ -z "$REGISTRIES" ]; then
	REGISTRIES=$WORK/registries.yaml
	sops -d talos/registries.yaml > "$REGISTRIES"
fi

# キーを名前で引く。「1 つ目の version」「最後の version」で数えていると、
# versions.yaml にブロックが増えた瞬間に静かに別の値を掴む。
# `yq` は使わない(版で構文が違うので、どこで回しても同じに動く awk にしてある)。
ver() { # $1=トップレベルのキー  $2=その下のキー
	awk -v top="$1:" -v key="  $2: " '$0 == top {f=1; next} /^[^ #]/ {f=0} f && index($0, key) == 1 {print substr($0, length(key)+1); exit}' talos/versions.yaml
}
TALOS=$(ver talos version)
SCHEMATIC=$(ver talos schematic)
K8S=$(ver kubernetes version)
GWAPI=$(ver gatewayAPI version)
# bootstrap/<name>/version.yaml の版(Renovate が上げる)
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

# --- inlineManifest を描く -------------------------------------------------
# `helm template` の出力をそのまま KubeInlineManifestConfig に包む。
inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

# bootstrap/<name>/ の chart を描いて inlineManifest にする。chart と repo は version.yaml の
# `# renovate:` の行から、値は values.yaml から読む。値をここに写さない(../docs/decisions.md)。
# namespace.yaml があれば先頭に付ける。chart は Namespace を描かないし、ArgoCD は
# machine config の中にいるので、machine config が最初に流れる時点では誰も作っていない。
# `updatedAt` は infisical の chart が描いた時刻を Deployment と Pod に付ける注釈(values では消せない)。
# 残すと描くたびに差分が出て、当て直すたびに infisical が再起動するので落とす。
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

# `--api-versions` は GatewayClass `cilium` のため。chart は Gateway API の CRD が「ある」ときだけ
# GatewayClass を描くが、`helm template` はクラスタを見ないので、渡さないと黙って抜ける。
# 抜けると Gateway が `Waiting for controller` のまま公開経路が全部死ぬ(2026-10-17 に踏んだ)。
# 下の needle で GatewayClass があることを見る。
chart cilium kube-system --api-versions gateway.networking.k8s.io/v1/GatewayClass

inline local-path < talos/manifests/local-path.yaml > "$WORK/inline-local-path.yaml"

# GitHub Actions(cilium-drift)と人(Entra)の RBAC。認証の設定と同じく、ArgoCD も CI も要らない層に置く
# (締め出されたときに直せる)。bootstrap/argocd/repos.yaml の `bootstrap` は apiserver/ を外している。
# 認証の側(OIDC の issuer)は patches/apiserver.yaml の KubeAuthenticationConfig。
inline apiserver-rbac < bootstrap/apiserver/rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

# 値のうち秘密だけは secret-values.yaml(SOPS)にあり、復号して values.yaml の上に重ねる。
# CI は鍵を持たないので `ARGOCD_SECRET_VALUES` / `INFISICAL_SECRET_VALUES` にダミーを渡す
# (SECRETS / REGISTRIES と同じ)。
#
# infisical はここに来るしかない。chart が DB と Redis のパスワードを
# Deployment の平文 env に焼き込むので、ArgoCD の Application には置けない
# (../docs/decisions.md「infisical だけは ArgoCD に移せない」)。
secret_values() { # $1=name  $2=env の上書き
	if [ -n "$2" ]; then echo "$2"; return 0; fi
	sops -d "bootstrap/$1/secret-values.yaml" > "$WORK/$1-secret-values.yaml"
	echo "$WORK/$1-secret-values.yaml"
}
# 先に変数に取る。`chart … -f "$(secret_values …)"` だと復号の失敗を `set -e` が拾わない
ARGOCD_SV=$(secret_values argocd "${ARGOCD_SECRET_VALUES:-}")
INFISICAL_SV=$(secret_values infisical "${INFISICAL_SECRET_VALUES:-}")
chart argocd argocd -f "$ARGOCD_SV"
chart infisical infisical -f "$INFISICAL_SV"

# ArgoCD の CRD は URL で渡す(理由は bootstrap/argocd/values.yaml の `crds`)。
# 版は chart の appVersion をそのまま使う。版を 2 つ持つと必ずずれる。
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

# cert-manager も bootstrap/ にいる。無いと証明書が 1 枚も発行されず、
# Gateway の HTTPS リスナーに載せる Secret ができない。
chart cert-manager cert-manager

# SOPS 済みの Secret も入れる。infisical/secrets.yaml は infisical の起動に要る
# (kubeSecretRef)ので、machine config に無いと起動しない。どちらも ArgoCD は復号できない。cloudflare-secret.yaml は
# DNS-01 の資格情報。machine config はもともと秘密の塊なので信頼水準は変わらない。
# `sops -d … | inline` と繋がないこと。`#!/bin/sh` には `pipefail` が無いので、
# 復号に失敗しても `set -e` が拾わず、中身が空の KubeInlineManifestConfig が
# 黙って出る。そして下の needle は `inline` が付ける `name:` しか見ないので通ってしまう
# (chart の方は `cilium-operator` のような中身を見ているので気づける)。
# いったんファイルに落とす。
inline_secret() { # $1=inline の名前  $2=SOPS ファイル  $3=env の上書き
	if [ -n "$3" ]; then
		inline "$1" < "$3" > "$WORK/inline-$1.yaml"
		return 0
	fi
	sops -d "$2" > "$WORK/plain-$1.yaml"
	inline "$1" < "$WORK/plain-$1.yaml" > "$WORK/inline-$1.yaml"
}
inline_secret infisical-secrets bootstrap/infisical/secrets.yaml "${INFISICAL_SECRET:-}"
inline_secret cloudflare-secret bootstrap/cert-manager/cloudflare-secret.yaml "${CLOUDFLARE_SECRET:-}"

# cert-manager の CRD も URL で渡す(理由は bootstrap/cert-manager/values.yaml の `crds`)。
cat >> "$WORK/external-crds.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: cert-manager-crds
url: https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR}/cert-manager.crds.yaml
---
PATCH

# Gateway API の CRD。無いと Gateway も HTTPRoute も適用できず公開経路が消える。
# Cilium の chart は CRD を同梱しない (gatewayAPI.enabled は「入れてある前提」)。
# standard-install.yaml は 10 個とも持っているので experimental の bundle は要らない。
# 埋めずに URL で渡す理由は ../docs/decisions.md「層の分け方」。
cat > "$WORK/gateway-api.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: gateway-api
url: https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI}/standard-install.yaml
PATCH

# --- 組み立て --------------------------------------------------------------
set -- --with-secrets "$SECRETS" \
	--kubernetes-version "$K8S" \
	--install-image "factory.talos.dev/installer/${SCHEMATIC}:${TALOS}"
for f in talos/patches/*.yaml "$REGISTRIES" "$WORK/gateway-api.yaml" "$WORK/external-crds.yaml" "$WORK"/inline-*.yaml; do
	set -- "$@" --config-patch "@$f"
done

rm -rf "$OUT"
talosctl gen config doany https://10.0.0.2:6443 "$@" --output-dir "$OUT" >/dev/null
echo "wrote $OUT/controlplane.yaml ($(wc -l < "$OUT/controlplane.yaml") 行)"

# 描いたものが本当に入ったか。gen config は知らないキーを黙って捨てることがある。
# 生成物では manifest が 1 行のエスケープ文字列になるので、引用符は \" で探す。
for n in "kube-apiserver:$K8S" "ghcr.io/siderolabs/kubelet:$K8S" \
	ks.doany.io token.actions.githubusercontent.com 'claims.repository == "danything/gitops"' \
	'gha:danything/gitops:refs/heads/main' login.microsoftonline.com 'entra:admin' 'entra:viewer' \
	'service-node-port-range: 80-32767' cilium-drift.yml 'enabled: false # Enable or disable kube-proxy' \
	balance-alb /var/mnt/local-path 'name: EPHEMERAL' 'maxSize: 64GiB' 'secure: false' \
	'name: cilium' cilium-operator KUBERNETES_SERVICE_PORT 'value: \"7445\"' 'cgroup-root: \"/sys/fs/cgroup\"' \
	'kind: GatewayClass' io.cilium/gateway-controller \
	'name: local-path' rancher.io/local-path \
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
	# `--` を付けておく(`-` で始まる needle を grep がオプションと取る)
	grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done
# machine.registries のキー。fj.doany.io は StaticHostConfig にも出るので行ごと見る
grep -qx '            fj.doany.io:' "$OUT/controlplane.yaml" \
	|| { echo "ERROR: machine.registries に fj.doany.io が無い" >&2; exit 1; }
# 無いことを見る側。flannel は「ドキュメントが在ること」が有効化の意味(talos/patches/cni.yaml)
for n in KubeFlannelCNIConfig /var/local-path-provisioner; do
	! grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に残っている" >&2; exit 1; }
done
# CRD は URL 側。入ると argocd は 1.83 MB、cert-manager は 1.30 MB 増える(bootstrap/argocd/values.yaml、
# bootstrap/cert-manager/values.yaml)。生成物は 1 行のエスケープ文字列になるので、包む前のファイルを見る。
for c in argocd cert-manager; do
	! grep -q 'kind: CustomResourceDefinition' "$WORK/inline-$c.yaml" \
		|| { echo "ERROR: $c の CRD が inline に入っている" >&2; exit 1; }
done
# Hubble の証明書はクラスタの中で作る(bootstrap/cilium/values.yaml の `hubble.tls`)。chart が Secret を描くのは
# `helm` 方式に戻ったとき
! grep -q '^    kind: Secret$' "$WORK/inline-cilium.yaml" \
	|| { echo "ERROR: cilium の inline に Secret(Hubble の証明書)が入っている" >&2; exit 1; }
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
