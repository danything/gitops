#!/bin/sh
# machine config を作る。手で書く部分(patches/)と、他から描いてくる部分
# (Cilium・local-path-provisioner)を 1 か所で組む。
#
# 値を二度書かないための道具。Cilium の設定は bootstrap/cilium/values.yaml が
# 正本で、machine config はそこから描いた派生物にする。手で合わせない
# (../docs/decisions.md「machine config と Cilium の chart をどう連動させるか」)。
#
#   ./talos/render.sh talos/clusterconfig
#
# 秘密(talos/secrets.yaml などの SOPS ファイル)は自分で復号して作業用の一時ディレクトリに置き、
# 終わったら消す(age の鍵が要る)。CI は鍵を持たないので SECRETS / REGISTRIES などの env で
# 渡し、そのときは復号しない。出力の machine config は秘密を含むので扱いに注意。
#
# 手元の PC(tools/t.ps1 のコンテナ)で回す。**出力先は丸ごと消して作り直す**ので、
# talos/clusterconfig/ に出したなら kubeconfig は `talosctl kubeconfig` で取り直すこと。
#
# `talosctl upgrade-k8s` の前にも実行すること(talos/README.md「inlineManifests を直したとき」)。
set -eu

OUT=${1:?usage: render.sh <output-dir>}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

WORK=$(mktemp -d)
# 呼び出し側から渡された SECRETS は消さない。自分で作ったものだけ片付ける。
OWN_SECRETS=
# 最後を `[ -n ... ] &&` で終えないこと。EXIT トラップの戻り値がスクリプトの
# 終了コードになるので、`OWN_SECRETS` が空だとテストが偽になって 1 で落ちる
# (CI が `SECRETS` を渡す場合がまさにそれ。実際に踏んだ)。
cleanup() {
	rm -rf "$WORK"
	if [ -n "$OWN_SECRETS" ]; then rm -f "$OWN_SECRETS"; fi
	return 0
}
trap cleanup EXIT INT TERM

SECRETS=${SECRETS:-}
if [ -z "$SECRETS" ]; then
	OWN_SECRETS=$WORK/secrets.yaml
	SECRETS=$OWN_SECRETS
	sops -d talos/secrets.yaml > "$SECRETS"
fi

# fj.doany.io のイメージ取得の資格情報(talos/README.md「fj.doany.io の資格情報」)。
# CI には age の鍵を渡さないので、`REGISTRIES` にダミーを入れて経路だけ通す。
REGISTRIES=${REGISTRIES:-}
if [ -z "$REGISTRIES" ]; then
	if [ -f talos/registries.yaml ]; then
		REGISTRIES=$WORK/registries.yaml
		sops -d talos/registries.yaml > "$REGISTRIES"
	else
		# 止めない。このファイルが無くても他は描けるので、作る前でも作業は進む。
		# ただし気づかず焼くと private イメージが全部 ImagePullBackOff になるので、
		# はっきり言う(talos/README.md「fj.doany.io の資格情報」)。
		echo "WARNING: talos/registries.yaml が無い。fj.doany.io の非公開イメージが引けない構成になる" >&2
	fi
fi

# キーを名前で引く。「1 つ目の version」「最後の version」で数えていると、
# versions.yaml にブロックが増えた瞬間に静かに別の値を掴む。
# `yq` は使わない(版で構文が違うので、どこで回しても同じに動く awk にしてある)。
ver() { # $1=トップレベルのキー  $2=その下のキー
	awk -v top="$1:" -v key="  $2: " '$0 == top {f=1; next} /^[^ #]/ {f=0} f && index($0, key) == 1 {print substr($0, length(key)+1); exit}' talos/versions.yaml
}
TALOS=$(ver talos version)
SCHEMATIC=$(ver talos schematic)
K8S=$(ver kubernetes version)
METRICS=$(ver metricsServer version)
GWAPI=$(ver gatewayAPI version)
CILIUM=$(sed -n 's/^version: \(.*\)$/\1/p' bootstrap/cilium/version.yaml)
CERTMGR=$(sed -n 's/^version: \(.*\)$/\1/p' bootstrap/cert-manager/version.yaml)
for v in "$TALOS" "$SCHEMATIC" "$K8S" "$METRICS" "$CILIUM" "$GWAPI" "$CERTMGR"; do
	[ -n "$v" ] || { echo "ERROR: versions.yaml から版を読めなかった" >&2; exit 1; }
