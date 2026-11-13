// Supabase Edge Function "admin-accounts" for Seekers League.
//
// Admin > Accounts: a site admin makes simple accounts that skip email
// confirmation (testing, demos, the Google Play reviewers), resets their
// passwords, turns their demo flag on or off and deletes them. Only accounts
// made here can be changed here, and never a site admin's account.
//
//   POST { "action": "create", "email": "...", "display_name": "...", "demo": true, "note"?: "..." }
//   POST { "action": "list" }
//   POST { "action": "reset_password", "user_id": "<uuid>" }
//   POST { "action": "delete", "user_id": "<uuid>" }
//   POST { "action": "set_demo", "user_id": "<uuid>", "demo": false }
//
// Answers (JSON, Cache-Control: no-store):
//   200 { "ok": true, ... }                      see each action below
//   200 { "ok": false, "code": "<code>", "message": "<fixed English text>" }
//         codes: bad_request, bad_email, bad_name, bad_note, email_taken,
//         rate_limited, password_rule, not_found, deleted, is_admin,
//         other_login, owns_community, not_ready (run the migration first),
//         error
//   401 { "ok": false, "code": "unauthorized" }  no token, a bad one, a guest
//   403 { "ok": false, "code": "forbidden" }     not a site admin, or a page
//                                                 on another site (Origin)
//   405 (not POST), 413 (body over 2 KB), 400 (not a JSON object),
//   503 { "ok": false, "code": "not_configured" }, 500 { "ok": false, "code": "error" }
//
//   create  -> { ok, user_id, email, password, account }   the password is in
//              this answer only: never stored, never logged
//   list    -> { ok, accounts: [...], made_24h, max_24h }  newest first, 200 at most
//   reset_password -> { ok, user_id, password, signed_out } again shown once
//   delete  -> { ok, user_id, deleted_at, already? }
//   set_demo -> { ok, user_id, demo }
//
// Every request: the Origin must be https://seekers-league.com (and, only
// when the secret ADMIN_ACCOUNTS_ALLOW_LOCAL is "1", http://127.0.0.1 or
// http://localhost on any port, for local test pages; a request without
// Origin, like curl, is not a browser and goes on). Then
// the caller's token is checked (auth.getUser), and the caller must be in
// site_admins, read with the service role. Only then is the body read.
//
// create: the email is trimmed and lowercased (at most 254 characters, a
// plain address; plus addressing such as seekersleague+review@gmail.com is
// fine); the display name follows the site's rule (1 to 40 characters after
// trimming, not blank; here also no control or bidi characters); a note is
// optional (at most 200 characters). At most 30 accounts per admin in 24
// hours: a slot is taken in the database under a lock
// (admin_account_take_slot) before the login is made, so requests at the
// same moment cannot make a 31st, and given back when the login cannot be
// made. The login is made confirmed (email_confirm) with
// user_metadata { display_name, role: "player", admin_created: true }, so
// the database's handle_new_user trigger makes the profile exactly as for a
// sign-up and the first sign-in needs nothing more; the profile is also
// upserted here, in case. If recording the account fails, the login is
// removed again.
//
// Passwords: 16 characters drawn with crypto.getRandomValues (rejection
// sampling, no modulo bias) from 56 that cannot be mistaken for each other
// (no 0 O o 1 l I), written xxxx-xxxx-xxxx-xxxx: about 93 bits. Each has an
// upper case letter, a lower case letter and a digit, and the hyphens are
// symbols, so it passes any Supabase password requirement and the site's
// 8-character minimum.
//
// reset_password and set_demo are refused for an account that is deleted,
// a site admin, or (reset, and turning demo on) also signs in with Google or
// Discord: a real person may have claimed that address. After a reset every
// session and refresh token of the account is removed
// (admin_account_signout), so whoever knew the old password is signed out;
// signed_out says whether that worked. Tokens already handed out expire
// within the hour.
//
// delete runs admin_account_erase() in the database: in one transaction,
// erase_user_data() and then the login, run as that account, exactly as the
// site's own Delete account (delete_my_account) does; then the row is marked
// deleted, its email and note blanked, and kept with the keys its tournament
// entries got (so a deleted demo account's games stay out of the numbers).
// An account that owns a community with players is refused as Delete account
// refuses it.
//
// "Verify JWT" is turned off for this function in the dashboard: the code
// above verifies the user itself (auth.getUser), like tournament-auto, and
// the browser's CORS preflight carries no token. Logs carry the action, the
// step and a short error code only, never emails, names, notes, passwords,
// tokens or user ids.

