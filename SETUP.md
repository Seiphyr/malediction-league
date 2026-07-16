# Malediction League Tracker — Setup

Free tier, no server to maintain. Two pieces: a Supabase project (the database)
and a static HTML file (the app) hosted anywhere.

---

## 1. Create the database (5 min)

1. Sign up at [supabase.com](https://supabase.com) and create a new project.
   Free tier is fine: 500MB database, 50,000 monthly active users.
2. Wait for the project to finish provisioning (~2 min).
3. Go to **SQL Editor → New query**, paste the entire contents of `schema.sql`,
   and hit **Run**. This creates every table, the security policies, and the
   public directory view.
4. Go to **Settings → API** and copy two values:
   - **Project URL** (looks like `https://abcdefgh.supabase.co`)
   - **anon / public** key (a long JWT string)

## 2. Wire up the app (1 min)

Open `malediction-league-tracker.html` in any text editor. Near the top of the
script block you'll find:

```js
const SUPABASE_URL  = 'PASTE_YOUR_PROJECT_URL_HERE';
const SUPABASE_ANON = 'PASTE_YOUR_ANON_KEY_HERE';
```

Paste your two values in. Save.

> **The anon key is safe to publish.** It only permits what the Row Level
> Security policies in `schema.sql` allow. Never paste the `service_role` key
> into this file — that one bypasses all security.

## 3. Email confirmation (optional but recommended)

By default Supabase emails a confirmation link on signup. For a small local
league this is friction you may not want.

- **To disable:** Authentication → Providers → Email → turn off
  "Confirm email". Players can then sign up and use the app immediately.
- **To keep it on:** it works fine, users just click a link first.

## 4. Host it (5 min, free)

Google OAuth isn't involved here, so the app *will* work from a local file —
but sharing a URL is the whole point. Options:

**GitHub Pages**
1. Create a public repo, upload `malediction-league-tracker.html`,
   rename it to `index.html`.
2. Settings → Pages → Source: `main` branch, `/root`.
3. Live at `https://yourname.github.io/reponame/` in ~1 min.

**Cloudflare Pages / Netlify** — drag the file into their dashboard. Done.

---

## How the permissions work

The role is chosen at signup and stored on the profile.

| Action | Player | Organizer |
|---|---|---|
| Browse public league directory (no login) | yes | yes |
| View standings, meta, brackets | yes | yes |
| Join a league via code | yes | yes |
| Check themselves in to a night | yes | yes |
| Log a match **they played in** | yes | yes |
| Log a match between two other people | no | yes |
| Edit/delete an unconfirmed match they reported | yes | yes |
| Edit/delete any match | no | yes |
| Create a league | no | yes |
| Create game nights | no | yes |
| Confirm reported matches | no | yes |
| Change scoring rules | no | yes |
| Promote a player to co-organizer | no | yes (owner/admin) |
| Delete the league | no | owner only |

These rules are enforced **in the database**, not in the browser. Editing the
JavaScript or calling the API directly won't bypass them — Postgres rejects the
write.

### The match confirmation flow

When a player logs their own match it's saved with `confirmed = false` and shows
an "unconfirmed" badge. An organizer clicks **Confirm** to lock it. Once
confirmed, the player can no longer edit or delete it. Unconfirmed matches still
count toward standings — the flag is a review tool, not a gate. If you'd rather
they *didn't* count until confirmed, change one line in `computeStandings`.

---

## Brand assets

The Malediction logo and the four faction icons are embedded directly in the HTML
as base64 — no separate image files, no broken paths, nothing extra to upload.
The file is self-contained: one HTML, done.

They're used under the Herald program permission. If that permission ever changes,
search for `const ASSETS` near the top of the script — removing that block and the
`<img id="brand-logo">` in the header reverts to a plain text wordmark.

---

## Verifying the game data

`SEEKERS` and `TERRAINS` sit at the top of the script, easy to edit.

The eight Seekers come from the official Seeker Decks on shop.malediction.gg and
should be right. **The four terrain names came from press coverage of the launch,
not the official content library** (that page renders via JavaScript and couldn't
be read automatically). Please check them against the real content library and
correct if needed — it's a one-line edit each.

Faction assignments for Seekers were inferred from the Two-Player Starter Box
pairings and product listings. Worth a sanity check by someone who knows the game.

---

## Cost at scale

Everything here fits the free tier comfortably:

- 500MB database ≈ hundreds of thousands of matches
- 50,000 monthly active users
- 5GB bandwidth/month

A league with 50 players playing weekly uses a rounding error of that. If you
somehow outgrow it, the Pro plan is $25/mo — but you'd need to be running
leagues across a whole country first.
