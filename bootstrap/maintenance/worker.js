// doany.io のメンテナンス/障害ページ。
//
// 動きは「まずオリジンに投げて、届かなかったときだけ自前のページを返す」。
// 平常時は素通しなので、Worker を置いたままにできる (メンテのたびに deploy し直さない)。
// オリジンが落ちている間は Cloudflare の 521/522 の代わりにこのページが出る。
//
// route は wrangler.toml。**proxied (オレンジ雲) のホストにしか当たらない**ので、
// 灰色雲のままのサブドメインを覆いたいときは maintenance.sh on で *.doany.io を proxied にする。

const RETRY_AFTER = 60 * 30; // 30分

export default {
  async fetch(request, env, ctx) {
    try {
      const res = await fetch(request);
      // Cloudflare がオリジンに繋げなかったときのステータス。
      if (res.status === 521 || res.status === 522 || res.status === 523 || res.status === 525) {
        return maintenance(request);
      }
      return res;
    } catch (e) {
      return maintenance(request);
    }
  },
};

function maintenance(request) {
  const host = new URL(request.url).hostname;
  const accept = request.headers.get("accept") || "";
  if (!accept.includes("text/html")) {
    // API や DoH の類にはページを返さない
    return new Response(JSON.stringify({ error: "service_unavailable", host }), {
      status: 503,
      headers: { "content-type": "application/json; charset=utf-8", "retry-after": String(RETRY_AFTER) },
    });
  }
  return new Response(html(host), {
    status: 503,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "retry-after": String(RETRY_AFTER),
      "cache-control": "no-store",
    },
  });
}

function html(host) {
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>メンテナンス中 — ${host}</title>
<style>
  :root { color-scheme: light dark; --fg:#1b1b1f; --muted:#5d5d68; --bg:#faf9f7; --card:#fff; --line:#e6e4e0; --accent:#c2643a; }
  @media (prefers-color-scheme: dark) {
    :root { --fg:#ececf1; --muted:#a0a0ad; --bg:#131316; --card:#1c1c21; --line:#2c2c34; --accent:#e08b5e; }
  }
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:grid; place-items:center; padding:24px;
         background:var(--bg); color:var(--fg);
         font-family: ui-sans-serif, system-ui, -apple-system, "Hiragino Kaku Gothic ProN", "Noto Sans JP", sans-serif; }
  .card { width:100%; max-width:34rem; background:var(--card); border:1px solid var(--line);
          border-radius:14px; padding:36px 32px; }
  h1 { margin:0 0 12px; font-size:1.45rem; letter-spacing:.01em; }
  p { margin:0 0 14px; line-height:1.75; color:var(--muted); }
  .host { display:inline-block; margin-top:18px; padding:5px 11px; border:1px solid var(--line);
          border-radius:999px; font-size:.82rem; color:var(--muted); font-family: ui-monospace, monospace; }
  .bar { height:3px; width:100%; margin:22px 0 4px; border-radius:2px; overflow:hidden; background:var(--line); }
  .bar span { display:block; height:100%; width:38%; border-radius:2px; background:var(--accent);
              animation: slide 1.9s ease-in-out infinite; }
  @keyframes slide { 0%{transform:translateX(-100%)} 100%{transform:translateX(300%)} }
  @media (prefers-reduced-motion: reduce) { .bar span { animation:none; width:100% } }
</style>
</head>
<body>
  <main class="card">
    <h1>メンテナンス中です</h1>
    <p>サーバーの入れ替え作業をしています。作業が終わり次第このページは自動で元に戻ります。</p>
    <p>しばらく待ってから再読み込みしてください。</p>
    <div class="bar"><span></span></div>
    <span class="host">${host}</span>
  </main>
</body>
</html>`;
}
