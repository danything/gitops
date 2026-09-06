#!/bin/sh
# 稼働中の k3s ホストに k3s-backup を入れる(1 回きり、clone から実行)。
# 終わったら clone は消してよい: 以後ホストに repo は要らない。
#   git clone ... && sudo ./backup/install.sh && rm -rf bootstrap
set -eu
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

if command -v dnf >/dev/null 2>&1; then
	dnf install -y restic sqlite age
else
	apt-get install -y restic sqlite3 age
fi

install -m 755 "$DIR/k3s-backup" /usr/local/bin/k3s-backup
install -m 644 "$DIR/k3s-backup.service" "$DIR/k3s-backup.timer" /etc/systemd/system/
systemctl daemon-reload

mkdir -p /etc/k3s-backup
chmod 700 /etc/k3s-backup
ENV_AGE="${ENV_AGE:-https://raw.githubusercontent.com/danything/gitops/main/recovery/env.age}"
if [ ! -f /etc/k3s-backup/env ]; then
	if [ -f "$ENV_AGE" ] || curl -fsSI "$ENV_AGE" >/dev/null 2>&1; then
		# 公開 repo gitops の recovery/ の暗号化済み env を復号(パスフレーズを聞かれる)
		case "$ENV_AGE" in
			http://*|https://*) curl -fsSL "$ENV_AGE" | age -d -o /etc/k3s-backup/env ;;
			*) age -d -o /etc/k3s-backup/env "$ENV_AGE" ;;
		esac
		chmod 600 /etc/k3s-backup/env
	else
		install -m 600 "$DIR/env.example" /etc/k3s-backup/env
		echo "Wrote /etc/k3s-backup/env from the example. Fill it in, then re-run this script." >&2
		echo "Afterwards seal it into gitops の recovery/:  age -p -o env.age /etc/k3s-backup/env" >&2
		exit 1
	fi
fi

set -a
. /etc/k3s-backup/env
set +a
if ! restic cat config >/dev/null 2>&1; then
	echo "Initializing restic repository at $RESTIC_REPOSITORY"
	restic init
fi

systemctl enable --now k3s-backup.timer
echo "Installed. First run now with:  sudo systemctl start k3s-backup.service && journalctl -u k3s-backup -f"
