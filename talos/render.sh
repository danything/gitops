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

SECRETS=${SECRETS:-}
if [ -z "$SECRETS" ]; then
	SECRETS=$(mktemp)
	trap 'rm -f "$SECRETS"' EXIT INT TERM
	sops -d talos/secrets.yaml > "$SECRETS"
fi

TALOS=$(sed -n 's/^  version: \(v.*\)$/\1/p' talos/versions.yaml | head -1)
SCHEMATIC=$(sed -n 's/^  schematic: \(.*\)$/\1/p' talos/versions.yaml | head -1)
K8S=$(sed -n 's/^  version: \(v.*\)$/\1/p' talos/versions.yaml | tail -1)
CILIUM=$(sed -n 's/^version: \(.*\)$/\1/p' bootstrap/cilium/version.yaml)
echo "talos=$TALOS k8s=$K8S cilium=$CILIUM"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${SECRETS:-}" ] && rm -f "$SECRETS"' EXIT INT TERM

# --- inlineManifest を描く -------------------------------------------------
# `helm template` の出力をそのまま KubeInlineManifestConfig に包む。
inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || true
helm template cilium cilium/cilium --version "$CILIUM" -n kube-system \
	-f bootstrap/cilium/values.yaml --kube-version "$K8S" \
	| inline cilium > "$WORK/inline-cilium.yaml"

inline local-path < talos/manifests/local-path.yaml > "$WORK/inline-local-path.yaml"

# --- 組み立て --------------------------------------------------------------
set -- --with-secrets "$SECRETS" \
	--kubernetes-version "$K8S" \
	--install-image "factory.talos.dev/installer/${SCHEMATIC}:${TALOS}"
for f in talos/patches/*.yaml; do set -- "$@" --config-patch "@$f"; done
for f in "$WORK"/inline-*.yaml; do set -- "$@" --config-patch "@$f"; done

rm -rf "$OUT"
talosctl gen config doany https://10.0.0.2:6443 "$@" --output-dir "$OUT" >/dev/null
echo "wrote $OUT/controlplane.yaml ($(wc -l < "$OUT/controlplane.yaml") 行)"

# 描いたものが本当に入ったか。gen config は知らないキーを黙って捨てることがある。
for n in 'name: cilium' 'name: local-path' 'cilium-operator' 'rancher.io/local-path'; do
	grep -qF "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
