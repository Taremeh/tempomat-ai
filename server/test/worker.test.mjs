// Tests for the Worker, run against the node:sqlite stand-in for D1.
// Run them from the repo root with: node --test 'server/test/*.test.mjs'

import { afterEach, beforeEach, describe, mock, test } from 'node:test'
import assert from 'node:assert/strict'

import worker, {
  addDays,
  branchFor,
  clampDays,
  flag,
  parseLatest,
  readStats,
  sanitizeOS,
  sanitizeVersion,
  tokensMatch,
  utcDay,
  weekOf,
} from '../src/worker.js'
import { D1Shim } from './d1.mjs'

const BASE = 'https://tempomat-ai.example.workers.dev'
const VERSION_URL = 'https://raw.example.com/Taremeh/tempomat-ai/{branch}/version.json'
const TOKEN = 'a-long-random-stats-token'
const TODAY = '2026-06-02' // a Tuesday
const realFetch = globalThis.fetch

// A ctx that keeps what the Worker hands to waitUntil, so a test can wait for the counting to finish.
function makeContext() {
  const pending = []
  return {
    pending,
    waitUntil(promise) { pending.push(promise) },
    passThroughOnException() {},
  }
}

async function call(path, { env = {}, method = 'GET', headers = {} } = {}) {
  const ctx = makeContext()
  const response = await worker.fetch(new Request(BASE + path, { method, headers }), env, ctx)
  await Promise.all(ctx.pending)
  return { response, body: await response.json(), ctx }
}

function rows(db) {
  return db.sqlite.prepare('SELECT * FROM counts ORDER BY day, version, os').all().map((row) => ({ ...row }))
}

function insert(db, list) {
  const statement = db.sqlite.prepare(
    'INSERT INTO counts (day, version, os, checks, daily, weekly, monthly, first) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
  for (const row of list) statement.run(...row)
}

// Replaces fetch with a handler and records every request it gets.
function stubFetch(handler) {
  const calls = []
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init })
    return handler(String(url), init)
  }
  return calls
}

function jsonResponse(body, status = 200) {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status })
}

function freezeClock(iso) {
  mock.timers.enable({ apis: ['Date'], now: Date.parse(iso) })
}

afterEach(() => {
  globalThis.fetch = realFetch
  mock.timers.reset()
  mock.restoreAll()
})

