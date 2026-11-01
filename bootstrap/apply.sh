#!/bin/sh
# machine config を描いて、そのまま当てる(talos.md「当て方」)。引数は talosctl apply-config に渡す:
#   tools/t --admin bootstrap/apply.sh --dry-run                     # 差分だけ見る
#   tools/t --admin bootstrap/apply.sh --mode=try --timeout 10m      # 試しに当てる(確定は --mode=no-reboot で当て直す)
#   tools/t --admin bootstrap/apply.sh --mode=no-reboot
#   tools/t --admin bootstrap/apply.sh --insecure -n <IP> -e <IP>    # maintenance mode のノード(recovery/README.md の 3)
# 描いたものは秘密を平文で含むので、コンテナの tmpfs(/dev/shm)に置いて、終わったら消す。手元のディスクには書かない。
# 中身を見たいときは `tools/t --admin sh -c './bootstrap/render.sh /dev/shm/c && less /dev/shm/c/controlplane.yaml'`。
set -eu
cd "$(dirname -- "$0")/.."
out=$(mktemp -d /dev/shm/clusterconfig.XXXXXX)
trap 'rm -rf "$out"' EXIT INT TERM
./bootstrap/render.sh "$out"
talosctl apply-config "$@" -f "$out/controlplane.yaml"
