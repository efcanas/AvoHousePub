const CACHE_NAME = 'avohouse-images-v2';

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      const scope = self.registration.scope;
      return cache.addAll([
        new URL('Fondo.webp', scope).href,
        new URL('LogoPrincipal.png', scope).href
      ]);
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key.startsWith('avohouse-images-') && key !== CACHE_NAME)
          .map(key => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});


 // Web Push: mostrar el aviso recibido y abrir el panel administrativo al tocarlo.
self.addEventListener('push', event => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = { body: event.data ? event.data.text() : '' };
  }

  const title = typeof payload.title === 'string' && payload.title
    ? payload.title
    : 'AvoHouse';
  const options = {
    body: typeof payload.body === 'string' ? payload.body : '',
    icon: payload.icon || new URL('LogoPrincipal.png', self.registration.scope).href,
    badge: payload.badge || new URL('LogoPrincipal.png', self.registration.scope).href,
    tag: payload.tag || 'ah-admin-notification',
    renotify: payload.renotify === true,
    requireInteraction: payload.requireInteraction === true,
    data: {
      url: typeof payload.url === 'string' ? payload.url : '/ahtv/admin/index.html'
    }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const relativeTarget = event.notification.data && event.notification.data.url
    ? event.notification.data.url
    : '/ahtv/admin/index.html';
  const targetUrl = new URL(relativeTarget, self.registration.scope).href;

  event.waitUntil((async () => {
    const windowClients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true
    });

    for (const client of windowClients) {
      if ('focus' in client) {
        if ('navigate' in client) await client.navigate(targetUrl);
        return client.focus();
      }
    }
    if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);

  if (request.method !== 'GET' || url.origin !== self.location.origin || request.destination !== 'image') {
    return;
  }

  event.respondWith(
    caches.match(request).then(cached => {
      const network = fetch(request).then(response => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
        }
        return response;
      }).catch(() => cached);

      return cached || network;
    })
  );
});
