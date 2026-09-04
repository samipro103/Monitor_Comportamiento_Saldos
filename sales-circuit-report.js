(() => {
  'use strict';

  const VIEW_ID = 'view-circuit-sales';
  const SESSION_KEY = 'monitor_saldos_session';

  let cfg = null;
  let rawData = null;
  let allRows = [];
  let masterFilters = null;

  const $ = s => document.querySelector(s);
  const $$ = s => Array.from(document.querySelectorAll(s));

  const esc = s => String(s ?? '').replace(/[&<>"']/g, m => ({
    '&':'&amp;',
    '<':'&lt;',
    '>':'&gt;',
    '"':'&quot;',
    "'":'&#39;'
  }[m]));

  const money = n => new Intl.NumberFormat('es-SV', {
    style:'currency',
    currency:'USD',
    minimumFractionDigits:2
  }).format(Number(n || 0));

  const num = n => new Intl.NumberFormat('es-SV').format(Number(n || 0));

  function pct(v) {
    if (v === null || v === undefined || Number.isNaN(Number(v))) return '—';
    const n = Number(v);
    return `${n > 0 ? '+' : ''}${n.toFixed(2)}%`;
  }

  function getSession() {
    try {
      return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null');
    } catch {
      return null;
    }
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

    if (!session?.refresh_token) throw new Error('La sesión expiró.');

    const r = await fetch(`${c.url}/auth/v1/token?grant_type=refresh_token`, {
      method:'POST',
      headers:{
        apikey:c.key,
        'Content-Type':'application/json'
      },
      body:JSON.stringify({refresh_token:session.refresh_token})
    });

    const d = await r.json().catch(() => ({}));

    if (!r.ok) throw new Error('La sesión expiró.');

    localStorage.setItem(SESSION_KEY, JSON.stringify(d));
    return d;
  }

  async function rpc(fn, payload = {}, retry = true) {
    const c = await getConfig();
    let session = getSession();

    if (!session?.access_token) throw new Error('Debes iniciar sesión.');

    const r = await fetch(`${c.url}/rest/v1/rpc/${fn}`, {
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
      return rpc(fn, payload, false);
    }

    const d = await r.json().catch(() => ({}));

    if (!r.ok) throw new Error(d.message || d.msg || `HTTP ${r.status}`);

    return d;
  }

  function injectStyles() {
    if ($('#salesCircuitStyles')) return;

    const style = document.createElement('style');
    style.id = 'salesCircuitStyles';
    style.textContent = `
      .sc-note{
        margin:0 0 18px;
        padding:10px 0 10px 14px;
        border-left:3px solid #7893a4;
        color:#5f707a;
        line-height:1.45
      }
      .sc-note b{color:#17384b}

      .sc-kpis{
        display:grid;
        grid-template-columns:repeat(4,minmax(0,1fr));
        border-top:1px solid #e1e7eb;
        border-bottom:1px solid #e1e7eb;
        margin:0 0 18px
      }
      .sc-kpi{
        padding:16px;
        border-right:1px solid #e1e7eb
      }
      .sc-kpi:last-child{border-right:0}
      .sc-kpi span{
        display:block;
        font-size:10px;
        font-weight:900;
        color:#71808c;
        text-transform:uppercase;
        letter-spacing:.04em
      }
      .sc-kpi b{
        display:block;
        font-size:23px;
        margin-top:5px;
        color:#102b3e
      }
      .sc-kpi small{
        display:block;
        color:#74828e;
        margin-top:3px
      }

      .sc-filters{
        display:grid;
        grid-template-columns:1fr 1fr 150px 150px 190px auto;
        gap:9px;
        align-items:end;
        margin:0 0 15px
      }
      .sc-field{
        display:flex;
        flex-direction:column;
        gap:5px;
        min-width:0
      }
      .sc-field label{
        font-size:10px;
        font-weight:900;
        color:#70818d;
        text-transform:uppercase
      }
      .sc-field select{
        width:100%;
        height:41px;
        border:1px solid #dce4ea;
        border-radius:8px;
        padding:0 10px;
        background:#fff;
        color:#172b3a;
        font:inherit
      }

      .sc-trend{
        display:inline-flex;
        padding:4px 7px;
        border-radius:999px;
        font-size:10px;
        font-weight:900;
        white-space:nowrap
      }
      .sc-grow{background:#e9f5ef;color:#1d704d}
      .sc-fall{background:#fde9e8;color:#a42e27}
      .sc-stable{background:#edf1f4;color:#5c6b75}
      .sc-new{background:#fff2d1;color:#866004}

      .sc-positive{color:#1d704d;font-weight:800}
      .sc-negative{color:#a42e27;font-weight:800}
      .sc-neutral{color:#5c6b75;font-weight:800}

      #view-circuit-sales .table-wrap{
        max-height:calc(100vh - 410px);
        min-height:300px
      }
      #view-circuit-sales th{
        position:sticky;
        top:0;
        z-index:2;
        background:#f7f9fa
      }

      .sc-mobile{display:none}

      @media(max-width:1100px){
        .sc-filters{grid-template-columns:repeat(3,minmax(0,1fr))}
        .sc-kpis{grid-template-columns:repeat(2,1fr)}
        .sc-kpi:nth-child(2){border-right:0}
      }

      @media(max-width:720px){
        .sc-filters{grid-template-columns:1fr 1fr}
        .sc-kpis{grid-template-columns:1fr 1fr}
        .sc-kpi{padding:12px 9px}
        .sc-kpi b{font-size:19px}
        .sc-desktop{display:none}
        .sc-mobile{display:block}
        .sc-mobile-row{
          padding:14px 2px;
          border-bottom:1px solid #e2e8ec
        }
        .sc-mobile-head{
          display:flex;
          justify-content:space-between;
          gap:10px
        }
        .sc-mobile-head b{color:#17384b}
        .sc-mobile-head small{
          display:block;
          margin-top:3px;
          color:#75848e
        }
        .sc-mobile-values{
          display:grid;
          grid-template-columns:1fr 1fr;
          gap:10px;
          margin-top:12px
        }
        .sc-mobile-values span{
          display:block;
          font-size:10px;
          font-weight:900;
          color:#73838e;
          text-transform:uppercase
        }
        .sc-mobile-values b{
          display:block;
          margin-top:2px
        }
      }
    `;

    document.head.appendChild(style);
  }

  function injectView() {
    if ($('#' + VIEW_ID)) return;

    const nav = $('.sidebar nav');
    const main = $('main');

    if (!nav || !main) return;

    const navBtn = document.createElement('button');
    navBtn.className = 'nav-item';
    navBtn.dataset.view = 'circuit-sales';
    navBtn.textContent = 'Ventas por circuito';

    const settingsBtn = nav.querySelector('[data-view="settings"]');
    nav.insertBefore(navBtn, settingsBtn || null);

    const section = document.createElement('section');
    section.id = VIEW_ID;
    section.className = 'view';

    section.innerHTML = `
      <div class="section-head">
        <div>
          <span class="eyebrow">VARIACIÓN MES A MES</span>
          <h2>Ventas por circuito</h2>
          <p>Solo clientes con Estado DMS = VENDE.</p>
        </div>
        <div id="scResultCount" class="count">0 circuitos</div>
      </div>

      <div class="sc-note">
        <b>Venta observada:</b> suma de disminuciones de balance detectadas por el monitor.
        Julio y agosto se comparan completos. Septiembre se compara contra los mismos días de agosto.
        <span id="scThrough"></span>
      </div>

      <div class="sc-kpis">
        <div class="sc-kpi">
          <span>Venta agosto</span>
          <b id="scAugust">$0.00</b>
          <small id="scAugustVar">vs julio</small>
        </div>

        <div class="sc-kpi">
          <span>Venta septiembre al día</span>
          <b id="scSeptember">$0.00</b>
          <small id="scSeptemberVar">vs agosto mismos días</small>
        </div>

        <div class="sc-kpi">
          <span>Circuitos cayendo</span>
          <b id="scFalling">0</b>
          <small>Variación menor a -5%</small>
        </div>

        <div class="sc-kpi">
          <span>Clientes VENDE</span>
          <b id="scClients">0</b>
          <small id="scCircuits">0 circuitos</small>
        </div>
      </div>

      <div class="sc-filters">
        <div class="sc-field">
          <label>Territorio</label>
          <select id="scTerritory"><option value="">Todos</option></select>
        </div>

        <div class="sc-field">
          <label>Ruta</label>
          <select id="scRoute"><option value="">Todas</option></select>
        </div>

        <div class="sc-field">
          <label>Circuito</label>
          <select id="scCircuit"><option value="">Todos</option></select>
        </div>

        <div class="sc-field">
          <label>Tendencia</label>
          <select id="scTrend">
            <option value="">Todas</option>
            <option value="CAE">Cae</option>
            <option value="ESTABLE">Estable</option>
            <option value="CRECE">Crece</option>
            <option value="NUEVO">Nuevo</option>
          </select>
        </div>

        <div class="sc-field">
          <label>Orden</label>
          <select id="scSort">
            <option value="current_drop">Mayor caída actual</option>
            <option value="aug_drop">Mayor caída Ago/Jul</option>
            <option value="sep_sales">Mayor venta Sep</option>
            <option value="aug_sales">Mayor venta Ago</option>
          </select>
        </div>

        <button id="scExport" class="btn secondary" type="button">CSV</button>
      </div>

      <div class="table-wrap tall sc-desktop">
        <table>
          <thead>
            <tr>
              <th>Territorio</th>
              <th>Ruta</th>
              <th>Circuito</th>
              <th class="num">Clientes VENDE</th>
              <th class="num">Julio</th>
              <th class="num">Agosto</th>
              <th class="num">Var. Ago/Jul</th>
              <th class="num">Septiembre</th>
              <th class="num">Ago. mismo período</th>
              <th class="num">Var. Sep/Ago</th>
              <th>Tendencia</th>
            </tr>
          </thead>
          <tbody id="scRows"></tbody>
        </table>
      </div>

      <div id="scMobile" class="sc-mobile"></div>
      <div id="scEmpty" class="empty hidden">No hay circuitos para los filtros seleccionados.</div>
    `;

    const settingsView = $('#view-settings');
    main.insertBefore(section, settingsView || null);

    navBtn.addEventListener('click', openView);

    $('#scTerritory').addEventListener('change', async () => {
      fillRoutes();
      fillCircuits();
      await loadReport();
    });

    $('#scRoute').addEventListener('change', async () => {
      fillCircuits();
      await loadReport();
    });

    $('#scCircuit').addEventListener('change', loadReport);
    $('#scTrend').addEventListener('change', render);
    $('#scSort').addEventListener('change', render);
    $('#scExport').addEventListener('click', exportCsv);
  }

  function openView() {
    $$('.nav-item').forEach(x => x.classList.remove('active'));
    $('.nav-item[data-view="circuit-sales"]')?.classList.add('active');

    $$('.view').forEach(x => x.classList.remove('active'));
    $('#' + VIEW_ID)?.classList.add('active');

    if ($('#pageTitle')) $('#pageTitle').textContent = 'Ventas por circuito';

    if (!rawData) loadReport().catch(showError);
  }

  function unique(values) {
    return [...new Set(values.filter(Boolean))]
      .sort((a,b) => String(a).localeCompare(String(b), 'es', {
        numeric:true,
        sensitivity:'base'
      }));
  }

  function setOptions(el, values, allText) {
    if (!el) return;

    const old = el.value;

    el.innerHTML =
      `<option value="">${esc(allText)}</option>` +
      values.map(v => `<option value="${esc(v)}">${esc(v)}</option>`).join('');

    if (values.includes(old)) el.value = old;
  }

  function fillMasterFilters() {
    if (!masterFilters) return;

    setOptions(
      $('#scTerritory'),
      unique((masterFilters.territories || []).map(String)),
      'Todos'
    );

    fillRoutes();
    fillCircuits();
  }

  function fillRoutes() {
    if (!masterFilters) return;

    const territory = $('#scTerritory')?.value || '';

    const routes = (masterFilters.routes || [])
      .filter(r => !territory || String(r.territory || '') === territory)
      .map(r => String(r.route || ''));

    setOptions($('#scRoute'), unique(routes), 'Todas');
  }

  function fillCircuits() {
    if (!masterFilters) return;

    const territory = $('#scTerritory')?.value || '';
    const route = $('#scRoute')?.value || '';

    const circuits = (masterFilters.circuits || [])
      .filter(r =>
        (!territory || String(r.territory || '') === territory) &&
        (!route || String(r.route || '') === route)
      )
      .map(r => String(r.circuit || ''));

    setOptions($('#scCircuit'), unique(circuits), 'Todos');
  }

  function trendClass(status) {
    if (status === 'CRECE') return 'sc-grow';
    if (status === 'CAE') return 'sc-fall';
    if (status === 'NUEVO') return 'sc-new';
    return 'sc-stable';
  }

  function variationClass(v) {
    if (v === null || v === undefined) return 'sc-neutral';

    const n = Number(v);

    if (n > 5) return 'sc-positive';
    if (n < -5) return 'sc-negative';

    return 'sc-neutral';
  }

  async function loadReport() {
    if ($('#scRows')) {
      $('#scRows').innerHTML = `
        <tr>
          <td colspan="11" style="padding:35px;text-align:center;color:#6d7d88">
            Calculando ventas por circuito…
          </td>
        </tr>
      `;
    }

    const data = await rpc('web_sales_circuit_report', {
      p_year:2026,
      p_territory:$('#scTerritory')?.value || null,
      p_route:$('#scRoute')?.value || null,
      p_circuit:$('#scCircuit')?.value || null
    });

    rawData = data;
    allRows = data.rows || [];

    if (!masterFilters) {
      masterFilters = data.filters || {};
      fillMasterFilters();
    }

    renderSummary();
    render();
  }

  function renderSummary() {
    const s = rawData?.summary || {};

    $('#scAugust').textContent = money(s.august_sales);
    $('#scAugustVar').textContent = `${pct(s.aug_vs_jul_pct)} vs julio`;

    $('#scSeptember').textContent = money(s.september_sales);
    $('#scSeptemberVar').textContent =
      `${pct(s.sep_vs_aug_same_pct)} vs agosto mismos días`;

    $('#scFalling').textContent = num(s.falling_sep_vs_aug || 0);
    $('#scClients').textContent = num(s.vende_clients || 0);
    $('#scCircuits').textContent = `${num(s.circuits || 0)} circuitos`;

    const through = rawData?.september_data_through;
    const days = Number(rawData?.september_days_observed || 0);

    $('#scThrough').textContent = through
      ? ` Septiembre disponible hasta ${through}; se compara contra los primeros ${days} día(s) de agosto.`
      : ' Todavía no hay datos de septiembre.';
  }

  function visibleRows() {
    let rows = [...allRows];

    const trend = $('#scTrend')?.value || '';

    if (trend) {
      rows = rows.filter(r => r.sep_vs_aug_status === trend);
    }

    const sort = $('#scSort')?.value || 'current_drop';

    rows.sort((a,b) => {
      if (sort === 'aug_drop') {
        return Number(a.aug_vs_jul_pct ?? 999999)
             - Number(b.aug_vs_jul_pct ?? 999999);
      }

      if (sort === 'sep_sales') {
        return Number(b.september_sales || 0)
             - Number(a.september_sales || 0);
      }

      if (sort === 'aug_sales') {
        return Number(b.august_sales || 0)
             - Number(a.august_sales || 0);
      }

      return Number(a.sep_vs_aug_same_pct ?? 999999)
           - Number(b.sep_vs_aug_same_pct ?? 999999);
    });

    return rows;
  }

  function render() {
    const rows = visibleRows();

    $('#scResultCount').textContent = `${num(rows.length)} circuito(s)`;
    $('#scEmpty').classList.toggle('hidden', rows.length > 0);

    $('#scRows').innerHTML = rows.map(r => `
      <tr>
        <td>${esc(r.territory || '—')}</td>
        <td>${esc(r.route || '—')}</td>
        <td><b>${esc(r.circuit || '—')}</b></td>
        <td class="num">${num(r.vende_clients)}</td>
        <td class="num">${money(r.july_sales)}</td>
        <td class="num">${money(r.august_sales)}</td>
        <td class="num ${variationClass(r.aug_vs_jul_pct)}">${pct(r.aug_vs_jul_pct)}</td>
        <td class="num"><b>${money(r.september_sales)}</b></td>
        <td class="num">${money(r.august_same_days_sales)}</td>
        <td class="num ${variationClass(r.sep_vs_aug_same_pct)}">${pct(r.sep_vs_aug_same_pct)}</td>
        <td>
          <span class="sc-trend ${trendClass(r.sep_vs_aug_status)}">
            ${esc(r.sep_vs_aug_status)}
          </span>
        </td>
      </tr>
    `).join('');

    $('#scMobile').innerHTML = rows.map(r => `
      <div class="sc-mobile-row">
        <div class="sc-mobile-head">
          <div>
            <b>${esc(r.circuit || '—')}</b>
            <small>${esc(r.territory || '—')} · ${esc(r.route || '—')}</small>
          </div>
          <span class="sc-trend ${trendClass(r.sep_vs_aug_status)}">
            ${esc(r.sep_vs_aug_status)}
          </span>
        </div>

        <div class="sc-mobile-values">
          <div>
            <span>Septiembre</span>
            <b>${money(r.september_sales)}</b>
          </div>
          <div>
            <span>Var. vs Ago</span>
            <b class="${variationClass(r.sep_vs_aug_same_pct)}">
              ${pct(r.sep_vs_aug_same_pct)}
            </b>
          </div>
          <div>
            <span>Agosto</span>
            <b>${money(r.august_sales)}</b>
          </div>
          <div>
            <span>Var. Ago/Jul</span>
            <b class="${variationClass(r.aug_vs_jul_pct)}">
              ${pct(r.aug_vs_jul_pct)}
            </b>
          </div>
        </div>
      </div>
    `).join('');
  }

  function csvCell(v) {
    return `"${String(v ?? '').replace(/"/g, '""')}"`;
  }

  function exportCsv() {
    const rows = visibleRows();

    const data = [[
      'Territorio',
      'Ruta',
      'ID Ruta',
      'Circuito',
      'Clientes VENDE',
      'EPIN',
      'Venta Julio',
      'Venta Agosto',
      'Variacion Ago vs Jul %',
      'Tendencia Ago vs Jul',
      'Venta Septiembre al dia',
      'Venta Agosto mismo periodo',
      'Variacion Sep vs Ago comparable %',
      'Tendencia Sep vs Ago'
    ]];

    rows.forEach(r => data.push([
      r.territory,
      r.route,
      r.id_route,
      r.circuit,
      r.vende_clients,
      r.epins,
      r.july_sales,
      r.august_sales,
      r.aug_vs_jul_pct,
      r.aug_vs_jul_status,
      r.september_sales,
      r.august_same_days_sales,
      r.sep_vs_aug_same_pct,
      r.sep_vs_aug_status
    ]));

    const csv =
      '\ufeff' +
      data.map(row => row.map(csvCell).join(';')).join('\r\n');

    const blob = new Blob([csv], {
      type:'text/csv;charset=utf-8'
    });

    const url = URL.createObjectURL(blob);

    const a = document.createElement('a');
    a.href = url;
    a.download = 'Ventas_por_Circuito_2026.csv';
    document.body.appendChild(a);
    a.click();
    a.remove();

    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function showError(err) {
    const msg = err?.message || String(err);

    if ($('#scRows')) {
      $('#scRows').innerHTML = `
        <tr>
          <td colspan="11" style="padding:20px;color:#9e2c25">
            <b>No se pudo cargar el informe.</b><br>${esc(msg)}
          </td>
        </tr>
      `;
    }
  }

  function init() {
    injectStyles();
    injectView();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
