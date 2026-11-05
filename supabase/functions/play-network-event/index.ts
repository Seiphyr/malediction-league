// Supabase Edge Function "play-network-event" for Seekers League.
//
// Fills in a community's listing of an official Play Network event from the
// public event page on malediction.gg, and saves it in public.pn_events with
// fetch_ok = true.
//
//   POST { "league_id": "<uuid>", "url": "<event link>" }  add or refresh
//   POST { "id": "<pn_events id>" }                        refresh a listing
//
// Answers (always HTTP 200 with JSON, except OPTIONS and wrong methods):
//   { "ok": true,  "event": <pn_events row> }
//   { "ok": false, "error": "<code>", "message": "<English text>" }
//   codes: bad_url, not_allowed, rate_limited, event_not_found,
//          upstream_error, parse_error, archived
//
// The caller must be signed in and an organizer of a community that is not
// archived. The function only ever requests
//   https://malediction.gg/play-network/events/single/<id>/<slug>/
// rebuilt from the parsed id and slug, so it is not an open proxy. It keeps
// how many players registered, never who: names, Discord handles, avatars
// and decks on the page are never read into the result or stored.
//
// "Verify JWT" is turned off for this function in the dashboard: the code
// below verifies the user itself (auth.getUser), which also works with the
// newer API keys.

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
// The newer API keys when the runtime provides them (SUPABASE_PUBLISHABLE_KEYS
// and SUPABASE_SECRET_KEYS, JSON objects keyed by name), else the legacy
// anon and service_role keys. The site already uses a publishable key, and
// the legacy keys may be turned off one day.
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
const SUPABASE_ANON_KEY = envKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
const SUPABASE_SERVICE_ROLE_KEY = envKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");

const ALLOWED_ORIGINS = new Set([
  "https://seekers-league.com",
  "https://www.seekers-league.com",
  "http://127.0.0.1:8770",
  "http://localhost:8770",
]);

const USER_AGENT = "SeekersLeague/1.0 (+https://seekers-league.com)";
const PN_HOSTS = new Set(["malediction.gg", "www.malediction.gg"]);
const FETCH_TIMEOUT_MS = 10_000;          // the whole look-up, body included
const MAX_PAGE_BYTES = 3 * 1024 * 1024;   // event pages are about 1 MB
const MAX_REQUEST_BYTES = 4 * 1024;
const MAX_REDIRECTS = 2;
const CACHE_MS = 60_000;
const CACHE_MAX = 200;

const SLUG = "(?:[A-Za-z0-9-]|%[0-9A-Fa-f]{2}){1,200}";
const PN_PATH = new RegExp(`^/play-network/events/single/([1-9][0-9]{0,8})/(${SLUG})/?$`);
// The closing slash and a clean end are required: a slug cut short by a
// character outside the slug alphabet (or past 200) is not taken, and the
// link the organizer pasted (or the stored one) is kept instead.
const PN_SLUG_IN_TEXT = new RegExp(`/play-network/events/single/([0-9]{1,9})/(${SLUG})/(?=$|[\\s"'<>?#&)\\]])`);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Code =
  | "bad_url"
  | "not_allowed"
  | "rate_limited"
  | "event_not_found"
  | "upstream_error"
  | "parse_error"
  | "archived";

const MESSAGES: Record<Code, string> = {
  bad_url:
    "That is not a Play Network event link. Paste the full address of the event page, like https://malediction.gg/play-network/events/single/393/event-name/",
  not_allowed: "Only an organizer of this community can add or refresh its events.",
  rate_limited: "Too many Play Network look-ups right now. Try again in a while.",
  event_not_found: "This event was not found on Play Network. Check the link.",
  upstream_error: "Play Network could not be reached. Try again later, or enter the details by hand.",
  parse_error: "The event page could not be read. Enter the details by hand.",
  archived: "This community is archived. Its events can no longer be changed.",
};

type Json = Record<string, unknown>;
type PnRef = { id: string; slug: string; url: string };

// What is kept from a page. No player data in here, ever.
type EventData = {
  title: string;
  starts_at: string | null;
  ends_at: string | null;
  venue: string | null;
  city: string | null;
  country: string | null;
  location_type: "Local" | "Online" | null;
  type_name: string | null;
  format: string | null;
  max_players: number | null;
  participants_count: number | null;
  slug: string | null; // canonical slug, from the page's own calendar link
};

