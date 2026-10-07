# 手元で使う運用のコマンド一式(tools/README.md)。手元には Docker だけを入れ、版はここで固定する。
# 版は Renovate が上げる(`# renovate:` の次の ARG。renovate.json の customManagers)。
# kubectl と talosctl はノードの版と揃えたいので、Renovate では talos の群(自動マージしない)。
FROM oven/bun:1.4.2 AS bun

FROM golang:1.26-trixie AS age
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 go install "filippo.io/age/cmd/...@${AGE_VERSION}"

FROM node:26.10.0-trixie-slim
ARG TARGETARCH

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.1
# renovate: datasource=github-releases depName=siderolabs/talos
ARG TALOSCTL_VERSION=v1.14.2
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.3.0
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=v3.13.3
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

# **入れるものは全部、公式が出しているチェックサムと照らし合わせる**(2026-10-07)。sops は age 鍵を、infisical は
# 秘密を扱うので、取得元やミラーでの差し替えに気づけるようにする。get は「ファイルを取る」、ok は
# 「チェックサムのファイル(ハッシュ  ファイル名 の形)に照らす」。一致しなければ組み立てごと止まる
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN a=$TARGETARCH; p=$a; [ "$a" = amd64 ] && p=x64; \
    mkdir /tmp/dl && cd /tmp/dl; \
    get() { curl -fsSLO "$1"; }; \
    ok() { curl -fsSL "$1" | grep -E "  ($2)\$" | sha256sum -c --strict -; }; \
    gh=https://github.com; \
    get "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$a/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$a/kubectl.sha256")  kubectl" | sha256sum -c --strict -; \
    get "$gh/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-$a"; \
    ok "$gh/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/sha256sum.txt" "talosctl-linux-$a"; \
    get "https://get.helm.sh/helm-${HELM_VERSION}-linux-$a.tar.gz"; \
    ok "https://get.helm.sh/helm-${HELM_VERSION}-linux-$a.tar.gz.sha256sum" "helm-${HELM_VERSION}-linux-$a.tar.gz"; \
    get "$gh/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.$a"; \
    ok "$gh/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt" "sops-${SOPS_VERSION}.linux.$a"; \
    get "$gh/Infisical/cli/releases/download/${INFISICAL_VERSION}/cli_${INFISICAL_VERSION#v}_linux_$a.tar.gz"; \
    ok "$gh/Infisical/cli/releases/download/${INFISICAL_VERSION}/checksums.txt" "cli_${INFISICAL_VERSION#v}_linux_$a.tar.gz"; \
    get "$gh/restic/restic/releases/download/${RESTIC_VERSION}/restic_${RESTIC_VERSION#v}_linux_$a.bz2"; \
    ok "$gh/restic/restic/releases/download/${RESTIC_VERSION}/SHA256SUMS" "restic_${RESTIC_VERSION#v}_linux_$a.bz2"; \
    get "$gh/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-$a"; \
    ok "$gh/jqlang/jq/releases/download/${JQ_VERSION}/sha256sum.txt" "jq-linux-$a"; \
    get "$gh/pulumi/pulumi/releases/download/${PULUMI_VERSION}/pulumi-${PULUMI_VERSION}-linux-$p.tar.gz"; \
    ok "$gh/pulumi/pulumi/releases/download/${PULUMI_VERSION}/pulumi-${PULUMI_VERSION#v}-checksums.txt" "pulumi-${PULUMI_VERSION}-linux-$p.tar.gz"; \
    install -m 755 kubectl /usr/local/bin/kubectl; \
    install -m 755 "talosctl-linux-$a" /usr/local/bin/talosctl; \
    tar -xzf "helm-${HELM_VERSION}-linux-$a.tar.gz" --strip-components=1 -C /usr/local/bin "linux-$a/helm"; \
    install -m 755 "sops-${SOPS_VERSION}.linux.$a" /usr/local/bin/sops; \
    tar -xzf "cli_${INFISICAL_VERSION#v}_linux_$a.tar.gz" -C /usr/local/bin infisical; \
    bunzip2 -c "restic_${RESTIC_VERSION#v}_linux_$a.bz2" > /usr/local/bin/restic; \
    install -m 755 "jq-linux-$a" /usr/local/bin/jq; \
    # Pulumi は本体と bun・Node.js の言語ホストだけ。ほかの言語のぶんは 200MB 近いので入れない。
    # bun の言語ホストが無いと runtime: bun のプロジェクトで SDK を作れない (pulumi install。2026-10-07 まで抜けていた)
    tar -xzf "pulumi-${PULUMI_VERSION}-linux-$p.tar.gz" --strip-components=1 -C /usr/local/bin pulumi/pulumi pulumi/pulumi-language-bun pulumi/pulumi-language-nodejs; \
    chmod +x /usr/local/bin/*; \
    cd / && rm -r /tmp/dl

# age はチェックサムのファイルを出していない(sigsum の証明だけ)。Go のモジュールとして入れ、Go の公開の
# チェックサムの台帳(sum.golang.org)で中身を確かめる
COPY --from=age /go/bin/age /go/bin/age-keygen /usr/local/bin/

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN npm install -g "cf@${CF_VERSION}" && npm cache clean --force

# 手元のユーザーの uid で動かす。HOME はリポジトリの .home/(compose.yaml)
WORKDIR /repo
