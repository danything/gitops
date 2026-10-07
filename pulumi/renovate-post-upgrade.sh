#!/usr/bin/env bash
# Renovate の postUpgradeTasks から呼ぶ(renovate.json)。pulumi/ の依存を上げた枝で `pulumi install` を流し、bun.lock を作り直す。
#
# Renovate は bun のプロジェクトでは自分で `bun install` して lock を直すが、ここの package.json は NetBird の SDK を
# `file:sdks/netbird` で指していて、SDK は `pulumi install` でしか作れない(git には入れない。pulumi/README.md)。
# Renovate の `bun install` は SDK が無くて落ちるので、renovate.json でそれを止め(updateLockFiles: false)、ここで作る。
#
# 動くのは Renovate のコンテナ(ghcr.io/renovatebot/renovate、5ym/repo-config の renovate.yml)の中、リポジトリの直下。
# Pulumi の CLI は入っていないので、.pulumi-version の版を公式のチェックサムと照らしてから入れる。bun は containerbase の
# install-tool で .bun-version の版を入れる。許可は repo-config の renovate.yml の RENOVATE_ALLOWED_COMMANDS
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