import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_REQUEST_BYTES = 2048;
const MAX_PER_DAY = 30;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PROD_ORIGIN = "https://seekers-league.com";
const LOCAL_ORIGIN = /^http:\/\/(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$/; // only with ADMIN_ACCOUNTS_ALLOW_LOCAL=1
const ACTIONS = new Set(["create", "list", "reset_password", "delete", "set_demo"]);
// No 0 O o, 1 l I.
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";

type Json = Record<string, unknown>;

const MESSAGES: Record<string, string> = {
  bad_request: "That request is not valid.",
  bad_email: "Enter a valid email address.",
  bad_name: "Pick a display name of 1 to 40 characters.",
  bad_note: "Keep the note under 200 characters.",
  email_taken: "An account with this email already exists.",
  rate_limited: "You made 30 accounts in the last 24 hours. Try again later.",
  password_rule: "Supabase refused the generated password. Check Authentication > Password requirements.",
  not_found: "This account was not made here.",
  deleted: "This account was deleted.",
  is_admin: "Site admin accounts are not changed here.",
  other_login: "This account also signs in with Google or Discord, so it is not changed here.",
  owns_community: "This account owns a community that still has players. Hand it over or archive it first (Manage).",
  not_ready: "Run migration-2026-11-29-admin-accounts.sql first.",
  error: "Something went wrong. Try again.",
};

// ---------------------------------------------------------------- config

// The newer API keys when the runtime provides them (SUPABASE_PUBLISHABLE_KEYS
// and SUPABASE_SECRET_KEYS, JSON objects keyed by name), else the legacy
// anon and service_role keys (same rule as tournament-auto and push-send).
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

type Config = { url: string; anon: string; service: string };

// Read on every request (cheap), so a changed key needs no cold start.
function config(): Config {
  return {
    url: (Deno.env.get("SUPABASE_URL") ?? "").trim().replace(/\/+$/, ""),
    anon: envKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY").trim(),
    service: envKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY").trim(),
  };
}

const CLIENT_OPTIONS = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

// ---------------------------------------------------------------- checks

function genPassword(): string {
  const n = ALPHABET.length; // 56
  const limit = 256 - (256 % n); // 224: bytes at or above it are drawn again
  for (;;) {
    const out: string[] = [];
    while (out.length < 16) {
      for (const b of crypto.getRandomValues(new Uint8Array(32))) {
        if (b < limit && out.length < 16) out.push(ALPHABET[b % n]);
      }
    }
    const s = out.join("");
    if (/[A-Z]/.test(s) && /[a-z]/.test(s) && /[0-9]/.test(s)) {
      return s.slice(0, 4) + "-" + s.slice(4, 8) + "-" + s.slice(8, 12) + "-" + s.slice(12, 16);
    }
  }
}

const EMAIL_RE =
  /^[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;

// A plain address, trimmed and lowercased, or null.
function normEmail(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const e = v.trim().toLowerCase();
  if (e.length < 3 || e.length > 254 || !EMAIL_RE.test(e)) return null;
  const local = e.slice(0, e.lastIndexOf("@"));
  if (local.length > 64 || local.startsWith(".") || local.endsWith(".") || local.includes("..")) return null;
  return e;
}

// Control characters and the bidi controls (written as escapes on purpose).
// deno-lint-ignore no-control-regex
const BAD_CHARS = /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;

// The site's display name rule (profiles_display_name_len: 1 to 40
// characters, not blank; the page trims), counted in code points as
// Postgres does. Null when it does not fit.
function checkName(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  const n = [...s].length;
  if (n < 1 || n > 40 || BAD_CHARS.test(s)) return null;
  return s;
}

// Optional note: trimmed, control and bidi characters dropped, at most 200
// characters. undefined = not valid; null = no note.
function checkNote(v: unknown): string | null | undefined {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") return undefined;
  const s = v.replace(new RegExp(BAD_CHARS.source, "g"), " ").replace(/\s+/g, " ").trim();
  if (!s) return null;
  return [...s].length > 200 ? undefined : s;
}

// ---------------------------------------------------------------- HTTP

function originAllowed(origin: string): boolean {
  return origin === PROD_ORIGIN || (Deno.env.get("ADMIN_ACCOUNTS_ALLOW_LOCAL") === "1" && LOCAL_ORIGIN.test(origin));
}

function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Max-Age": "86400",
  };
  if (origin && originAllowed(origin)) h["Access-Control-Allow-Origin"] = origin;
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

function fail(code: string, cors: Record<string, string>): Response {
  return reply({ ok: false, code, message: MESSAGES[code] ?? MESSAGES.error }, cors);
}

// A JSON object of at most MAX_REQUEST_BYTES; "big" when larger.
async function readRequestJson(req: Request): Promise<Json | "big" | null> {
  if (!req.body) return null;
  if (Number(req.headers.get("content-length") ?? "0") > MAX_REQUEST_BYTES) return "big";
  const reader = req.body.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_REQUEST_BYTES) {
      await reader.cancel().catch(() => {});
      return "big";
    }
    parts.push(value);
  }
  const buf = new Uint8Array(size);
  let at = 0;
  for (const p of parts) {
    buf.set(p, at);
    at += p.byteLength;
  }
  try {
    const v = JSON.parse(new TextDecoder().decode(buf));
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null;
  } catch {
    return null;
  }
}

