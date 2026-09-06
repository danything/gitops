# talos

実機(HP ProLiant DL360 Gen9)を Talos Linux に載せ替えるための machine config。
**v1.14.0 の形で書いてある**(1.13 以前とは別物。作法は [../docs/talos.md](../docs/talos.md))。

talhelper は使わない。`talosctl gen config` にこのディレクトリのパッチを渡すだけで足りる。

```shell
# 1) 秘密を作る。生成物は SOPS(age)で暗号化してコミットする
talosctl gen secrets -o secrets.yaml
sops -e -i secrets.yaml            # → talos/secrets.yaml (暗号化済み)

# 2) machine config を作る
sops -d secrets.yaml > /tmp/secrets.plain.yaml
talosctl gen config doany https://10.0.0.2:6443 \
  --with-secrets /tmp/secrets.plain.yaml \
  --install-image factory.talos.dev/installer/32820716ca2384dc3cefbb672e6be929c67636e93e556d7740c312efb6538302:v1.14.0 \
  --config-patch @patches/cluster.yaml \
  --config-patch @patches/main.yaml \
  --output-dir /tmp/talos-config
shred -u /tmp/secrets.plain.yaml

# 3) maintenance mode のノードに流す(ISO で起動した直後)
talosctl apply-config --insecure -n <コンソールに出た IP> -f /tmp/talos-config/controlplane.yaml
# 自動でディスクにインストールして再起動する。ISO を抜いてから:
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig bootstrap
talosctl -n 10.0.0.2 -e 10.0.0.2 --talosconfig /tmp/talos-config/talosconfig kubeconfig
```

`clusterconfig/` と平文の秘密は `.gitignore` 済み。

## まだ確認できていないこと

QEMU の user-mode ネットワークでは試せず、実機でしか確かめられないもの:

- bond0(eno1 + eno2、balance-alb)と eno4 の static
- **IPv6 の `::2` 固定**。NetworkManager の `ipv6.token` に相当する設定が Talos に見当たらないので、
  `patches/cluster.yaml` では stable-privacy(MAC を出さない)にして、AAAA は cloudflare-ddns に任せる方針
- wg-easy の hostNetwork UDP 51820
- PT3 を KubeVirt に渡す vfio(`patches/main.yaml`)
