/* Seekers League keeps nothing offline and intercepts no request. This worker
   exists for one reason: phone browsers only let a page raise a notification
   through one. Tapping the notification brings the site back to the front. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true })
      .then(l => (l.length ? l[0].focus() : self.clients.openWindow("./")))
  );
});