done
echo "talos=$TALOS k8s=$K8S cilium=$CILIUM metrics-server=$METRICS gateway-api=$GWAPI cert-manager=$CERTMGR"

# --- inlineManifest を描く -------------------------------------------------
# `helm template` の出力をそのまま KubeInlineManifestConfig に包む。
inline() { # $1=name  stdin=manifest
	printf 'apiVersion: v1alpha1\nkind: KubeInlineManifestConfig\nname: %s\nmanifest: |-\n' "$1"
	sed 's/^/    /'
}

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || true
# `--api-versions` は GatewayClass `cilium` のため。chart は Gateway API の CRD が「ある」ときだけ
# GatewayClass を描くが、`helm template` はクラスタを見ないので、渡さないと黙って抜ける。
# 抜けると Gateway が `Waiting for controller` のまま公開経路が全部死ぬ(2026-10-17 に踏んだ)。
# 下の needle で GatewayClass があることを見る。
helm template cilium cilium/cilium --version "$CILIUM" -n kube-system \
	-f bootstrap/cilium/values.yaml \
	--kube-version "$K8S" \
	--api-versions gateway.networking.k8s.io/v1/GatewayClass \
	| awk -v ns=kube-system -f talos/add-namespace.awk \
	| inline cilium > "$WORK/inline-cilium.yaml"

inline local-path < talos/manifests/local-path.yaml > "$WORK/inline-local-path.yaml"

# bootstrap-applier の RBAC。当のワークフローに当てさせるわけにいかない (自分の権限を
# 書き換えられる) ので bootstrap-apply.yml は bootstrap/apiserver/ を除外していて、ここで載せる。
# 認証の側(OIDC の issuer)は patches/apiserver.yaml の KubeAuthenticationConfig。
inline apiserver-rbac < bootstrap/apiserver/rbac.yaml > "$WORK/inline-apiserver-rbac.yaml"

# --- HelmChart の形の CR から描く -------------------------------------------
# argocd と infisical は `bootstrap/` の SOPS 済み CR(`helm.cattle.io/v1` の HelmChart の形)が正本。
# クラスタにこの CRD は無く、ここが chart・repo・版・値を読む入れ物として使っているだけ。
# 同じ chart・同じ値を `helm template` して inlineManifest にする。値をここに写さないのは
# Cilium と同じ方針(../docs/decisions.md)。
#
# infisical はここに来るしかない。chart が DB と Redis のパスワードを
# Deployment の平文 env に焼き込むので、ArgoCD の Application には置けない
# (../docs/decisions.md「infisical だけは ArgoCD に移せない」)。
# render.sh は age の鍵を持っているので、復号した値をそのまま helm に渡せる。
# 生成物は machine config の中にしか出ない。

# CR(復号済み)から spec の 1 つのキー、または spec.values の中身を取り出す。
# `yq` は使わない(版で構文が違うので、どこで回しても同じに動く awk にしてある)。
hc() { # $1=file  $2=キー名 または @values
	awk -v key="$2" '
		BEGIN { pfx = "    " key ": " }
		key != "@values" {
			if (index($0, pfx) == 1) { print substr($0, length(pfx)+1); exit }
			next
		}
		/^    values:$/ { inv = 1; next }
		inv && /^[^ ]/  { exit }          # sops: など、トップレベルに戻ったら終わり
		inv             { print substr($0, 9) }
	' "$1"
}

