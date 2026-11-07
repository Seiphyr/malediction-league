// Supabase Edge Function "play-network-event" for Seekers League.
//
// Fills in a community's listing of an official Play Network event from the
// public event page on malediction.gg, and saves it in public.pn_events with
// fetch_ok = true.
//
//   POST { "league_id": "<uuid>", "url": "<event link>" }  add or refresh
//   POST { "id": "<pn_events id>" }                        refresh a listing
//   POST { "tournament_id": "<uuid>",                      import the players
//          "known"?: { "<card base id>": "<name>" } }      of a tournament
//
// "known" is the site's own card list (collection number such as "CON-48"
// to its name, at most 4000 entries), so Play Network card ids become the
// names the site uses. It comes from the caller (the organizer's page), so
// it is never trusted on its own: a name from it is used only when it is
// the same name (case, apostrophes, dashes and spaces aside) the Play
// Network page itself gives that card; otherwise the Play Network name is
// kept and the card counts as unknown. Without it (an older page) the names
// come from the Play Network page and no card is reported as unknown.
//
// Answers (always HTTP 200 with JSON, except OPTIONS and wrong methods):
//   { "ok": true,  "event": <pn_events row> }
//   { "ok": true,  "tournament": { id, rev, status: "draft" },
//     "registrants": { total, added, removed, linked },
//     "decks": { n, miss, unk, part, hidden, pre },
//     "warning"?: "count_mismatch" | "too_many" }       (tournament mode)
//   { "ok": false, "error": "<code>", "message": "<English text>" }
//   codes: bad_url, not_allowed, rate_limited, event_not_found,
//          upstream_error, parse_error, archived, started
//   decks: n players with a deck imported, miss players without one, unk
//          cards the site does not know (in all decks), part decks read in
//          part, hidden true while Play Network still hides the decks (before
//          the event starts there), pre players who have linked a deck there.
//
// Listing mode: the caller must be signed in and an organizer of a community
// that is not archived. Tournament mode: the caller must be the organizer of
// a tournament still in draft (checked by t_fetch_allow, as the caller). The
// function only ever requests
//   https://malediction.gg/play-network/events/single/<id>/<slug>/
// rebuilt from the parsed id and slug, and, in tournament mode, deck pages
// whose link is on that event page and has one of these two shapes:
//   https://malediction.gg/play-network/decks/view/<slug>/<32 letters or digits>/
//   https://malediction.gg/play-network/decks/snapshot/<this event id>/<this player's profile id>/
// (www.malediction.gg too), at most 32 per import, so it is not an open proxy.
// A listing keeps how many players registered, never who, and the event's
// settings (number of rounds, round length, game mode), which the tournament
// mode also passes to t_import as p_meta.
//
// Only the tournament mode reads who registered. Exactly what it reads is
// listed above the registrants block below ("From each registered player").
// In short: nickname, profile id, avatar, Discord handle and the deck (name,
// link, Seeker, terrain, card ids and the Play Network check hashes); first
// and last names are never read. Decks are read only when Play Network shows
// them, which is once the event has started there (Ongoing or Completed).
// It hands them to t_import, which keeps them inside that tournament only
// (they are deleted with it). The list is never cached, logged or echoed
// back: the answer carries counts only.
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
const MAX_REQUEST_BYTES = 32 * 1024;      // "known" (the site's card list) is about 7 KB
const MAX_REDIRECTS = 2;
const DECK_TIMEOUT_MS = 8_000;            // one deck page
const DECK_PAGES_MAX = 32;                // deck pages per import
const DECK_PAGES_AT_ONCE = 4;
const DECK_BUDGET_MS = 20_000;            // no new deck page after this, from the start of the request
const REGS_MAX_BYTES = 1_500_000;         // p_regs; past it the decks already stored are kept
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
  | "archived"
  | "started";

const MESSAGES: Record<Code, string> = {
  bad_url:
    "That is not a Play Network event link. Paste the full address of the event page, like https://malediction.gg/play-network/events/single/393/event-name/",
  not_allowed: "Only an organizer of this community can add or refresh its events.",
  rate_limited: "Too many Play Network look-ups right now. Try again in a while.",
  event_not_found: "This event was not found on Play Network. Check the link.",
  upstream_error: "Play Network could not be reached. Try again later, or enter the details by hand.",
  parse_error: "The event page could not be read. Enter the details by hand.",
  archived: "This community is archived. Its events can no longer be changed.",
  started: "The tournament has started, so its list of players is fixed.",
};

// Tournament mode wording for two of the codes above.
const T_NOT_ALLOWED = "Only the organizer of this tournament can update its players.";
const T_PARSE_ERROR =
  "The list of registered players could not be read from the Play Network page. Add players by hand.";

type Json = Record<string, unknown>;
type PnRef = { id: string; slug: string; url: string };

// What is kept from a page for a listing (and the only thing cached): the
// event's details and its settings (number of rounds, round length, game
// mode), which the tournament mode also hands to t_import. No player data in
// here, ever: the tournament mode reads its registrants with
// readRegistrants() and never stores them here.
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
  num_rounds: number | null;    // 0..100; Play Network shows 0 when not set
  round_minutes: number | null; // 0..1440
  game_mode: "1x1" | "2x2" | null;
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

// An event page. A missing event answers 302 to the list of events: only a
// redirect to the same event on malediction.gg is followed.
function fetchPage(ref: PnRef): Promise<Page> {
  return fetchHtml(ref.url, (next: URL) => {
    const m = PN_PATH.exec(next.pathname);
    if (next.protocol !== "https:" || !PN_HOSTS.has(next.hostname) || next.port !== "" || !m || m[1] !== ref.id) {
      return null;
    }
    return `https://${next.hostname}${next.pathname}`;
  }, MAX_REDIRECTS, FETCH_TIMEOUT_MS);
}

