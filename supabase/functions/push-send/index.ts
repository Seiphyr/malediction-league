// Supabase Edge Function "push-send" for Seekers League.
//
// Delivers the Web Push notifications queued in public.push_outbox. The
// database kicks it (push_kick, through pg_net) when a message is queued,
// and the pg_cron job sl-push (push_tick) kicks it once a minute for the
// rest: messages queued for later, retries. Nobody's browser calls it.
//
//   POST /functions/v1/push-send          header x-push-secret: <secret>
//   POST /functions/v1/push-send?wait=1   the same, but waits for the run
//
// Answers (JSON):
//   202 { "ok": true, "started": true }      the run goes on in the background
//   200 { "ok": true, "claimed": n, "sent": n, "retry": n, "failed": n,
//         "gone": n, "ms": n }               ?wait=1 (or no EdgeRuntime)
//   502 { "ok": false, "code": "claim_failed" | "done_failed", ...counts }
//   401 { "ok": false, "code": "forbidden" }       x-push-secret is wrong
//   503 { "ok": false, "code": "not_configured" }  a secret is missing
//   503 { "ok": false, "code": "vapid_mismatch" }  the VAPID keys are no pair
//   405 (not POST), 413 (body over 1 KB; the body is otherwise ignored)
//
// A run claims up to 40 messages at a time with the service role
// (push_claim, a 120 s lease), encrypts each one for each of the player's
// devices (RFC 8291, aes128gcm), signs a VAPID token (RFC 8292, ES256),
// posts it to the device's push service, and reports back (push_done):
// sent, retry later (429, 5xx, timeout, network) or failed; devices the push
// service no longer knows (404, 410) are deleted. No new claim after 30 s or
// 400 messages; a batch still running 60 s after its claim stops and its
// untried messages are retried later, so the lease never runs out under a
// send (cron and kick runs overlap all the time).
//
// It only ever posts to the push services of the browsers (the same host
// list as push_subscribe), with no redirects and a 10 s timeout. No imports:
// plain fetch and WebCrypto, so the file deploys from the dashboard as is.
//
// "Verify JWT" is turned off for this function in the dashboard: the shared
// secret (Vault sl_push_secret = function secret PUSH_CRON_SECRET) is the
// only way in. Logs carry counts and short error codes only, never
// endpoints, keys, user ids or message text.

const MAX_REQUEST_BYTES = 1024;
const CLAIM_ROWS = 40;            // rows per push_claim
const LEASE_S = 120;              // push_claim lease
const RUN_ROWS_MAX = 400;         // rows per run
// 2026-11-09: the worst case of one claim must be reported inside its lease, and the
// last claim's inside the 150 s wall clock of the free plan:
// BATCH_DEADLINE_MS + SEND_TIMEOUT_MS + 2 * RPC_TIMEOUT_MS + 1 s = 91 s < 120 s lease;
// CLAIM_WINDOW_MS + 91 s = 121 s < 150 s.
const CLAIM_WINDOW_MS = 30_000;   // no new claim after this, from the start of the run
const BATCH_DEADLINE_MS = 60_000; // no new send this long after a claim
const POOL = 8;                   // sends at once
const SEND_TIMEOUT_MS = 10_000;
const RPC_TIMEOUT_MS = 10_000;
const PAYLOAD_MAX = 3000;         // bytes of JSON before encryption
const RS = 4096;                  // aes128gcm record size (one record)
const JWT_TTL_S = 12 * 3600;
const DEFAULT_SUBJECT = "https://seekers-league.com";
// The same list as push_subscribe in the database.
const PUSH_HOSTS =
  /^(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9.-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)$/;
const URGENCY = new Set(["very-low", "low", "normal", "high"]);

type Json = Record<string, unknown>;
type Bytes = Uint8Array<ArrayBuffer>;

// ---------------------------------------------------------------- config

