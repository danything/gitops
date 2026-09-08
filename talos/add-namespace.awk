# helm の描き出しに namespace を補う。
# chart によっては metadata.namespace を書かない(infisical の Deployment と
# Service が実際にそうだった)。helm / kubectl なら `-n` で決まるが、Talos の
# マニフェスト適用には既定の namespace が無いので default に落ちる。
#
#   awk -v ns=infisical -f ns.awk < helm-output.yaml
BEGIN {
	# クラスタスコープのものには足さない(足すと API が弾く)。
	split("Namespace ClusterRole ClusterRoleBinding CustomResourceDefinition " \
	      "ValidatingWebhookConfiguration MutatingWebhookConfiguration APIService " \
	      "StorageClass PriorityClass RuntimeClass IngressClass PersistentVolume " \
	      "ClusterIssuer CiliumClusterwideNetworkPolicy", a, " ")
	for (i in a) cluster[a[i]] = 1
	n = 0
}
/^---$/ { flush(); print; next }
{ buf[n++] = $0 }
END { flush() }

function flush(   i, kind, mi, hasns, inmeta) {
	if (n == 0) return
	kind = ""; mi = -1; hasns = 0; inmeta = 0
	for (i = 0; i < n; i++) {
		if (buf[i] ~ /^kind: /)     { kind = substr(buf[i], 7) }
		if (buf[i] ~ /^metadata:$/) { mi = i; inmeta = 1; continue }
		if (inmeta && buf[i] ~ /^[^ ]/) inmeta = 0
		if (inmeta && buf[i] ~ /^  namespace:/) hasns = 1
	}
	for (i = 0; i < n; i++) {
		print buf[i]
		if (i == mi && !hasns && kind != "" && !(kind in cluster))
			print "  namespace: " ns
	}
	n = 0
}
