#!/bin/sh
# restore.sh: まっさらなホストを、restic のバックアップ(backup/k3s-backup が取ったもの)から
# 元の k3s ホストに戻す。秘密は一切含まないので公開しておいてよい。
#
# 必要なのは age のパスフレーズ 1 つ。秘密(R2 の鍵と restic のパスワード)は同じ repo の env.age に
# 暗号化して置いてあり、既定でそれを取りに行く。
#
#   curl -fsSLO https://raw.githubusercontent.com/danything/gitops/main/recovery/restore.sh
#   sudo sh restore.sh          # パスフレーズを聞かれる
#
#   別の env.age を使うなら ENV_AGE=<path か URL>。
#   パスフレーズも env.age も無い場合は環境変数で直接渡す:
#
#       sudo env RESTIC_REPOSITORY=s3:https://... RESTIC_PASSWORD=... \
#                AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=auto \
#                sh restore.sh
#
# 流れ: restic を入れる → 最新スナップショットを / に展開(PVC データ、k3s の証明書、
# k3s と NetworkManager の設定、バックアップ timer 一式)→ 同じバージョンの k3s を「起動せず」に入れる
# → state.db を差し替える → ネットワーク設定を適用して k3s を起動。
# 最後の段は SSH が切れても止まらないよう systemd-run で切り離す。切れたら 10.0.0.2 か 10.10.0.4 に入り直す。
#
# 既に k3s が入っているホストでは動かない(上書き再構築はしない)。
# やり直すなら先に sudo /usr/local/bin/k3s-uninstall.sh。

set -eu

SNAP_DIR=/var/lib/k3s-backup
STATE_DB=/var/lib/rancher/k3s/server/db/state.db
SNAPSHOT="${RESTIC_SNAPSHOT:-latest}"
# RESTORE_DRILL=1: 復元リハーサル(VM)用。実機のネットワーク設定(bond0 / eno4)は当てず、k3s の flannel-iface を外し、
# バックアップ timer は有効にしない(本番のリポジトリに VM のスナップショットを混ぜないため)。
DRILL="${RESTORE_DRILL:-0}"
ENV_AGE="${ENV_AGE:-https://raw.githubusercontent.com/danything/gitops/main/recovery/env.age}"
TAG=k3s-host

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo sh $0" >&2; exit 1; }

# --- 0) secrets: env.age を復号して /etc/k3s-backup/env に置く(復元後の timer もこれを使う) -----
# 優先順: 環境変数 RESTIC_REPOSITORY > 既に置いてある /etc/k3s-backup/env > ENV_AGE を復号。
if [ -z "${RESTIC_REPOSITORY:-}" ] && [ ! -f /etc/k3s-backup/env ] && [ -n "$ENV_AGE" ]; then
	command -v age >/dev/null 2>&1 || { command -v dnf >/dev/null 2>&1 && dnf install -y age || apt-get install -y age; }
	mkdir -p /etc/k3s-backup && chmod 700 /etc/k3s-backup
	case "$ENV_AGE" in
		http://*|https://*) curl -fsSL "$ENV_AGE" | age -d -o /etc/k3s-backup/env ;;
		*) age -d -o /etc/k3s-backup/env "$ENV_AGE" ;;
	esac
	chmod 600 /etc/k3s-backup/env
fi
if [ -f /etc/k3s-backup/env ]; then
	set -a
	. /etc/k3s-backup/env
	set +a
fi
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY (or ENV_AGE=path-to-env.age)}" "${RESTIC_PASSWORD:?set RESTIC_PASSWORD}"
case "$RESTIC_REPOSITORY" in
	s3:*) : "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}" ;;
esac
export RESTIC_REPOSITORY RESTIC_PASSWORD

if command -v k3s >/dev/null 2>&1; then
	echo "k3s is already installed on this host -- refusing to continue." >&2
	exit 1
fi

# --- 1) tools ------------------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
	dnf install -y restic sqlite curl NetworkManager
else
	apt-get update && apt-get install -y restic sqlite3 curl
fi
# 移行前のホストは Ubuntu 26.04 + NetworkManager(netplan バックエンド)。復元先も同じ前提。

