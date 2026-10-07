# 手元で使う運用のコマンド一式(tools/README.md)。手元には Docker だけを入れ、版はここで固定する。
# 版は Renovate が上げる(`# renovate:` の次の ARG。renovate.json の customManagers)。
# kubectl と talosctl はノードの版と揃えたいので、Renovate では talos の群(自動マージしない)。
FROM oven/bun:1.4.2 AS bun

FROM node:26.10.0-trixie-slim
ARG TARGETARCH

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.36.2
# renovate: datasource=github-releases depName=siderolabs/talos
ARG TALOSCTL_VERSION=v1.14.0
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v3.22.0
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=v3.13.3
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=v1.3.2
# renovate: datasource=github-releases depName=Infisical/cli
ARG INFISICAL_VERSION=v0.43.139
# renovate: datasource=github-releases depName=restic/restic
ARG RESTIC_VERSION=v0.19.1
# renovate: datasource=github-releases depName=jqlang/jq
ARG JQ_VERSION=jq-1.8.2
# renovate: datasource=github-releases depName=pulumi/pulumi
ARG PULUMI_VERSION=v3.267.0
# renovate: datasource=npm depName=cf
ARG CF_VERSION=1.0.0-beta.12

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl bzip2 git openssh-client less \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; a=$TARGETARCH; cd /tmp; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$a/kubectl"; \
    curl -fsSLo /usr/local/bin/talosctl "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-$a"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-$a.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin "linux-$a/helm"; \
    curl -fsSLo /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.$a"; \
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-$a.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen; \
    curl -fsSL "https://github.com/Infisical/cli/releases/download/${INFISICAL_VERSION}/cli_${INFISICAL_VERSION#v}_linux_$a.tar.gz" | tar -xz -C /usr/local/bin infisical; \
    curl -fsSL "https://github.com/restic/restic/releases/download/${RESTIC_VERSION}/restic_${RESTIC_VERSION#v}_linux_$a.bz2" | bunzip2 > /usr/local/bin/restic; \
    curl -fsSLo /usr/local/bin/jq "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-$a"; \
    p=$a; [ "$a" = amd64 ] && p=x64; [ "$a" = arm64 ] && p=arm64; \
    # Pulumi は本体と bun・Node.js の言語ホストだけ。ほかの言語のぶんは 200MB 近いので入れない。
    # bun の言語ホストが無いと runtime: bun のプロジェクトで SDK を作れない (pulumi install。2026-10-07 まで抜けていた)
    curl -fsSL "https://get.pulumi.com/releases/sdk/pulumi-${PULUMI_VERSION}-linux-$p.tar.gz" | tar -xz --strip-components=1 -C /usr/local/bin pulumi/pulumi pulumi/pulumi-language-bun pulumi/pulumi-language-nodejs; \
    chmod +x /usr/local/bin/*

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN npm install -g "cf@${CF_VERSION}" && npm cache clean --force

# 手元のユーザーの uid で動かす。HOME はリポジトリの .home/(compose.yaml)
WORKDIR /repo
