/* ════════════════════════════════════════════════════════════════
   Ghost Chat — Service Worker
   Handles Web Push notifications when the app is closed / in background.

   Setup:
   1. Run: npx web-push generate-vapid-keys
   2. Put the Public Key in index.html → VAPID_PUBLIC_KEY
   3. Put both keys in Supabase Edge Function secrets
   4. Deploy the edge function (see supabase/functions/push-notify/index.ts)
   ════════════════════════════════════════════════════════════════ */

const CACHE_NAME = 'ghost-chat-v1';

/* ── Install: pre-cache essential files ── */
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(['/']))
  );
});

/* ── Activate: clean up old caches ── */
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

/* ── Push: show notification ONLY when app is in background / closed ── */
self.addEventListener('push', event => {
  let data = { title: 'Ghost Chat', body: 'New message', icon: '' };
  try { data = { ...data, ...event.data.json() }; } catch(e) {}

  event.waitUntil(
    // Check every open window that belongs to this service worker
    self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then(clientList => {
        // If ANY window has the app open AND is currently focused/visible → skip
        const appIsActive = clientList.some(
          client => client.focused || client.visibilityState === 'visible'
        );

        if (appIsActive) {
          // App is open — the in-app notification banner handles it; do nothing
          return;
        }

        // App is closed or in background → show OS notification
        const options = {
          body:     data.body,
          icon:     data.icon || '/icon-192.png',
          badge:    '/icon-192.png',
          tag:      data.tag || 'ghost-chat-msg',
          renotify: true,
          silent:   false,
          vibrate:  [200, 100, 200],
          data:     { url: data.url || '/' },
          actions: [
            { action: 'open',    title: 'Open Chat' },
            { action: 'dismiss', title: 'Dismiss'   }
          ]
        };

        return self.registration.showNotification(data.title, options);
      })
  );
});

/* ── Notification click: focus or open the app ── */
self.addEventListener('notificationclick', event => {
  event.notification.close();
  if (event.action === 'dismiss') return;

  const targetUrl = event.notification.data?.url || '/';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      // Focus existing tab if already open
      for (const client of clientList) {
        if ((client.url.includes('index.html') || client.url === targetUrl) && 'focus' in client) {
          return client.focus();
        }
      }
      // Otherwise open a new tab
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});

/* ── Push subscription change: re-subscribe if token refreshes ── */
self.addEventListener('pushsubscriptionchange', event => {
  event.waitUntil(
    self.registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: event.oldSubscription?.options?.applicationServerKey
    }).then(sub => {
      // Notify all open windows to re-save the subscription
      return self.clients.matchAll({ type:'window' }).then(clients => {
        clients.forEach(c => c.postMessage({ type:'push-resubscribe', sub: sub.toJSON() }));
      });
    })
  );
});