describe('helpers', () => {
  test('sanitizeVersion keeps short version strings and turns anything else into unknown', () => {
    for (const good of ['0.2', '1.10.3', '2.0-beta+7', 'A'.repeat(24)]) assert.equal(sanitizeVersion(good), good)
    for (const bad of [null, undefined, '', 'A'.repeat(25), '0.2;DROP TABLE counts', '0.2 ', '0.2/x', '0,2', 'é1']) {
      assert.equal(sanitizeVersion(bad), 'unknown', `for ${JSON.stringify(bad)}`)
    }
  })

  test('sanitizeOS keeps major or major.minor and turns anything else into unknown', () => {
    for (const good of ['14', '15.1', '26.0', '999.999']) assert.equal(sanitizeOS(good), good)
    for (const bad of [null, '', '1234', '15.', '.1', '14.6.1', '15.1234', 'macOS 15', '15,1', '١٥']) {
      assert.equal(sanitizeOS(bad), 'unknown', `for ${JSON.stringify(bad)}`)
    }
  })

  test('flag is 1 only for exactly "1"', () => {
    assert.equal(flag('1'), 1)
    for (const other of ['0', '', ' 1', '1 ', '01', '1.0', 'true', 'yes', '2', null, undefined]) {
      assert.equal(flag(other), 0, `for ${JSON.stringify(other)}`)
    }
  })

  test('clampDays defaults to 30 and stays between 1 and 366', () => {
    assert.equal(clampDays(null), 30)
    assert.equal(clampDays(''), 30)
    assert.equal(clampDays('abc'), 30)
    assert.equal(clampDays('7'), 7)
    assert.equal(clampDays('0'), 1)
    assert.equal(clampDays('-5'), 1)
    assert.equal(clampDays('366'), 366)
    assert.equal(clampDays('1000'), 366)
  })

  test('tokensMatch needs the same bytes and the same length', () => {
    assert.equal(tokensMatch('abc', 'abc'), true)
    assert.equal(tokensMatch('abd', 'abc'), false)
    assert.equal(tokensMatch('ab', 'abc'), false)
    assert.equal(tokensMatch('abcd', 'abc'), false)
    assert.equal(tokensMatch('', 'abc'), false)
    assert.equal(tokensMatch('', ''), false)
    assert.equal(tokensMatch('x', ''), false)
    assert.equal(tokensMatch('tökén', 'tökén'), true)
    assert.equal(tokensMatch('tokén', 'tökén'), false)
  })

  test('branchFor allows only listed branches and falls back to main', () => {
    const branches = 'main, multi-profile'
    assert.equal(branchFor('multi-profile', branches), 'multi-profile')
    assert.equal(branchFor('main', branches), 'main')
    assert.equal(branchFor('feature', branches), 'main')
    assert.equal(branchFor('main, multi-profile', branches), 'main')
    assert.equal(branchFor('../../etc', branches), 'main')
    assert.equal(branchFor('', branches), 'main')
    assert.equal(branchFor(null, branches), 'main')
    assert.equal(branchFor('multi-profile', undefined), 'main')
  })

  test('weekOf gives the Monday, the same as SQLite does', () => {
    assert.equal(weekOf('2026-05-31'), '2026-05-25') // Sunday
    assert.equal(weekOf('2026-06-01'), '2026-06-01') // Monday
    assert.equal(weekOf('2026-06-07'), '2026-06-01') // Sunday
    assert.equal(weekOf('2027-01-01'), '2026-12-28') // a Friday, across a year boundary
    const db = new D1Shim()
    const sql = db.sqlite.prepare("SELECT date(?, 'weekday 0', '-6 days') AS week")
    for (let day = '2026-12-20'; day <= '2027-01-10'; day = addDays(day, 1)) {
      assert.equal(weekOf(day), sql.get(day).week, `for ${day}`)
    }
  })

  test('addDays and utcDay work in UTC across month and year boundaries', () => {
    assert.equal(addDays('2026-03-01', -1), '2026-02-28')
    assert.equal(addDays('2028-03-01', -1), '2028-02-29')
    assert.equal(addDays('2026-12-31', 1), '2027-01-01')
    assert.equal(utcDay(new Date('2026-06-02T23:59:59-05:00')), '2026-06-03')
  })

  test('the table holds only the counters', () => {
    const db = new D1Shim()
    const columns = db.sqlite.prepare('PRAGMA table_info(counts)').all().map((column) => column.name)
    assert.deepEqual(columns, ['day', 'version', 'os', 'checks', 'daily', 'weekly', 'monthly', 'first'])
  })
})

