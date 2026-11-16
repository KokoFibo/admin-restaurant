/* Service worker Dapora Admin.
 * Tujuan: aplikasi bisa dipasang dan terbuka cepat. SENGAJA tidak menyimpan data: /api, /v1, Supabase (login, pesanan, tagihan) dan semua
 * permintaan selain GET selalu langsung ke jaringan. Tanpa internet, panel tidak bisa mencatat apa pun (itu disengaja). */
const SHELL = 'dapora-shell-v1', ASSETS = 'dapora-assets-v1';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil((async () => {
  const keep = [SHELL, ASSETS];
  await Promise.all((await caches.keys()).filter(k => !keep.includes(k)).map(k => caches.delete(k)));
  await self.clients.claim();
})()));

async function cacheFirst(name, req) {
  const c = await caches.open(name), hit = await c.match(req); if (hit) return hit;
  const res = await fetch(req); if (res.ok && res.type === 'basic') c.put(req, res.clone()); return res;
}
async function swr(name, req) {
  const c = await caches.open(name), hit = await c.match(req);
  const net = fetch(req).then(res => { if (res.ok) c.put(req, res.clone()); return res; }).catch(() => hit);
  return hit || net;
}
/** Halaman: selalu coba jaringan (versi terbaru); bila offline, pakai kerangka yang tersimpan. */
async function page(req) {
  const c = await caches.open(SHELL);
  try {
    const res = await fetch(req);
    if (res.ok && (res.headers.get('content-type') || '').includes('text/html')) c.put('/index.html', res.clone());
    return res;
  } catch {
    return (await c.match('/index.html')) || new Response('Tidak ada koneksi internet.', { status: 503, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  }
}

self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    const p = url.pathname;
    if (p.startsWith('/api/') || p.startsWith('/v1/') || p === '/version.json' || p === '/sw.js') return;   // langsung ke jaringan
    if (p.startsWith('/assets/')) return e.respondWith(cacheFirst(ASSETS, req));                        // berkas bernama-hash: tidak pernah berubah
    if (req.mode === 'navigate') return e.respondWith(page(req));
    if (p.startsWith('/icons/') || p === '/manifest.webmanifest') return e.respondWith(swr(SHELL, req));
    return;
  }
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') e.respondWith(swr(ASSETS, req));
});