// The newer API keys when the runtime provides them (SUPABASE_SECRET_KEYS, a
// JSON object keyed by name), else the legacy service_role key (same rule as
// play-network-event and tournament-auto).
function envKey(listName: string, legacyName: string): string {
  const raw = (Deno.env.get(listName) ?? "").trim();
  if (raw) {
    try {
      const v: unknown = JSON.parse(raw);
      if (typeof v === "string" && v) return v;
      if (v && typeof v === "object") {
        const o = v as Record<string, unknown>;
        const k = typeof o.default === "string" && o.default ? o.default : Object.values(o).find((x) => typeof x === "string" && x);
        if (typeof k === "string" && k) return k;
      }
    } catch {
      if (/^sb_[a-z]+_\S+$/.test(raw)) return raw;
    }
  }
  return Deno.env.get(legacyName) ?? "";
}

type Config = {
  url: string; key: string; secret: string; pub: string; priv: string; subject: string;
  testHosts: Set<string>;
};

// Read on every request (cheap), so a changed secret needs no cold start.
function config(): Config {
  const url = (Deno.env.get("SUPABASE_URL") ?? "").trim().replace(/\/+$/, "");
  // Tests only: extra hosts, plain http allowed, when the project is local.
  const local = /^http:\/\/127\.0\.0\.1(:[0-9]{1,5})?$/.test(url);
  const testHosts = new Set(
    local ? (Deno.env.get("PUSH_TEST_HOSTS") ?? "").split(",").map((h) => h.trim().toLowerCase()).filter(Boolean) : [],
  );
  return {
    url,
    key: envKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY").trim(),
    secret: (Deno.env.get("PUSH_CRON_SECRET") ?? "").trim(),
    pub: (Deno.env.get("VAPID_PUBLIC_KEY") ?? "").trim(),
    priv: (Deno.env.get("VAPID_PRIVATE_KEY") ?? "").trim(),
    subject: (Deno.env.get("VAPID_SUBJECT") ?? "").trim() || DEFAULT_SUBJECT,
    testHosts,
  };
}

// ---------------------------------------------------------------- bytes

const te = new TextEncoder();

function b64u(b: Uint8Array | ArrayBuffer): string {
  const u = b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = "";
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Accepts base64url and standard base64, with or without "=" padding.
function unb64u(s: string): Bytes {
  const t = String(s).trim().replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
  if (!/^[A-Za-z0-9+/]*$/.test(t) || t.length % 4 === 1) throw new Error("bad_base64");
  const bin = atob(t + "===".slice((t.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function cat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

async function sha256(b: Bytes): Promise<Bytes> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", b));
}

async function hmac(key: Bytes, data: Bytes): Promise<Bytes> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

// Constant time: both sides hashed, then the digests XOR-compared.
async function sameSecret(given: string, want: string): Promise<boolean> {
  const [a, b] = await Promise.all([sha256(te.encode(given)), sha256(te.encode(want))]);
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0 && want.length > 0;
}

// ---------------------------------------------------------------- RFC 8291

// Encrypts one message for one subscription (aes128gcm, a single record).
// opts (salt, asKeyPair) are for the RFC 8291 section 5 test vector only;
// normally both are fresh for every message.
async function encryptAes128gcm(
  payload: Uint8Array | string,
  uaPub: Bytes,
  auth: Bytes,
  opts?: { salt?: Bytes; asKeyPair?: CryptoKeyPair },
): Promise<Bytes> {
  const plain = typeof payload === "string" ? te.encode(payload) : payload;
  if (uaPub.length !== 65 || uaPub[0] !== 4) throw new Error("bad_keys");
  if (auth.length !== 16) throw new Error("bad_keys");
  if (plain.length + 1 + 16 > RS) throw new Error("too_big");
  const salt = opts?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const as = opts?.asKeyPair ??
    (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]) as CryptoKeyPair);
  const asPub = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const ua = await crypto.subtle.importKey("raw", uaPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: ua }, as.privateKey, 256));
  const prkKey = await hmac(auth, ecdh);
  const ikm = await hmac(prkKey, cat(te.encode("WebPush: info\0"), uaPub, asPub, new Uint8Array([1])));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, cat(te.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, cat(te.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const key = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, cat(plain, new Uint8Array([2]))));
  const head = new Uint8Array(21);
  head.set(salt, 0);
  new DataView(head.buffer).setUint32(16, RS);
  head[20] = asPub.length;
  return cat(head, asPub, ct);
}