describe('GET /v1/check counting', () => {
  let db
  beforeEach(() => {
    db = new D1Shim()
    freezeClock(`${TODAY}T10:00:00Z`)
  })

  test('adds up repeated checks per day, version and macOS version', async () => {
    const env = { DB: db }
    await call('/v1/check?v=0.2&b=2&os=15.1&branch=main&day=1&week=1&month=1&first=1', { env })
    await call('/v1/check?v=0.2&b=2&os=15.1&branch=main&day=0&week=0&month=0&first=0', { env })
    await call('/v1/check?v=0.2&b=2&os=15.1&branch=main&day=1&week=0&month=0&first=0', { env })
    await call('/v1/check?v=0.3&b=3&os=15.1&branch=main&day=1&week=1&month=0&first=0', { env })
    await call('/v1/check?v=0.2&b=2&os=14.6&branch=&day=1&week=1&month=1&first=1', { env })
    mock.timers.setTime(Date.parse('2026-06-03T00:00:01Z'))
    await call('/v1/check?v=0.2&b=2&os=15.1&branch=main&day=1&week=0&month=0&first=0', { env })

    assert.deepEqual(rows(db), [
      { day: '2026-06-02', version: '0.2', os: '14.6', checks: 1, daily: 1, weekly: 1, monthly: 1, first: 1 },
      { day: '2026-06-02', version: '0.2', os: '15.1', checks: 3, daily: 2, weekly: 1, monthly: 1, first: 1 },
      { day: '2026-06-02', version: '0.3', os: '15.1', checks: 1, daily: 1, weekly: 1, monthly: 0, first: 0 },
      { day: '2026-06-03', version: '0.2', os: '15.1', checks: 1, daily: 1, weekly: 0, monthly: 0, first: 0 },
    ])
  })

  test('stores bad versions and macOS versions as unknown', async () => {
    const env = { DB: db }
    await call(`/v1/check?v=${encodeURIComponent("0.2'; DROP TABLE counts; --")}&os=14.6.1&day=1`, { env })
    await call(`/v1/check?v=${'9'.repeat(25)}&os=1234&day=1`, { env })
    await call('/v1/check?day=1', { env })
    await call('/v1/check?v=0.2&os=15&day=1', { env })
    assert.deepEqual(rows(db), [
      { day: TODAY, version: '0.2', os: '15', checks: 1, daily: 1, weekly: 0, monthly: 0, first: 0 },
      { day: TODAY, version: 'unknown', os: 'unknown', checks: 3, daily: 3, weekly: 0, monthly: 0, first: 0 },
    ])
  })

  test('counts a flag only when it is exactly "1"', async () => {
    const env = { DB: db }
    await call('/v1/check?v=0.2&os=15.1&day=true&week=01&month=2&first=%201', { env })
    await call('/v1/check?v=0.2&os=15.1&day=1.0&week=yes&month=&first=1%20', { env })
    await call('/v1/check?v=0.2&os=15.1', { env })
    assert.deepEqual(rows(db), [
      { day: TODAY, version: '0.2', os: '15.1', checks: 3, daily: 0, weekly: 0, monthly: 0, first: 0 },
    ])
  })

  test('answers normally when the database fails', async () => {
    stubFetch(() => jsonResponse({ version: '0.3', build: 3 }))
    const logged = mock.method(console, 'error', () => {})
    const failingDatabases = [
      { prepare() { throw new Error('D1 is down') } },
      { prepare: () => ({ bind: () => ({ run: async () => { throw new Error('D1_ERROR: busy') } }) }) },
      undefined,
    ]
    for (const DB of failingDatabases) {
      const { response, body, ctx } = await call('/v1/check?v=0.2&b=2&os=15.1&day=1', { env: { DB, VERSION_URL } })
      assert.equal(response.status, 200)
      assert.deepEqual(body, { version: '0.3', build: 3 })
      assert.equal(ctx.pending.length, 1)
    }
    assert.equal(logged.mock.callCount(), 3)
    assert.deepEqual(logged.mock.calls[0].arguments, ['Counting a check failed:', 'D1 is down'])
    assert.deepEqual(logged.mock.calls[1].arguments, ['Counting a check failed:', 'D1_ERROR: busy'])
  })

  test('writes in waitUntil, not before answering', async () => {
    let finishWrite
    const DB = {
      prepare: () => ({ bind: () => ({ run: () => new Promise((resolve) => { finishWrite = resolve }) }) }),
    }
    const ctx = makeContext()
    const response = await worker.fetch(new Request(`${BASE}/v1/check?v=0.2&day=1`), { DB }, ctx)
    assert.equal(response.status, 200)
    assert.equal(ctx.pending.length, 1)
    finishWrite()
    await Promise.all(ctx.pending)
  })
})

