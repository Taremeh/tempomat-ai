# AI Tempomat update server

A Cloudflare Worker with a D1 database. It does two things for the app:

- **Tells the app about new versions.** The app asks `/v1/check` about 10 seconds after launch, and after that once per UTC day while it runs. The Worker answers with the latest release from `version.json` on GitHub, for the branch the app was built from. Branches other than `main` and `multi-profile` get `main`'s release.
- **Counts active installs, without IDs.** Each check carries four flags the app works out itself: whether it's the install's first check of this UTC day, of this week, of this month, and ever. The Worker adds them to counters per day, app version and macOS version. The day flags received on a day add up to that day's active installs, the week flags of a week to that week's, and so on. Nothing that tells one install from another is sent or stored.

The app only checks when `checkURL` in [`../version.json`](../version.json) is set, and users can turn the check off in the app.

## What the app sends

```
GET /v1/check?v=0.2&b=2&os=15.6&branch=main&day=1&week=0&month=0&first=0
User-Agent: AITempomat/0.2
```

| Parameter | What it is |
| --- | --- |
| `v`, `b` | The app's version and build. |
| `os` | The macOS version, major and minor only. |
| `branch` | The branch the app was built from, when it's `main` or `multi-profile`; the app sends any other as empty. Used to pick the release, not stored. |
| `day`, `week`, `month`, `first` | `1` when this is the install's first check of the UTC day, of the week (Monday to Sunday), of the month, or ever. Otherwise `0`. |

The answer is the latest release, with only the fields the app uses:

```json
{"version":"0.3","build":3,"notes":"One or two sentences for the update banner.","url":"https://github.com/Taremeh/tempomat-ai/commits/main"}
```

When the Worker can't read `version.json`, it answers `{}`. The app shows an update only when `build` is higher than its own.

## Deploy

You need a Cloudflare account (the free plan is enough) and Node.js for `npx`.

```bash
cd server
npx wrangler login
npx wrangler d1 create tempomat-ai
```

Paste the `database_id` it prints into `wrangler.toml`, in place of `REPLACE-WITH-DATABASE-ID-FROM-wrangler-d1-create`. Then create the table, set the token that guards the numbers, and deploy:

```bash
npx wrangler d1 execute tempomat-ai --remote --file schema.sql
openssl rand -hex 32                  # a token for /v1/stats; keep it in your password manager
npx wrangler secret put STATS_TOKEN   # paste the token
npx wrangler deploy
```

`wrangler deploy` prints the Worker's URL, like `https://tempomat-ai.<subdomain>.workers.dev`. Try it:

```bash
curl "https://tempomat-ai.<subdomain>.workers.dev/v1/check?v=0.2&b=2&os=15.6&branch=main"
```

Then put `<url>/v1/check` into `"checkURL"` in `../version.json`, rebuild (`./scripts/build-app.sh --install`), commit and push. The URL goes into the app at build time, so apps built before that never check. Users who built earlier start checking with their next build.

## Releasing

1. Bump `version` and `build` in `../version.json`. `build` only ever goes up, and it's what the app compares.
2. Write one or two short sentences in `notes`. Point `url` at what's new, if you like.
3. Commit and push to `main` (or to `multi-profile`, for apps built from that branch).

The push is the release. GitHub and Cloudflare each cache `version.json` for up to five minutes, so the Worker serves the new version within about ten. Running apps see it at their next check: at launch, or after midnight UTC.

## Reading the numbers

```bash
curl -s -H "Authorization: Bearer $STATS_TOKEN" "https://tempomat-ai.<subdomain>.workers.dev/v1/stats?days=30"
```

```json
{
  "days": [{ "day": "2026-10-26", "active": 2, "checks": 3, "new": 1 }],
  "weeks": [{ "week": "2026-10-26", "active": 2 }],
  "months": [{ "month": "2026-10", "active": 2 }],
  "versions": { "day": "2026-10-26", "active": [{ "version": "0.2", "active": 2 }] },
  "os": { "day": "2026-10-26", "active": [{ "os": "15.6", "active": 1 }, { "os": "26.0", "active": 1 }] }
}
```

- **days:** per UTC day, newest first. `active` is the installs that checked that day, `checks` every check (launches too), `new` the installs that checked for the first time.
- **weeks:** per week, Monday to Sunday, named by its Monday. `active` is the installs that checked that week.
- **months:** per calendar month, the same.
- **versions, os:** on the most recent day with checks, the active installs per app version and per macOS version.