// A deck page of this event's registrant: only links that pass deckUrlOf()
// (view/<slug>/<hash>/ or snapshot/<event id>/<profile id>/), and at most
// one redirect, to a link that passes it too.
function fetchDeckPage(url: string, eventId: string, pid: string): Promise<Page> {
  if (deckUrlOf(url, eventId, pid) !== url) return Promise.resolve<Page>({ kind: "error" });
  return fetchHtml(url, (next: URL) => {
    if (next.protocol !== "https:" || !PN_HOSTS.has(next.hostname) || next.port !== "" || next.username || next.password) {
      return null;
    }
    return deckUrlOf(`https://${next.hostname}${next.pathname}`, eventId, pid);
  }, 1, DECK_TIMEOUT_MS);
}

// GET of an HTML page on malediction.gg: no automatic redirects (follow()
// decides each one: the next link, or null for not_found), text/html only,
// at most MAX_PAGE_BYTES, timeoutMs for the whole look-up, body included.
async function fetchHtml(start: string, follow: (next: URL) => string | null, maxRedirects: number, timeoutMs: number): Promise<Page> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    let url = start;
    for (let hop = 0; hop <= maxRedirects; hop++) {
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
        const loc = res.headers.get("location");
        if (!loc) return { kind: "error" };
        let next: URL;
        try {
          next = new URL(loc, url);
        } catch {
          return { kind: "not_found" };
        }
        const to = follow(next);
        if (!to) return { kind: "not_found" };
        url = to;
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

// A count no larger than max, else null. Keeps the value inside the checks
// on pn_events, so an odd number on the page never makes the save fail.
function toCountMax(v: unknown, max: number): number | null {
  const n = toCount(v);
  return n !== null && n <= max ? n : null;
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

// How many registered: a number only, for the listing. The members list
// holds names, Discord handles and decks; here it is only counted, never
// parsed or kept. The tournament mode reads its registrants with
// readRegistrants() below (the fields listed there, nothing else).
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
  const gm = clean(ev?.game_mode_name, 10);
  const game_mode = gm === "1x1" || gm === "2x2" ? gm : null;

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
      num_rounds: toCountMax(ev?.num_rounds, 100),
      round_minutes: toCountMax(ev?.round_duration_minutes, 1440),
      game_mode,
      slug: cal?.slug ?? null,
    },
  };
}

// ---- registrants (pure) ----
// Tournament mode only. Plain JavaScript on purpose: no TypeScript syntax
// between this line and the end marker (types are in JSDoc, parameter types
// come from defaults), so the test page can run this block in a browser. It
// uses clean(), toCount(), literalStart(), sliceLiteral() and MAX_PAGE_BYTES
// from above, and crypto.subtle (Deno, or a browser page on https or
// 127.0.0.1).
//
// From each registered player (member_status "Joined") it reads ONLY:
//   user_public_id, profile_url, nickname   who it is (as before)
//   avatar          the picture shown next to the name; only
//                   http(s)://(www.)malediction.gg/wp-content/uploads/...
//                   .jpg/.jpeg/.png/.webp/.gif, stored as https; else none
//   discord_handle  2 to 40 characters, for the organizer and the player's
//                   opponent of the round
//   deck_name, deck_url                       the deck's name and link
//   seeker_card_id, seeker_name, terrain_name the Seeker (names as fallback)
//   main_decklist_hash, side_decklist_hash    the locked list's check hashes
//   live_main_decklist_hash, live_side_decklist_hash  the deck as it is now
//                                             (counted while decks are hidden)
//   locked_deck_data   only main_decklist_hash, side_decklist_hash,
//                      seeker_card_id, legacy_card_id, terrain_type_id
//   deck_cards_json    the card ids of the locked deck (Play Network cuts it
//                      at 40 entries)
// From the event page: playNetworkCurrentEventData.event_state,
// playNetworkShowEventDecks, and only the name of each card of
// window.MaledictionCardsDB. From a deck page: only seeker, legacy,
// terrain, main and side of window.deckBuilderState.
// Never read: first_name, last_name, deck_description, id, user_id,
// event_id, is_verified, created_at, deck_id, deck_hash, deck_icon,
// seeker_icon, deck_updated_at*, card texts. Never console.* the literal,
// the list, a name, a handle or a deck.

const PID = /^[A-Za-z0-9]{6,32}$/;
const PROFILE = /^https:\/\/(?:www\.)?malediction\.gg\/app\/profile\/([A-Za-z0-9]{6,32})\/?$/;
const PROFILE_ROW =
  /<a href="https:\/\/(?:www\.)?malediction\.gg\/app\/profile\/([A-Za-z0-9]{6,32})\/?"[^>]*compPlayerRowNickname[^>]*>\s*<span[^>]*>([^<]{0,200})<\/span>/g;
const MAX_REGISTRANTS = 256;

// Decks: card ids look like CON-48-1-CA (set, number, printing, edition);
// CON-48 is the collection number the site's card list uses.
const CARD_ID = /^[A-Z]{2,5}-[0-9]{1,4}-[0-9]{1,3}-[A-Z]{1,4}$/;
const CARD_BASE = /^[A-Z]{2,5}-[0-9]{1,4}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const AVATAR =
  /^https?:\/\/((?:www\.)?malediction\.gg)\/wp-content\/uploads\/([A-Za-z0-9\/._-]{1,180}\.(?:jpe?g|png|webp|gif|JPE?G|PNG|WEBP|GIF))$/;
const DECK_VIEW = /^https:\/\/(?:www\.)?malediction\.gg\/play-network\/decks\/view\/[a-z0-9-]{1,200}\/[A-Za-z0-9]{32}\/$/;
// Limits. A deck over one of them is not imported (the player registers
// theirs by hand), never cut.
const LIM = {
  main: 60, side: 15, qty: 9, names: 64, name: 80, deckName: 80, url: 300, avatar: 200, discord: 40,
  list: 64, listChars: 8192, lockChars: 4096, stateChars: 50000, dbChars: 2 * 1024 * 1024, dbCards: 4000,
  unk: 20, unkMax: 200, known: 4000,
};