describe('GET /v1/check latest release', () => {
  const env = { DB: undefined, VERSION_URL, BRANCHES: 'main,multi-profile' }
  beforeEach(() => {
    env.DB = new D1Shim()
  })

  test('returns the valid fields of version.json and nothing else', async () => {
    const calls = stubFetch(() => jsonResponse({
      version: '0.3', build: 3, notes: 'Faster history.', url: 'https://github.com/Taremeh/tempomat-ai/commits/main',
      checkURL: 'https://tempomat-ai.example.workers.dev/v1/check', extra: true,
    }))
    const { response, body } = await call('/v1/check?v=0.2&b=2&os=15.1&branch=main&day=1', { env })
    assert.equal(response.status, 200)
    assert.deepEqual(body, {
      version: '0.3', build: 3, notes: 'Faster history.', url: 'https://github.com/Taremeh/tempomat-ai/commits/main',
    })
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, 'https://raw.example.com/Taremeh/tempomat-ai/main/version.json')
    assert.deepEqual(calls[0].init.cf, { cacheTtl: 300, cacheEverything: true })
  })

  test('drops invalid fields', async () => {
    const bodies = [
      { version: 3, build: -1, notes: 42, url: 'javascript:alert(1)' },
      { version: 'x'.repeat(25), build: 2.5, notes: null, url: 'ftp://example.com/x' },
      { version: '', build: '3', notes: ['a'], url: 'not a url' },
      { build: Number.MAX_SAFE_INTEGER + 2, url: '' },
    ]
    for (const latest of bodies) {
      stubFetch(() => jsonResponse(latest))
      const { body } = await call('/v1/check?v=0.2&branch=main', { env })
      assert.deepEqual(body, {}, `for ${JSON.stringify(latest)}`)
    }
    stubFetch(() => jsonResponse({ version: '0.3', build: 0, url: 'http://example.com/notes' }))
    assert.deepEqual((await call('/v1/check', { env })).body, { version: '0.3', build: 0, url: 'http://example.com/notes' })
  })

  test('truncates notes to 500 characters without splitting one', async () => {
    stubFetch(() => jsonResponse({ version: '0.3', build: 3, notes: 'a'.repeat(600) }))
    assert.equal((await call('/v1/check', { env })).body.notes, 'a'.repeat(500))

    stubFetch(() => jsonResponse({ version: '0.3', build: 3, notes: '😀'.repeat(600) }))
    const { notes } = (await call('/v1/check', { env })).body
    assert.equal(Array.from(notes).length, 500)
    assert.equal(notes, '😀'.repeat(500))

    stubFetch(() => jsonResponse({ version: '0.3', build: 3, notes: '' }))
    assert.equal((await call('/v1/check', { env })).body.notes, '')
  })

  test('answers {} when the version file cannot be read', async () => {
    const failures = [
      () => { throw new TypeError('fetch failed') },
      () => jsonResponse('not json'),
      () => jsonResponse('{"version": "0.3",'),
      () => jsonResponse({ version: '0.3', build: 3 }, 404),
      () => jsonResponse({ version: '0.3', build: 3 }, 500),
      () => jsonResponse([{ version: '0.3', build: 3 }]),
      () => jsonResponse('null'),
      () => jsonResponse('"0.3"'),
    ]
    for (const failure of failures) {
      stubFetch(failure)
      const { response, body } = await call('/v1/check?v=0.2&day=1', { env })
      assert.equal(response.status, 200)
      assert.deepEqual(body, {})
    }
    // The check is still counted every time.
    assert.equal(rows(env.DB)[0].checks, failures.length)
  })

  test('answers {} without fetching when VERSION_URL is not set', async () => {
    const calls = stubFetch(() => jsonResponse({ version: '0.3', build: 3 }))
    const { body } = await call('/v1/check?v=0.2', { env: { DB: env.DB } })
    assert.deepEqual(body, {})
    assert.equal(calls.length, 0)
  })

  test('asks for the client branch only when it is listed, and main otherwise', async () => {
    const calls = stubFetch(() => jsonResponse({ version: '0.3', build: 3 }))
    await call('/v1/check?branch=multi-profile', { env })
    await call('/v1/check?branch=main', { env })
    await call('/v1/check?branch=some-fork', { env })
    await call(`/v1/check?branch=${encodeURIComponent('../../etc/passwd')}`, { env })
    await call('/v1/check?branch=', { env })
    await call('/v1/check', { env })
    await call('/v1/check?branch=multi-profile', { env: { ...env, BRANCHES: 'main' } })
    assert.deepEqual(calls.map((c) => c.url), [
      'https://raw.example.com/Taremeh/tempomat-ai/multi-profile/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
      'https://raw.example.com/Taremeh/tempomat-ai/main/version.json',
    ])
  })

  test('parseLatest ignores anything that is not an object', () => {
    for (const value of [null, undefined, 3, 'x', [], [{ version: '1' }], true]) assert.deepEqual(parseLatest(value), {})
  })
})