// ---------------------------------------------------------------- RFC 8292

type Vapid = { id: string; pub: string; key: CryptoKey };
let vapidCache: Vapid | null = null;

// Imported once per isolate (per key pair), with a sign-and-verify self-test.
async function vapidKeys(pubS: string, privS: string): Promise<Vapid | null> {
  const id = b64u(await sha256(te.encode(pubS + "|" + privS)));
  if (vapidCache && vapidCache.id === id) return vapidCache;
  try {
    const pub = unb64u(pubS), d = unb64u(privS);
    if (pub.length !== 65 || pub[0] !== 4 || d.length !== 32) return null;
    const jwk = { kty: "EC", crv: "P-256", x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33, 65)), d: b64u(d) };
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const ver = await crypto.subtle.importKey("raw", pub, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const probe = crypto.getRandomValues(new Uint8Array(32));
    const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, probe);
    if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, ver, sig, probe))) return null;
    vapidCache = { id, pub: b64u(pub), key };
    return vapidCache;
  } catch {
    return null;
  }
}

// ES256 JWT for one push service origin. WebCrypto's ECDSA signature is
// already the raw r||s (64 bytes) that JWS wants.
async function vapidJwt(aud: string, sub: string, key: CryptoKey, nowS = Math.floor(Date.now() / 1000)): Promise<string> {
  const h = b64u(te.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const c = b64u(te.encode(JSON.stringify({ aud, exp: nowS + JWT_TTL_S, sub })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, te.encode(h + "." + c));
  return h + "." + c + "." + b64u(sig);
}

// ---------------------------------------------------------------- PostgREST

type Rpc = { ok: true; data: unknown } | { ok: false; code: string };

async function rpc(cfg: Config, name: string, args: Json): Promise<Rpc> {
  const headers: Record<string, string> = {
    apikey: cfg.key,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  // A legacy service_role JWT also needs Authorization; an sb_secret_ key must not have it.
  if (cfg.key.startsWith("eyJ")) headers.Authorization = "Bearer " + cfg.key;
  try {
    const res = await fetch(cfg.url + "/rest/v1/rpc/" + name, {
      method: "POST",
      headers,
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
    });
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      return { ok: false, code: "http_" + res.status };
    }
    return { ok: true, data: await res.json() };
  } catch (e) {
    return { ok: false, code: e instanceof Error && e.name === "TimeoutError" ? "timeout" : "net" };
  }
}

// ---------------------------------------------------------------- one message

type Sub = { id: string | null; endpoint: string; p256dh: string; auth: string };
type Row = {
  id: number; kind: string; fam: string; title: string; body: string; url: string; tag: string;
  urgency: string; ttl: number; ts: number; data: Json; subs: Sub[];
};
type Outcome = { as: "okd" | "gone" | "bad" | null; err: string | null; retry: boolean; after: number | null };

const str = (v: unknown, max = 4096) => (typeof v === "string" ? v : v == null ? "" : String(v)).slice(0, max);

function parseRow(v: unknown): Row | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Json;
  const id = Number(o.id);
  if (!Number.isSafeInteger(id)) return null;
  const subs: Sub[] = (Array.isArray(o.subs) ? o.subs : []).filter((s) => s && typeof s === "object").map((s) => {
    const x = s as Json;
    return { id: typeof x.id === "string" ? x.id : null, endpoint: str(x.endpoint), p256dh: str(x.p256dh, 200), auth: str(x.auth, 100) };
  });
  const ts = Date.parse(str(o.ts, 64));
  const ttl = Math.floor(Number(o.ttl));
  return {
    id,
    kind: str(o.kind, 40),
    fam: str(o.fam, 40),
    title: str(o.title),
    body: str(o.body, 16384),
    url: str(o.url, 1024),
    tag: str(o.tag, 200) || "sl",
    urgency: URGENCY.has(str(o.urgency)) ? str(o.urgency) : "normal",
    ttl: Number.isFinite(ttl) ? Math.max(0, Math.min(ttl, 2419200)) : 0,
    ts: Number.isFinite(ts) ? ts : Date.now(),
    data: o.data && typeof o.data === "object" && !Array.isArray(o.data) ? (o.data as Json) : {},
    subs,
  };
}

// The JSON the service worker reads (spec 2.3). Over 3000 bytes, the body is
// cut first, then the title, each ending with "…". null: it cannot fit.
function buildPayload(r: Row): Bytes | null {
  const o = { v: 1, id: r.id, kind: r.kind, fam: r.fam, title: r.title, body: r.body, tag: r.tag, url: r.url, ts: r.ts, data: r.data };
  const enc = () => te.encode(JSON.stringify(o));
  let b: Bytes;
  for (const f of ["body", "title"] as const) {
    b = enc();
    if (b.length <= PAYLOAD_MAX) return b;
    const cps = Array.from(o[f]);
    const at = (n: number) => (o[f] = cps.slice(0, n).join("").trimEnd() + "…", enc());
    let lo = 0, hi = cps.length - 1;       // largest n whose cut fits
    if (at(0).length > PAYLOAD_MAX) {
      o[f] = f === "body" ? "" : "…";
      b = enc();
      if (b.length <= PAYLOAD_MAX) return b;
      continue;
    }
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (at(mid).length <= PAYLOAD_MAX) lo = mid;
      else hi = mid - 1;
    }
    return at(lo);
  }
  return null;
}

