#!/bin/sh
# **machine config を作る。** 手で書く部分(patches/)と、他から描いてくる部分
# (Cilium・local-path-provisioner)を 1 か所で組む。
#
# **値を二度書かないための道具。** Cilium の設定は bootstrap/cilium/values.yaml が
# 正本で、machine config はそこから描いた派生物にする。手で合わせない
# (../docs/decisions.md「machine config と Cilium の chart をどう連動させるか」)。
#
#   ./talos/render.sh /tmp/talos-config
#
# 秘密は talos/secrets.yaml(SOPS)。復号は呼び出し側でやる ── このスクリプトは
# 平文を書き出さない。
#
# **`talosctl upgrade-k8s` の前にも実行すること。** upgrade-k8s は inlineManifests を
# reconcile するので、古い machine config のまま流すと Cilium が巻き戻る。
set -eu

OUT=${1:?usage: render.sh <output-dir>}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
# **呼び出し側から渡された SECRETS は消さない。** 自分で作ったものだけ片付ける。
OWN_SECRETS=
# **最後を `[ -n ... ] &&` で終えないこと。** EXIT トラップの戻り値がスクリプトの
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

# **ghcr.io の pull 資格情報。** k3s 期はホストの /etc/rancher/k3s/registries.yaml に
# 置いていたもので、**ノード単位で持つので namespace ごとの imagePullSecrets が要らない。**
# 無いと danything の private なリポジトリから出ているイメージが引けない。
# 値は Infisical の /worklog/ghcr-pull と同じ PAT。
#
# **平文は書き出さない**ので、talos/registries.yaml(SOPS で丸ごと暗号化)を復号して渡す。
# CI には age の鍵を渡さないので、`REGISTRIES` にダミーを入れて経路だけ通す。
REGISTRIES=${REGISTRIES:-}
if [ -z "$REGISTRIES" ]; then
	if [ -f talos/registries.yaml ]; then
		REGISTRIES=$WORK/registries.yaml
		sops -d talos/registries.yaml > "$REGISTRIES"
	else
		# **止めない。** このファイルが無くても他は描けるので、作る前でも作業は進む。
		# ただし気づかず焼くと private イメージが全部 ImagePullBackOff になるので、
		# はっきり言う(talos/README.md「ghcr.io の資格情報」)。
		echo "WARNING: talos/registries.yaml が無い。ghcr.io の private イメージが引けない構成になる" >&2
	fi
fi

# **キーを名前で引く。** 「1 つ目の version」「最後の version」で数えていると、
# versions.yaml にブロックが増えた瞬間に静かに別の値を掴む。
# `yq` は使わない ── サーバに入っているのが v3 で構文が違う。
ver() { # $1=トップレベルのキー  $2=その下のキー
	awk -v top="$1:" -v key="  $2: " '$0 == top {f=1; next} /^[^ #]/ {f=0} f && index($0, key) == 1 {print substr($0, length(key)+1); exit}' talos/versions.yaml
}
TALOS=$(ver talos version)
SCHEMATIC=$(ver talos schematic)
K8S=$(ver kubernetes version)
METRICS=$(ver metricsServer version)
CILIUM=$(sed -n 's/^version: \(.*\)$/\1/p' bootstrap/cilium/version.yaml)
for v in "$TALOS" "$SCHEMATIC" "$K8S" "$METRICS" "$CILIUM"; do
	[ -n "$v" ] || { echo "ERROR: versions.yaml から版を読めなかった" >&2; exit 1; }
done
echo "talos=$TALOS k8s=$K8S cilium=$CILIUM metrics-server=$METRICS"

# --- inlineManifest を描く -------------------------------------------------
# `helm template` の出力をそのまま KubeInlineManifestConfig に包む。
inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || true
# **値は 2 枚重ね。** 正本は bootstrap/cilium/values.yaml で、Talos で変わるところだけを
# talos/cilium-values.yaml が上書きする(KubePrism と cgroup)。**これを忘れると
# k3s 向けの 127.0.0.1:6443 が埋まったまま出てきて、Talos で Cilium が上がらない。**
helm template cilium cilium/cilium --version "$CILIUM" -n kube-system \
	-f bootstrap/cilium/values.yaml -f talos/cilium-values.yaml \
	--kube-version "$K8S" \
	| inline cilium > "$WORK/inline-cilium.yaml"

inline local-path < talos/manifests/local-path.yaml > "$WORK/inline-local-path.yaml"

# **CI は自分の権限を作れない。** bootstrap-apply.yml が使う `bootstrap-applier` の
# ClusterRole/ClusterRoleBinding は、**当のワークフローに当てさせるわけにいかない**
# (自分の権限を書き換えられてしまうので、あちらは bootstrap/apiserver/ を除外している)。
# k3s 期は手で当てていた。Talos では machine config が持つ。
#
# **`bootstrap/apiserver/rbac.yaml` が正本。** ここでは写さずに描いてくる
# ([../bootstrap/apiserver/rbac.yaml](../bootstrap/apiserver/rbac.yaml))。
# authentication-config.yaml の方は patches/apiserver.yaml の `KubeAuthenticationConfig`
# に移してあるので、ここには来ない。
inline apiserver-rbac < bootstrap/apiserver/rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

# **metrics-server も Talos には無い。** k3s では組み込みのアドオンだった。
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null 2>&1 || true
helm template metrics-server metrics-server/metrics-server --version "$METRICS" \
	-n kube-system -f talos/metrics-server-values.yaml --kube-version "$K8S" \
	| inline metrics-server > "$WORK/inline-metrics-server.yaml"

# --- 組み立て --------------------------------------------------------------
set -- --with-secrets "$SECRETS" \
	--kubernetes-version "$K8S" \
	--install-image "factory.talos.dev/installer/${SCHEMATIC}:${TALOS}"
for f in talos/patches/*.yaml; do set -- "$@" --config-patch "@$f"; done
if [ -n "$REGISTRIES" ]; then set -- "$@" --config-patch "@$REGISTRIES"; fi
for f in "$WORK"/inline-*.yaml; do set -- "$@" --config-patch "@$f"; done

rm -rf "$OUT"
talosctl gen config doany https://10.0.0.2:6443 "$@" --output-dir "$OUT" >/dev/null
echo "wrote $OUT/controlplane.yaml ($(wc -l < "$OUT/controlplane.yaml") 行)"

# 描いたものが本当に入ったか。gen config は知らないキーを黙って捨てることがある。
# **生成物では manifest が 1 行のエスケープ文字列になる**ので、引用符は \" で探す。
for n in 'name: cilium' 'name: local-path' 'cilium-operator' 'rancher.io/local-path' \
	'KUBERNETES_SERVICE_PORT' 'value: \"7445\"' 'cgroup-root: \"/sys/fs/cgroup\"' \
	'name: metrics-server' 'system:metrics-server' '--kubelet-insecure-tls' \
	'/var/mnt/local-path' 'name: EPHEMERAL' 'maxSize: 64GiB' 'secure: false' \
	'name: apiserver-rbac' 'bootstrap-applier' \
	"ghcr.io/siderolabs/kubelet:$K8S"; do
	# **`--` を忘れないこと。** `--kubelet-insecure-tls` のような needle を
	# grep がオプションとして解釈して落ちる。
	grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
