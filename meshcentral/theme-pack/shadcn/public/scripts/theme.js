// MeshCentral "shadcn" theme pack.
// The main app sets data-bs-theme itself; standalone pages (login, terms, messages) do not,
// so mirror the user's night mode choice there to keep both halves of the UI consistent.
(function () {
    function apply() {
        if (typeof setNightMode === 'function') return; // Main app handles it.
        var mode = '0';
        try { mode = localStorage.getItem('nightMode') || '0'; } catch (ex) { }
        var dark = (mode == '1') || ((mode == '0') && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
        document.documentElement.setAttribute('data-bs-theme', dark ? 'dark' : 'light');
    }
    apply();
    if (window.matchMedia) { window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', apply); }
})();