describe('headers and routing', () => {
  test('every answer is uncached JSON', async () => {
    stubFetch(() => jsonResponse({ version: '0.3', build: 3 }))
    const db = new D1Shim()
    const env = { DB: db, VERSION_URL, STATS_TOKEN: TOKEN }
    const responses = [
      (await call('/v1/check?v=0.2', { env })).response,
      (await call('/v1/stats', { env, headers: { authorization: `Bearer ${TOKEN}` } })).response,
      (await call('/v1/stats', { env })).response,
      (await call('/v1/stats', { env: { DB: db } })).response,
      (await call('/nope', { env })).response,
      (await call('/v1/check', { env, method: 'POST' })).response,
    ]
    assert.deepEqual(responses.map((r) => r.status), [200, 200, 401, 403, 404, 405])
    for (const response of responses) {
      assert.equal(response.headers.get('content-type'), 'application/json')
      assert.equal(response.headers.get('cache-control'), 'no-store')
    }
  })

  test('unknown paths are 404', async () => {
    const db = new D1Shim()
    for (const path of ['/', '/v1', '/v1/', '/v1/check/', '/v2/check', '/v1/stats/x', '/V1/CHECK', '/v1/checks']) {
      const { response } = await call(path, { env: { DB: db, STATS_TOKEN: TOKEN } })
      assert.equal(response.status, 404, `for ${path}`)
    }
    assert.deepEqual(rows(db), [])
  })

  test('other methods on the two paths are 405 and count nothing', async () => {
    const db = new D1Shim()
    for (const [method, path] of [['POST', '/v1/check'], ['PUT', '/v1/check'], ['HEAD', '/v1/check'],
      ['DELETE', '/v1/stats'], ['POST', '/v1/stats']]) {
      const ctx = makeContext()
      const response = await worker.fetch(new Request(`${BASE}${path}?v=0.2&day=1`, { method }), { DB: db, STATS_TOKEN: TOKEN }, ctx)
      assert.equal(response.status, 405, `for ${method} ${path}`)
      assert.equal(response.headers.get('allow'), 'GET')
      assert.equal(ctx.pending.length, 0)
    }
    assert.deepEqual(rows(db), [])
  })
})