// A short, non-secret error code for the logs.
function errCode(e: unknown): string {
  if (!e || typeof e !== "object") return "";
  const o = e as Record<string, unknown>;
  const c = o.code ?? o.status ?? o.name ?? "";
  return String(c).replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 40);
}

function logFail(action: string, step: string, e: unknown) {
  console.error("admin-accounts: " + action + " " + step + " failed", errCode(e));
}

// PostgREST: the table or function is not there yet (the migration has not run).
function missing(e: unknown, status?: number): boolean {
  const c = e && typeof e === "object" ? String((e as Record<string, unknown>).code ?? "") : "";
  return c === "PGRST205" || c === "PGRST202" || c === "42P01" || c === "42883" || status === 404;
}

// ---------------------------------------------------------------- actions

// deno-lint-ignore no-explicit-any
type Client = any;

async function isAdmin(service: Client, uid: string): Promise<boolean | null> {
  const { data, error } = await service.from("site_admins").select("user_id").eq("user_id", uid).maybeSingle();
  if (error) return null;
  return !!data;
}

async function doCreate(service: Client, uid: string, body: Json, cors: Record<string, string>): Promise<Response> {
  const email = normEmail(body.email);
  if (!email) return fail("bad_email", cors);
  const name = checkName(body.display_name);
  if (!name) return fail("bad_name", cors);
  if (body.demo !== undefined && typeof body.demo !== "boolean") return fail("bad_request", cors);
  const demo = body.demo !== false;
  const note = checkNote(body.note);
  if (note === undefined) return fail("bad_note", cors);

  // The brake (a slot taken under a lock), which also tells whether the migration ran.
  const sl = await service.rpc("admin_account_take_slot", { p_by: uid });
  if (sl.error) {
    if (missing(sl.error, sl.status)) return fail("not_ready", cors);
    logFail("create", "slot", sl.error);
    return fail("error", cors);
  }
  const sd = obj(sl.data);
  if (sd.ok !== true) return fail(sd.code === "rate_limited" ? "rate_limited" : "error", cors);
  const slot = Number(sd.slot);
  const giveBack = async () => {
    const r = await service.rpc("admin_account_free_slot", { p_slot: slot, p_by: uid });
    if (r.error) logFail("create", "free_slot", r.error);
  };

  const password = genPassword();
  const made = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { display_name: name, role: "player", admin_created: true },
  });
  if (made.error || !made.data?.user?.id) {
    await giveBack();
    const e = made.error ?? {};
    const c = String(e.code ?? "");
    if (c === "email_exists" || c === "user_already_exists" || (e.status === 422 && /already/i.test(String(e.message ?? "")))) {
      return fail("email_taken", cors);
    }
    if (c === "weak_password") return fail("password_rule", cors);
    if (c === "email_address_invalid" || c === "validation_failed") return fail("bad_email", cors);
    logFail("create", "createUser", e);
    return fail("error", cors);
  }
  const id = String(made.data.user.id);

  // handle_new_user normally made the profile already; this only fills a gap.
  const prof = await service.from("profiles").upsert({ id, display_name: name, role: "player" }, { onConflict: "id", ignoreDuplicates: true });
  if (prof.error) logFail("create", "profile", prof.error);

  const rec = await service.from("admin_accounts").insert({ user_id: id, email, created_by: uid, demo, note });
  if (rec.error) {
    logFail("create", "record", rec.error);
    // Undo: the login (the delete trigger tombstones the profile), then the
    // brand-new profile itself, which nothing refers to yet.
    const del = await service.auth.admin.deleteUser(id);
    if (del.error) logFail("create", "undo_login", del.error);
    const dp = await service.from("profiles").delete().eq("id", id);
    if (dp.error) logFail("create", "undo_profile", dp.error);
    await giveBack();
    return fail(missing(rec.error, rec.status) ? "not_ready" : "error", cors);
  }
  const account = {
    user_id: id, email, display_name: name, demo, note, created_at: new Date().toISOString(),
    created_by: uid, created_by_name: null, deleted_at: null, last_sign_in_at: null, is_admin: false, other_login: false,
  };
  return reply({ ok: true, user_id: id, email, password, account }, cors);
}

