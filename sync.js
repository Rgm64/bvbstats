/* Cross-device sync for the Beach Stat Collector.
 *
 * Design note: the app is local-first and stays that way. Collection writes to
 * localStorage synchronously on every tap; this module only reconciles that
 * store with the server when a network happens to be available. Nothing here
 * is ever on the critical path of recording a rally, so a slow, failing or
 * paused backend cannot interrupt a match.
 *
 * Talks to Supabase over plain HTTP rather than through the vendor SDK, so the
 * app keeps its no-dependency, no-build-step property and there is no extra
 * bundle for the service worker to cache.
 */
(function () {
  'use strict';

  /* ==================== merge ====================
     A season is well under a megabyte, so matches move whole rather than being
     diffed. One person stats one match on one device, so match-level
     last-write-wins is safe: the only losing case is two devices editing the
     same match at once, which does not happen in this workflow. */

  /* Returns every match, tombstones included — callers filter for display, and
     the tombstone must survive so a delete does not resurrect from a device
     that still has the old row. Pure and idempotent. */
  function mergeMatches(local, remote) {
    const out = new Map();
    (local || []).forEach(m => { if (m && m.id) out.set(m.id, m); });
    (remote || []).forEach(r => {
      if (!r || !r.id) return;
      const mine = out.get(r.id);
      if (!mine) { out.set(r.id, r); return; }
      /* Ties keep the local copy, so merging is deterministic either way round. */
      out.set(r.id, (r.updatedAt || 0) > (mine.updatedAt || 0) ? r : mine);
    });
    return [...out.values()].sort((a, b) => {
      const da = (a.cfg && a.cfg.date) || '', db = (b.cfg && b.cfg.date) || '';
      return da === db ? String(a.id).localeCompare(String(b.id)) : da.localeCompare(db);
    });
  }

  const visible = list => (list || []).filter(m => !m.deleted);

  /* ==================== session ====================
     Tokens are kept in localStorage so a home-screen app stays signed in
     across launches. */

  const SESSION_KEY = 'bvstat:session';
  const SYNCED_KEY = 'bvstat:synced';   // { matchId: updatedAt } last confirmed on the server

  function readJSON(key, fallback) {
    try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
    catch (e) { return fallback; }
  }
  function writeJSON(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); return true; }
    catch (e) { return false; }
  }

  function Client(cfg) {
    this.url = (cfg && cfg.url || '').replace(/\/+$/, '');
    this.anonKey = (cfg && cfg.anonKey) || '';
    this.session = readJSON(SESSION_KEY, null);
    this.synced = readJSON(SYNCED_KEY, {});
  }

  Client.prototype.configured = function () { return !!(this.url && this.anonKey); };
  Client.prototype.signedIn = function () { return !!(this.session && this.session.access_token); };
  Client.prototype.email = function () { return this.session && this.session.email || null; };

  Client.prototype.setSession = function (s) {
    this.session = s;
    if (s) writeJSON(SESSION_KEY, s); else { try { localStorage.removeItem(SESSION_KEY); } catch (e) {} }
  };

  Client.prototype.signOut = function () {
    this.setSession(null);
    this.synced = {};
    writeJSON(SYNCED_KEY, {});
  };

  /* Magic link. The redirect comes back to this same page with tokens in the
     URL fragment, which adoptRedirect() below picks up. */
  Client.prototype.sendMagicLink = function (email) {
    const redirect = location.origin + location.pathname;
    return fetch(this.url + '/auth/v1/otp', {
      method: 'POST',
      headers: { 'apikey': this.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email, create_user: true,
                             options: { email_redirect_to: redirect } }),
    }).then(res => res.ok ? { ok: true }
                          : res.json().catch(() => ({})).then(b => ({
                              ok: false,
                              error: b.msg || b.error_description || b.message || ('sign-in failed (' + res.status + ')'),
                            })));
  };

  /* Reads `#access_token=...` left by the magic link, stores it, and scrubs the
     fragment so the tokens do not linger in the address bar or history. */
  Client.prototype.adoptRedirect = function () {
    const hash = location.hash || '';
    if (hash.indexOf('access_token=') < 0) return false;
    const p = new URLSearchParams(hash.replace(/^#/, ''));
    const access = p.get('access_token');
    if (!access) return false;
    this.setSession({
      access_token: access,
      refresh_token: p.get('refresh_token') || '',
      expires_at: Date.now() + (parseInt(p.get('expires_in') || '3600', 10) * 1000),
      email: claimFrom(access, 'email'),
      sub: claimFrom(access, 'sub'),
    });
    history.replaceState(null, '', location.pathname + location.search);
    return true;
  };

  /* The JWT payload is readable without verifying it — the server verifies on
     every request, so this is only used for display and for stamping a row's
     owner. */
  function claimFrom(jwt, key) {
    try {
      const part = String(jwt).split('.')[1];
      const json = atob(part.replace(/-/g, '+').replace(/_/g, '/'));
      return JSON.parse(decodeURIComponent(escape(json)))[key] || null;
    } catch (e) { return null; }
  }

  Client.prototype.refreshIfNeeded = function () {
    const s = this.session;
    if (!s || !s.refresh_token) return Promise.resolve(!!s);
    if (s.expires_at && Date.now() < s.expires_at - 60000) return Promise.resolve(true);
    const self = this;
    return fetch(this.url + '/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      headers: { 'apikey': this.anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: s.refresh_token }),
    }).then(res => {
      if (!res.ok) throw new Error('session expired');
      return res.json();
    }).then(b => {
      self.setSession({
        access_token: b.access_token,
        refresh_token: b.refresh_token || s.refresh_token,
        expires_at: Date.now() + ((b.expires_in || 3600) * 1000),
        email: (b.user && b.user.email) || s.email,
        sub: (b.user && b.user.id) || s.sub,
      });
      return true;
    }).catch(() => {
      /* A refresh token that no longer works means signed out, not broken.
         Local data is untouched; the user simply signs in again. */
      self.signOut();
      return false;
    });
  };

  Client.prototype.headers = function (extra) {
    return Object.assign({
      'apikey': this.anonKey,
      'Authorization': 'Bearer ' + (this.session && this.session.access_token || this.anonKey),
      'Content-Type': 'application/json',
    }, extra || {});
  };

  /* ==================== transport ==================== */

  Client.prototype.pull = function () {
    return fetch(this.url + '/rest/v1/matches?select=id,payload,updated_at,deleted', {
      headers: this.headers(),
    }).then(res => {
      if (!res.ok) throw new Error('pull failed (' + res.status + ')');
      return res.json();
    }).then(rows => rows.map(row => {
      const m = row.payload || {};
      m.id = row.id;
      m.updatedAt = Number(row.updated_at) || 0;
      m.deleted = !!row.deleted;
      return m;
    }));
  };

  /* Upserts whole matches plus their derived stat rows. statsFor(match) returns
     the two Master_Data rows so the reporting table stays current. */
  Client.prototype.push = function (matches, statsFor) {
    if (!matches.length) return Promise.resolve({ pushed: 0 });
    const owner = this.session && this.session.sub;
    const self = this;
    const rows = matches.map(m => ({
      id: m.id,
      owner: owner,
      school: (m.cfg && m.cfg.school) || null,
      opponent: (m.cfg && m.cfg.oppo) || null,
      played_on: (m.cfg && m.cfg.date) || null,
      track_st: !!(m.cfg && m.cfg.trackST),
      payload: m,
      updated_at: m.updatedAt || 0,
      deleted: !!m.deleted,
    }));
    return fetch(this.url + '/rest/v1/matches?on_conflict=id', {
      method: 'POST',
      headers: this.headers({ 'Prefer': 'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify(rows),
    }).then(res => {
      if (!res.ok) return res.text().then(t => { throw new Error('push failed (' + res.status + '): ' + t.slice(0, 200)); });
      return statsFor ? self.pushStats(matches, statsFor) : null;
    }).then(() => {
      matches.forEach(m => { self.synced[m.id] = m.updatedAt || 0; });
      writeJSON(SYNCED_KEY, self.synced);
      return { pushed: matches.length };
    });
  };

  Client.prototype.pushStats = function (matches, statsFor) {
    const rows = [];
    matches.forEach(m => {
      if (m.deleted) return;                       // cascade removes them anyway
      (statsFor(m) || []).forEach(r => rows.push(r));
    });
    if (!rows.length) return Promise.resolve();
    return fetch(this.url + '/rest/v1/match_stats?on_conflict=match_id,slot', {
      method: 'POST',
      headers: this.headers({ 'Prefer': 'resolution=merge-duplicates,return=minimal' }),
      body: JSON.stringify(rows),
    }).then(res => {
      /* Stats are derived and regenerated on the next sync, so a failure here
         must not fail the push that carried the actual match. */
      if (!res.ok) console.warn('stat projection failed (' + res.status + ')');
    });
  };

  /* Matches this device has changed since the server last confirmed them.
     The comparison must be directional: a match the server is AHEAD of is not
     pending, it is merely stale here. Treating "different" as "pending" makes
     a device that is behind look like it has unpushed work, which in turn
     stops it from ever accepting the newer copy. */
  Client.prototype.pending = function (matches) {
    const self = this;
    return (matches || []).filter(m => {
      const confirmed = self.synced[m.id];
      return confirmed === undefined || (m.updatedAt || 0) > confirmed;
    });
  };

  /* Anything just read back from the server is confirmed by definition. */
  Client.prototype.confirm = function (rows) {
    let changed = false;
    (rows || []).forEach(r => {
      if (this.synced[r.id] !== (r.updatedAt || 0)) { this.synced[r.id] = r.updatedAt || 0; changed = true; }
    });
    if (changed) writeJSON(SYNCED_KEY, this.synced);
  };

  /* One full reconcile: pull, merge, push whatever the server has not got.
     Resolves with the merged list plus a status the UI can display. */
  Client.prototype.sync = function (localMatches, statsFor) {
    const self = this;
    if (!this.configured()) return Promise.resolve({ state: 'local', matches: localMatches });
    if (!this.signedIn()) return Promise.resolve({ state: 'signedout', matches: localMatches });
    return this.refreshIfNeeded().then(alive => {
      if (!alive) return { state: 'signedout', matches: localMatches };
      return self.pull().then(remote => {
        self.confirm(remote);
        const merged = mergeMatches(localMatches, remote);
        /* Only what this device is ahead on actually needs pushing. */
        const out = self.pending(merged);
        return self.push(out, statsFor)
          .then(() => ({ state: 'synced', matches: merged, pushed: out.length }));
      });
    }).catch(err => ({
      state: 'offline',
      matches: localMatches,
      pending: self.pending(localMatches).length,
      error: String(err && err.message || err),
    }));
  };

  window.BVSync = {
    Client: Client,
    mergeMatches: mergeMatches,
    visible: visible,
  };
})();
