/* Service worker for the Beach Stat Collector.

   Strategy: network-first with a short timeout, falling back to cache.

   Why not cache-first (the usual choice for an offline app)? Because the
   app is installed to a home screen and updated by pushing to GitHub
   Pages. Cache-first would pin an installed instance to whatever version
   it first saw, and pushed fixes would never arrive. Network-first keeps
   the cache refreshed on every online launch while still opening
   instantly with no signal — at a venue the fetch rejects immediately and
   the cached shell is served.

   Bump VERSION on each release: it names the cache (so old ones are
   purged on activate) and changes this file's bytes, which is what makes
   the browser notice there is a new worker at all. */

const VERSION = 'v3.1.0';
const CACHE = 'bvstat-' + VERSION;
const TIMEOUT_MS = 3000;

const SHELL = [
  './',
  './index.html',
  './config.js',
  './sync.js',
  './manifest.json',
  './apple-touch-icon.png',
  './icon-192.png',
  './icon-512.png',
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  if (new URL(req.url).origin !== self.location.origin) return;
  event.respondWith(networkFirst(event, req));
});

async function networkFirst(event, req) {
  const cache = await caches.open(CACHE);
  try {
    const fresh = await withTimeout(fetch(req), TIMEOUT_MS);
    if (fresh && fresh.ok) event.waitUntil(cache.put(req, fresh.clone()));
    return fresh;
  } catch (err) {
    const hit = await cache.match(req);
    if (hit) return hit;
    /* A navigation to any path under scope should still open the app. */
    if (req.mode === 'navigate') {
      const shell = (await cache.match('./index.html')) || (await cache.match('./'));
      if (shell) return shell;
    }
    throw err;
  }
}

/* A dead network rejects fast, but a captive portal can hang for a long
   time. Racing a timer keeps a courtside launch snappy either way. */
function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('network timeout')), ms);
    promise.then(
      value => { clearTimeout(timer); resolve(value); },
      error => { clearTimeout(timer); reject(error); }
    );
  });
}
