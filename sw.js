/* Seekers League keeps nothing offline and intercepts no request. This worker
   exists because phone browsers only let a site raise a notification through
   one. It shows two kinds: the ones the open page raises itself, and (since
   2026-11-09) the ones pushed by the server when this device has notifications
   on (Account > Notifications). Tapping a notification brings the site back to
   the front and opens what it was about. The address comes from the
   notification's data and is used only when it belongs to this site. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
/* 2026-11-09: pushed notifications. The payload is {v, id, kind, fam, title,
   body, tag, url, ts, data}; unknown fields and a missing data are fine. A
   page in front gets the message too (sl-push) and the notification is then
   silent; the match and round kinds vibrate only when no page is in front. */
const LOUD = /^(t_round|t_bye|t_invite|m_join|gm_join|gm_live|m_confirm|gm_confirm)$/;
function fmtT(body, iso) {                    // {t} weekday day month time, {h} time only, phone's timezone
  const d = new Date(iso || "");
  if (!iso || isNaN(d)) return body.replace(/ ?· ?\{[th]\}|\{[th]\} ?· ?|\{[th]\}/g, "");
  // Same locale rule as the site (slEnLoc / SL_LOC / SL_H12 in index.html): English, US or GB order, the device's 12/24 h.
  const lang = (self.navigator && self.navigator.language) || undefined;
  let loc = "en-GB", h12;
  try { const p = new Intl.DateTimeFormat(lang, {day:"numeric",month:"numeric",year:"numeric"}).formatToParts(new Date(2026,10,30)),
            i = k => p.findIndex(x => x.type === k);
        if (i("month") > -1 && i("month") < i("day")) loc = "en-US";
        h12 = !!new Intl.DateTimeFormat(lang, {hour:"numeric"}).resolvedOptions().hour12 } catch (x) { h12 = loc === "en-US" }
  const f = o => { try { return new Intl.DateTimeFormat(loc, Object.assign({}, o, {hour12: h12})).format(d) } catch (x) { return d.toISOString().slice(0,16).replace("T"," ") } };
  return body.replace(/\{t\}/g, f({weekday:"short",day:"numeric",month:"short",hour:"2-digit",minute:"2-digit"}))
             .replace(/\{h\}/g, f({hour:"2-digit",minute:"2-digit"}));
}
self.addEventListener("push", e => {
  let p = {}; try { p = e.data ? e.data.json() : {} } catch (x) {}
  p = p && typeof p === "object" ? p : {};
  const dd = (typeof p.data === "object" && p.data) || {};
  const title = String(p.title || "Seekers League").slice(0, 120);
  const body = fmtT(String(p.body || ""), dd.starts_at).slice(0, 300);
  const data = Object.assign({}, dd, { url: String(p.url || ""), kind: String(p.kind || ""),
                tid: dd.tid || null, month: null, lid: dd.lid || null });
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(l => {
    const vis = l.filter(c => c.visibilityState === "visible");
    vis.forEach(c => { try { c.postMessage({ type: "sl-push", kind: data.kind, fam: String(p.fam || ""), title, body, url: data.url, data }) } catch (x) {} });
    const o = { body, tag: String(p.tag || "sl"), renotify: true, icon: "icons/icon-192.png", badge: "icons/badge-96.png",
                data, timestamp: +p.ts || Date.now() };
    if (vis.length) o.silent = true; else if (LOUD.test(data.kind)) o.vibrate = [200, 100, 200];   // never both: showNotification throws
    return self.registration.showNotification(title, o);   // always show one (iOS revokes the subscription otherwise)
  }));
});
/* The browser renewed the subscription: subscribe again with the same key when
   it did not, and tell an open page (sl-resub), which sends the new address to
   the server. With no page open, the next visit does it (slPushSync). */
self.addEventListener("pushsubscriptionchange", e => {
  const k = e.oldSubscription && e.oldSubscription.options && e.oldSubscription.options.applicationServerKey;
  const old = e.oldSubscription && e.oldSubscription.endpoint || null;
  e.waitUntil((e.newSubscription ? Promise.resolve(e.newSubscription)
      : k ? self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: k }) : Promise.resolve(null))
    .then(() => self.clients.matchAll({ type: "window", includeUncontrolled: true }))
    .then(l => l.forEach(c => c.postMessage({ type: "sl-resub", old })))
    .catch(() => {}));
});
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
      c.postMessage({ type: "sl-open", url, tid: d.tid || null, month: d.month || null, lid: d.lid || null, kind: d.kind || null });
      return c.focus();
    })
  );
});
