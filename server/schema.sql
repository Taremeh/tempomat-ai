-- One row per UTC day, app version and macOS version, holding only counters.
-- No IPs, no user agents, no identifiers and no row per request.
--   checks:  every check received
--   daily:   checks that were an install's first of that UTC day (sum over a day = daily active installs)
--   weekly:  first of that ISO week, Monday to Sunday (sum over a week = weekly active installs)
--   monthly: first of that calendar month (sum over a month = monthly active installs)
--   first:   an install's first check ever (sum = new installs)
CREATE TABLE IF NOT EXISTS counts (
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  os TEXT NOT NULL,
  checks INTEGER NOT NULL DEFAULT 0,
  daily INTEGER NOT NULL DEFAULT 0,
  weekly INTEGER NOT NULL DEFAULT 0,
  monthly INTEGER NOT NULL DEFAULT 0,
  first INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, version, os)
);