# $1=名前(argocd / infisical)。$2 は復号済みの CR(下の decrypt_cr が作る)。
helmchart_inline() { # $1=name  $2=復号済み CR
	_name=$1
	_cr=$2
	_chart=$(hc "$_cr" chart)
	_repo=$(hc "$_cr" repo)
	_ver=$(hc "$_cr" version)
	_ns=$(hc "$_cr" targetNamespace)
	if [ -z "$_ver" ]; then
		# 止めない。版を固定するのは人の手作業(bootstrap/README.md
		# 「Helm で入れるもの」)で、それより前でも他は描けるようにしておく。
		echo "WARNING: bootstrap/$_name/helmchart.yaml に version: が無いので $_name を描かない" >&2
		echo "         sops edit で chart:/repo:/version: の 3 行を連続させること" >&2
		return 0
	fi
	hc "$_cr" @values > "$WORK/$_name-values.yaml"
	helm repo add "$_name" "$_repo" >/dev/null 2>&1 || true
	helm repo update "$_name" >/dev/null 2>&1 || true
	# namespace を先頭に付ける。chart は Namespace を描かないし、
	# `bootstrap/<name>/namespace.yaml` を当てているのは GitHub Actions
	# (bootstrap-apply.yml)で、クラスタが立っていないと走れない。
	# machine config が最初に流れる時点では誰も作っていないので、ここで一緒に入れる
	# (local-path が自分の namespace を同梱しているのと同じ)。
	{
		cat "bootstrap/$_name/namespace.yaml"
		echo ---
		helm template "$_name" "$_name/$_chart" --version "$_ver" -n "$_ns" \
			-f "$WORK/$_name-values.yaml" -f "talos/$_name-values.yaml" \
			--kube-version "$K8S" | awk -v ns="$_ns" -f talos/add-namespace.awk
	} | inline "$_name" > "$WORK/inline-$_name.yaml"
	echo "  $_name: chart $_chart $_ver -> $(wc -c < "$WORK/inline-$_name.yaml") バイト"
}

# 復号してパスを返す。CI には age の鍵を渡さないので、`ARGOCD_CHART` /
# `INFISICAL_CHART` にダミーを入れて経路だけ通す(SECRETS / REGISTRIES と同じ)。
decrypt_cr() { # $1=name  $2=env で渡された上書き
	if [ -n "$2" ]; then echo "$2"; return 0; fi
	if [ ! -f "bootstrap/$1/helmchart.yaml" ]; then
		echo "WARNING: bootstrap/$1/helmchart.yaml が無いので $1 を描かない" >&2
		return 0
	fi
	sops -d "bootstrap/$1/helmchart.yaml" > "$WORK/$1-chart.yaml"
	echo "$WORK/$1-chart.yaml"
}

ARGOCD_CR=$(decrypt_cr argocd "${ARGOCD_CHART:-}")
INFISICAL_CR=$(decrypt_cr infisical "${INFISICAL_CHART:-}")
# `[ … ] && cmd` で書かないこと。`set -e` の下では、条件が偽のときに
# その行が 1 を返してスクリプトごと落ちる(cleanup のトラップで実際に踏んだ)。
if [ -n "$ARGOCD_CR" ]; then helmchart_inline argocd "$ARGOCD_CR"; fi
if [ -n "$INFISICAL_CR" ]; then helmchart_inline infisical "$INFISICAL_CR"; fi

# ArgoCD の CRD は URL で渡す(理由は talos/argocd-values.yaml)。
# 版は chart の appVersion をそのまま使う。版を 2 つ持つと必ずずれる。
if [ -f "$WORK/inline-argocd.yaml" ]; then
	ARGOCD_APP=$(helm show chart "argocd/$(hc "$ARGOCD_CR" chart)" \
		--version "$(hc "$ARGOCD_CR" version)" 2>/dev/null \
		| sed -n 's/^appVersion: *//p' | tr -d "\"'")
	[ -n "$ARGOCD_APP" ] || { echo "ERROR: argo-cd の appVersion を読めなかった" >&2; exit 1; }
	echo "  argocd の CRD: $ARGOCD_APP"
	for c in application applicationset appproject; do
		cat >> "$WORK/external-crds.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: argocd-$c-crd
url: https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_APP}/manifests/crds/$c-crd.yaml
---
PATCH
	done
fi