/**
 * The avatar as an https link on malediction.gg, or null.
 * @param {unknown} v
 * @returns {string | null}
 */
function avatarOf(v = Object()) {
  if (typeof v !== "string" || v.length > LIM.avatar) return null;
  const m = AVATAR.exec(v);
  if (!m || m[2].includes("..") || m[2].includes("//")) return null;
  return `https://${m[1]}/wp-content/uploads/${m[2]}`;
}

/**
 * A Discord handle of 2 to 40 characters (plain text), or null.
 * @param {unknown} v
 * @returns {string | null}
 */
function discordOf(v = Object()) {
  const t = clean(v, 200);
  return t && t.length >= 2 && t.length <= LIM.discord ? t : null;
}

/**
 * The deck link if it is a Play Network deck page of this registrant, else null.
 * @param {unknown} v
 * @param {string} eventId
 * @param {string} pid
 * @returns {string | null}
 */
function deckUrlOf(v = Object(), eventId = "", pid = "") {
  if (typeof v !== "string" || v.length > LIM.url) return null;
  if (DECK_VIEW.test(v)) return v;
  if (!/^[1-9][0-9]{0,8}$/.test(eventId) || !PID.test(pid)) return null;
  for (const h of ["https://malediction.gg", "https://www.malediction.gg"]) {
    if (v === `${h}/play-network/decks/snapshot/${eventId}/${pid}/`) return v;
  }
  return null;
}

/** @param {unknown} x @returns {string | null} */
function cardIdOf(x = Object()) {
  return typeof x === "string" && CARD_ID.test(x) ? x : null;
}

/** @param {unknown} x @returns {string | null} */
function hashOf(x = Object()) {
  return typeof x === "string" && HEX64.test(x) ? x : null;
}

/**
 * A card name: plain text, curly apostrophes folded, at most 80 characters.
 * @param {unknown} v
 * @returns {string | null}
 */
function cardNameOf(v = Object()) {
  const t = clean(v, 200);
  if (!t) return null;
  const f = t.replace(/[\u2018\u2019\u02bc]/g, "'");
  return f.length <= LIM.name ? f : null;
}

/**
 * The site's card list sent by the page, {"CON-48": "Akhenzan Shieldmage"},
 * checked; null when missing or not valid (then no card counts as unknown).
 * @param {unknown} v
 * @returns {Record<string, string> | null}
 */
function knownOf(v = Object()) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const keys = Object.keys(v);
  if (keys.length === 0 || keys.length > LIM.known) return null;
  const out = Object.create(null);
  for (const k of keys) {
    const n = CARD_BASE.test(k) ? cardNameOf(v[k]) : null;
    if (!n) return null;
    out[k] = n;
  }
  return out;
}

/**
 * The event's state and whether its page shows decks.
 * @param {string} html
 * @returns {{ state: string | null, show: boolean | null }}
 */
function eventState(html = "") {
  let state = null;
  const at = literalStart(html, "playNetworkCurrentEventData");
  const lit = at < 0 ? null : sliceLiteral(html, at, 200_000);
  if (lit) {
    try {
      const v = JSON.parse(lit);
      if (v && typeof v === "object" && typeof v.event_state === "string") state = v.event_state.slice(0, 20);
    } catch (_e) {
      state = null;
    }
  }
  const s = /\bplayNetworkShowEventDecks\s*=\s*(true|false)\b/.exec(html);
  return { state, show: s ? s[1] === "true" : null };
}

/**
 * Card id -> name from window.MaledictionCardsDB (only the names), or null.
 * @param {string} html
 * @returns {Map<string, string> | null}
 */