function hostAllowed(endpoint: string, cfg: Config): URL | null {
  if (endpoint.length > 1024) return null;
  let u: URL;
  try {
    u = new URL(endpoint);
  } catch {
    return null;
  }
  if (u.username || u.password) return null;
  const host = u.hostname.toLowerCase();
  if (cfg.testHosts.has(host) && (u.protocol === "http:" || u.protocol === "https:")) return u;
  if (u.protocol !== "https:" || u.port !== "" || !PUSH_HOSTS.test(host)) return null;
  return u;
}

function retryAfter(v: string | null): number | null {
  if (!v) return null;
  const s = v.trim();
  const n = /^[0-9]{1,10}$/.test(s) ? Number(s) : Math.ceil((Date.parse(s) - Date.now()) / 1000);
  return Number.isFinite(n) ? Math.max(0, Math.min(n, 3600)) : null;
}

type Run = { vapid: Vapid; cfg: Config; jwts: Map<string, Promise<string>> };

async function sendOne(run: Run, r: Row, payload: Bytes, s: Sub): Promise<Outcome> {
  const u = hostAllowed(s.endpoint, run.cfg);
  if (!u) return { as: "bad", err: "host", retry: false, after: null };
  let body: Bytes;
  try {
    body = await encryptAes128gcm(payload, unb64u(s.p256dh), unb64u(s.auth));
  } catch {
    return { as: "bad", err: "bad_keys", retry: false, after: null };
  }
  const aud = u.origin;
  let jwt = run.jwts.get(aud);
  if (!jwt) {
    jwt = vapidJwt(aud, run.cfg.subject, run.vapid.key);
    run.jwts.set(aud, jwt);
  }
  const topic = b64u(await sha256(te.encode(r.tag))).slice(0, 32);
  let res: Response;
  try {
    res = await fetch(u.href, {
      method: "POST",
      redirect: "manual",
      headers: {
        TTL: String(r.ttl),
        Urgency: r.urgency,
        Topic: topic,
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        Authorization: "vapid t=" + (await jwt) + ", k=" + run.vapid.pub,
      },
      body,
      signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
    });
  } catch (e) {
    const n = e instanceof Error ? e.name : "";
    return { as: null, err: n === "TimeoutError" || n === "AbortError" ? "timeout" : "net", retry: true, after: null };
  }
  await res.body?.cancel().catch(() => {});
  const st = res.status;
  if (st === 200 || st === 201 || st === 202) return { as: "okd", err: null, retry: false, after: null };
  if (st === 404 || st === 410) return { as: "gone", err: null, retry: false, after: null };
  if (st === 429 || st >= 500) {
    return { as: "bad", err: st === 429 ? "http_429" : "http_5xx", retry: true, after: retryAfter(res.headers.get("retry-after")) };
  }
  return { as: "bad", err: "http_" + st, retry: false, after: null };
}