# cert-manager も bootstrap/ にいる。無いと証明書が 1 枚も発行されず、
# Gateway の HTTPS リスナーに載せる Secret ができない。
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null 2>&1 || true
{
	cat bootstrap/cert-manager/namespace.yaml
	echo ---
	helm template cert-manager jetstack/cert-manager --version "$CERTMGR" -n cert-manager \
		-f bootstrap/cert-manager/values.yaml \
		--kube-version "$K8S" | awk -v ns=cert-manager -f talos/add-namespace.awk
} | inline cert-manager > "$WORK/inline-cert-manager.yaml"

# SOPS 済みの Secret も入れる。infisical/secrets.yaml は infisical の起動に要る
# (kubeSecretRef)ので、CI が当てるのでは間に合わない。cloudflare-secret.yaml は
# DNS-01 の資格情報。machine config はもともと秘密の塊なので信頼水準は変わらない。
# `sops -d … | inline` と繋がないこと。`#!/bin/sh` には `pipefail` が無いので、
# 復号に失敗しても `set -e` が拾わず、中身が空の KubeInlineManifestConfig が
# 黙って出る。そして下の needle は `inline` が付ける `name:` しか見ないので通ってしまう
# (chart の方は `cilium-operator` のような中身を見ているので気づける)。
# いったんファイルに落とす。
inline_secret() { # $1=inline の名前  $2=SOPS ファイル  $3=env の上書き
	if [ -n "$3" ]; then
		inline "$1" < "$3" > "$WORK/inline-$1.yaml"
		return 0
	fi
	if [ ! -f "$2" ]; then
		echo "WARNING: $2 が無いので $1 を描かない" >&2
		return 0
	fi
	sops -d "$2" > "$WORK/plain-$1.yaml"
	inline "$1" < "$WORK/plain-$1.yaml" > "$WORK/inline-$1.yaml"
}
inline_secret infisical-secrets bootstrap/infisical/secrets.yaml "${INFISICAL_SECRET:-}"
inline_secret cloudflare-secret bootstrap/cert-manager/cloudflare-secret.yaml "${CLOUDFLARE_SECRET:-}"

# cert-manager の CRD も URL で渡す(理由は bootstrap/cert-manager/values.yaml の `crds`)。
cat >> "$WORK/external-crds.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: cert-manager-crds
url: https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR}/cert-manager.crds.yaml
---
PATCH

# Gateway API の CRD。無いと Gateway も HTTPRoute も適用できず公開経路が消える。
# Cilium の chart は CRD を同梱しない (gatewayAPI.enabled は「入れてある前提」)。
# standard-install.yaml は 10 個とも持っているので experimental の bundle は要らない。
# 埋めずに URL で渡す理由は ../docs/decisions.md「層の分け方」。
cat > "$WORK/gateway-api.yaml" <<PATCH
apiVersion: v1alpha1
kind: KubeExternalManifestConfig
name: gateway-api
url: https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI}/standard-install.yaml
PATCH

# metrics-server も Talos には無い。無いと `kubectl top` と各 UI の使用量表示が消える。
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null 2>&1 || true
helm template metrics-server metrics-server/metrics-server --version "$METRICS" \
	-n kube-system -f talos/metrics-server-values.yaml --kube-version "$K8S" \
	| awk -v ns=kube-system -f talos/add-namespace.awk \
	| inline metrics-server > "$WORK/inline-metrics-server.yaml"

# --- 組み立て --------------------------------------------------------------
set -- --with-secrets "$SECRETS" \
	--kubernetes-version "$K8S" \
	--install-image "factory.talos.dev/installer/${SCHEMATIC}:${TALOS}"