function cardsDb(html = "") {
  const m = /\bMaledictionCardsDB\s*=\s*(?:window\.MaledictionCardsDB\s*\|\|\s*)?(?=\{)/.exec(html);
  if (!m) return null;
  const lit = sliceLiteral(html, m.index + m[0].length, LIM.dbChars);
  if (!lit) return null;
  let v = null;
  try {
    v = JSON.parse(lit);
  } catch (_e) {
    return null;
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const db = new Map();
  for (const id of Object.keys(v)) {
    if (db.size >= LIM.dbCards) break;
    const c = v[id];
    const name = CARD_ID.test(id) && c && typeof c === "object" ? cardNameOf(c.name) : null;
    if (name) db.set(id, name);
  }
  return db;
}

/**
 * The deck fields of a member, copied by name: the only ones ever read.
 * @param {any} m
 */
function deckSrcOf(m = Object()) {
  return {
    deck_name: m.deck_name,
    deck_url: m.deck_url,
    seeker_card_id: m.seeker_card_id,
    seeker_name: m.seeker_name,
    terrain_name: m.terrain_name,
    main_decklist_hash: m.main_decklist_hash,
    side_decklist_hash: m.side_decklist_hash,
    live_main_decklist_hash: m.live_main_decklist_hash,
    live_side_decklist_hash: m.live_side_decklist_hash,
    locked_deck_data: m.locked_deck_data,
    deck_cards_json: m.deck_cards_json,
  };
}

/**
 * locked_deck_data (a JSON string on the page): only the hashes and the ids.
 * @param {any} m
 * @returns {{ mh: string | null, sh: string | null, s: string | null, l: string | null, t: string | null } | null}
 */
function lockedOf(m = Object()) {
  let v = m.locked_deck_data;
  if (typeof v === "string") {
    if (!v || v.length > LIM.lockChars) return null;
    try {
      v = JSON.parse(v);
    } catch (_e) {
      return null;
    }
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  return {
    mh: hashOf(v.main_decklist_hash),
    sh: hashOf(v.side_decklist_hash),
    s: cardIdOf(v.seeker_card_id),
    l: cardIdOf(v.legacy_card_id),
    t: cardIdOf(v.terrain_type_id),
  };
}

/**
 * deck_cards_json: [seeker, legacy, terrain, main..., side...], one entry per
 * copy; null when missing, too long or with an id that is not a card id.
 * @param {any} m
 * @returns {string[] | null}
 */
function listOf(m = Object()) {
  let v = m.deck_cards_json;
  if (typeof v === "string") {
    if (v.length > LIM.listChars) return null;
    try {
      v = JSON.parse(v);
    } catch (_e) {
      return null;
    }
  }
  if (!Array.isArray(v) || v.length > LIM.list) return null;
  for (const x of v) if (!cardIdOf(x)) return null;
  return v;
}

/** @param {string} s @returns {Promise<string>} */
async function sha256hex(s = "") {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  let h = "";
  for (const b of d) h += b.toString(16).padStart(2, "0");
  return h;
}

/** "<id>:<qty>" sorted by id, joined by "|". @param {Record<string, number>} q */
function entriesOf(q = Object()) {
  return Object.keys(q).sort().map((k) => `${k}:${q[k]}`).join("|");
}

/** Play Network's main hash. @param {{s: string, l: string | null, t: string}} ids @param {Record<string, number>} main */
function mainHash(ids = Object(), main = Object()) {
  return sha256hex(`S:${ids.s}|L:${ids.l ?? ""}|T:${ids.t}|${entriesOf(main)}`);
}

/** Play Network's side hash. @param {Record<string, number>} side */
function sideHash(side = Object()) {
  return sha256hex(entriesOf(side));
}

/**
 * The key a stored deck is kept by (tournament_pn.lock_h): sha256 of the
 * main and the side check hashes together, so a new side deck, like a new
 * main deck, is read again. null without a target.
 * @param {{mh: string, sh: string | null} | null} target
 * @returns {Promise<string | null>}
 */
async function lockKey(target = Object()) {
  if (!target || !target.mh) return null;
  return sha256hex(`K1|${target.mh}|${target.sh ?? ""}`);
}

/** {id: copies} of a list of ids. @param {string[]} a */
function countOf(a = Object()) {
  const q = Object.create(null);
  for (const x of a) q[x] = (q[x] || 0) + 1;
  return q;
}

/**
 * {id: qty} from a deck page (an empty PHP array [] is an empty map), or
 * null when not valid.
 * @param {unknown} v
 */
function qtyMapOf(v = Object()) {
  if (Array.isArray(v) && v.length === 0) return Object.create(null);
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const keys = Object.keys(v);
  if (keys.length > LIM.names) return null;
  const q = Object.create(null);
  for (const k of keys) {
    const n = v[k];
    if (!cardIdOf(k) || !Number.isInteger(n) || n < 1 || n > LIM.qty) return null;
    q[k] = n;
  }
  return q;
}

/**
 * window.deckBuilderState of a deck page: seeker, legacy, terrain, main and
 * side only, or null.
 * @param {string} html
 */
function deckStateOf(html = "") {
  const m = /\bdeckBuilderState\s*=\s*(?=\{)/.exec(html);
  if (!m) return null;
  const lit = sliceLiteral(html, m.index + m[0].length, LIM.stateChars);
  if (!lit) return null;
  let v = null;
  try {
    v = JSON.parse(lit);
  } catch (_e) {
    return null;
  }
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const s = cardIdOf(v.seeker);
  const t = cardIdOf(v.terrain);
  const noL = v.legacy === null || v.legacy === undefined || v.legacy === "";
  const l = noL ? null : cardIdOf(v.legacy);
  if (!s || !t || (!noL && !l)) return null;
  const main = qtyMapOf(v.main);
  const side = v.side === null || v.side === undefined ? Object.create(null) : qtyMapOf(v.side);
  if (!main || !side) return null;
  return { s, l, t, main, side };
}

/**
 * The main/side split of the list after its first three entries: each block
 * is sorted, so the split is at a sort break, or at the end (no side), or
 * anywhere (tried in that order). ok when both locked (or live) hashes
 * match; else k is the split whose main hash matched (mainOk), or the first
 * sort break, or the end.
 * @param {string[]} rest
 * @param {{s: string, l: string | null, t: string}} ids
 * @param {{st: string, mh: string, sh: string | null} | null} target
 * @returns {Promise<{ ok: boolean, k: number, mainOk: boolean }>}
 */
async function splitList(rest = Object(), ids = Object(), target = Object()) {
  const ks = [];
  for (let i = 1; i < rest.length; i++) if (rest[i] < rest[i - 1]) ks.push(i);
  const brk = ks.length ? ks[0] : rest.length;
  ks.push(rest.length);
  for (let k = 0; k < rest.length; k++) ks.push(k);
  let mainK = -1;
  if (target && target.mh) {
    const seen = new Set();
    for (const k of ks) {
      if (seen.has(k)) continue;
      seen.add(k);
      if (await mainHash(ids, countOf(rest.slice(0, k))) !== target.mh) continue;
      if (mainK < 0) mainK = k;
      if (target.sh && await sideHash(countOf(rest.slice(k))) === target.sh) return { ok: true, k, mainOk: true };
    }
  }
  return { ok: false, k: mainK >= 0 ? mainK : brk, mainOk: mainK >= 0 };
}

/**
 * What the event page says about a registrant's deck, before any deck page:
 * shown (deck fields on the page), live (a deck linked now, even while
 * hidden), ids (Seeker, legacy, terrain: from the lock first), target (the
 * hashes to check: locked, else live), the list split, and the deck link.
 * deck is false when there is no deck to import.
 * @param {any} m  deckSrcOf() of the member
 * @param {string} eventId
 * @param {string} pid
 */
async function deckPlan(m = Object(), eventId = "", pid = "") {
  const lock = lockedOf(m);
  const list = listOf(m);
  const lockMain = (lock && lock.mh) || hashOf(m.main_decklist_hash);
  const lockSide = (lock && lock.sh) || hashOf(m.side_decklist_hash);
  const liveMain = hashOf(m.live_main_decklist_hash);
  const shown = !!(lock || lockMain || (list && list.length > 0));
  const l3 = list && list.length >= 3 ? list : null;
  const ids = {
    s: (lock && lock.s) || cardIdOf(m.seeker_card_id) || (l3 ? l3[0] : null),
    l: (lock && lock.l) || (l3 ? l3[1] : null),
    t: (lock && lock.t) || (l3 ? l3[2] : null),
  };
  const target = lockMain
    ? { st: "locked", mh: lockMain, sh: lockSide }
    : liveMain
    ? { st: "linked", mh: liveMain, sh: hashOf(m.live_side_decklist_hash) }
    : null;
  const url = deckUrlOf(m.deck_url, eventId, pid);
  const deck = shown && !!ids.s && !!ids.t;
  let rest = null;
  let split = null;
  if (deck && l3 && l3[0] === ids.s && l3[1] === ids.l && l3[2] === ids.t) {
    rest = l3.slice(3);
    split = await splitList(rest, ids, target);
  }
  return { shown, live: !!liveMain, deck, ids, target, url, rest, split, needPage: deck && !(split && split.ok) && !!url };
}

/**
 * The deck in Play Network ids, from the plan and (when one was read) the
 * deck page's state: {st, h, s, l, t, main, side}, or null. "locked" (or
 * "linked") when the hashes match; else "partial": the list's verified main
 * and the rest of the cut list, or the deck page's list when the event page
 * has none. The Seeker and terrain are exact either way.
 * @param {any} plan
 * @param {any} state  deckStateOf() of the deck page, or null
 */
async function deckFinish(plan = Object(), state = Object()) {
  if (!plan || !plan.deck) return null;
  const ids = plan.ids;
  const target = plan.target;
  const h = await lockKey(target);
  if (plan.split && plan.split.ok) {
    return { st: target.st, h, ...ids, main: countOf(plan.rest.slice(0, plan.split.k)), side: countOf(plan.rest.slice(plan.split.k)) };
  }
  const same = state && state.s === ids.s && (state.l || null) === (ids.l || null) && state.t === ids.t;
  if (same && target && target.sh && await mainHash(ids, state.main) === target.mh && await sideHash(state.side) === target.sh) {
    return { st: target.st, h, ...ids, main: state.main, side: state.side };
  }
  if (plan.split) {
    return { st: "partial", h, ...ids, main: countOf(plan.rest.slice(0, plan.split.k)), side: countOf(plan.rest.slice(plan.split.k)) };
  }
  if (same) return { st: "partial", h, ...ids, main: state.main, side: state.side };
  return null;
}

/**
 * A card name compared loosely: lower case, curly apostrophes, dashes and
 * runs of spaces folded.
 * @param {string} s
 */
function foldName(s = "") {
  return s.normalize("NFKC").toLowerCase().replace(/[‘’ʼ`]/g, "'")
    .replace(/[‐-―−]/g, "-").replace(/\s+/g, " ").trim();
}

/**
 * Our names: the site's list (known) by collection number, but only when
 * that name is the Play Network page's own name for the card (known comes
 * from the caller and cannot rename a card); else the Play Network name,
 * else the id. A card whose number is not in known, whose name there does
 * not match, or that the Play Network page does not name, is kept under the
 * Play Network name (or id) and reported (k counts them, unk names the
 * first 20).
 * Returns the deck as t_import takes it ({s, t, l, c, sd, k, unk}: c holds
 * the main deck plus the terrain and the legacy, like My decks), or null
 * when over a limit.
 * @param {any} raw  deckFinish()
 * @param {Map<string, string> | null} db
 * @param {Record<string, string> | null} known
 * @param {{ seeker: unknown, terrain: unknown }} fb  Play Network names of the Seeker and terrain
 */
function mapDeck(raw = Object(), db = Object(), known = Object(), fb = Object()) {
  const unk = [];
  const unkSeen = new Set();
  const nameOf = (id = "", fallback = Object()) => {
    const base = id.replace(/-[0-9]{1,3}-[A-Z]{1,4}$/, "");
    const pn = (db && db.get(id)) || cardNameOf(fallback);
    const ours = known && Object.prototype.hasOwnProperty.call(known, base) ? known[base] : null;
    if (ours && pn && foldName(ours) === foldName(pn)) return ours;
    const n = pn || id;
    if (known && !unkSeen.has(n)) {
      unkSeen.add(n);
      unk.push(n);
    }
    return n;
  };
  const s = nameOf(raw.s, fb.seeker);
  const t = nameOf(raw.t, fb.terrain);
  const l = raw.l ? nameOf(raw.l, null) : null;
  const c = Object.create(null);
  const sd = Object.create(null);
  let nm = 0;
  let ns = 0;
  for (const id of Object.keys(raw.main)) {
    const n = nameOf(id, null);
    c[n] = (c[n] || 0) + raw.main[id];
    nm += raw.main[id];
  }
  for (const id of Object.keys(raw.side)) {
    const n = nameOf(id, null);
    sd[n] = (sd[n] || 0) + raw.side[id];
    ns += raw.side[id];
  }
  c[t] = (c[t] || 0) + 1;
  if (l) c[l] = (c[l] || 0) + 1;
  if (nm > LIM.main || ns > LIM.side || Object.keys(c).length > LIM.names || Object.keys(sd).length > LIM.names) return null;
  for (const q of Object.keys(c).map((k) => c[k]).concat(Object.keys(sd).map((k) => sd[k]))) if (q > LIM.qty) return null;
  return { s, t, l, c, sd, k: Math.min(unkSeen.size, LIM.unkMax), unk: unk.slice(0, LIM.unk), nm, ns };
}

/**
 * The deck object handed to t_import for one registrant, or null.
 * @param {any} src  deckSrcOf()
 * @param {any} raw  deckFinish()
 * @param {Map<string, string> | null} db
 * @param {Record<string, string> | null} known
 * @param {string} eventId
 * @param {string} pid
 */
function deckOut(src = Object(), raw = Object(), db = Object(), known = Object(), eventId = "", pid = "") {
  if (!raw) return null;
  const d = mapDeck(raw, db, known, { seeker: src.seeker_name, terrain: src.terrain_name });
  if (!d) return null;
  return {
    n: clean(src.deck_name, LIM.deckName),
    u: deckUrlOf(src.deck_url, eventId, pid),
    s: d.s, t: d.t, l: d.l, c: d.c, sd: d.sd,
    st: raw.st, h: raw.h, k: d.k, unk: d.unk,
  };
}

/**
 * The array literal of `let playNetworkEventMembers = [...]`, parsed, or null.
 * @param {string} html
 * @returns {any[] | null}
 */
function membersArray(html = "") {
  const at = literalStart(html, "playNetworkEventMembers");
  if (at < 0) return null;
  const lit = sliceLiteral(html, at, MAX_PAGE_BYTES);
  if (!lit) return null;
  try {
    const v = JSON.parse(lit);
    return Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

/**
 * Registered players from the JSON members literal, or null when it is
 * missing or does not parse. Each entry: pid, name, av (avatar or null), dc
 * (Discord handle or null) and src (deckSrcOf(), kept in memory only, never
 * handed on as it is).
 * @param {string} html
 * @returns {{ list: { pid: string, name: string, av: string | null, dc: string | null, src: any }[], capped: boolean } | null}
 */
function registrantsFromJson(html = "") {
  const arr = membersArray(html);
  if (!arr) return null;
  const list = [];
  const seen = new Set();
  let capped = false;
  for (const m of arr) {
    if (!m || typeof m !== "object" || Array.isArray(m)) continue;
    if (m.member_status !== "Joined") continue;
    const pid = typeof m.user_public_id === "string" && PID.test(m.user_public_id)
      ? m.user_public_id
      : PROFILE.exec(typeof m.profile_url === "string" ? m.profile_url : "")?.[1];
    if (!pid || seen.has(pid)) continue;
    if (list.length >= MAX_REGISTRANTS) {
      capped = true;
      break;
    }
    seen.add(pid);
    list.push({
      pid,
      name: clean(m.nickname, 40) ?? "Player",
      av: avatarOf(m.avatar),
      dc: discordOf(m.discord_handle),
      src: deckSrcOf(m),
    });
  }
  return { list, capped };
}

/**
 * Registered players from the server-rendered Players tab, or null when the
 * list is not on the page. The Organizer block comes before it and is left out.
 * @param {string} html
 * @returns {{ list: { pid: string, name: string }[], capped: boolean } | null}
 */
function registrantsFromHtml(html = "") {
  const s = html.indexOf('id="ActivePlayersListContainer"');
  if (s < 0) return null;
  let e = html.indexOf('data-content-type="matches"', s);
  if (e < 0) e = s + 600000;
  const part = html.slice(s, e);
  const list = [];
  const seen = new Set();
  let capped = false;
  for (const m of part.matchAll(PROFILE_ROW)) {
    const pid = m[1];
    if (seen.has(pid)) continue;
    if (list.length >= MAX_REGISTRANTS) {
      capped = true;
      break;
    }
    seen.add(pid);
    list.push({ pid, name: clean(m[2], 40) ?? "Player" });
  }
  return { list, capped };
}

/**
 * Who registered for the event: profile id and nickname of each player
 * (plus avatar, Discord handle and deck fields from the JSON literal only).
 * The JSON literal is preferred; the HTML list is the fallback. A list whose
 * length equals the official count wins; else the JSON list, else a
 * non-empty HTML list; else null (the caller answers parse_error).
 * @param {string} html
 * @returns {{ list: { pid: string, name: string }[], count: number | null, source: "json" | "html", capped: boolean } | null}
 */
function readRegistrants(html = "") {
  const f = /name=\\?"registered_participants\\?"\s+value=\\?"(\d{1,6})\\?"/.exec(html);
  const count = f ? toCount(f[1]) : null;
  const json = registrantsFromJson(html);
  if (json && (count === null || json.list.length === count)) {
    return { list: json.list, count, source: "json", capped: json.capped };
  }
  const htm = registrantsFromHtml(html);
  if (htm && count !== null && htm.list.length === count) {
    return { list: htm.list, count, source: "html", capped: htm.capped };
  }
  if (json) return { list: json.list, count, source: "json", capped: json.capped };
  if (htm && htm.list.length > 0) return { list: htm.list, count, source: "html", capped: htm.capped };
  return null;
}
// ---- end registrants ----

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

// The tournament mode always reads the page fresh, then leaves its EventData
// (never the registrants) in the cache the same way lookUp() does.
function rememberEvent(id: string, result: LookUp): void {
  if (result.kind !== "ok" && result.code !== "event_not_found") return;
  if (cache.size >= CACHE_MAX) {
    const now = Date.now();
    for (const [k, v] of cache) if (now - v.at >= CACHE_MS) cache.delete(k);
    if (cache.size >= CACHE_MAX) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
  }
  cache.set(id, { at: Date.now(), result });
}

// ---------------------------------------------------------------- endpoint

const CLIENT_OPTIONS = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };
const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CLIENT_OPTIONS);

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "bad_request", message: "Use POST." }, cors, 405);
  const started = Date.now();

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

    // 2. The request: { tournament_id }, { league_id, url } or { id }.
    const body = await readRequestJson(req);
    if (!body) return fail("bad_url", cors);
    if (body.tournament_id !== undefined && body.tournament_id !== null) {
      return await importRegistrants(caller, body.tournament_id, body.known, started, cors);
    }
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
      num_rounds: ev.num_rounds,
      round_minutes: ev.round_minutes,
      game_mode: ev.game_mode,
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

// ---------------------------------------------------------------- tournaments

function asCount(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

type Reg = { pid: string; name: string; av?: string | null; dc?: string | null; src?: unknown };
type Stored = { lock_h: string | null; deck_st: string | null; unk_n: number };
type DeckCounts = { n: number; miss: number; unk: number; part: number };

// The decks of the registrants, for t_import: pid -> the deck object, or
// {keep: true, n, u} (the deck already stored is still the same locked
// main and side deck: no deck page is read for it, only its name and link
// are updated), or absent (no deck: the player registers theirs by
// hand). Deck pages are read for decks the event page holds only in part
// (Play Network cuts its list at 40 cards), at most DECK_PAGES_MAX, 4 at a
// time, none started after DECK_BUDGET_MS from the start of the request;
// the others stay "partial" until the next import.
async function readDecks(
  list: Reg[],
  plans: Map<string, Awaited<ReturnType<typeof deckPlan>>>,
  html: string,
  eventId: string,
  known: Record<string, string> | null,
  stored: Map<string, Stored>,
  deadline: number,
): Promise<{ dks: Map<string, unknown>; counts: DeckCounts }> {
  const db = cardsDb(html);
  const dks = new Map<string, unknown>();
  const counts: DeckCounts = { n: 0, miss: 0, unk: 0, part: 0 };
  type Job = { r: Reg; plan: Awaited<ReturnType<typeof deckPlan>>; state: unknown };
  const jobs: Job[] = [];
  const ready: Job[] = [];
  for (const r of list) {
    const plan = plans.get(r.pid);
    if (!plan || !plan.deck) {
      counts.miss++;
      continue;
    }
    // keep only skips reading the cards again: the deck's name and link are
    // always sent, so a renamed deck or a link that moved to the snapshot
    // page (the deck was edited after locking) is updated.
    const was = stored.get(r.pid);
    if (was && was.deck_st === "locked" && was.unk_n === 0 && plan.target && plan.target.st === "locked" &&
        was.lock_h !== null && was.lock_h === await lockKey(plan.target)) {
      dks.set(r.pid, { keep: true, n: clean(((r.src ?? {}) as Json).deck_name, LIM.deckName), u: plan.url });
      counts.n++;
      continue;
    }
    const job: Job = { r, plan, state: null };
    if (plan.needPage && jobs.length < DECK_PAGES_MAX) jobs.push(job);
    ready.push(job);
  }
  let next = 0;
  const worker = async () => {
    while (next < jobs.length && Date.now() < deadline) {
      const job = jobs[next++];
      const page = await fetchDeckPage(job.plan.url as string, eventId, job.r.pid);
      job.state = page.kind === "ok" ? deckStateOf(page.html) : null;
    }
  };
  await Promise.all(Array.from({ length: Math.min(DECK_PAGES_AT_ONCE, jobs.length) }, worker));
  for (const job of ready) {
    const raw = await deckFinish(job.plan, job.state);
    const dk = deckOut(job.r.src, raw, db, known, eventId, job.r.pid);
    if (!dk) {
      counts.miss++;
      continue;
    }
    dks.set(job.r.pid, dk);
    counts.n++;
    counts.unk += dk.k;
    if (dk.st === "partial") counts.part++;
  }
  return { dks, counts };
}

// POST { tournament_id, known? }: reads the registered players of the
// tournament's Play Network event and merges them into the tournament (draft
// only), with their avatars, Discord handles and decks. The answer carries
// counts only; the client re-reads the tournament row.
async function importRegistrants(
  caller: typeof service,
  raw: unknown,
  rawKnown: unknown,
  started: number,
  cors: Record<string, string>,
): Promise<Response> {
  if (typeof raw !== "string" || !UUID.test(raw)) return fail("not_allowed", cors, T_NOT_ALLOWED);
  const tid = raw;
  const oops = "Something went wrong. Try again later.";

  // 3. Organizer, draft, community not archived, 30 s since the last import
  //    and the pn_fetch_log brake (it logs this look-up), asked as the caller
  //    before anything leaves for malediction.gg.
  const allow = await caller.rpc("t_fetch_allow", { p_tid: tid });
  if (allow.error) {
    console.error("play-network-event: t_fetch_allow failed", allow.error.code ?? "");
    return fail("upstream_error", cors, oops);
  }
  const a = (allow.data && typeof allow.data === "object" ? allow.data : {}) as Json;
  if (a.ok !== true) {
    if (a.reason === "archived") return fail("archived", cors);
    if (a.reason === "started") return fail("started", cors);
    if (a.reason === "rate_limited") return fail("rate_limited", cors);
    return fail("not_allowed", cors, T_NOT_ALLOWED);
  }
  const ref = parsePnUrl(a.url);
  if (!ref) return fail("bad_url", cors, "The Play Network link of this tournament is not valid.");
  const pnEventId = typeof a.pn_event_id === "string" && UUID.test(a.pn_event_id) ? a.pn_event_id : null;

  // 4. The official page, fresh: the registrants are never cached.
  const page = await fetchPage(ref);
  if (page.kind === "not_found") {
    rememberEvent(ref.id, { kind: "error", code: "event_not_found" });
    return fail("event_not_found", cors);
  }
  if (page.kind === "error") return fail("upstream_error", cors);
  const found = parseEvent(page.html, ref); // keeps the id and published/test checks
  rememberEvent(ref.id, found);
  if (found.kind === "error") return fail(found.code, cors);
  const regs = readRegistrants(page.html);
  if (!regs) return fail("parse_error", cors, T_PARSE_ERROR);
  const ev = found.data;
  const list = regs.list as Reg[];

  // 5. Decks, read only from the JSON list and only while Play Network shows
  //    them (from the start of the event there). While it hides them
  //    (Upcoming), only the players who have linked a deck are counted (pre)
  //    and the decks already imported stay as they are. A list read from the
  //    Players tab (no JSON) carries no avatars, handles or decks, so
  //    t_import then leaves those as they are too (no "decks" in p_meta).
  const json = regs.source === "json";
  const es = eventState(page.html);
  let shownAny = false;
  let pre = 0;
  const plans = new Map<string, Awaited<ReturnType<typeof deckPlan>>>();
  if (json) {
    for (const r of list) {
      const plan = await deckPlan(r.src, ref.id, r.pid);
      plans.set(r.pid, plan);
      if (plan.shown) shownAny = true;
      if (plan.live) pre++;
    }
  }
  const hidden = !json || es.state === "Upcoming" || es.show === false || (!shownAny && pre > 0);
  let dks = new Map<string, unknown>();
  let counts: DeckCounts = { n: 0, miss: json ? list.length : 0, unk: 0, part: 0 };
  if (json && !hidden) {
    const stored = new Map<string, Stored>();
    const st = await service.from("tournament_pn").select("pid, lock_h, deck_st, unk_n").eq("tournament_id", tid);
    if (st.error) console.error("play-network-event: tournament_pn read failed", st.error.code ?? "");
    for (const row of (st.data ?? []) as Json[]) {
      if (typeof row.pid === "string") {
        stored.set(row.pid, {
          lock_h: typeof row.lock_h === "string" ? row.lock_h : null,
          deck_st: typeof row.deck_st === "string" ? row.deck_st : null,
          unk_n: typeof row.unk_n === "number" ? row.unk_n : 0,
        });
      }
    }
    ({ dks, counts } = await readDecks(list, plans, page.html, ref.id, knownOf(rawKnown), stored, started + DECK_BUDGET_MS));
  }

  // p_regs: {pid, name} as before, plus av, dc and dk from the JSON list.
  // Past REGS_MAX_BYTES a player's deck is not sent again ({keep: true}):
  // the deck stored earlier, if any, stays (warning too_many).
  let size = 0;
  let sizeCut = false;
  const pRegs = list.map((r) => {
    const o: Json = { pid: r.pid, name: r.name };
    if (json) {
      o.av = r.av ?? null;
      o.dc = r.dc ?? null;
      const dk = dks.get(r.pid);
      if (dk !== undefined) {
        const len = JSON.stringify(dk).length;
        if (size + len > REGS_MAX_BYTES) {
          sizeCut = true;
          o.dk = { keep: true };
        } else {
          size += len;
          o.dk = dk;
        }
      }
    }
    return o;
  });

  // 6. Merge (service role: t_import is not callable by users). p_meta is
  //    the event's settings, and decks/pre: t_import keeps them in
  //    payload.pn while the tournament is in draft.
  const imp = await service.rpc("t_import", {
    p_tid: tid,
    p_regs: pRegs,
    p_count: regs.count,
    p_meta: {
      rounds: ev.num_rounds,
      system: ev.format,
      minutes: ev.round_minutes,
      game_mode: ev.game_mode,
      ...(json ? { decks: hidden ? "hidden" : "shown", pre } : {}),
    },
  });
  if (imp.error) {
    console.error("play-network-event: t_import failed", imp.error.code ?? "");
    return fail("upstream_error", cors, oops);
  }
  const r = (imp.data && typeof imp.data === "object" ? imp.data : {}) as Json;
  if (r.ok !== true) {
    if (r.reason === "status" || r.reason === "started") return fail("started", cors);
    if (r.reason === "not_allowed") return fail("not_allowed", cors, T_NOT_ALLOWED);
    if (r.reason === "archived") return fail("archived", cors);
    console.error("play-network-event: t_import refused", typeof r.reason === "string" ? r.reason.slice(0, 40) : "");
    return fail("upstream_error", cors, oops);
  }

  // 7. Refresh the listing's details and count too, when the tournament still
  //    has one. Only that row is updated (never a new listing); errors ignored.
  if (pnEventId) {
    const canonical = ev.slug ? pnRef(ref.id, ev.slug) : ref;
    const upd = await service.from("pn_events").update({
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
      num_rounds: ev.num_rounds,
      round_minutes: ev.round_minutes,
      game_mode: ev.game_mode,
      fetch_ok: true,
      fetched_at: new Date().toISOString(),
    }).eq("id", pnEventId).eq("pn_id", Number(ref.id));
    if (upd.error) console.error("play-network-event: listing refresh failed", upd.error.code ?? "");
  }

  // 8. Counts only: the list itself is never echoed. The deck counts are
  //    t_import's (what it stored, after its own checks) when it gives them.
  const warning = r.warning === "too_many" || r.warning === "count_mismatch"
    ? r.warning
    : regs.capped || sizeCut
    ? "too_many"
    : regs.count !== null && regs.list.length !== regs.count
    ? "count_mismatch"
    : null;
  const d = (r.decks && typeof r.decks === "object" ? r.decks : null) as Json | null;
  return reply({
    ok: true,
    tournament: { id: tid, rev: asCount(r.rev), status: "draft" },
    registrants: { total: asCount(r.total), added: asCount(r.added), removed: asCount(r.removed), linked: asCount(r.linked) },
    decks: {
      n: d ? asCount(d.n) : counts.n,
      miss: d ? asCount(d.miss) : counts.miss,
      unk: d ? asCount(d.unk) : counts.unk,
      part: d ? asCount(d.part) : counts.part,
      hidden,
      pre,
    },
    ...(warning ? { warning } : {}),
  }, cors);
}
