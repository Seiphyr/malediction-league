/* Seekers League keeps nothing offline and intercepts no request. This worker
   exists for one reason: phone browsers only let a page raise a notification
   through one. Tapping the notification brings the site back to the front and
   opens the tournament it was about. The address comes from the notification's
   data and is used only when it belongs to this site. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const d = e.notification.data || {};
  let url = self.registration.scope;
  try {
    const u = new URL(String(d.url || ""), self.registration.scope);
    if (u.origin === self.location.origin) url = u.href;
  } catch (x) {}
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(l => {
      const c = l.find(x => x.focused) || l[0];
      if (!c) return self.clients.openWindow(url);
      c.postMessage({ type: "sl-open", url, tid: d.tid || null, month: d.month || null });
      return c.focus();
    })
  );
});
