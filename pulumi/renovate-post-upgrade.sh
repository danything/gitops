#!/usr/bin/env bash
# Renovate の postUpgradeTasks から呼ぶ(理由は renovate.json)。`pulumi install` で bun.lock を作り直す。
# Renovate のコンテナには Pulumi の CLI が無いので、チェックサムと照らしてから入れる。
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v bun >/dev/null 2>&1; then
  install-tool bun "$(cat .bun-version)" >/dev/null
fi

v=v$(cat .pulumi-version)
a=$(uname -m); case "$a" in x86_64) a=x64 ;; aarch64) a=arm64 ;; esac
f=pulumi-$v-linux-$a.tar.gz
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
curl -fsSL -o "$d/$f" "https://github.com/pulumi/pulumi/releases/download/$v/$f"
curl -fsSL "https://github.com/pulumi/pulumi/releases/download/$v/pulumi-${v#v}-checksums.txt" | grep " $f\$" | (cd "$d" && sha256sum -c --strict - >/dev/null)
tar -xzf "$d/$f" -C "$d"
export PATH="$d/pulumi:$PATH" PULUMI_HOME="$d/home" PULUMI_SKIP_UPDATE_CHECK=true DO_NOT_TRACK=1

# SDK(Pulumi.yaml の packages)を作って bun install まで。provider のプラグイン(azuread・cloudflare)は lock に関係ないので落とさない
pulumi install --no-plugins
