/* Engine backend: gives the app the same small API it had inside Claude (claude.use('db' | 'sample' | 'assets' | 'downloads')),
   backed by Supabase. All documents live in one table, public.docs (user_id, col, id, data jsonb), guarded by row-level security. */
(function () {
  const cfg = window.ENGINE_CONFIG || {};
  const configured = !!(cfg.url && cfg.anonKey && window.supabase);
  const sb = configured ? window.supabase.createClient(cfg.url, cfg.anonKey, { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'engine.auth' } }) : null;

  let session = null;
  const LS_SESSION = 'engine.auth';
  // Read the stored session synchronously so the app can open offline without waiting on the network.
  try { const raw = JSON.parse(localStorage.getItem(LS_SESSION) || 'null'); session = raw && (raw.currentSession || raw); if (session && !session.user) session = null; } catch (e) { session = null; }
  const ready = sb ? sb.auth.getSession().then(r => { if (r.data.session) session = r.data.session; }).catch(() => {}) : Promise.resolve();
  const uid = () => session && session.user && session.user.id;
  const err = (code, message) => { const e = new Error(message || code); e.code = code; return e; };
  const isNet = e => !navigator.onLine || /fetch|network|timed? ?out|Load failed/i.test(String(e && (e.message || e)));
  // Postgres data errors (class 22/23) will never succeed on retry; everything else is retried by the app's outbox.
  const mapErr = e => (e && /^2[23]/.test(e.code || '')) ? err('invalid_argument', e.message) : err('unavailable', e && e.message);

  /* ---------- db ---------- */
  const cache = new Map();      // col -> Map(id -> data)
  const listeners = new Map();  // col -> Set({ q, next, onErr })
  function snap(rows) {
    const md = { fromCache: false, hasPendingWrites: false };
    const docs = rows.map(r => ({ id: r.id, exists: true, data: () => r.data, metadata: md }));
    return { docs, size: docs.length, empty: !docs.length, metadata: md, docChanges: () => [] };
  }
  function emit(col) {
    const m = cache.get(col); if (!m) return;
    for (const l of listeners.get(col) || []) {
      let rows = [...m.entries()].map(([id, data]) => ({ id, data }));
      if (l.q.ob) { const f = l.q.ob, dir = l.q.dir === 'desc' ? -1 : 1; rows.sort((a, b) => { const x = a.data[f], y = b.data[f]; return (x < y ? -1 : x > y ? 1 : 0) * dir; }); }
      if (l.q.lim) rows = rows.slice(0, l.q.lim);
      try { l.next(snap(rows)); } catch (e) { console.error(e); }
    }
  }
  const loading = new Map();
  function load(col) {
    if (!sb || !uid()) return Promise.resolve();
    if (loading.has(col)) return loading.get(col);
    const p = (async () => {
      const all = []; const page = 1000;
      for (let from = 0; ; from += page) {
        const { data, error } = await sb.from('docs').select('id,data').eq('col', col).range(from, from + page - 1);
        if (error) throw error;
        all.push(...data); if (data.length < page) break;
      }
      cache.set(col, new Map(all.map(r => [r.id, r.data]))); emit(col);
    })().catch(e => { if (!isNet(e)) for (const l of listeners.get(col) || []) l.onErr && l.onErr(mapErr(e)); }).finally(() => loading.delete(col));
    loading.set(col, p); return p;
  }
  const reloadAll = () => { for (const col of listeners.keys()) load(col); };
  let reloadT = null; const pending = new Set();
  function reloadSoon(col) { if (col) pending.add(col); else for (const c of listeners.keys()) pending.add(c); clearTimeout(reloadT); reloadT = setTimeout(() => { for (const c of pending) load(c); pending.clear(); }, 300); }
  let channel = null;
  // Row-level security limits inserts and updates to this user's rows. Deletes can't be filtered and carry only the
  // primary key (user_id, col, id), so check the owner here.
  function subscribe() {
    if (channel || !sb || !uid()) return;
    channel = sb.channel('docs')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'docs' }, p => {
        const r = (p.new && p.new.col) ? p.new : (p.old || {});
        if (r.user_id && r.user_id !== uid()) return;
        reloadSoon(r.col);
      })
      .subscribe(st => { if (st === 'SUBSCRIBED') reloadSoon(); });
  }
  window.addEventListener('online', reloadAll);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && navigator.onLine) reloadAll(); });

  function query(q) {
    return {
      where() { return query(q); },
      orderBy(f, dir) { return query({ ...q, ob: f, dir }); },
      limit(n) { return query({ ...q, lim: n }); },
      doc(id) { return docRef(q.col, id); },
      onSnapshot(next, onErr) {
        const l = { q, next, onErr }; (listeners.get(q.col) || listeners.set(q.col, new Set()).get(q.col)).add(l);
        if (cache.has(q.col)) setTimeout(() => emit(q.col), 0); else load(q.col);
        subscribe();
        return () => listeners.get(q.col).delete(l);
      }
    };
  }
  function docRef(col, id) {
    return {
      id,
      async set(data) {
        if (!uid()) throw err('unavailable', 'signed out');
        const { error } = await sb.from('docs').upsert({ user_id: uid(), col, id, data, updated_at: new Date().toISOString() });
        if (error) throw mapErr(error);
        const m = cache.get(col); if (m) m.set(id, data);
      },
      async delete() {
        if (!uid()) throw err('unavailable', 'signed out');
        const { error } = await sb.from('docs').delete().match({ user_id: uid(), col, id });
        if (error) throw mapErr(error);
        const m = cache.get(col); if (m) m.delete(id);
      }
    };
  }
  const db = { collection: col => query({ col }) };

  /* ---------- Claude evaluations (Supabase Edge Function "evaluate" holds the API key) ---------- */
  // The function streams newline-delimited JSON: {t} text deltas, {reset} when a fallback model restarts the answer,
  // then {done, text, stop} or {error, code}.
  async function sample(input, opts = {}) {
    if (!navigator.onLine) throw err('upstream_error', 'offline');
    await ready;
    const { data } = await sb.auth.getSession();
    const s = data && data.session;
    if (!s) throw err('session_expired', 'signed out');
    let res;
    try {
      res = await fetch(cfg.url + '/functions/v1/evaluate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: cfg.anonKey, Authorization: 'Bearer ' + s.access_token },
        body: JSON.stringify({ prompt: typeof input === 'string' ? input : JSON.stringify(input) })
      });
    } catch (e) { throw err('upstream_error', e && e.message); }
    if (!res.ok) {
      let b = {}; try { b = await res.json(); } catch (e) {}
      throw err(b.code || (res.status === 429 ? 'rate_limited' : 'upstream_error'), b.error || 'HTTP ' + res.status);
    }
    const reader = res.body.getReader(), dec = new TextDecoder();
    let buf = '', text = '', fin = null;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (!line) continue;
        let ev; try { ev = JSON.parse(line); } catch (e) { continue; }
        if (ev.error) throw err(ev.code || 'upstream_error', ev.error);
        if (ev.reset) text = '';
        if (ev.t) { text += ev.t; if (opts.onText) opts.onText({ text, delta: ev.t }); }
        if (ev.done) fin = ev;
      }
    }
    if (!fin) throw err('upstream_error', 'The evaluation was cut off.');
    if (typeof fin.text === 'string') text = fin.text;
    return { text, truncated: fin.stop === 'max_tokens' };
  }

  /* ---------- progress photos (private Storage bucket "photos") ---------- */
  const URLS_KEY = 'engine.photoUrls';
  let urls = {}; try { urls = JSON.parse(localStorage.getItem(URLS_KEY) || '{}'); } catch (e) { urls = {}; }
  const fetching = new Set();
  function photoUrl(path) {
    const hit = urls[path];
    if (hit && hit.exp > Date.now() + 86400000) return hit.url;
    if (!fetching.has(path) && sb && navigator.onLine) {
      fetching.add(path);
      sb.storage.from('photos').createSignedUrl(path, 60 * 60 * 24 * 30).then(({ data }) => {
        if (data && data.signedUrl) { urls[path] = { url: data.signedUrl, exp: Date.now() + 60 * 60 * 24 * 30 * 1000 }; try { localStorage.setItem(URLS_KEY, JSON.stringify(urls)); } catch (e) {} window.dispatchEvent(new Event('engine:photo')); }
      }).finally(() => fetching.delete(path));
    }
    return hit ? hit.url : '';
  }
  const assets = {
    async upload(blob) {
      if (!uid()) throw err('unavailable');
      const path = `${uid()}/${(crypto.randomUUID && crypto.randomUUID()) || Date.now().toString(36)}.jpg`;
      const { error } = await sb.storage.from('photos').upload(path, blob, { contentType: blob.type || 'image/jpeg' });
      if (error) throw err(isNet(error) ? 'unavailable' : 'upload_failed', error.message);
      return { id: path };
    }
  };

  /* ---------- export ---------- */
  const downloads = {
    async save({ filename, data, mimeType }) {
      const url = URL.createObjectURL(new Blob([data], { type: mimeType || 'application/json' }));
      const a = Object.assign(document.createElement('a'), { href: url, download: filename });
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 4000);
      return { status: 'saved' };
    }
  };

  if (sb) sb.auth.onAuthStateChange((ev, s) => {
    const was = uid();
    if (s || ev === 'SIGNED_OUT') session = s;
    if (s) { subscribe(); if (!was) setTimeout(reloadAll, 0); }
    if (ev === 'SIGNED_IN' || ev === 'SIGNED_OUT') window.dispatchEvent(new CustomEvent('engine:auth', { detail: ev }));
  });

  window.claude = {
    use: async name => {
      if (!sb) return null;
      if (name === 'db') return uid() ? db : null;
      if (name === 'sample') return sample;
      if (name === 'assets') return assets;
      if (name === 'downloads') return downloads;
      return null;
    }
  };
  window.engine = {
    configured,
    ready,
    signedIn: () => !!uid(),
    uid,
    email: () => session && session.user && session.user.email,
    async signIn(email, password) { const { error } = await sb.auth.signInWithPassword({ email, password }); if (error) throw error; await ready; },
    async signUp(email, password) { const { data, error } = await sb.auth.signUp({ email, password, options: { emailRedirectTo: location.origin + location.pathname } }); if (error) throw error; return { needsConfirm: !data.session }; },
    async signOut() { try { await sb.auth.signOut(); } catch (e) {} session = null; },
    photoUrl
  };
})();