for f in talos/patches/*.yaml; do set -- "$@" --config-patch "@$f"; done
if [ -n "$REGISTRIES" ]; then set -- "$@" --config-patch "@$REGISTRIES"; fi
set -- "$@" --config-patch "@$WORK/gateway-api.yaml"
if [ -f "$WORK/external-crds.yaml" ]; then set -- "$@" --config-patch "@$WORK/external-crds.yaml"; fi
for f in "$WORK"/inline-*.yaml; do set -- "$@" --config-patch "@$f"; done

rm -rf "$OUT"
talosctl gen config doany https://10.0.0.2:6443 "$@" --output-dir "$OUT" >/dev/null
echo "wrote $OUT/controlplane.yaml ($(wc -l < "$OUT/controlplane.yaml") 行)"

# 描いたものが本当に入ったか。gen config は知らないキーを黙って捨てることがある。
# 生成物では manifest が 1 行のエスケープ文字列になるので、引用符は \" で探す。
for n in 'name: cilium' 'name: local-path' 'cilium-operator' 'rancher.io/local-path' \
	'KUBERNETES_SERVICE_PORT' 'value: \"7445\"' 'cgroup-root: \"/sys/fs/cgroup\"' \
	'kind: GatewayClass' 'io.cilium/gateway-controller' \
	'name: metrics-server' 'system:metrics-server' '--kubelet-insecure-tls' \
	'/var/mnt/local-path' 'name: EPHEMERAL' 'maxSize: 64GiB' 'secure: false' \
	'name: apiserver-rbac' 'bootstrap-applier' 'entra:admin' 'entra:viewer' \
	login.microsoftonline.com \
	"gateway-api/releases/download/$GWAPI/standard-install.yaml" \
	'gha:danything/gitops:refs/heads/main' \
	"ghcr.io/siderolabs/kubelet:$K8S"; do
	# `--` を忘れないこと。`--kubelet-insecure-tls` のような needle を
	# grep がオプションとして解釈して落ちる。
	grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done

# 描けたときだけ見る。version が入る前は argocd / infisical を飛ばすので
# (上の WARNING)、無条件の needle にすると作業できなくなる。
if [ -f "$WORK/inline-argocd.yaml" ]; then
	for n in 'name: argocd' 'argocd-server' 'name: argocd-application-crd' \
		'manifests/crds/applicationset-crd.yaml' \
		'kind: Namespace\nmetadata:\n  name: argocd'; do
		grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
	done
	# CRD は URL で渡すので、描き出しに入っていないこと。入ると 1.83 MB 増える。
	# 生成物ではなく包む前のファイルを見る(あちらは 1 行のエスケープ文字列になる)。
	! grep -q 'kind: CustomResourceDefinition' "$WORK/inline-argocd.yaml" \
		|| { echo "ERROR: argocd の CRD が inline に入っている(talos/argocd-values.yaml)" >&2; exit 1; }
fi
if [ -f "$WORK/inline-infisical.yaml" ]; then
	for n in 'name: infisical' 'infisical-standalone' \
		'metadata:\n  namespace: infisical' \
		'kind: Namespace\nmetadata:\n  name: infisical'; do
		grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
	done
fi
for n in 'name: cert-manager' 'cert-manager-webhook' 'name: cert-manager-crds' \
	"cert-manager/releases/download/$CERTMGR/cert-manager.crds.yaml" \
	'kind: Namespace\nmetadata:\n  name: cert-manager'; do
	grep -qF -- "$n" "$OUT/controlplane.yaml" || { echo "ERROR: '$n' が生成物に無い" >&2; exit 1; }
done
# CRD は URL 側。入ると 1.30 MB 増える(bootstrap/cert-manager/values.yaml)。
! grep -q 'kind: CustomResourceDefinition' "$WORK/inline-cert-manager.yaml" \
	|| { echo "ERROR: cert-manager の CRD が inline に入っている" >&2; exit 1; }
if [ -f "$WORK/inline-infisical-secrets.yaml" ]; then
	grep -qF -- 'name: infisical-secrets' "$OUT/controlplane.yaml" \
		|| { echo "ERROR: 'name: infisical-secrets' が生成物に無い" >&2; exit 1; }
fi
if [ -f "$WORK/inline-cloudflare-secret.yaml" ]; then
	grep -qF -- 'name: cloudflare-secret' "$OUT/controlplane.yaml" \
		|| { echo "ERROR: 'name: cloudflare-secret' が生成物に無い" >&2; exit 1; }
fi
talosctl validate --config "$OUT/controlplane.yaml" --mode metal