describe('GET /v1/stats access', () => {
  const env = { DB: undefined, STATS_TOKEN: TOKEN }
  beforeEach(() => {
    env.DB = new D1Shim()
  })

  test('is 401 without the right bearer token', async () => {
    const wrong = [
      {},
      { authorization: '' },
      { authorization: 'Bearer' },
      { authorization: 'Bearer ' },
      { authorization: `Basic ${TOKEN}` },
      { authorization: TOKEN },
      { authorization: `Bearer ${TOKEN.slice(0, -1)}x` },
      { authorization: `Bearer ${TOKEN.slice(0, -1)}` },
      { authorization: `Bearer ${TOKEN}x` },
    ]
    for (const headers of wrong) {
      const { response, body } = await call('/v1/stats', { env, headers })
      assert.equal(response.status, 401, `for ${JSON.stringify(headers)}`)
      assert.equal(response.headers.get('www-authenticate'), 'Bearer')
      assert.deepEqual(Object.keys(body), ['error'])
    }
    const { response } = await call('/v1/stats', { env, headers: { authorization: `Bearer ${TOKEN}` } })
    assert.equal(response.status, 200)
  })

  test('refuses everyone when STATS_TOKEN is not set', async () => {
    for (const STATS_TOKEN of [undefined, '']) {
      for (const authorization of ['Bearer ', 'Bearer undefined', 'Bearer null', `Bearer ${TOKEN}`]) {
        const { response, body } = await call('/v1/stats', { env: { DB: env.DB, STATS_TOKEN }, headers: { authorization } })
        assert.equal(response.status, 403)
        assert.deepEqual(Object.keys(body), ['error'])
      }
    }
  })

  test('is 500 JSON when the database fails', async () => {
    mock.method(console, 'error', () => {})
    const DB = { prepare() { throw new Error('D1 is down') } }
    const { response, body } = await call('/v1/stats', { env: { DB, STATS_TOKEN: TOKEN }, headers: { authorization: `Bearer ${TOKEN}` } })
    assert.equal(response.status, 500)
    assert.deepEqual(Object.keys(body), ['error'])
  })
})