async function doList(service: Client, uid: string, cors: Record<string, string>): Promise<Response> {
  const { data, error, status } = await service.rpc("admin_accounts_list", { p_by: uid });
  if (error) {
    if (missing(error, status)) return fail("not_ready", cors);
    logFail("list", "rpc", error);
    return fail("error", cors);
  }
  const d = obj(data);
  return reply({
    ok: true,
    accounts: Array.isArray(d.items) ? d.items : [],
    made_24h: Number(d.made_24h) || 0,
    max_24h: Number(d.max_24h) || MAX_PER_DAY,
  }, cors);
}

// A plain object, or {}.
function obj(v: unknown): Json {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : {};
}

// The id in the body: a uuid, lowercased; null otherwise.
function bodyId(body: Json): string | null {
  return typeof body.user_id === "string" && UUID.test(body.user_id) ? body.user_id.toLowerCase() : null;
}

// What admin_account_state() says of an account made here, or a failure answer.
async function state(service: Client, action: string, id: string, cors: Record<string, string>): Promise<Json | Response> {
  const { data, error, status } = await service.rpc("admin_account_state", { p_user: id });
  if (error) {
    if (missing(error, status)) return fail("not_ready", cors);
    logFail(action, "state", error);
    return fail("error", cors);
  }
  const d = obj(data);
  if (d.found !== true) return fail("not_found", cors);
  return d;
}

async function doReset(service: Client, body: Json, cors: Record<string, string>): Promise<Response> {
  const id = bodyId(body);
  if (!id) return fail("bad_request", cors);
  const st = await state(service, "reset_password", id, cors);
  if (st instanceof Response) return st;
  if (st.deleted === true) return fail("deleted", cors);
  if (st.is_admin !== false) return fail("is_admin", cors);
  if (st.other_login !== false) return fail("other_login", cors);
  const password = genPassword();
  const { error } = await service.auth.admin.updateUserById(id, { password });
  if (error) {
    if (String(error.code ?? "") === "weak_password") return fail("password_rule", cors);
    if (error.status === 404 || String(error.code ?? "") === "user_not_found") return fail("deleted", cors);
    logFail("reset_password", "updateUser", error);
    return fail("error", cors);
  }
  // Sign the account out everywhere: whoever knew the old password loses access.
  const so = await service.rpc("admin_account_signout", { p_user: id });
  const signedOut = !so.error && obj(so.data).ok === true;
  if (!signedOut) logFail("reset_password", "signout", so.error ?? { code: String(obj(so.data).code ?? "") });
  return reply({ ok: true, user_id: id, password, signed_out: signedOut }, cors);
}