// ---------------------------------------------------------------- one run

type Done = { id: number; status: "sent" | "retry" | "failed"; err: string | null; retry_after_s: number | null; gone: string[]; okd: string[]; bad: string[] };
type Counts = { claimed: number; sent: number; retry: number; failed: number; gone: number };

function rowResult(id: number, outs: Outcome[], subs: Sub[], fixedErr: string | null): Done {
  const d: Done = { id, status: "failed", err: null, retry_after_s: null, gone: [], okd: [], bad: [] };
  if (fixedErr) return { ...d, err: fixedErr };
  let firstErr: string | null = null, retryErr: string | null = null;
  for (let i = 0; i < outs.length; i++) {
    const o = outs[i], sid = subs[i].id;
    if (o.as && sid) d[o.as].push(sid);
    if (o.err && !firstErr) firstErr = o.err;
    if (o.retry && !retryErr) retryErr = o.err;
    if (o.after != null) d.retry_after_s = Math.max(d.retry_after_s ?? 0, o.after);
  }
  if (outs.some((o) => o.as === "okd")) {
    d.status = "sent";
    d.retry_after_s = null;
  } else if (retryErr) {
    d.status = "retry";
    d.err = retryErr;
  } else {
    d.err = firstErr ?? (outs.length && outs.every((o) => o.as === "gone") ? "gone" : "no_subscription");
  }
  return d;
}

async function batch(run: Run, rows: Row[], claimedAt: number): Promise<Done[]> {
  type Task = { r: number; s: number; payload: Bytes };
  const outs: (Outcome | undefined)[][] = rows.map((r) => r.subs.map(() => undefined));
  const fixed: (string | null)[] = rows.map(() => null);
  const tasks: Task[] = [];
  rows.forEach((r, ri) => {
    const payload = buildPayload(r);
    if (!payload) fixed[ri] = "too_big";
    else if (!r.subs.length) fixed[ri] = "no_subscription";
    else r.subs.forEach((_, si) => tasks.push({ r: ri, s: si, payload }));
  });
  let next = 0;
  const late = () => Date.now() - claimedAt >= BATCH_DEADLINE_MS;
  const worker = async () => {
    while (next < tasks.length && !late()) {
      const t = tasks[next++];
      const r = rows[t.r];
      try {
        outs[t.r][t.s] = await sendOne(run, r, t.payload, r.subs[t.s]);
      } catch {
        outs[t.r][t.s] = { as: null, err: "error", retry: true, after: null };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(POOL, tasks.length) }, worker));
  return rows.map((r, ri) =>
    rowResult(r.id, outs[ri].map((o) => o ?? { as: null, err: "deadline", retry: true, after: null }), r.subs, fixed[ri])
  );
}

