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
#
# **`yq` は使わない。** サーバに入っているのは v3(jq 構文)で、v4 の式は動かない
# ── render.sh が awk で組んでいるのと同じ理由。ここは python3 + PyYAML(どちらも
# サーバにある)で読む。
set -eu

NODE=${1:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

command -v talosctl >/dev/null || { echo "talosctl がない" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 がない" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "python3 の PyYAML がない" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# 1. git から作る。**本番と同じ道具で**(render.sh は Cilium と local-path を描いてから組む)
./talos/render.sh "$WORK/rendered" >/dev/null

# 2. ノードから取る。`get machineconfig` は資源の器に入って返るので、中身だけ取り出す
# shellcheck disable=SC2086
talosctl ${NODE:+-n "$NODE"} get machineconfig v1alpha1 -o yaml > "$WORK/live-raw.yaml"

# 3. 秘密と、比べても意味のないものを両方から落としてから並べる。
#
#    **鍵と証明書は落とす** — ノードのものが正で、git の側は render.sh が
#    talos/secrets.yaml から毎回描く。ここで見たいのは「設定がズレていないか」であって
#    鍵の一致ではない。**資源の器(metadata・version)も落とす** — ノード側にしか無い。
cat > "$WORK/norm.py" <<'PY'
import sys

import yaml

# 落とす場所。("a", "b") は a.b、"*" はその階層の全部
DROP = [
    ("machine", "token"),
    ("machine", "ca"),
    ("machine", "certSANs"),
    ("machine", "registries", "config", "*", "auth"),
    ("cluster", "id"),
    ("cluster", "secret"),
    ("cluster", "token"),
    ("cluster", "ca"),
    ("cluster", "aggregatorCA"),
    ("cluster", "serviceAccount"),
    ("cluster", "secretboxEncryptionSecret"),
    ("cluster", "etcd", "ca"),
]


def drop(node, path):
    if not isinstance(node, dict):
        return
    head, rest = path[0], path[1:]
    keys = list(node) if head == "*" else [head]
    for key in keys:
        if key not in node:
            continue
        if rest:
            drop(node[key], rest)
        else:
            del node[key]


def machine_config(doc):
    """`talosctl get machineconfig` の器から中身を出す。素の machine config はそのまま"""
    if not isinstance(doc, dict):
        return None
    spec = doc.get("spec")
    if spec is None:
        return doc if "machine" in doc else None
    # 版によって spec が YAML 文字列のことがある
    return yaml.safe_load(spec) if isinstance(spec, str) else spec


config = None
for doc in yaml.safe_load_all(sys.stdin):
    found = machine_config(doc)
    if found and "machine" in found:
        config = found
        break
if config is None:
    sys.exit("machine config を読めなかった")

for path in DROP:
    drop(config, path)
yaml.safe_dump(config, sys.stdout, sort_keys=True, allow_unicode=True, default_flow_style=False)
PY

python3 "$WORK/norm.py" < "$WORK/rendered/controlplane.yaml" > "$WORK/a.yaml"
python3 "$WORK/norm.py" < "$WORK/live-raw.yaml" > "$WORK/b.yaml"

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