type LookUp =
  | { kind: "ok"; data: EventData }
  | { kind: "error"; code: "event_not_found" | "upstream_error" | "parse_error" };

// ---------------------------------------------------------------- HTTP

function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "86400",
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function reply(body: Json, cors: Record<string, string>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function fail(code: Code, cors: Record<string, string>, message?: string): Response {
  return reply({ ok: false, error: code, message: message ?? MESSAGES[code] }, cors);
}

async function readCapped(stream: ReadableStream<Uint8Array>, max: number): Promise<Uint8Array | null> {
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    parts.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.byteLength;
  }
  return out;
}

async function readRequestJson(req: Request): Promise<Json | null> {
  if (!req.body) return null;
  if (Number(req.headers.get("content-length") ?? "0") > MAX_REQUEST_BYTES) return null;
  const buf = await readCapped(req.body, MAX_REQUEST_BYTES);
  if (!buf) return null;
  try {
    const v = JSON.parse(new TextDecoder().decode(buf));
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- links

function pnRef(id: string, slug: string): PnRef {
  const s = slug.toLowerCase();
  return { id, slug: s, url: `https://malediction.gg/play-network/events/single/${id}/${s}/` };
}

// The canonical link, or null. Same rule as public.pn_canonical_url():
// https only, malediction.gg or www.malediction.gg, slug required, trailing
// slash optional, query and fragment dropped.
function parsePnUrl(raw: unknown): PnRef | null {
  if (typeof raw !== "string") return null;
  const t = raw.trim();
  if (!t || t.length > 500) return null;
  let u: URL;
  try {
    u = new URL(t);
  } catch {
    return null;
  }
  if (u.protocol !== "https:" || !PN_HOSTS.has(u.hostname) || u.port !== "" || u.username !== "" || u.password !== "") {
    return null;
  }
  const m = PN_PATH.exec(u.pathname);
  return m ? pnRef(m[1], m[2]) : null;
}

// ---------------------------------------------------------------- fetching

type Page = { kind: "ok"; html: string } | { kind: "not_found" } | { kind: "error" };

async function fetchPage(ref: PnRef): Promise<Page> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
  try {
    let url = ref.url;
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const res = await fetch(url, {
        method: "GET",
        redirect: "manual",
        signal: ctl.signal,
        headers: {
          "User-Agent": USER_AGENT,
          "Accept": "text/html,application/xhtml+xml",
          "Accept-Language": "en",
        },
      });
      if (res.status >= 300 && res.status < 400) {
        await res.body?.cancel().catch(() => {});
        // A missing event answers 302 to the list of events. Only a redirect
        // to the same event on malediction.gg is followed.
        const loc = res.headers.get("location");
        if (!loc) return { kind: "error" };
        let next: URL;
        try {
          next = new URL(loc, url);
        } catch {
          return { kind: "not_found" };
        }
        const m = PN_PATH.exec(next.pathname);
        if (next.protocol !== "https:" || !PN_HOSTS.has(next.hostname) || next.port !== "" || !m || m[1] !== ref.id) {
          return { kind: "not_found" };
        }
        url = `https://${next.hostname}${next.pathname}`;
        continue;
      }
      if (res.status === 404 || res.status === 410) {
        await res.body?.cancel().catch(() => {});
        return { kind: "not_found" };
      }
      if (res.status !== 200 || !res.body) {
        await res.body?.cancel().catch(() => {});
        return { kind: "error" };
      }
      if (!/^text\/html\b/i.test(res.headers.get("content-type") ?? "")) {
        await res.body.cancel().catch(() => {});
        return { kind: "error" };
      }
      if (Number(res.headers.get("content-length") ?? "0") > MAX_PAGE_BYTES) {
        await res.body.cancel().catch(() => {});
        return { kind: "error" };
      }
      const buf = await readCapped(res.body, MAX_PAGE_BYTES);
      if (!buf) return { kind: "error" };
      return { kind: "ok", html: new TextDecoder("utf-8").decode(buf) };
    }
    return { kind: "error" };
  } catch {
    return { kind: "error" };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- parsing

const NAMED_ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]{1,6}|#[0-9]{1,7}|[a-z]{2,6});/gi, (whole: string, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return n > 0 && n <= 0x10ffff && !(n >= 0xd800 && n <= 0xdfff) ? String.fromCodePoint(n) : "";
    }
    return NAMED_ENTITIES[e.toLowerCase()] ?? whole;
  });
}