echo "Snapshots in repository:"
restic snapshots --tag "$TAG" --compact

# --- 2) restore files to their original places ---------------------------------
echo "Restoring snapshot '$SNAPSHOT' to / ..."
restic restore "$SNAPSHOT" --tag "$TAG" --target /
[ -f "$SNAP_DIR/state.db" ] || { echo "no $SNAP_DIR/state.db in the snapshot" >&2; exit 1; }

# --- 3) k3s: install without starting, then put the restored datastore in place -----
K3S_VERSION="$(cat "$SNAP_DIR/k3s-version" 2>/dev/null || true)"
echo "Installing k3s ${K3S_VERSION:-(latest)} (not started) ..."
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_VERSION="$K3S_VERSION" sh -

mkdir -p "$(dirname "$STATE_DB")"
rm -f "$STATE_DB" "${STATE_DB}-wal" "${STATE_DB}-shm"
cp "$SNAP_DIR/state.db" "$STATE_DB"
rm -f "$SNAP_DIR/state.db"

# 復元直後は AdGuard の LoadBalancer(port 53)に endpoint が無く、kube-proxy がローカル宛 53 番を REJECT する。
# systemd-resolved のスタブ(127.0.0.53)がそれに巻き込まれて名前解決が死に、containerd がイメージを取れず
# AdGuard も上がらない、という鶏卵になる(2026-09-06 のリハーサルで発生)。スタブを外して上流 DNS を直接使う。
if [ -L /etc/resolv.conf ] && grep -q '127.0.0.53' /etc/resolv.conf 2>/dev/null && [ -f /run/systemd/resolve/resolv.conf ]; then
	ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
	echo "resolv.conf: bypassing systemd-resolved stub (uses upstream DNS directly)"
fi

systemctl daemon-reload
if [ "$DRILL" = 1 ]; then
	echo "DRILL: not enabling k3s-backup.timer, dropping flannel-iface from k3s config"
	sed -i '/^flannel-iface:/d' /etc/rancher/k3s/config.yaml
else
	systemctl enable k3s-backup.timer 2>/dev/null || echo "WARNING: k3s-backup.timer not in snapshot; install it from the gitops repo (backup/)" >&2
fi

# firewalld は k3s と相性が悪い(公式も無効化を推奨)。フィルタは k3s 側(nft)に任せる。
if command -v firewall-cmd >/dev/null 2>&1; then
	systemctl disable --now firewalld || true
fi

# --- 4) network + start, detached from this SSH session ------------------------
# 復元した bond0 / eno4 プロファイルを有効化すると、今 DHCP で繋がっている NIC が bond に入って
# SSH が切れることがある。切れても最後まで走るように systemd-run で切り離す。
cat > /run/k3s-restore-finish.sh <<'FIN'
#!/bin/sh
set -u
if [ "${RESTORE_DRILL:-0}" != 1 ] && command -v nmcli >/dev/null 2>&1; then
	# Ubuntu: NM の profile は /etc/netplan/90-NM-*.yaml に入っているので netplan 側を先に再生成する
	command -v netplan >/dev/null 2>&1 && netplan generate || true
	nmcli general reload || true
	nmcli connection reload || true
	# インストーラが作った自動プロファイルは bond のスレーブを横取りするので消す
	nmcli -g NAME,TYPE connection show | while IFS=: read -r name type; do
		case "$name" in "Wired connection"*) nmcli connection delete "$name" || true ;; esac
	done
	nmcli connection up bond0 || true
	nmcli connection up eno4 || true
fi
systemctl enable --now k3s
[ "${RESTORE_DRILL:-0}" = 1 ] || systemctl start k3s-backup.timer || true
FIN
chmod +x /run/k3s-restore-finish.sh

echo "Applying network profiles and starting k3s (this session may drop; reconnect to 10.0.0.2 / 10.10.0.4) ..."
systemd-run --unit=k3s-restore-finish --collect --setenv=RESTORE_DRILL="$DRILL" /run/k3s-restore-finish.sh
echo "Follow with:  journalctl -u k3s-restore-finish -u k3s -f    then:  sudo k3s kubectl get pods -A"
