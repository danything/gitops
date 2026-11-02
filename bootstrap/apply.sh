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
# render.sh の作業場所(復号した入力を置く)も tmpfs に
export TMPDIR=/dev/shm
trap 'rm -rf "$out"' EXIT
trap 'exit 130' INT TERM
./bootstrap/render.sh "$out"
# **--dry-run の差分は、変わった inlineManifests(Secret を含む)を平文で出す。** 2026-11-02 にクラスタの age の鍵が
# 端末に出て、そのまま貼られて作り直した。age の鍵と、名前が鍵・トークン・パスワードらしい行の値は伏せる。
# 伏せきれないものもあるので、--dry-run の出力は人に見せない・貼らない
case " $* " in
*" --dry-run "*)
	talosctl apply-config "$@" -f "$out/controlplane.yaml" 2>&1 | sed -E \
		-e 's/AGE-SECRET-KEY-[0-9A-Z]+/AGE-SECRET-KEY-<伏せた>/g' \
		-e 's/^([+-]? +[A-Za-z0-9_.-]*(key|Key|KEY|token|Token|TOKEN|password|Password|PASSWORD|secret|Secret|SECRET)[A-Za-z0-9_.-]*: ).+/\1<伏せた>/' ;;
*) talosctl apply-config "$@" -f "$out/controlplane.yaml" ;;
esac
