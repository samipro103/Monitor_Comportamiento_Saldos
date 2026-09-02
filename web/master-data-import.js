(() => {
  'use strict';

  const SESSION_KEY = 'monitor_saldos_session';
  let cfg = null;

  const $ = s => document.querySelector(s);
  const esc = s => String(s ?? '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));

  function getSession() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); }
    catch { return null; }
  }

  function setSession(s) {
    localStorage.setItem(SESSION_KEY, JSON.stringify(s));
  }

  async function getConfig() {
    if (cfg) return cfg;
    const r = await fetch('./config.json?v=24', {cache:'no-store'});
    if (!r.ok) throw new Error(`No se pudo leer config.json (HTTP ${r.status}).`);
    const d = await r.json();
    cfg = {
      url:String(d.supabase_url || '').trim(),
      key:String(d.supabase_publishable_key || '').trim()
    };
    return cfg;
  }

  async function refreshSession(session) {
    const c = await getConfig();
    if (!session?.refresh_token) throw new Error('La sesión expiró. Vuelve a iniciar sesión.');
    const r = await fetch(`${c.url}/auth/v1/token?grant_type=refresh_token`, {
      method:'POST',
      headers:{apikey:c.key, 'Content-Type':'application/json'},
      body:JSON.stringify({refresh_token:session.refresh_token})
    });
    const d = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error('La sesión expiró. Vuelve a iniciar sesión.');
    setSession(d);
    return d;
  }

  async function rpc(fn, payload = {}, retry = true) {
    const c = await getConfig();
    let session = getSession();
    if (!session?.access_token) throw new Error('Debes iniciar sesión primero.');

    let r = await fetch(`${c.url}/rest/v1/rpc/${fn}`, {
      method:'POST',
      headers:{
        apikey:c.key,
        Authorization:`Bearer ${session.access_token}`,
        'Content-Type':'application/json',
        Accept:'application/json'
      },
      body:JSON.stringify(payload)
    });

    if (r.status === 401 && retry) {
      session = await refreshSession(session);
      r = await fetch(`${c.url}/rest/v1/rpc/${fn}`, {
        method:'POST',
        headers:{
          apikey:c.key,
          Authorization:`Bearer ${session.access_token}`,
          'Content-Type':'application/json',
          Accept:'application/json'
        },
        body:JSON.stringify(payload)
      });
    }

    const d = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(d.message || d.msg || `HTTP ${r.status}`);
    return d;
  }

  function normalizeHeader(v) {
    return String(v || '')
      .replace(/^\uFEFF/, '')
      .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
      .trim().toUpperCase()
      .replace(/[_\.]+/g, ' ')
      .replace(/\s+/g, ' ');
  }

  function digits(v) {
    return String(v || '').replace(/\D/g, '');
  }

  function parseDelimited(text) {
    text = String(text || '').replace(/^\uFEFF/, '');
    const firstLine = text.split(/\r?\n/, 1)[0] || '';
    const delimiter = (firstLine.match(/;/g) || []).length >= (firstLine.match(/,/g) || []).length ? ';' : ',';

    const rows = [];
    let row = [];
    let cell = '';
    let quoted = false;

    for (let i = 0; i < text.length; i++) {
      const ch = text[i];

      if (quoted) {
        if (ch === '"') {
          if (text[i + 1] === '"') {
            cell += '"';
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell += ch;
        }
        continue;
      }

      if (ch === '"') {
        quoted = true;
      } else if (ch === delimiter) {
        row.push(cell);
        cell = '';
      } else if (ch === '\n') {
        row.push(cell);
        rows.push(row);
        row = [];
        cell = '';
      } else if (ch !== '\r') {
        cell += ch;
      }
    }

    if (cell.length || row.length) {
      row.push(cell);
      rows.push(row);
    }

    return rows;
  }

  function headerIndex(header) {
    const out = new Map();
    header.forEach((h, i) => out.set(normalizeHeader(h), i));
    return out;
  }

  function valueAt(row, idx, names) {
    for (const name of names) {
      const i = idx.get(normalizeHeader(name));
      if (i != null && i < row.length) return String(row[i] ?? '').trim();
    }
    return '';
  }

  function parseClients(rows) {
    if (!rows.length) throw new Error('El archivo de clientes está vacío.');
    const idx = headerIndex(rows[0]);
    const compact = idx.has('EPIN PHONE');

    const idNames = compact ? ['id_dms'] : ['COD.POINT', 'COD POINT'];
    const epinNames = compact ? ['epin_phone'] : ['MOVILES EPIN'];

    if (!idNames.some(x => idx.has(normalizeHeader(x)))) {
      throw new Error('No encuentro la columna COD.POINT / id_dms.');
    }
    if (!epinNames.some(x => idx.has(normalizeHeader(x)))) {
      throw new Error('No encuentro la columna MOVILES EPIN / epin_phone.');
    }

    const map = new Map();
    let conflicts = 0;
    let skipped = 0;

    for (let i = 1; i < rows.length; i++) {
      const row = rows[i];
      if (!row || !row.length) continue;

      const idDms = valueAt(row, idx, idNames);
      const epinRaw = valueAt(row, idx, epinNames);
      if (!idDms || !epinRaw) {
        skipped++;
        continue;
      }

      const base = {
        id_dms:idDms,
        point_name:valueAt(row, idx, compact ? ['point_name'] : ['PUNTO']),
        owner_name:valueAt(row, idx, compact ? ['owner_name'] : ['DUEÑO', 'DUENO']),
        circuit:valueAt(row, idx, compact ? ['circuit'] : ['CIRCUITO']).toUpperCase(),
        department:valueAt(row, idx, compact ? ['department'] : ['DEPARTAMENTO']),
        city:valueAt(row, idx, compact ? ['city'] : ['CIUDAD']),
        dms_status:valueAt(row, idx, compact ? ['dms_status'] : ['ESTADO DMS']),
        source_updated_at:valueAt(row, idx, compact ? ['source_updated_at'] : ['FECHA ULTIMA MODIFICACION'])
      };

      const phones = compact ? [epinRaw] : epinRaw.split('|');
      for (const raw of phones) {
        const epinPhone = digits(raw);
        if (!epinPhone) continue;

        const rec = {epin_phone:epinPhone, ...base};
        const previous = map.get(epinPhone);
        if (previous && previous.id_dms !== idDms) {
          conflicts++;
          continue;
        }
        map.set(epinPhone, rec);
      }
    }

    return {
      rows:[...map.values()],
      conflicts,
      skipped
    };
  }

  function parseCircuits(rows) {
    if (!rows.length) throw new Error('El archivo de circuitos está vacío.');
    const idx = headerIndex(rows[0]);

    if (!idx.has('CIRCUIT')) {
      if (!idx.has('CIRCUITO')) throw new Error('No encuentro la columna circuito.');
    }

    const map = new Map();

    for (let i = 1; i < rows.length; i++) {
      const row = rows[i];
      if (!row || !row.length) continue;

      const circuit = valueAt(row, idx, ['circuit', 'circuito']).toUpperCase();
      if (!circuit) continue;

      map.set(circuit, {
        circuit,
        id_route:valueAt(row, idx, ['id_route', 'id_ruta']),
        route:valueAt(row, idx, ['route', 'ruta']),
        territory:valueAt(row, idx, ['territory', 'territorios']),
        status:valueAt(row, idx, ['status', 'estado']),
        lunes:valueAt(row, idx, ['lunes']),
        martes:valueAt(row, idx, ['martes']),
        miercoles:valueAt(row, idx, ['miercoles']),
        jueves:valueAt(row, idx, ['jueves']),
        viernes:valueAt(row, idx, ['viernes']),
        sabado:valueAt(row, idx, ['sabado']),
        domingo:valueAt(row, idx, ['domingo'])
      });
    }

    return {rows:[...map.values()]};
  }

  async function readText(file) {
    if (!file) throw new Error('Selecciona un archivo CSV.');
    return await file.text();
  }

  function setProgress(kind, message, state = '') {
    const el = $(`#md-${kind}-status`);
    if (!el) return;
    el.className = `md-status ${state}`;
    el.textContent = message;
  }

  async function uploadInChunks(kind, records) {
    if (!records.length) throw new Error('No se encontraron registros válidos.');

    const importId = crypto.randomUUID();
    const fn = kind === 'clients' ? 'web_master_upsert_clients' : 'web_master_upsert_circuits';
    const chunkSize = kind === 'clients' ? 400 : 200;

    let done = 0;
    for (let i = 0; i < records.length; i += chunkSize) {
      const chunk = records.slice(i, i + chunkSize);
      await rpc(fn, {
        p_import_id:importId,
        p_rows:chunk
      });
      done += chunk.length;
      const pct = Math.round(done * 100 / records.length);
      setProgress(kind, `Subiendo ${done.toLocaleString('es-SV')} de ${records.length.toLocaleString('es-SV')} (${pct}%)…`, 'working');
    }

    const final = await rpc('web_master_finalize_import', {
      p_kind:kind,
      p_import_id:importId
    });

    return final;
  }

  async function importClients() {
    const input = $('#md-clients-file');
    const btn = $('#md-clients-btn');
    btn.disabled = true;

    try {
      setProgress('clients', 'Leyendo archivo…', 'working');
      const parsed = parseClients(parseDelimited(await readText(input.files?.[0])));
      setProgress('clients', `${parsed.rows.length.toLocaleString('es-SV')} relaciones EPIN → DMS listas. Subiendo…`, 'working');

      const final = await uploadInChunks('clients', parsed.rows);
      const extra = parsed.conflicts ? ` · ${parsed.conflicts} conflicto(s) omitidos` : '';
      setProgress('clients', `Listo: ${Number(final.total_active || parsed.rows.length).toLocaleString('es-SV')} EPIN activos${extra}.`, 'ok');
      await refreshStatus();
    } catch (e) {
      setProgress('clients', `Error: ${e.message || e}`, 'error');
    } finally {
      btn.disabled = false;
    }
  }

  async function importCircuits() {
    const input = $('#md-circuits-file');
    const btn = $('#md-circuits-btn');
    btn.disabled = true;

    try {
      setProgress('circuits', 'Leyendo archivo…', 'working');
      const parsed = parseCircuits(parseDelimited(await readText(input.files?.[0])));
      setProgress('circuits', `${parsed.rows.length.toLocaleString('es-SV')} circuitos listos. Subiendo…`, 'working');

      const final = await uploadInChunks('circuits', parsed.rows);
      setProgress('circuits', `Listo: ${Number(final.total_active || parsed.rows.length).toLocaleString('es-SV')} circuitos activos.`, 'ok');
      await refreshStatus();
    } catch (e) {
      setProgress('circuits', `Error: ${e.message || e}`, 'error');
    } finally {
      btn.disabled = false;
    }
  }

  async function refreshStatus() {
    const el = $('#md-master-status');
    if (!el) return;

    try {
      const s = await rpc('web_master_status');
      el.innerHTML = `<b>${Number(s.clients || 0).toLocaleString('es-SV')} EPIN relacionados</b> · ${Number(s.circuits || 0).toLocaleString('es-SV')} circuitos/rutas`;
    } catch (e) {
      el.textContent = 'Datos maestros todavía no cargados.';
    }
  }

  function injectStyles() {
    if ($('#mdStyles')) return;
    const style = document.createElement('style');
    style.id = 'mdStyles';
    style.textContent = `
      .md-section{margin-top:30px;padding-top:24px;border-top:1px solid #dfe6ea}
      .md-section h3{margin:4px 0 6px;color:#173447}
      .md-section>p{margin:0 0 18px;color:#687985}
      .md-status-main{margin:10px 0 22px;font-size:14px;color:#496171}
      .md-grid{display:grid;grid-template-columns:1fr 1fr;gap:26px}
      .md-import{padding-top:4px}
      .md-import h4{margin:0 0 6px;color:#173447}
      .md-import p{margin:0 0 12px;color:#71808c;font-size:13px}
      .md-import input[type=file]{display:block;width:100%;margin:0 0 10px;font:inherit}
      .md-status{min-height:20px;margin-top:10px;font-size:12px;color:#657784}
      .md-status.working{color:#7d6400}.md-status.ok{color:#187450}.md-status.error{color:#b42318}
      @media(max-width:760px){.md-grid{grid-template-columns:1fr}.md-import{padding-bottom:10px}}
    `;
    document.head.appendChild(style);
  }

  function injectUi() {
    const view = $('#view-settings');
    if (!view || $('#mdMasterSection')) return;

    const account = view.querySelector('.account-actions');
    const section = document.createElement('section');
    section.id = 'mdMasterSection';
    section.className = 'md-section';
    section.innerHTML = `
      <span class="eyebrow">DATOS MAESTROS</span>
      <h3>Ruta, circuito y relación EPIN / DMS</h3>
      <p>Actualiza estas bases cuando cambien clientes o circuitos. La web guarda solo los campos necesarios para relacionar el informe.</p>
      <div id="md-master-status" class="md-status-main">Consultando datos cargados…</div>

      <div class="md-grid">
        <div class="md-import">
          <h4>1. Base de clientes</h4>
          <p>Acepta la base RPOINTS completa o el CSV limpio incluido en el parche. Relaciona MOVILES EPIN con COD.POINT.</p>
          <input id="md-clients-file" type="file" accept=".csv,text/csv">
          <button id="md-clients-btn" class="btn primary" type="button">Importar clientes</button>
          <div id="md-clients-status" class="md-status"></div>
        </div>

        <div class="md-import">
          <h4>2. Circuitos y rutas</h4>
          <p>Acepta el archivo circuito / id_ruta / ruta / territorios.</p>
          <input id="md-circuits-file" type="file" accept=".csv,text/csv">
          <button id="md-circuits-btn" class="btn primary" type="button">Importar circuitos</button>
          <div id="md-circuits-status" class="md-status"></div>
        </div>
      </div>
    `;

    if (account) view.insertBefore(section, account);
    else view.appendChild(section);

    $('#md-clients-btn').addEventListener('click', importClients);
    $('#md-circuits-btn').addEventListener('click', importCircuits);

    const settingsBtn = document.querySelector('.nav-item[data-view="settings"]');
    settingsBtn?.addEventListener('click', () => setTimeout(refreshStatus, 50));
  }

  function init() {
    injectStyles();
    injectUi();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
