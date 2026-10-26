// The update check and active-user counter for AI Tempomat, as a Cloudflare Worker with a D1 database.
//
// GET /v1/check answers with the latest release and adds the request's flags to that day's counters.
// GET /v1/stats sums the counters per day, week and month, for whoever holds the STATS_TOKEN secret.
// Nothing that identifies an install is received or stored, and no request is logged. See README.md.

const VERSION_PATTERN = /^[0-9A-Za-z.+-]{1,24}$/
const OS_PATTERN = /^\d{1,3}(\.\d{1,3})?$/
const MAX_LATEST_VERSION_LENGTH = 24
const MAX_NOTES_LENGTH = 500
const DEFAULT_STATS_DAYS = 30
const MAX_STATS_DAYS = 366
const VERSION_FETCH_TIMEOUT_MS = 5000

// Adds one check to its row, or starts the row. The flags are 0 or 1.
const COUNT_CHECK_SQL = `
  INSERT INTO counts (day, version, os, checks, daily, weekly, monthly, first)
  VALUES (?, ?, ?, 1, ?, ?, ?, ?)
  ON CONFLICT(day, version, os) DO UPDATE SET
    checks = checks + 1,
    daily = daily + excluded.daily,
    weekly = weekly + excluded.weekly,
    monthly = monthly + excluded.monthly,
    first = first + excluded.first`

const DAYS_SQL = `
  SELECT day, SUM(daily) AS active, SUM(checks) AS checks, SUM(first) AS new_installs
  FROM counts WHERE day BETWEEN ? AND ?
  GROUP BY day ORDER BY day DESC`

// A week is named by its Monday: the next Sunday (or the day itself, on a Sunday) minus six days.
const WEEKS_SQL = `
  SELECT date(day, 'weekday 0', '-6 days') AS week, SUM(weekly) AS active
  FROM counts WHERE day BETWEEN ? AND ?
  GROUP BY week ORDER BY week DESC`

const MONTHS_SQL = `
  SELECT substr(day, 1, 7) AS month, SUM(monthly) AS active
  FROM counts WHERE day BETWEEN ? AND ?
  GROUP BY month ORDER BY month DESC`

const LATEST_DAY_SQL = 'SELECT MAX(day) AS day FROM counts WHERE day <= ?'

const VERSIONS_SQL = `
  SELECT version, SUM(daily) AS active FROM counts WHERE day = ?
  GROUP BY version ORDER BY active DESC, version`

const OS_SQL = `
  SELECT os, SUM(daily) AS active FROM counts WHERE day = ?
  GROUP BY os ORDER BY active DESC, os`

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    let handler
    switch (url.pathname) {
      case '/v1/check': handler = handleCheck; break
      case '/v1/stats': handler = handleStats; break
      default: return json({ error: 'not found' }, 404)
    }
    if (request.method !== 'GET') return json({ error: 'method not allowed' }, 405, { allow: 'GET' })
    return handler(request, url, env, ctx)
  },
}

// Counts the check after the response is on its way, and answers with the latest release for the client's branch.
async function handleCheck(request, url, env, ctx) {
  const query = url.searchParams
  const check = {
    day: utcDay(new Date()),
    version: sanitizeVersion(query.get('v')),
    os: sanitizeOS(query.get('os')),
    daily: flag(query.get('day')),
    weekly: flag(query.get('week')),
    monthly: flag(query.get('month')),
    first: flag(query.get('first')),
  }
  // A failed write costs one count, never the answer. Only the error's message is logged, nothing about the request.
  ctx.waitUntil(countCheck(env.DB, check).catch((error) => {
    console.error('Counting a check failed:', error?.message ?? String(error))
  }))
  return json(await fetchLatest(env, query.get('branch')))
}

async function handleStats(request, url, env) {
  if (!env.STATS_TOKEN) return json({ error: 'stats are off until the STATS_TOKEN secret is set' }, 403)
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.get('authorization') ?? '')
  if (!match || !tokensMatch(match[1], env.STATS_TOKEN)) {
    return json({ error: 'unauthorized' }, 401, { 'www-authenticate': 'Bearer' })
  }
  try {
    return json(await readStats(env.DB, clampDays(url.searchParams.get('days')), utcDay(new Date())))
  } catch (error) {
    console.error('Reading the stats failed:', error?.message ?? String(error))
    return json({ error: 'the database could not be read' }, 500)
  }
}

// Adds one check to the counters of its day, app version and macOS version.
export async function countCheck(db, check) {
  await db.prepare(COUNT_CHECK_SQL)
    .bind(check.day, check.version, check.os, check.daily, check.weekly, check.monthly, check.first)
    .run()
}

// The latest release for the branch, read from VERSION_URL, with only its valid fields. Any failure gives {}.
async function fetchLatest(env, requestedBranch) {
  if (!env.VERSION_URL) return {}
  const branch = branchFor(requestedBranch, env.BRANCHES)
  try {
    const response = await fetch(env.VERSION_URL.replaceAll('{branch}', branch), {
      cf: { cacheTtl: 300, cacheEverything: true },
      signal: AbortSignal.timeout(VERSION_FETCH_TIMEOUT_MS),
    })
    const text = await response.text()
    if (!response.ok) return {}
    return parseLatest(JSON.parse(text))
  } catch {
    return {}
  }
}