async function drain(cfg: Config, vapid: Vapid): Promise<Json> {
  const t0 = Date.now();
  const c: Counts = { claimed: 0, sent: 0, retry: 0, failed: 0, gone: 0 };
  const codes: Record<string, number> = {};
  const run: Run = { vapid, cfg, jwts: new Map() };
  let fail: string | null = null;
  while (Date.now() - t0 < CLAIM_WINDOW_MS && c.claimed < RUN_ROWS_MAX) {
    const claimedAt = Date.now();
    const got = await rpc(cfg, "push_claim", { p_limit: Math.min(CLAIM_ROWS, RUN_ROWS_MAX - c.claimed), p_lease_s: LEASE_S });
    if (!got.ok) {
      console.error("push-send: push_claim failed", got.code);
      fail = "claim_failed";
      break;
    }
    const list = Array.isArray(got.data) ? got.data : [];
    if (!list.length) break;
    c.claimed += list.length;
    const rows = list.map(parseRow).filter((r): r is Row => r !== null);
    const res = await batch(run, rows, claimedAt);
    let done = await rpc(cfg, "push_done", { p_res: res });
    if (!done.ok) {
      await new Promise((ok) => setTimeout(ok, 1000));
      done = await rpc(cfg, "push_done", { p_res: res });
    }
    for (const d of res) {
      c[d.status]++;
      c.gone += d.gone.length;
      if (d.err) codes[d.err] = (codes[d.err] ?? 0) + 1;
    }
    if (!done.ok) {
      // The rows stay claimed until their lease ends, then go out again.
      console.error("push-send: push_done failed", done.code);
      fail = "done_failed";
      break;
    }
  }
  const out = { ...c, ms: Date.now() - t0 };
  console.log("push-send: run", JSON.stringify({ ...out, codes }));
  return fail ? { ok: false, code: fail, ...out } : { ok: true, ...out };
}

// ---------------------------------------------------------------- endpoint

function reply(body: Json, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

// The body is not used; only its size is checked.
async function bodyTooBig(req: Request): Promise<boolean> {
  if (Number(req.headers.get("content-length") ?? "0") > MAX_REQUEST_BYTES) return true;
  if (!req.body) return false;
  const reader = req.body.getReader();
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return false;
    size += value.byteLength;
    if (size > MAX_REQUEST_BYTES) {
      await reader.cancel().catch(() => {});
      return true;
    }
  }
}

type EdgeRt = { waitUntil?: (p: Promise<unknown>) => void };

async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return reply({ ok: false, code: "bad_method" }, 405);
  try {
    if (await bodyTooBig(req)) return reply({ ok: false, code: "too_big" }, 413);
    const cfg = config();
    if (!cfg.secret || !cfg.pub || !cfg.priv || !cfg.url || !cfg.key) {
      console.error("push-send: not_configured");
      return reply({ ok: false, code: "not_configured" }, 503);
    }
    if (!(await sameSecret(req.headers.get("x-push-secret") ?? "", cfg.secret))) {
      return reply({ ok: false, code: "forbidden" }, 401);
    }
    const vapid = await vapidKeys(cfg.pub, cfg.priv);
    if (!vapid) {
      console.error("push-send: vapid_mismatch");
      return reply({ ok: false, code: "vapid_mismatch" }, 503);
    }
    const safe = () =>
      drain(cfg, vapid).catch((e) => {
        console.error("push-send: error", e instanceof Error ? e.name : "unknown");
        return { ok: false, code: "error" } as Json;
      });
    // pg_net gives up after 8 s and a run can take longer: answer at once and
    // go on in the background, unless the caller asks to wait (?wait=1).
    const edge = (globalThis as unknown as { EdgeRuntime?: EdgeRt }).EdgeRuntime;
    if (new URL(req.url).searchParams.get("wait") !== "1" && typeof edge?.waitUntil === "function") {
      edge.waitUntil(safe());
      return reply({ ok: true, started: true }, 202);
    }
    const out = await safe();
    return reply(out, out.ok === true ? 200 : 502);
  } catch (e) {
    console.error("push-send: error", e instanceof Error ? e.name : "unknown");
    return reply({ ok: false, code: "error" }, 500);
  }
}

export { b64u, encryptAes128gcm, handler, unb64u, vapidJwt };

if (!Deno.env.get("PUSH_SEND_NO_SERVE")) Deno.serve(handler);
