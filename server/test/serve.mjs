// Runs the Worker on this Mac for trying it with the real app, without Cloudflare and without npm packages.
// D1 is the node:sqlite stand-in, and the version file comes from a local JSON file, read again on every check.
//
//   node server/test/serve.mjs --latest version.json --token secret [--port 8787] [--db counts.sqlite]
//                              [--branches main,multi-profile]
//
// PORT, STATS_TOKEN and BRANCHES in the environment work too. Without --db the counts live in memory.

import { readFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { parseArgs } from 'node:util'

import worker from '../src/worker.js'
import { D1Shim } from './d1.mjs'

// The Worker fetches VERSION_URL with the branch filled in. Here that URL answers with the --latest file, whatever the branch.
const LOCAL_VERSION_URL = 'http://latest.invalid/{branch}/version.json'
const SKIPPED_HEADERS = new Set(['host', 'connection', 'keep-alive', 'transfer-encoding', 'upgrade'])

const USAGE = `Usage: node server/test/serve.mjs [--latest version.json] [--token secret] [--port 8787]
                             [--db counts.sqlite] [--branches main,multi-profile]`

function main() {
  const { values: options } = parseArgs({
    options: {
      port: { type: 'string', default: process.env.PORT ?? '8787' },
      db: { type: 'string', default: ':memory:' },
      latest: { type: 'string' },
      token: { type: 'string', default: process.env.STATS_TOKEN ?? '' },
      branches: { type: 'string', default: process.env.BRANCHES ?? 'main,multi-profile' },
      help: { type: 'boolean', short: 'h', default: false },
    },
  })
  if (options.help) {
    console.log(USAGE)
    return
  }
  const port = Number.parseInt(options.port, 10)
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error(`Not a port: ${options.port}\n${USAGE}`)
    process.exitCode = 2
    return
  }

  globalThis.fetch = async (url) => {
    const branch = String(url).startsWith('http://latest.invalid/') ? String(url).split('/')[3] : null
    if (branch === null || !options.latest) return new Response('not found', { status: 404 })
    try {
      const text = await readFile(options.latest, 'utf8')
      console.log(`  version file for ${branch}: ${options.latest}`)
      return new Response(text, { status: 200, headers: { 'content-type': 'application/json' } })
    } catch (error) {
      console.log(`  version file for ${branch}: cannot read ${options.latest} (${error.code ?? error.message})`)
      return new Response('not found', { status: 404 })
    }
  }

  const env = {
    DB: new D1Shim(options.db),
    VERSION_URL: LOCAL_VERSION_URL,
    BRANCHES: options.branches,
    STATS_TOKEN: options.token,
  }

  const server = createServer(async (incoming, outgoing) => {
    incoming.resume()
    try {
      const headers = new Headers()
      for (const [name, value] of Object.entries(incoming.headers)) {
        if (SKIPPED_HEADERS.has(name) || value === undefined) continue
        for (const one of Array.isArray(value) ? value : [value]) headers.append(name, one)
      }
      const request = new Request(`http://127.0.0.1:${server.address().port}${incoming.url}`, { method: incoming.method, headers })
      const pending = []
      const ctx = { waitUntil: (promise) => pending.push(promise), passThroughOnException() {} }
      const response = await worker.fetch(request, env, ctx)
      const body = Buffer.from(await response.arrayBuffer())
      outgoing.writeHead(response.status, Object.fromEntries(response.headers))
      outgoing.end(incoming.method === 'HEAD' ? undefined : body)
      await Promise.allSettled(pending)
      console.log(`${incoming.method} ${incoming.url} -> ${response.status}`)
    } catch (error) {
      console.error(`${incoming.method} ${incoming.url} failed:`, error)
      if (!outgoing.headersSent) outgoing.writeHead(500, { 'content-type': 'text/plain' })
      outgoing.end('internal error')
    }
  })

  server.listen(port, '127.0.0.1', () => {
    const url = `http://127.0.0.1:${server.address().port}`
    console.log(`Listening on ${url}`)
    console.log(`  check URL:  ${url}/v1/check`)
    console.log(`  stats:      curl -H "Authorization: Bearer <token>" ${url}/v1/stats`)
    console.log(`  database:   ${options.db === ':memory:' ? 'in memory' : options.db}`)
    console.log(`  latest:     ${options.latest ?? 'none, so checks answer {}'}`)
    if (!options.token) console.log('  no --token, so /v1/stats answers 403')
  })
}

// `node --test` inside server/ runs every .mjs under test/, this one too. Serve only when started directly.
if (!process.env.NODE_TEST_CONTEXT) main()