// The client's branch when it is one of BRANCHES (a comma-separated list), else main.
export function branchFor(requested, branches) {
  const allowed = String(branches ?? '').split(',').map((branch) => branch.trim()).filter(Boolean)
  return requested && allowed.includes(requested) ? requested : 'main'
}

// Keeps the fields of a version.json the client may use, each only when it is valid, and drops everything else.
export function parseLatest(value) {
  const latest = {}
  if (!value || typeof value !== 'object' || Array.isArray(value)) return latest
  const { version, build, notes, url } = value
  if (typeof version === 'string' && version.length > 0 && version.length <= MAX_LATEST_VERSION_LENGTH) {
    latest.version = version
  }
  if (Number.isSafeInteger(build) && build >= 0) latest.build = build
  if (typeof notes === 'string') latest.notes = truncate(notes, MAX_NOTES_LENGTH)
  if (isWebURL(url)) latest.url = url
  return latest
}

// The app version as sent, or "unknown" when it isn't a short version string.
export function sanitizeVersion(value) {
  return typeof value === 'string' && VERSION_PATTERN.test(value) ? value : 'unknown'
}

// The macOS major.minor version as sent, or "unknown" when it isn't one.
export function sanitizeOS(value) {
  return typeof value === 'string' && OS_PATTERN.test(value) ? value : 'unknown'
}

// 1 for a flag sent as exactly "1", else 0.
export function flag(value) {
  return value === '1' ? 1 : 0
}

// The number of days /v1/stats covers: 30 when missing or not a number, else between 1 and 366.
export function clampDays(value) {
  const days = Number.parseInt(value ?? '', 10)
  if (!Number.isFinite(days)) return DEFAULT_STATS_DAYS
  return Math.min(MAX_STATS_DAYS, Math.max(1, days))
}

// Compares in a time that depends only on the expected token's length, so a wrong token tells nothing
// about how much of it was right.
export function tokensMatch(given, expected) {
  const encoder = new TextEncoder()
  const a = encoder.encode(String(given))
  const b = encoder.encode(String(expected))
  let difference = a.length ^ b.length
  for (let i = 0; i < b.length; i++) difference |= (a[i] | 0) ^ b[i]
  return b.length > 0 && difference === 0
}

// The counters summed for the days from today - (days - 1) to today, newest first.
// Weeks and months are the ones those days fall in, each summed in full, so the oldest week and month aren't cut short.
// The version and macOS breakdowns are for the most recent day with any checks.
export async function readStats(db, days, today) {
  const from = addDays(today, 1 - days)
  const [dayRows, weekRows, monthRows, latestDay] = await Promise.all([
    db.prepare(DAYS_SQL).bind(from, today).all(),
    db.prepare(WEEKS_SQL).bind(weekOf(from), today).all(),
    db.prepare(MONTHS_SQL).bind(`${from.slice(0, 7)}-01`, today).all(),
    db.prepare(LATEST_DAY_SQL).bind(today).first('day'),
  ])
  const [versionRows, osRows] = latestDay
    ? await Promise.all([
        db.prepare(VERSIONS_SQL).bind(latestDay).all(),
        db.prepare(OS_SQL).bind(latestDay).all(),
      ])
    : [{ results: [] }, { results: [] }]
  return {
    days: dayRows.results.map((row) => ({ day: row.day, active: row.active, checks: row.checks, new: row.new_installs })),
    weeks: weekRows.results.map((row) => ({ week: row.week, active: row.active })),
    months: monthRows.results.map((row) => ({ month: row.month, active: row.active })),
    versions: { day: latestDay ?? null, active: versionRows.results.map((row) => ({ version: row.version, active: row.active })) },
    os: { day: latestDay ?? null, active: osRows.results.map((row) => ({ os: row.os, active: row.active })) },
  }
}

// The UTC calendar day of a date, as YYYY-MM-DD.
export function utcDay(date) {
  return date.toISOString().slice(0, 10)
}

// The day n days after a YYYY-MM-DD day (before it, for a negative n).
export function addDays(day, n) {
  const date = new Date(`${day}T00:00:00Z`)
  date.setUTCDate(date.getUTCDate() + n)
  return utcDay(date)
}

// The Monday of the ISO week a YYYY-MM-DD day falls in, the same as SQLite's date(day, 'weekday 0', '-6 days').
export function weekOf(day) {
  const date = new Date(`${day}T00:00:00Z`)
  return addDays(day, -((date.getUTCDay() + 6) % 7))
}

function truncate(text, maxCharacters) {
  if (text.length <= maxCharacters) return text
  // Counts characters, not UTF-16 units, so an emoji is never cut in half.
  return Array.from(text).slice(0, maxCharacters).join('')
}

function isWebURL(value) {
  if (typeof value !== 'string') return false
  try {
    const { protocol } = new URL(value)
    return protocol === 'https:' || protocol === 'http:'
  } catch {
    return false
  }
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers },
  })
}
