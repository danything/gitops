# 手元で使う運用のコマンド一式(tools/README.md)。版は Renovate が `# renovate:` の次の ARG を上げる。
FROM oven/bun:1.4.3 AS bun

FROM golang:1.27-trixie AS age
# renovate: datasource=github-releases depName=FiloSottile/age
ARG AGE_VERSION=v1.3.2
RUN CGO_ENABLED=0 go install "filippo.io/age/cmd/...@${AGE_VERSION}"

FROM node:26.12.0-trixie-slim
ARG TARGETARCH

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.37.1
# renovate: datasource=github-releases depName=siderolabs/talos
ARG TALOSCTL_VERSION=v1.15.0-alpha.1
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v4.3.1
# renovate: datasource=github-releases depName=getsops/sops
ARG SOPS_VERSION=v3.13.3
# renovate: datasource=github-releases depName=Infisical/cli
ARG INFISICAL_VERSION=v0.44.3
# renovate: datasource=github-releases depName=restic/restic
ARG RESTIC_VERSION=v0.19.1
# renovate: datasource=github-releases depName=pulumi/pulumi
ARG PULUMI_VERSION=v3.270.0
# renovate: datasource=npm depName=cf
ARG CF_VERSION=1.0.0-beta.18

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl bzip2 git openssh-client less openssl \
 && rm -rf /var/lib/apt/lists/*

# 入れるものは全部、公式のチェックサムと照らす(ok は「ハッシュ  ファイル名」の形のファイルに照らす)
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
    get "$gh/pulumi/pulumi/releases/download/${PULUMI_VERSION}/pulumi-${PULUMI_VERSION}-linux-$p.tar.gz"; \
    ok "$gh/pulumi/pulumi/releases/download/${PULUMI_VERSION}/pulumi-${PULUMI_VERSION#v}-checksums.txt" "pulumi-${PULUMI_VERSION}-linux-$p.tar.gz"; \
    # kubectl・talosctl・helm の本物は libexec。/usr/local/bin のほうは creds.sh
    mkdir -p /usr/local/libexec/gitops; \
    install -m 755 kubectl /usr/local/libexec/gitops/kubectl; \
    install -m 755 "talosctl-linux-$a" /usr/local/libexec/gitops/talosctl; \
    tar -xzf "helm-${HELM_VERSION}-linux-$a.tar.gz" --strip-components=1 -C /usr/local/libexec/gitops "linux-$a/helm"; \
    install -m 755 "sops-${SOPS_VERSION}.linux.$a" /usr/local/bin/sops; \
    tar -xzf "cli_${INFISICAL_VERSION#v}_linux_$a.tar.gz" -C /usr/local/bin infisical; \
    bunzip2 -c "restic_${RESTIC_VERSION#v}_linux_$a.bz2" > /usr/local/bin/restic; \
    # Pulumi は本体と bun・Node.js の言語ホストだけ(bun が無いと pulumi install で SDK を作れない)
    tar -xzf "pulumi-${PULUMI_VERSION}-linux-$p.tar.gz" --strip-components=1 -C /usr/local/bin pulumi/pulumi pulumi/pulumi-language-bun pulumi/pulumi-language-nodejs; \
    chmod +x /usr/local/bin/* /usr/local/libexec/gitops/*; \
    cd / && rm -r /tmp/dl

# age はチェックサムのファイルを出していないので、Go のモジュールとして入れ sum.golang.org で確かめる
COPY --from=age /go/bin/age /go/bin/age-keygen /usr/local/bin/

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
RUN npm install -g "cf@${CF_VERSION}" && npm cache clean --force

# クラスタに繋ぐときだけ資格情報を tmpfs に作って渡す
COPY --chmod=755 creds.sh /usr/local/bin/creds.sh
RUN for t in kubectl talosctl helm; do ln -s creds.sh "/usr/local/bin/$t"; done

WORKDIR /repo
