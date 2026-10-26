// A stand-in for Cloudflare D1 over node:sqlite, for the tests and the local server.
// It has the part of D1's API the Worker uses: prepare(sql).bind(...values) and then run(), all() or first(column).
// Like D1, it runs nothing until run, all or first, and refuses undefined values.

import { readFileSync } from 'node:fs'
import { DatabaseSync } from 'node:sqlite'

const SCHEMA_URL = new URL('../schema.sql', import.meta.url)

export class D1Shim {
  // A database at the path (created when missing), or in memory. The schema is applied unless schema is false.
  constructor(path = ':memory:', { schema = true } = {}) {
    this.sqlite = new DatabaseSync(path)
    if (schema) this.sqlite.exec(readFileSync(SCHEMA_URL, 'utf8'))
  }

  prepare(sql) {
    return new D1Statement(this.sqlite, sql, [])
  }
}

class D1Statement {
  constructor(sqlite, sql, values) {
    this.sqlite = sqlite
    this.sql = sql
    this.values = values
  }

  bind(...values) {
    const index = values.indexOf(undefined)
    if (index !== -1) throw new TypeError(`D1_TYPE_ERROR: Type 'undefined' not supported for value at index ${index}`)
    return new D1Statement(this.sqlite, this.sql, values)
  }

  async run() {
    const info = this.sqlite.prepare(this.sql).run(...this.values)
    return { success: true, meta: { changes: info.changes, last_row_id: Number(info.lastInsertRowid) }, results: [] }
  }

  async all() {
    const rows = this.sqlite.prepare(this.sql).all(...this.values)
    return { success: true, meta: { rows_read: rows.length }, results: rows.map((row) => ({ ...row })) }
  }

  async first(column) {
    const row = this.sqlite.prepare(this.sql).get(...this.values)
    if (!row) return null
    if (column === undefined) return { ...row }
    if (!(column in row)) throw new Error(`D1_COLUMN_NOTFOUND: Column not found (${column})`)
    return row[column]
  }
}
