/* =====================================================================
   Supabase 어댑터
   claude.ai 평가시스템이 쓰던 window.claude.use('db'|'user'|'downloads')와
   같은 모양을 Supabase 위에 만들어, 화면 코드는 거의 그대로 쓴다.

   모드
   - anon  : 로그인 전. 데이터 없음(로그인 화면만)
   - judge : 위원 로그인(성명+전화번호 → 세션 토큰). RPC로 자기 학부 팀·자기 점수만 읽고 씀
   - admin : Supabase Auth 관리자 계정. 표 전체 읽기, 설정·초기화·대리 입력

   실시간 대신 4초마다 다시 읽고, 바뀐 부분만 화면에 알린다.
   ===================================================================== */
(function () {
  'use strict';
  const cfg = window.SB_CONFIG || {};
  const configured = !!(cfg.url && cfg.anonKey && !/YOUR_/.test(cfg.url + cfg.anonKey) && window.supabase);
  const client = configured ? window.supabase.createClient(cfg.url, cfg.anonKey) : null;
  const POLL_MS = cfg.pollMs || 4000;

  const LS = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) {} }
  };
  const pad = b => String(b).padStart(2, '0');
  const AWARD = { grand: '대상', gold: '금상', silver: '은상', bronze: '동상', merit: '장려상' };

  const SB = window.SB = {
    configured, client, mode: 'anon', isAdmin: false, uid: null, email: null,
    token: LS.get('sbJudgeToken'), judgeId: null, lastError: null
  };

  /* ---------- 상태와 구독 ---------- */
  let state = { config: { judges: [], locked: false, quota: {}, slotMin: 10 }, teams: {}, scores: {} };
  const last = { config: '', teams: '', scores: '' };
  const subs = { config: [], teams: [], scores: [] };
  const clone = v => v == null ? undefined : JSON.parse(JSON.stringify(v));
  const docSnap = (id, data) => ({ id, exists: data != null, data: () => clone(data) });
  const colSnap = m => ({ docs: Object.keys(m).sort().map(k => docSnap(k, m[k])) });
  function emit(force) {
    const parts = { config: state.config, teams: state.teams, scores: state.scores };
    for (const k of Object.keys(parts)) {
      const s = JSON.stringify(parts[k]);
      if (!force && s === last[k]) continue;
      last[k] = s;
      subs[k].forEach(f => { try { f.cb(k === 'config' ? docSnap('main', parts[k]) : colSnap(parts[k])); } catch (e) { console.error(e); } });
    }
  }
  function fail(e) {
    SB.lastError = e;
    for (const k of Object.keys(subs)) subs[k].forEach(f => { if (f.err) try { f.err(e); } catch (x) {} });
  }

  /* ---------- 읽기 ---------- */
  async function rows(q) { const { data, error } = await q; if (error) throw error; return data || []; }

  async function fetchAdmin() {
    const [js, qs, st, ts, ms, sc] = await Promise.all([
      rows(client.from('judges').select('id,division,name,org,title,phone_hash,active').order('id')),
      rows(client.from('award_quota').select('*')),
      rows(client.from('settings').select('*')),
      rows(client.from('teams').select('*').order('booth')),
      rows(client.from('team_members').select('booth,seq,name').order('booth').order('seq')),
      rows(client.from('scores').select('*'))
    ]);
    const quota = {};
    qs.forEach(q => { quota[q.division] = {}; for (const k in AWARD) quota[q.division][AWARD[k]] = q[k]; });
    const s0 = st[0] || {};
    const config = {
      judges: js.filter(j => j.active !== false).map(j => ({ id: j.id, division: j.division, name: j.name, org: j.org || '', title: j.title || '', phoneHash: j.phone_hash ? 'set' : null })),
      locked: !!s0.locked, slotMin: s0.slot_min || 10, quota
    };
    const members = {};
    ms.forEach(m => (members[m.booth] = members[m.booth] || []).push(m.name));
    const teams = {}, divOf = {};
    ts.forEach(t => {
      const b = pad(t.booth); divOf[t.booth] = t.division;
      teams[b] = { booth: b, division: t.division, dept: t.dept, advisor: t.advisor || '', team: t.team_name, work: t.work_title,
                   company: t.company || '', memberNames: members[t.booth] || [], members: (members[t.booth] || []).length };
    });
    const scores = {};
    sc.forEach(s => {
      scores[s.judge_id + '__' + pad(s.booth)] = { judgeId: s.judge_id, booth: pad(s.booth), division: divOf[s.booth], items: s.items,
        total: s.total, absent: s.absent, memo: s.memo || '', updatedAt: s.updated_at, rev: s.rev, by: s.updated_by };
    });
    return { config, teams, scores };
  }

  async function fetchJudge() {
    const { data, error } = await client.rpc('judge_sheet', { p_token: SB.token });
    if (error) {
      if (/로그인이 만료|invalid input syntax for type uuid/.test(error.message || '')) { SB.token = null; LS.set('sbJudgeToken', null); location.reload(); }
      throw error;
    }
    const j = data.judge;
    SB.judgeId = j.id;
    const config = { judges: [{ id: j.id, division: j.division, name: j.name, org: j.org || '', title: j.title || '', phoneHash: 'set' }],
                     locked: !!data.locked, slotMin: data.slot_min || 10, quota: {} };
    const teams = {}, scores = {};
    (data.teams || []).forEach(t => {
      const b = pad(t.booth);
      teams[b] = { booth: b, division: t.division || j.division, dept: t.dept, advisor: t.advisor || '', team: t.team_name, work: t.work_title, company: t.company || '' };
      if (t.score) scores[j.id + '__' + b] = { judgeId: j.id, booth: b, division: j.division, items: t.score.items, total: t.score.total,
        absent: t.score.absent, memo: t.score.memo || '', updatedAt: t.score.updated_at, rev: t.score.rev, by: t.score.updated_by };
    });
    return { config, teams, scores };
  }

  let fetching = null, fails = 0;
  async function refresh() {
    if (SB.mode === 'anon') { emit(); return; }
    if (fetching) return fetching;
    fetching = (async () => {
      try { state = SB.mode === 'admin' ? await fetchAdmin() : await fetchJudge(); fails = 0; emit(); }
      catch (e) { console.error(e); if (++fails === 3) fail(e); throw e; }
      finally { fetching = null; }
    })();
    return fetching;
  }
  const refreshSoon = () => setTimeout(() => refresh().catch(() => {}), 0);

  /* ---------- 쓰기 ---------- */
  function rpcErr(error) { const e = new Error((error && (error.message || error.hint)) || '저장하지 못했습니다'); e.code = error && error.code; return e; }

  async function setScore(id, body) {
    const [jid, b] = id.split('__');
    const args = { p_booth: Number(b), p_items: body.items.map(Number), p_absent: !!body.absent, p_memo: body.memo || '', p_base_rev: Number(body.baseRev) || 0 };
    const { error } = SB.mode === 'admin'
      ? await client.rpc('admin_submit_score', { p_judge: jid, ...args })
      : await client.rpc('submit_score', { p_token: SB.token, ...args });
    if (error) throw rpcErr(error);
    refreshSoon();
  }

  async function updateConfig(patch) {
    if (SB.mode !== 'admin') throw new Error('관리자만 할 수 있습니다');
    if ('locked' in patch) {
      const { error } = await client.from('settings').update({ locked: !!patch.locked, updated_at: new Date().toISOString() }).eq('id', true);
      if (error) throw rpcErr(error);
    }
    if (patch.quota) {
      const rowsQ = Object.entries(patch.quota).map(([division, q]) => ({ division, grand: q['대상'] || 0, gold: q['금상'] || 0, silver: q['은상'] || 0, bronze: q['동상'] || 0, merit: q['장려상'] || 0 }));
      const { error } = await client.from('award_quota').upsert(rowsQ, { onConflict: 'division' });
      if (error) throw rpcErr(error);
    }
    if (patch.judges) {
      for (const j of patch.judges) {
        const { error } = await client.from('judges').update({ name: j.name, org: j.org || null, title: j.title || null }).eq('id', j.id);
        if (error) throw rpcErr(error);
        if (j.phoneNew) {
          const r = await client.rpc('admin_set_phone', { p_judge: j.id, p_phone: String(j.phoneNew) });
          if (r.error) throw rpcErr(r.error);
        }
      }
    }
    refreshSoon();
  }

  async function updateTeam(b, patch) {
    if (SB.mode !== 'admin') throw new Error('관리자만 할 수 있습니다');
    const booth = Number(b), up = {};
    if ('team' in patch) up.team_name = patch.team;
    if ('work' in patch) up.work_title = patch.work;
    if ('company' in patch) up.company = patch.company || null;
    if ('dept' in patch) up.dept = patch.dept;
    if ('advisor' in patch) up.advisor = patch.advisor || null;
    if (Object.keys(up).length) {
      const { error } = await client.from('teams').update(up).eq('booth', booth);
      if (error) throw rpcErr(error);
    }
    if (Array.isArray(patch.memberNames)) {
      const old = await rows(client.from('team_members').select('name,is_leader,note').eq('booth', booth));
      const keep = {}; old.forEach(m => keep[m.name] = m);
      let r = await client.from('team_members').delete().eq('booth', booth);
      if (r.error) throw rpcErr(r.error);
      const ins = patch.memberNames.map((name, i) => ({ booth, seq: i + 1, name, is_leader: !!(keep[name] && keep[name].is_leader), note: keep[name] ? keep[name].note : null }));
      if (ins.length) { r = await client.from('team_members').insert(ins); if (r.error) throw rpcErr(r.error); }
    }
    refreshSoon();
  }

  async function deleteScore(id) {
    if (SB.mode !== 'admin') throw new Error('관리자만 할 수 있습니다');
    const [jid, b] = id.split('__');
    const { error } = await client.from('scores').delete().eq('judge_id', jid).eq('booth', Number(b));
    if (error) throw rpcErr(error);
    delete state.scores[id];
    refreshSoon();
  }

  /* ---------- window.claude 와 같은 모양 ---------- */
  const db = {
    doc(path) {
      const [col, id] = path.split('/');
      return {
        onSnapshot(cb, err) { if (col === 'config') { subs.config.push({ cb, err }); setTimeout(() => cb(docSnap('main', state.config))); } return () => {}; },
        async get() {
          await refresh();
          const m = col === 'config' ? { main: state.config } : state[col] || {};
          return docSnap(id, m[id]);
        },
        async set(body) { if (col === 'scores') return setScore(id, body); throw new Error('지원하지 않는 저장입니다: ' + path); },
        async update(patch) {
          if (col === 'config') return updateConfig(patch);
          if (col === 'teams') return updateTeam(id, patch);
          throw new Error('지원하지 않는 저장입니다: ' + path);
        },
        async delete() { if (col === 'scores') return deleteScore(id); throw new Error('지원하지 않는 삭제입니다: ' + path); }
      };
    },
    collection(col) {
      return { onSnapshot(cb, err) { (subs[col] = subs[col] || []).push({ cb, err }); setTimeout(() => cb(colSnap(state[col] || {}))); return () => {}; } };
    }
  };
  const user = {
    async canEdit() { return SB.isAdmin; },
    async isOwner() { return SB.isAdmin; },
    async id() { return SB.uid || (SB.judgeId ? 'judge:' + SB.judgeId : null); }
  };
  const downloads = {
    async save({ filename, data }) {
      const url = URL.createObjectURL(data instanceof Blob ? data : new Blob([data]));
      const a = document.createElement('a'); a.href = url; a.download = filename || 'download';
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 4000);
    }
  };

  /* ---------- 로그인·로그아웃 ---------- */
  SB.judgeLogin = async (name, phone) => {
    const { data, error } = await client.rpc('judge_login', { p_name: name, p_phone: phone });
    if (error) return { ok: false, error: error.message || '로그인하지 못했습니다' };
    if (data && data.ok === false) return data;
    if (!data || !data.token) return { ok: false, error: '로그인하지 못했습니다' };
    LS.set('sbJudgeToken', data.token);
    return { ok: true, ...data };
  };
  SB.adminLogin = async (email, password) => {
    const { error } = await client.auth.signInWithPassword({ email, password });
    if (error) return { ok: false, error: '이메일 또는 비밀번호가 맞지 않습니다' };
    const r = await client.rpc('is_admin');
    if (r.error || r.data !== true) { await client.auth.signOut(); return { ok: false, error: '관리자로 지정되지 않은 계정입니다' }; }
    LS.set('sbJudgeToken', null);
    return { ok: true };
  };
  SB.logout = async () => {
    try {
      if (SB.mode === 'judge' && SB.token) await client.rpc('judge_logout', { p_token: SB.token });
      if (SB.mode === 'admin') await client.auth.signOut();
    } catch (e) {}
    LS.set('sbJudgeToken', null);
    location.reload();
  };

  /* ---------- 시작 ---------- */
  SB.ready = (async () => {
    if (!configured) return;
    try {
      const { data: { session } } = await client.auth.getSession();
      if (session) {
        const r = await client.rpc('is_admin');
        if (!r.error && r.data === true) { SB.mode = 'admin'; SB.isAdmin = true; SB.uid = session.user.id; SB.email = session.user.email; }
      }
      if (SB.mode === 'anon' && SB.token) SB.mode = 'judge';
      await refresh().catch(() => {});
      if (SB.mode === 'admin') {
        const s = await client.storage.from('private-assets').createSignedUrl('cert-seal.png', 60 * 60 * 6);
        if (!s.error && s.data) window.CERT_SEAL_URL = s.data.signedUrl;
      }
    } catch (e) { console.error(e); SB.lastError = e; }
    setInterval(() => { if (!document.hidden) refresh().catch(() => {}); }, POLL_MS);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh().catch(() => {}); });
  })();

  window.claude = {
    async use(name) {
      if (!configured) return null;
      await SB.ready;
      return name === 'db' ? db : name === 'user' ? user : name === 'downloads' ? downloads : null;
    }
  };
})();