// Plain text: tags out, entities decoded, WordPress escapes ("Dell\'Otaku")
// undone, control characters and extra spaces out, cut to max characters.
function clean(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  let t = v.replace(/<br\s*\/?>/gi, ", ").replace(/<[^>]{0,1000}>/g, " ");
  t = decodeEntities(t);
  t = t.replace(/\\+(['"])/g, "$1");
  t = t.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim();
  if (!t) return null;
  const chars = Array.from(t);
  return chars.length > max ? chars.slice(0, max).join("").trimEnd() : t;
}

function toCount(v: unknown): number | null {
  const s = typeof v === "number" ? String(v) : typeof v === "string" ? v.trim() : "";
  return /^[0-9]{1,5}$/.test(s) ? Number(s) : null;
}

// The JSON literal (object or array) that starts at html[start], found with
// a bracket counter that skips over strings. null if it does not close
// within max characters.
function sliceLiteral(html: string, start: number, max: number): string | null {
  const open = html[start];
  if (open !== "{" && open !== "[") return null;
  const end = Math.min(html.length, start + max);
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < end; i++) {
    const c = html[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === "\"") inString = false;
      continue;
    }
    if (c === "\"") inString = true;
    else if (c === "{" || c === "[") depth++;
    else if (c === "}" || c === "]") {
      depth--;
      if (depth === 0) return html.slice(start, i + 1);
    }
  }
  return null;
}

// Where the literal of `let <name> = ` starts. The bare name also appears in
// later reassignments, so the "let" declaration is the one looked for.
function literalStart(html: string, name: string): number {
  const m = new RegExp(`\\blet\\s+${name}\\s*=\\s*`).exec(html);
  return m ? m.index + m[0].length : -1;
}

// let playNetworkCurrentEventData = {...};
function readEventJson(html: string): Json | null {
  const at = literalStart(html, "playNetworkCurrentEventData");
  if (at < 0) return null;
  const lit = sliceLiteral(html, at, 200_000);
  if (!lit) return null;
  try {
    const v = JSON.parse(lit);
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null;
  } catch {
    return null;
  }
}

function calendarTime(s: string): string | null {
  const m = /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/.exec(s);
  if (!m) return null;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
  return isNaN(d.getTime()) ? null : d.toISOString();
}

// "2026-11-08 15:30:00" with utc_offset "+01:00".
function localTime(t: unknown, offset: unknown): string | null {
  if (typeof t !== "string" || typeof offset !== "string") return null;
  const m = /^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d(?::\d\d)?)$/.exec(t.trim());
  const o = offset.trim();
  if (!m || !/^[+-]\d\d:\d\d$/.test(o)) return null;
  const d = new Date(`${m[1]}T${m[2]}${o}`);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

// The page has "Add to calendar" links for other events too: only the one
// whose details point back at this event counts.
function readCalendar(html: string, id: string): { title: string | null; start: string | null; end: string | null; slug: string | null } | null {
  const re = /https:\/\/calendar\.google\.com\/calendar\/render\?[^"'<>\s\\]{1,4000}/g;
  for (const m of html.matchAll(re)) {
    let p: URLSearchParams;
    try {
      p = new URL(decodeEntities(m[0])).searchParams;
    } catch {
      continue;
    }
    const details = p.get("details") ?? "";
    if (!details.includes(`/single/${id}/`)) continue;
    const link = PN_SLUG_IN_TEXT.exec(details);
    const d = /^(\d{8}T\d{6}Z)\/(\d{8}T\d{6}Z)$/.exec(p.get("dates") ?? "");
    return {
      title: p.get("text"),
      start: d ? calendarTime(d[1]) : null,
      end: d ? calendarTime(d[2]) : null,
      slug: link && link[1] === id ? link[2].toLowerCase() : null,
    };
  }
  return null;
}

// How many registered: a number only. The members list holds names, Discord
// handles and decks; it is only counted, never parsed or kept.
function readParticipants(html: string): number | null {
  const f = /name=\\?"registered_participants\\?"\s+value=\\?"(\d{1,6})\\?"/.exec(html);
  if (f) return toCount(f[1]);
  const at = literalStart(html, "playNetworkEventMembers");
  if (at < 0) return null;
  const lit = sliceLiteral(html, at, MAX_PAGE_BYTES);
  if (!lit) return null;
  return lit.match(/"member_status"\s*:\s*"Joined"/g)?.length ?? 0;
}

function parseEvent(html: string, ref: PnRef): LookUp {
  const ev = readEventJson(html);
  if (ev && String(ev.id) !== ref.id) return { kind: "error", code: "parse_error" };
  if (ev && ((typeof ev.publish_status === "string" && ev.publish_status !== "Published") || String(ev.is_test) === "1")) {
    return { kind: "error", code: "event_not_found" };
  }
  const cal = readCalendar(html, ref.id);
  if (!ev && !cal) return { kind: "error", code: "parse_error" };

  const title = clean(ev?.event_name, 200) ?? clean(cal?.title, 200);
  // The calendar link gives UTC times; the JSON gives local times and an offset.
  const starts = cal?.start ?? localTime(ev?.start_time, ev?.utc_offset);
  let ends = cal?.end ?? localTime(ev?.end_time, ev?.utc_offset);
  if (!starts || (ends && Date.parse(ends) < Date.parse(starts))) ends = null;
  if (!title || !starts) return { kind: "error", code: "parse_error" };

  const lt = ev?.location_type;
  const location_type = lt === "Local" || lt === "Online" ? lt : null;
  const venue = location_type === "Online"
    ? clean(ev?.online_platform, 200)
    : clean(ev?.lgs_name, 200) ?? clean(ev?.address_line, 200);

  return {
    kind: "ok",
    data: {
      title,
      starts_at: starts,
      ends_at: ends,
      venue,
      city: clean(ev?.city, 100),
      country: clean(ev?.country_name, 100),
      location_type,
      type_name: clean(ev?.type_name, 60),
      format: clean(ev?.system_name, 60),
      max_players: toCount(ev?.max_players),
      participants_count: readParticipants(html),
      slug: cal?.slug ?? null,
    },
  };
}

// ---------------------------------------------------------------- cache

// Per Play Network id, for 60 s, in this instance only. Holds only the
// parsed EventData (no player data) or a not-found answer.
const cache = new Map<string, { at: number; result: LookUp }>();

async function lookUp(ref: PnRef): Promise<LookUp> {
  const hit = cache.get(ref.id);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.result;
  const page = await fetchPage(ref);
  let result: LookUp;
  if (page.kind === "not_found") result = { kind: "error", code: "event_not_found" };
  else if (page.kind === "error") result = { kind: "error", code: "upstream_error" };
  else result = parseEvent(page.html, ref);
  if (result.kind === "ok" || result.code === "event_not_found") {
    if (cache.size >= CACHE_MAX) {
      const now = Date.now();
      for (const [k, v] of cache) if (now - v.at >= CACHE_MS) cache.delete(k);
      if (cache.size >= CACHE_MAX) {
        const oldest = cache.keys().next().value;
        if (oldest !== undefined) cache.delete(oldest);
      }
    }
    cache.set(ref.id, { at: Date.now(), result });
  }
  return result;
}

// ---------------------------------------------------------------- endpoint

const CLIENT_OPTIONS = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CLIENT_OPTIONS);

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "bad_request", message: "Use POST." }, cors, 405);

  try {
    // 1. A signed-in user. The anon key alone is not a user.
    const token = /^Bearer\s+(\S{20,8192})$/i.exec(req.headers.get("authorization") ?? "")?.[1];
    if (!token) return fail("not_allowed", cors, "Sign in to add events.");
    const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      ...CLIENT_OPTIONS,
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: auth, error: authErr } = await caller.auth.getUser(token);
    const user = auth?.user;
    if (authErr || !user || user.is_anonymous) return fail("not_allowed", cors, "Sign in to add events.");

    // 2. The request: { league_id, url } or { id }.
    const body = await readRequestJson(req);
    if (!body) return fail("bad_url", cors);
    let leagueId: string;
    let ref: PnRef | null;
    if (body.id !== undefined && body.id !== null) {
      if (typeof body.id !== "string" || !UUID.test(body.id)) return fail("not_allowed", cors);
      // Read as the caller: a listing they cannot see does not exist for them.
      const { data, error } = await caller.from("pn_events").select("id, league_id, url").eq("id", body.id).maybeSingle();
      if (error) {
        console.error("play-network-event: read listing failed", error.code ?? "");
        return fail("upstream_error", cors, "Something went wrong. Try again later.");
      }
      if (!data) return fail("not_allowed", cors);
      leagueId = String(data.league_id);
      ref = parsePnUrl(data.url);
    } else {
      if (typeof body.league_id !== "string" || !UUID.test(body.league_id)) return fail("not_allowed", cors);
      leagueId = body.league_id;
      ref = parsePnUrl(body.url);
    }
    if (!ref) return fail("bad_url", cors);

    // 3. An organizer of a community that is not archived, asked as the
    //    caller, before anything leaves for malediction.gg.
    const admin = await caller.rpc("is_league_admin", { p_league: leagueId });
    if (admin.error) {
      console.error("play-network-event: is_league_admin failed", admin.error.code ?? "");
      return fail("upstream_error", cors, "Something went wrong. Try again later.");
    }
    if (admin.data !== true) return fail("not_allowed", cors);
    const lg = await caller.from("leagues").select("archived_at").eq("id", leagueId).maybeSingle();
    if (lg.error || !lg.data) return fail("not_allowed", cors);
    if (lg.data.archived_at) return fail("archived", cors);

    // 4. The brake: logs this look-up, or refuses it.
    const allow = await caller.rpc("pn_fetch_allow", { p_league: leagueId });
    if (allow.error) {
      console.error("play-network-event: pn_fetch_allow failed", allow.error.code ?? "");
      return fail("upstream_error", cors, "Something went wrong. Try again later.");
    }
    if (allow.data !== true) return fail("rate_limited", cors);

    // 5. The official page.
    const found = await lookUp(ref);
    if (found.kind === "error") return fail(found.code, cors);
    const ev = found.data;
    const canonical = ev.slug ? pnRef(ref.id, ev.slug) : ref;

    // 6. Save it (service role: the only writer of fetch_ok = true rows).
    const fields = {
      url: canonical.url,
      title: ev.title,
      starts_at: ev.starts_at,
      ends_at: ev.ends_at,
      venue: ev.venue,
      city: ev.city,
      country: ev.country,
      location_type: ev.location_type,
      type_name: ev.type_name,
      format: ev.format,
      max_players: ev.max_players,
      participants_count: ev.participants_count,
      fetch_ok: true,
      fetched_at: new Date().toISOString(),
    };
    const pnId = Number(ref.id);
    let saved = await saveListing(leagueId, pnId, fields, user.id);
    if (saved.error && saved.error.code === "23505") saved = await saveListing(leagueId, pnId, fields, user.id);
    if (saved.error || !saved.data) {
      console.error("play-network-event: save failed", saved.error?.code ?? "");
      return fail("upstream_error", cors, "The event was read but could not be saved. Try again later.");
    }
    return reply({ ok: true, event: saved.data }, cors);
  } catch (e) {
    console.error("play-network-event: unexpected error", e instanceof Error ? e.name : "");
    return fail("upstream_error", cors, "Something went wrong. Try again later.");
  }
});

// Updates the listing of this event in this community, or creates it.
async function saveListing(leagueId: string, pnId: number, fields: Json, userId: string) {
  const existing = await service.from("pn_events").select("id").eq("league_id", leagueId).eq("pn_id", pnId).maybeSingle();
  if (existing.error) return { data: null, error: existing.error };
  if (existing.data) {
    return await service.from("pn_events").update(fields).eq("id", existing.data.id).select("*").single();
  }
  return await service.from("pn_events")
    .insert({ ...fields, league_id: leagueId, pn_id: pnId, created_by: userId })
    .select("*").single();
}
