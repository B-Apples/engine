/* Engine service worker. The app shell is cached per version so Engine opens with no signal; tools/stamp.py
   rewrites VERSION from the shell files' contents before each publish, which is what makes phones pick up an update.
   Supabase data, auth and evaluations always go to the network (the app keeps its own offline copy and outbox). */
const VERSION = '2ead46864c03';
const SHELL = 'engine-shell-' + VERSION;
const RUNTIME = 'engine-runtime';
const FILES = ['./', 'index.html', 'config.js', 'backend.js', 'vendor/supabase.js', 'manifest.webmanifest',
  'icons/icon.svg', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/maskable-512.png', 'icons/apple-touch-icon.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES.map(f => new Request(f, { cache: 'reload' })))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k.startsWith('engine-shell-') && k !== SHELL).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

async function fromShell(req) {
  const hit = await caches.match(req, { cacheName: SHELL, ignoreSearch: true });
  return hit || fetch(req);
}
// Fonts and signed photo links never change for a given URL, so the first copy is kept.
async function cacheFirst(req) {
  const c = await caches.open(RUNTIME);
  const hit = await c.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok || res.type === 'opaque') c.put(req, res.clone());
  return res;
}
async function staleWhileRevalidate(req) {
  const c = await caches.open(RUNTIME);
  const hit = await c.match(req);
  const net = fetch(req).then(res => { if (res.ok) c.put(req, res.clone()); return res; }).catch(() => hit);
  return hit || net;
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    if (req.mode === 'navigate') e.respondWith(caches.match('index.html', { cacheName: SHELL }).then(r => r || fetch(req)));
    else e.respondWith(fromShell(req));
    return;
  }
  if (url.hostname === 'fonts.googleapis.com') return e.respondWith(staleWhileRevalidate(req));
  if (url.hostname === 'fonts.gstatic.com') return e.respondWith(cacheFirst(req));
  if (url.hostname.endsWith('.supabase.co') && url.pathname.startsWith('/storage/v1/object/sign/')) return e.respondWith(cacheFirst(req));
});