`days` counts back from today (UTC), 30 by default and 1 to 366. Days without checks are left out. Weeks and months are the ones those days fall in, each summed in full. Without the token the answer is 401, and with no `STATS_TOKEN` set, 403 for everyone.

The table is small enough to ask directly too:

```bash
# Daily active installs and new installs, last 30 days
npx wrangler d1 execute tempomat-ai --remote --command "SELECT day, SUM(daily) AS active, SUM(first) AS new FROM counts WHERE day >= date('now', '-29 days') GROUP BY day ORDER BY day DESC"

# Weekly active installs (weeks named by their Monday)
npx wrangler d1 execute tempomat-ai --remote --command "SELECT date(day, 'weekday 0', '-6 days') AS week, SUM(weekly) AS active FROM counts GROUP BY week ORDER BY week DESC LIMIT 12"

# Monthly active installs
npx wrangler d1 execute tempomat-ai --remote --command "SELECT substr(day, 1, 7) AS month, SUM(monthly) AS active FROM counts GROUP BY month ORDER BY month DESC"

# Active installs per app version, today
npx wrangler d1 execute tempomat-ai --remote --command "SELECT version, SUM(daily) AS active FROM counts WHERE day = date('now') GROUP BY version ORDER BY active DESC"
```

## What is stored, and what isn't

- **Stored:** the `counts` table in [`schema.sql`](schema.sql). One row per UTC day, app version and macOS version, with five counters. That's all.
- **Not stored:** IP addresses, user agents, the branch or the build. The table has no row per request. The Worker logs nothing about requests. Workers Logs stay off in `wrangler.toml`. When D1 fails, only the error message is logged.
- **D1 keeps a history.** Its Time Travel is always on and keeps a point-in-time history of the table for 7 days (30 on a paid plan), so for that long the minute each counter changed can be recovered. After that, only the daily totals remain.
- **Cloudflare still sees the IP address** of every request, because it has to deliver the request and the answer. The Worker doesn't read it.

## Caveats

The counts are approximate:

- They count installs, not people. A second Mac is a second install, and an install whose settings were reset counts as new again.
- Installs that are offline, have the check turned off, or were built before `checkURL` was set aren't counted.
- A check whose answer is lost after the Worker counted it (the Mac sleeps, Wi-Fi drops, the app's 15 s timeout) is sent again with the same flags and counted twice. Without an ID, exactly once isn't possible.
- Anyone can send fake checks, since nothing is signed. Made-up versions show up as extra rows, which you can delete with SQL.
- The app works out its flags from its own clock in UTC, and the Worker files them under the UTC day it receives them. A Mac with a wrong clock, or a check sent just before midnight UTC and received after, can land on the neighboring day.
- Weekly and monthly numbers are calendar weeks (Monday to Sunday, UTC) and calendar months, not the last 7 or 30 days. The current week and month are still filling up.

Each check is one Worker request and one small D1 write, well within the free plan for thousands of daily users.

## Trying it locally

The tests run the Worker against a SQLite stand-in for D1 ([`test/d1.mjs`](test/d1.mjs)). From the repo root, with Node 22.13 or later and nothing to install:

```bash
node --test 'server/test/*.test.mjs'
```

[`test/serve.mjs`](test/serve.mjs) runs the Worker on this Mac, for trying it with the real app:

```bash
node server/test/serve.mjs --latest version.json --token test
```

It listens on `http://127.0.0.1:8787` and prints every request, so you can see what the app sends. The `--latest` file plays `version.json` on GitHub for every branch, and it's read again on every check, so you can edit it while the server runs. Copy `version.json` and raise its `build` to make the update banner appear. Other options: `--port`, `--db counts.sqlite` to keep the counts in a file (they're in memory without it), and `--branches main,multi-profile`. `PORT`, `STATS_TOKEN` and `BRANCHES` in the environment work too.

To point the app at it, set its `updateCheckURL` default, which replaces the check URL built into the app, then quit and reopen the app:

```bash
defaults write local.ai-tempomat updateCheckURL http://127.0.0.1:8787/v1/check
defaults delete local.ai-tempomat updateCheckURL   # back to the built-in URL
```

The Update button in the banner then really runs: it pulls the app's folder, and builds and reinstalls the app if the pull brings the build your `--latest` file names (otherwise it stops and says so). The app's checks to this server are counted apart from those to the built-in one, so trying it doesn't use up the real flags.
