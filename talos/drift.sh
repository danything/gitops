#!/bin/sh
# **動いている machine config と、このリポジトリから作る machine config を比べる。読むだけ。**
#
# Talos では k3s の頃と違い、CNI も storage も machine config の inlineManifests に載る
# (render.sh)。つまり**ズレは git とノードの間で起きる** ── `talosctl apply-config` を
# 手で打ち忘れる、実機で `talosctl patch` して git に戻し忘れる、のどちらでも。
#
# **当てない。** machine config の適用は再起動を伴うことがあり、1 ノードでは即断になる。
# Talos API は mTLS だけで OIDC を受けないので、CI にも渡さない
# (.github/workflows/talos-validate.yml の「検出は自動、適用は手動」と同じ線)。
# これは**ホストから手で回す道具**で、ノードの os:admin 証明書を持っている人だけが使える。
#
#   ./talos/drift.sh                # talosconfig の既定のノード
#   ./talos/drift.sh 10.0.0.2       # ノードを指定
#
# 出力は diff。**何も出なければ一致**。終了コードは一致 0 / ズレ 1(cron に置ける)。
set -eu

NODE=${1:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

command -v talosctl >/dev/null || { echo "talosctl がない" >&2; exit 2; }
command -v yq >/dev/null || { echo "yq がない" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# 1. git から作る。**本番と同じ道具で**(render.sh は Cilium と local-path を描いてから組む)
./talos/render.sh "$WORK/rendered" >/dev/null

# 2. ノードから取る。`get machineconfig` は資源の器に入って返るので中身(.spec)だけ出す
# shellcheck disable=SC2086
talosctl ${NODE:+-n "$NODE"} get machineconfig v1alpha1 -o yaml \
	| yq -e '.spec' > "$WORK/live.yaml"

# 3. 秘密と、比べても意味のないものを両方から落としてから比べる。
#
#    **鍵と証明書は落とす** — ノードのものが正で、git の側は render.sh が
#    talos/secrets.yaml から毎回描くため、同じでも表現が揺れる。ここで見たいのは
#    「設定がズレていないか」であって鍵の一致ではない。
#    **version は落とす** — 資源の版はノード側にしか無い。
strip() {
	yq -P '
		del(.machine.token, .machine.ca, .machine.certSANs,
		    .cluster.id, .cluster.secret, .cluster.token, .cluster.ca,
		    .cluster.aggregatorCA, .cluster.serviceAccount, .cluster.secretboxEncryptionSecret,
		    .cluster.etcd.ca, .cluster.apiServer.admissionControl,
		    .machine.registries.config.*.auth) |
		sort_keys(..)
	' "$1"
}

strip "$WORK/rendered/controlplane.yaml" > "$WORK/a.yaml"
strip "$WORK/live.yaml" > "$WORK/b.yaml"

if diff -u --label "git (talos/render.sh)" "$WORK/a.yaml" --label "node" "$WORK/b.yaml"; then
	echo "一致(ズレなし)"
	exit 0
fi

cat >&2 <<'MSG'

ズレている。当てるなら(再起動が要ることがある):

  ./talos/render.sh /tmp/talos-config
  talosctl apply-config -n <node> -f /tmp/talos-config/controlplane.yaml

逆にノード側が正なら、patches/ を直して git に戻すこと。
MSG
exit 1
