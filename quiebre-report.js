(() => {
  'use strict';

  const REPORT_VIEW_ID = 'view-quiebre';
  const SESSION_KEY = 'monitor_saldos_session';
  let cfg = null;
  let reportData = null;
  let currentRows = [];

  const $ = s => document.querySelector(s);
  const $$ = s => Array.from(document.querySelectorAll(s));
  const esc = s => String(s ?? '').replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  const fmtNum = n => new Intl.NumberFormat('es-SV').format(Number(n || 0));
  const fmtMoney = n => new Intl.NumberFormat('es-SV', {style:'currency', currency:'USD', minimumFractionDigits:2}).format(Number(n || 0));

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
      url: String(d.supabase_url || '').trim(),
      key: String(d.supabase_publishable_key || '').trim()
    };
    return cfg;
  }

  async function refreshSession(session) {
    const c = await getConfig();
    if (!session?.refresh_token) throw new Error('La sesión expiró. Vuelve a iniciar sesión.');
    const r = await fetch(`${c.url}/auth/v1/token?grant_type=refresh_token`, {
      method: 'POST',
      headers: {apikey:c.key, 'Content-Type':'application/json'},
      body: JSON.stringify({refresh_token:session.refresh_token})
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
      method: 'POST',
      headers: {
        apikey: c.key,
        Authorization: `Bearer ${session.access_token}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(payload)
    });

    if (r.status === 401 && retry) {
      session = await refreshSession(session);
      r = await fetch(`${c.url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          apikey: c.key,
          Authorization: `Bearer ${session.access_token}`,
          'Content-Type': 'application/json',
          Accept: 'application/json'
        },
        body: JSON.stringify(payload)
      });
    }

    const d = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(d.message || d.msg || `HTTP ${r.status}`);
    return d;
  }

  function monthName(year, month) {
    return new Intl.DateTimeFormat('es-SV', {month:'long', year:'numeric', timeZone:'America/El_Salvador'})
      .format(new Date(Date.UTC(year, month - 1, 15)));
  }

  function previousMonthValue() {
    const now = new Date();
    const y = now.getFullYear();
    const m = now.getMonth(); // mes anterior porque enero=0; si estamos en septiembre devuelve agosto=8 para Date(y,8,1)
    const d = new Date(y, m - 1, 1);
    const yy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    return `${yy}-${mm}`;
  }

  function duration(seconds) {
    seconds = Math.max(0, Math.round(Number(seconds || 0)));
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days} d ${hours} h ${mins} min`;
    if (hours > 0) return `${hours} h ${mins} min`;
    return `${mins} min`;
  }

  function localDate(v) {
    if (!v) return '—';
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) return '—';
    return new Intl.DateTimeFormat('es-SV', {
      timeZone:'America/El_Salvador', day:'2-digit', month:'2-digit', year:'numeric',
      hour:'2-digit', minute:'2-digit'
    }).format(d);
  }

  function levelClass(level) {
    return ({CRITICO:'qr-critical', ALTO:'qr-high', MEDIO:'qr-medium', BAJO:'qr-low'})[level] || 'qr-low';
  }

  function injectStyles() {
    if ($('#qrStyles')) return;
    const style = document.createElement('style');
    style.id = 'qrStyles';
    style.textContent = `
      .qr-toolbar{display:grid;grid-template-columns:minmax(160px,190px) minmax(220px,1fr) minmax(150px,190px) auto;gap:10px;align-items:end;margin:18px 0 22px}
      .qr-field{display:flex;flex-direction:column;gap:6px}.qr-field label{font-size:11px;font-weight:800;letter-spacing:.06em;color:#667788;text-transform:uppercase}
      .qr-field input,.qr-field select{height:42px;border:1px solid #dce4ea;border-radius:8px;background:#fff;padding:0 11px;font:inherit;color:#172b3a;outline:none}
      .qr-field input:focus,.qr-field select:focus{border-color:#7294aa;box-shadow:0 0 0 3px rgba(53,103,135,.08)}
      .qr-kpis{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));border-top:1px solid #e1e7eb;border-bottom:1px solid #e1e7eb;margin:0 0 22px}
      .qr-kpi{padding:18px 16px;border-right:1px solid #e1e7eb}.qr-kpi:last-child{border-right:0}.qr-kpi span{display:block;font-size:11px;font-weight:800;color:#71808c;text-transform:uppercase;letter-spacing:.05em}.qr-kpi b{display:block;font-size:25px;margin-top:5px;color:#102b3e}.qr-kpi small{display:block;color:#74828e;margin-top:3px}
      .qr-note{display:flex;gap:12px;align-items:flex-start;border-left:3px solid #7b98aa;padding:10px 0 10px 14px;margin:0 0 18px;color:#51626f}.qr-note b{color:#173447}
      .qr-note.warn{border-left-color:#c48b19}.qr-note.ok{border-left-color:#20825d}
      .qr-level{display:inline-flex;align-items:center;font-size:10px;font-weight:900;letter-spacing:.04em;padding:4px 7px;border-radius:999px;white-space:nowrap}
      .qr-critical{background:#fde8e7;color:#9f231b}.qr-high{background:#fff0df;color:#a35b09}.qr-medium{background:#fff8d8;color:#806400}.qr-low{background:#e9f5ef;color:#1f6c4b}
      .qr-duration b{display:block;color:#102b3e}.qr-duration small{display:block;color:#71808c;margin-top:2px}
      .qr-state{font-weight:800;font-size:11px;white-space:nowrap}.qr-state.zero{color:#b42318}.qr-state.low{color:#9a6500}.qr-state.ok{color:#187450}
      .qr-loading{padding:45px 10px;text-align:center;color:#667788}.qr-error{padding:16px;border-left:3px solid #b42318;background:#fff8f7;color:#8e241d;margin:16px 0}
      #view-quiebre .table-wrap{max-height:calc(100vh - 365px);min-height:260px}
      #view-quiebre th{position:sticky;top:0;z-index:2;background:#f7f9fa}
      #view-quiebre .qr-actions{display:flex;gap:8px;align-items:center;justify-content:flex-end}
      @media(max-width:1000px){.qr-toolbar{grid-template-columns:1fr 1fr}.qr-kpis{grid-template-columns:repeat(2,1fr)}.qr-kpi:nth-child(2n){border-right:0}.qr-kpi:last-child{grid-column:1/-1;border-top:1px solid #e1e7eb}}
      @media(max-width:640px){.qr-toolbar{grid-template-columns:1fr}.qr-kpis{grid-template-columns:1fr 1fr}.qr-kpi{padding:14px 10px}.qr-kpi b{font-size:21px}#view-quiebre .section-head{align-items:flex-start}.qr-actions{width:100%;justify-content:flex-start!important;flex-wrap:wrap}}
      @media print{.sidebar,.topbar,.qr-toolbar,.qr-actions,#toast{display:none!important}.workspace{margin:0!important}.view{display:none!important}#view-quiebre{display:block!important}.qr-kpis{grid-template-columns:repeat(5,1fr)}#view-quiebre .table-wrap{max-height:none;overflow:visible}body{background:#fff}}
    `;
    document.head.appendChild(style);
  }

  function injectView() {
    if ($('#' + REPORT_VIEW_ID)) return;

    const nav = $('.sidebar nav');
    if (!nav) return;
    const btn = document.createElement('button');
    btn.className = 'nav-item';
    btn.dataset.view = 'quiebre';
    btn.textContent = 'Informe de quiebre';
    const settingsBtn = nav.querySelector('[data-view="settings"]');
    nav.insertBefore(btn, settingsBtn || null);

    const main = $('main');
    const settingsView = $('#view-settings');
    const section = document.createElement('section');
    section.id = REPORT_VIEW_ID;
    section.className = 'view';
    section.innerHTML = `
      <div class="section-head">
        <div>
          <span class="eyebrow">QUIEBRE ACUMULADO</span>
          <h2>Informe mensual de saldo $0.00</h2>
          <p id="qrSubtitle">Tiempo observado en quiebre real por cliente.</p>
        </div>
        <div class="qr-actions">
          <button id="qrPrint" class="btn secondary small" type="button">Imprimir / PDF</button>
          <button id="qrExport" class="btn primary small" type="button">Exportar CSV</button>
        </div>
      </div>

      <div class="qr-toolbar">
        <div class="qr-field"><label>Mes del informe</label><input id="qrPeriod" type="month"></div>
        <div class="qr-field"><label>Buscar</label><input id="qrSearch" type="search" placeholder="ID, teléfono, comercio, ruta o circuito"></div>
        <div class="qr-field"><label>Quiebre mínimo</label><select id="qrMinHours"><option value="0">Todos</option><option value="24">24 horas o más</option><option value="48">48 horas o más</option><option value="72">72 horas o más</option></select></div>
        <button id="qrLoad" class="btn primary" type="button">Generar informe</button>
      </div>

      <div class="qr-kpis">
        <div class="qr-kpi"><span>Clientes con quiebre</span><b id="qrClients">—</b><small>Durante el mes</small></div>
        <div class="qr-kpi"><span>Horas acumuladas</span><b id="qrHours">—</b><small>Entre todos los clientes</small></div>
        <div class="qr-kpi"><span>Más de 24 h</span><b id="qr24">—</b><small>Casos relevantes</small></div>
        <div class="qr-kpi"><span>Más de 72 h</span><b id="qr72">—</b><small>Casos críticos</small></div>
        <div class="qr-kpi"><span>En quiebre al cierre</span><b id="qrAtClose">—</b><small>Saldo $0.00</small></div>
      </div>

      <div id="qrCoverage" class="qr-note"><div><b>Cobertura del histórico</b><div>Cargando…</div></div></div>

      <div class="section-head">
        <div><span class="eyebrow">DETALLE POR CLIENTE</span><h2 id="qrTableTitle">Quiebre del período</h2><p id="qrResultCount">0 resultados</p></div>
      </div>
      <div class="table-wrap tall">
        <table>
          <thead><tr>
            <th>Nivel</th><th>ID</th><th>Teléfono</th><th>Comercio</th><th>Zona</th><th>Ruta</th><th>Circuito</th>
            <th class="num">Saldo cierre</th><th class="num">Entradas</th><th>Quiebre acumulado</th><th>Mayor continuo</th><th>Estado al cierre</th>
          </tr></thead>
          <tbody id="qrRows"></tbody>
        </table>
      </div>
      <div id="qrEmpty" class="empty hidden">No hay clientes con quiebre para los filtros seleccionados.</div>
    `;
    main.insertBefore(section, settingsView || null);

    $('#qrPeriod').value = previousMonthValue();

    btn.addEventListener('click', () => {
      $$('.nav-item').forEach(x => x.classList.remove('active'));
      btn.classList.add('active');
      $$('.view').forEach(x => x.classList.remove('active'));
      section.classList.add('active');
      const title = $('#pageTitle');
      if (title) title.textContent = 'Informe de quiebre';
      if (!reportData) loadReport().catch(showError);
    });

    $('#qrLoad').addEventListener('click', () => loadReport().catch(showError));
    $('#qrPeriod').addEventListener('change', () => loadReport().catch(showError));
    $('#qrMinHours').addEventListener('change', applyFilters);
    $('#qrSearch').addEventListener('input', applyFilters);
    $('#qrExport').addEventListener('click', exportCsv);
    $('#qrPrint').addEventListener('click', () => window.print());

    // Conserva el botón principal "Actualizar vista" de la app.
    const scan = $('#scanBtn');
    if (scan && !scan.dataset.qrWrapped) {
      const original = scan.onclick;
      scan.onclick = async ev => {
        if ($('#' + REPORT_VIEW_ID)?.classList.contains('active')) {
          try { await loadReport(); }
          catch (e) { showError(e); }
          return;
        }
        if (typeof original === 'function') return original.call(scan, ev);
      };
      scan.dataset.qrWrapped = '1';
    }
  }

  function showError(err) {
    const body = $('#qrRows');
    if (body) body.innerHTML = `<tr><td colspan="12"><div class="qr-error"><b>No se pudo generar el informe.</b><br>${esc(err?.message || String(err))}</div></td></tr>`;
  }

  async function loadReport() {
    const period = $('#qrPeriod')?.value || previousMonthValue();
    const [yearText, monthText] = period.split('-');
    const year = Number(yearText), month = Number(monthText);
    if (!year || !month) throw new Error('Selecciona un mes válido.');

    $('#qrRows').innerHTML = '<tr><td colspan="12"><div class="qr-loading">Calculando quiebre acumulado…</div></td></tr>';
    $('#qrLoad').disabled = true;
    try {
      reportData = await rpc('web_quiebre_monthly', {p_year:year, p_month:month, p_query:null});
      const s = reportData.summary || {};
      $('#qrClients').textContent = fmtNum(s.clients_with_quiebre);
      $('#qrHours').textContent = `${fmtNum(Number(s.total_hours || 0).toFixed(0))} h`;
      $('#qr24').textContent = fmtNum(s.over_24h);
      $('#qr72').textContent = fmtNum(s.over_72h);
      $('#qrAtClose').textContent = fmtNum(s.in_quiebre_at_close);
      $('#qrSubtitle').textContent = `Quiebre acumulado de ${monthName(year, month)}. Solo cuenta tiempo observado en saldo $0.00 después de haber tenido saldo positivo.`;
      $('#qrTableTitle').textContent = `Clientes con quiebre · ${monthName(year, month)}`;

      const cov = $('#qrCoverage');
      const complete = Boolean(reportData.complete_period);
      cov.className = `qr-note ${complete ? 'ok' : 'warn'}`;
      cov.innerHTML = `<div><b>${complete ? 'Cobertura completa del mes' : 'Atención: cobertura incompleta'}</b><div>Histórico disponible: ${localDate(reportData.coverage_from)} — ${localDate(reportData.coverage_to)}. ${complete ? 'El período solicitado está cubierto.' : 'Las horas podrían estar incompletas si faltan tomas del mes.'}</div></div>`;

      applyFilters();
    } finally {
      $('#qrLoad').disabled = false;
    }
  }

  function applyFilters() {
    if (!reportData) return;
    const q = String($('#qrSearch')?.value || '').trim().toLowerCase();
    const minHours = Number($('#qrMinHours')?.value || 0);
    currentRows = (reportData.rows || []).filter(r => {
      if (Number(r.total_hours || 0) < minHours) return false;
      if (!q) return true;
      return [r.id_client, r.phone, r.commerce, r.zone, r.route, r.circuit, r.closing_state, r.level]
        .some(v => String(v ?? '').toLowerCase().includes(q));
    });
    renderRows(currentRows);
  }

  function renderRows(rows) {
    const body = $('#qrRows');
    $('#qrResultCount').textContent = `${fmtNum(rows.length)} cliente(s), ordenados de mayor a menor quiebre.`;
    $('#qrEmpty').classList.toggle('hidden', rows.length > 0);
    body.innerHTML = rows.map(r => {
      const stateClass = r.closing_state === 'EN QUIEBRE' ? 'zero' : (String(r.closing_state).includes('SALDO') && r.closing_state !== 'CON SALDO' ? 'low' : 'ok');
      return `<tr>
        <td><span class="qr-level ${levelClass(r.level)}">${esc(r.level)}</span></td>
        <td><b>${esc(r.id_client)}</b></td>
        <td>${esc(r.phone || '—')}</td>
        <td>${esc(r.commerce || '—')}</td>
        <td>${esc(r.zone || '—')}</td>
        <td>${esc(r.route || '—')}</td>
        <td>${esc(r.circuit || '—')}</td>
        <td class="num">${r.closing_balance == null ? '—' : fmtMoney(r.closing_balance)}</td>
        <td class="num">${fmtNum(r.quiebre_entries)}${r.came_in_quiebre ? '<small title="Venía en quiebre desde el mes anterior"> + arrastre</small>' : ''}</td>
        <td class="qr-duration"><b>${duration(r.total_seconds)}</b><small>${Number(r.total_hours || 0).toFixed(2)} h · ${Number(r.equivalent_days || 0).toFixed(2)} días</small></td>
        <td class="qr-duration"><b>${duration(r.longest_seconds)}</b><small>${Number(r.longest_hours || 0).toFixed(2)} h</small></td>
        <td><span class="qr-state ${stateClass}">${esc(r.closing_state || '—')}</span></td>
      </tr>`;
    }).join('');
  }

  function csvCell(v) {
    return `"${String(v ?? '').replaceAll('"', '""')}"`;
  }

  function exportCsv() {
    if (!reportData) return;
    const period = $('#qrPeriod')?.value || '';
    const s = reportData.summary || {};
    const rows = [
      ['INFORME DE QUIEBRE ACUMULADO', period],
      ['Clientes con quiebre', s.clients_with_quiebre],
      ['Horas acumuladas', s.total_hours],
      ['Clientes >=24h', s.over_24h],
      ['Clientes >=48h', s.over_48h],
      ['Clientes >=72h', s.over_72h],
      ['En quiebre al cierre', s.in_quiebre_at_close],
      ['Cobertura desde', localDate(reportData.coverage_from)],
      ['Cobertura hasta', localDate(reportData.coverage_to)],
      [],
      ['Nivel','ID','Telefono','Comercio','Zona','Ruta','Circuito','Saldo cierre','Entradas a quiebre','Venia en quiebre','Recuperaciones','Horas acumuladas','Dias equivalentes','Mayor quiebre h','Primer quiebre del periodo','Ultimo quiebre del periodo','Ultima recuperacion','Estado al cierre','Saldo actual'],
      ...currentRows.map(r => [
        r.level, r.id_client, r.phone, r.commerce, r.zone, r.route, r.circuit,
        r.closing_balance, r.quiebre_entries, r.came_in_quiebre ? 'SI' : 'NO', r.recoveries,
        r.total_hours, r.equivalent_days, r.longest_hours,
        localDate(r.first_quiebre_at), localDate(r.last_quiebre_at), localDate(r.last_recovery_at),
        r.closing_state, r.current_balance
      ])
    ];
    const csv = rows.map(r => r.map(csvCell).join(';')).join('\r\n');
    const blob = new Blob(['\ufeff' + csv], {type:'text/csv;charset=utf-8'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `Informe_Quiebre_${period || 'mensual'}.csv`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function init() {
    injectStyles();
    injectView();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
