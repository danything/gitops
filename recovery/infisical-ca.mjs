// Infisical の Kubernetes auth(operator の Machine Identity)の CA を見る / 差し替える。
// infisical.sh ca から呼ぶ(port-forward 18080 と TOKEN・CA の env はあちらが用意する)。トークンは表示しない。
// identity は bootstrap/README.md「Infisical の中の構成」の infisical-operator(InfisicalSecret の identityId)。
const ID = "f2bc3416-f196-4626-9bf3-c11693b32cc6";
const url = `http://127.0.0.1:18080/api/v1/auth/kubernetes-auth/identities/${ID}`;
const ca = Buffer.from(process.env.CA, "base64").toString();
const h = { Authorization: `Bearer ${process.env.TOKEN}`, "Content-Type": "application/json" };
// 比べやすいように、CA は先頭 1 行(BEGIN の次)の頭だけ出す
const head = (pem) => (pem ?? "").split("\n")[1]?.slice(0, 20);
const show = (j) => {
  const a = j.identityKubernetesAuth;
  return a
    ? { kubernetesHost: a.kubernetesHost, tokenReviewMode: a.tokenReviewMode, allowedNamespaces: a.allowedNamespaces,
        allowedNames: a.allowedNames, caHead: head(a.caCert) }
    : { status: j.statusCode, message: j.message };
};
console.log("cluster caHead:", head(ca));
console.log("infisical:", show(await (await fetch(url, { headers: h })).json()));
if (process.argv[2] === "apply") {
  const r = await fetch(url, { method: "PATCH", headers: h, body: JSON.stringify({ caCert: ca }) });
  console.log("patched:", r.status, show(await r.json()));
}