describe('GET /v1/stats numbers', () => {
  // [day, version, os, checks, daily, weekly, monthly, first], with today = Tuesday 2026-06-02.
  // Sunday 2026-05-24 ends one week and Monday 2026-05-25 starts the next; Sunday 2026-05-31 ends May.
  const fixture = [
    ['2026-04-30', '0.1', '14.6', 5, 4, 4, 4, 0], // before the range, the week and the month
    ['2026-05-03', '0.2', '15.1', 3, 3, 3, 2, 1], // a Sunday before the range: only in May
    ['2026-05-23', '0.2', '15.1', 4, 3, 1, 0, 1], // Saturday, week of 05-18
    ['2026-05-24', '0.2', '15.1', 6, 5, 2, 0, 0], // Sunday, week of 05-18
    ['2026-05-24', '0.2', '14.6', 2, 2, 1, 1, 1], // Sunday, week of 05-18
    ['2026-05-25', '0.2', '15.1', 7, 6, 6, 0, 0], // Monday, week of 05-25
    ['2026-05-31', '0.2', '15.1', 5, 4, 1, 0, 2], // Sunday, week of 05-25, last day of May
    ['2026-06-01', '0.2', '15.1', 9, 7, 7, 7, 0], // Monday, a new week and a new month
    ['2026-06-01', '0.3', '15.1', 2, 1, 0, 0, 1],
    ['2026-06-02', '0.3', '15.1', 4, 3, 1, 1, 0], // today
    ['2026-06-02', '0.2', '14.6', 2, 2, 1, 1, 0],
    ['2026-06-02', '0.3', 'unknown', 1, 1, 0, 0, 1],
  ]
  let db
  beforeEach(() => {
    db = new D1Shim()
    insert(db, fixture)
  })

  test('sums days, Monday weeks, months and today\'s versions and macOS versions', async () => {
    freezeClock(`${TODAY}T10:00:00Z`)
    const { response, body } = await call('/v1/stats', { env: { DB: db, STATS_TOKEN: TOKEN }, headers: { authorization: `Bearer ${TOKEN}` } })
    assert.equal(response.status, 200)
    assert.deepEqual(body, {
      days: [
        { day: '2026-06-02', active: 6, checks: 7, new: 1 },
        { day: '2026-06-01', active: 8, checks: 11, new: 1 },
        { day: '2026-05-31', active: 4, checks: 5, new: 2 },
        { day: '2026-05-25', active: 6, checks: 7, new: 0 },
        { day: '2026-05-24', active: 7, checks: 8, new: 1 },
        { day: '2026-05-23', active: 3, checks: 4, new: 1 },
      ],
      weeks: [
        { week: '2026-06-01', active: 9 },
        { week: '2026-05-25', active: 7 },
        { week: '2026-05-18', active: 4 },
      ],
      months: [
        { month: '2026-06', active: 9 },
        { month: '2026-05', active: 3 },
      ],
      versions: { day: '2026-06-02', active: [{ version: '0.3', active: 4 }, { version: '0.2', active: 2 }] },
      os: { day: '2026-06-02', active: [{ os: '15.1', active: 3 }, { os: '14.6', active: 2 }, { os: 'unknown', active: 1 }] },
    })
  })

  test('sums whole weeks and months for the days asked for', async () => {
    const week = await readStats(db, 7, TODAY) // from Wednesday 2026-05-27
    assert.deepEqual(week.days.map((d) => d.day), ['2026-06-02', '2026-06-01', '2026-05-31'])
    assert.deepEqual(week.weeks, [{ week: '2026-06-01', active: 9 }, { week: '2026-05-25', active: 7 }])
    assert.deepEqual(week.months, [{ month: '2026-06', active: 9 }, { month: '2026-05', active: 3 }])

    const today = await readStats(db, 1, TODAY)
    assert.deepEqual(today.days, [{ day: '2026-06-02', active: 6, checks: 7, new: 1 }])
    assert.deepEqual(today.weeks, [{ week: '2026-06-01', active: 9 }])
    assert.deepEqual(today.months, [{ month: '2026-06', active: 9 }])
  })

  test('puts a Sunday in the week before and a Monday in its own week', async () => {
    const fresh = new D1Shim()
    insert(fresh, [
      ['2026-05-31', '0.2', '15.1', 1, 1, 1, 0, 0], // Sunday
      ['2026-06-01', '0.2', '15.1', 10, 10, 10, 10, 0], // Monday
    ])
    const stats = await readStats(fresh, 30, TODAY)
    assert.deepEqual(stats.weeks, [{ week: '2026-06-01', active: 10 }, { week: '2026-05-25', active: 1 }])
  })

  test('takes the breakdowns from the most recent day with checks', async () => {
    const stats = await readStats(db, 30, '2026-06-10')
    assert.equal(stats.versions.day, '2026-06-02')
    assert.equal(stats.os.day, '2026-06-02')
    const older = await readStats(db, 30, '2026-05-30')
    assert.deepEqual(older.versions, { day: '2026-05-25', active: [{ version: '0.2', active: 6 }] })
    assert.deepEqual(older.os, { day: '2026-05-25', active: [{ os: '15.1', active: 6 }] })
  })

  test('is empty but well formed without any checks', async () => {
    assert.deepEqual(await readStats(new D1Shim(), 30, TODAY), {
      days: [], weeks: [], months: [], versions: { day: null, active: [] }, os: { day: null, active: [] },
    })
  })

  test('clamps days between 1 and 366, 30 by default', async () => {
    const full = new D1Shim()
    const list = []
    for (let i = 0; i < 400; i++) list.push([addDays(TODAY, -i), '0.2', '15.1', 1, 1, 0, 0, 0])
    insert(full, list)
    freezeClock(`${TODAY}T10:00:00Z`)
    const env = { DB: full, STATS_TOKEN: TOKEN }
    const headers = { authorization: `Bearer ${TOKEN}` }
    const expected = { '': 30, '?days=': 30, '?days=abc': 30, '?days=7': 7, '?days=0': 1, '?days=-5': 1,
      '?days=366': 366, '?days=1000': 366 }
    for (const [query, count] of Object.entries(expected)) {
      const { body } = await call(`/v1/stats${query}`, { env, headers })
      assert.equal(body.days.length, count, `for ${query || 'no days'}`)
      assert.equal(body.days[0].day, TODAY)
      assert.equal(body.days.at(-1).day, addDays(TODAY, 1 - count))
    }
  })
})
