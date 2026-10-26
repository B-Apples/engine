# Engine

A personal training app: strength, cycling, running, swimming and stretching, with multi-week blocks,
progression forecasts, body tracking and post-workout evaluations from Claude.

It is an installable web app (PWA). Open the site in Chrome on Android, then use **Install app**.

## How it fits together

- `index.html` is the whole app. It keeps an offline copy of your data and a queue of unsent changes,
  so logging works with no signal.
- `backend.js` connects the app to Supabase: sign-in, the `docs` table (one JSON document per record),
  live sync between devices, and progress photos in a private storage bucket.
- `sw.js` caches the app so it opens offline. Run `python3 tools/stamp.py` before publishing so phones pick up the new version.
- `supabase/migrations` sets up the database with row-level security, so each account can only reach its own rows.
- `supabase/functions/evaluate` calls Claude for workout evaluations. The Anthropic API key is stored as the
  `ANTHROPIC_API_KEY` secret in Supabase and never reaches the browser.
- `config.js` holds the Supabase URL and publishable key, which are safe to publish.

Third-party code: `vendor/supabase.js` is supabase-js (MIT, see `vendor/supabase-js.LICENSE`).