async function doDelete(service: Client, body: Json, cors: Record<string, string>): Promise<Response> {
  const id = bodyId(body);
  if (!id) return fail("bad_request", cors);
  const { data, error, status } = await service.rpc("admin_account_erase", { p_user: id });
  if (error) {
    if (String(error.hint ?? "") === "sl_owns_league") return fail("owns_community", cors);
    if (missing(error, status)) return fail("not_ready", cors);
    logFail("delete", "rpc", error);
    return fail("error", cors);
  }
  const d = obj(data);
  if (d.ok !== true) {
    const c = typeof d.code === "string" && MESSAGES[d.code] ? d.code : "error";
    return fail(c, cors);
  }
  return reply({ ok: true, user_id: id, deleted_at: d.deleted_at ?? null, ...(d.already === true ? { already: true } : {}) }, cors);
}

async function doSetDemo(service: Client, body: Json, cors: Record<string, string>): Promise<Response> {
  const id = bodyId(body);
  if (!id || typeof body.demo !== "boolean") return fail("bad_request", cors);
  // Refused in the database for an account not made here, deleted, a site
  // admin, or (turning demo on) one that also signs in with Google or Discord.
  const { data, error, status } = await service.rpc("admin_account_set_demo", { p_user: id, p_demo: body.demo });
  if (error) {
    if (missing(error, status)) return fail("not_ready", cors);
    logFail("set_demo", "rpc", error);
    return fail("error", cors);
  }
  const d = obj(data);
  if (d.ok !== true) {
    const c = typeof d.code === "string" && MESSAGES[d.code] ? d.code : "error";
    return fail(c, cors);
  }
  return reply({ ok: true, user_id: id, demo: d.demo === true }, cors);
}

// ---------------------------------------------------------------- endpoint

async function handler(req: Request): Promise<Response> {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);
  if (origin !== null && !originAllowed(origin)) return reply({ ok: false, code: "forbidden" }, cors, 403);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply({ ok: false, code: "bad_request" }, cors, 405);

  try {
    const cfg = config();
    if (!cfg.url || !cfg.anon || !cfg.service) return reply({ ok: false, code: "not_configured" }, cors, 503);

    // 1. A signed-in user. The anon key alone is not a user, nor is a guest.
    const token = /^Bearer\s+(\S{20,8192})$/i.exec(req.headers.get("authorization") ?? "")?.[1];
    if (!token) return reply({ ok: false, code: "unauthorized" }, cors, 401);
    const anon = createClient(cfg.url, cfg.anon, CLIENT_OPTIONS);
    const { data: auth, error: authErr } = await anon.auth.getUser(token);
    const user = auth?.user;
    if (authErr || !user?.id || user.is_anonymous) return reply({ ok: false, code: "unauthorized" }, cors, 401);
    const uid = String(user.id);

    // 2. A site admin, asked with the service role.
    const service = createClient(cfg.url, cfg.service, CLIENT_OPTIONS);
    const adm = await isAdmin(service, uid);
    if (adm === null) {
      logFail("auth", "site_admins", null);
      return reply({ ok: false, code: "error" }, cors, 500);
    }
    if (!adm) return reply({ ok: false, code: "forbidden" }, cors, 403);

    // 3. The request.
    const body = await readRequestJson(req);
    if (body === "big") return reply({ ok: false, code: "bad_request" }, cors, 413);
    if (!body) return reply({ ok: false, code: "bad_request" }, cors, 400);
    const action = typeof body.action === "string" && ACTIONS.has(body.action) ? body.action : "";
    if (!action) return reply({ ok: false, code: "bad_request" }, cors, 400);

    if (action === "create") return await doCreate(service, uid, body, cors);
    if (action === "list") return await doList(service, uid, cors);
    if (action === "reset_password") return await doReset(service, body, cors);
    if (action === "delete") return await doDelete(service, body, cors);
    return await doSetDemo(service, body, cors);
  } catch (e) {
    console.error("admin-accounts: error", e instanceof Error ? e.name : "unknown");
    return reply({ ok: false, code: "error" }, cors, 500);
  }
}

export { ALPHABET, checkName, checkNote, genPassword, handler, normEmail };

if (Deno.env.get("ADMIN_ACCOUNTS_NO_SERVE") !== "1") Deno.serve(handler);
