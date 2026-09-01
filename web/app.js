(()=> {
let CFG={};
async function loadConfig(){
  const r=await fetch('./config.json?v=24',{cache:'no-store'});
  if(!r.ok) throw new Error(`No se pudo leer config.json (HTTP ${r.status}).`);
  const d=await r.json();
  CFG={
    SUPABASE_URL:String(d.supabase_url||'').trim(),
    SUPABASE_PUBLISHABLE_KEY:String(d.supabase_publishable_key||'').trim()
  };
  return CFG;
}
const $=s=>document.querySelector(s), $$=s=>Array.from(document.querySelectorAll(s));
let session=null, activeView='overview', searchTimer=null, summaryData=null;
let currentClient=null,currentChart=[],currentDaily=[],currentThresholds={};

const fmtNum=n=>new Intl.NumberFormat('es-SV').format(Number(n||0));
const fmtMoney=n=>new Intl.NumberFormat('es-SV',{style:'currency',currency:'USD',minimumFractionDigits:2}).format(Number(n||0));
const fmtPct=n=>`${Number(n||0).toFixed(1)}%`;
const esc=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
function isoLocal(v,dateOnly=false){if(!v)return'—';const d=new Date(v);if(Number.isNaN(d.getTime()))return'—';return new Intl.DateTimeFormat('es-SV',{timeZone:'America/El_Salvador',day:'2-digit',month:'2-digit',year:'numeric',...(dateOnly?{}:{hour:'2-digit',minute:'2-digit'})}).format(d)}
function toast(msg,ms=3200){const t=$('#toast');t.textContent=msg;t.classList.remove('hidden');clearTimeout(t._tm);t._tm=setTimeout(()=>t.classList.add('hidden'),ms)}
function saveSession(s){session=s;localStorage.setItem('monitor_saldos_session',JSON.stringify(s))}
function clearSession(){session=null;localStorage.removeItem('monitor_saldos_session')}
function loadSession(){try{return JSON.parse(localStorage.getItem('monitor_saldos_session')||'null')}catch{return null}}
function configReady(){
  const url = String(CFG.SUPABASE_URL || '').trim();
  const key = String(CFG.SUPABASE_PUBLISHABLE_KEY || '').trim();
  return url.startsWith('https://') && url.includes('.supabase.co') && key.length >= 20;
}
async function login(email,password){const r=await fetch(`${CFG.SUPABASE_URL}/auth/v1/token?grant_type=password`,{method:'POST',headers:{apikey:CFG.SUPABASE_PUBLISHABLE_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,password})});const d=await r.json().catch(()=>({}));if(!r.ok)throw new Error(d.error_description||d.msg||'No se pudo iniciar sesión.');saveSession(d);return d}
async function refreshSession(){if(!session?.refresh_token)throw new Error('Sin sesión');const r=await fetch(`${CFG.SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`,{method:'POST',headers:{apikey:CFG.SUPABASE_PUBLISHABLE_KEY,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});const d=await r.json().catch(()=>({}));if(!r.ok){clearSession();throw new Error('La sesión expiró.')}saveSession(d);return d}
async function rpc(fn,payload={},retry=true){const r=await fetch(`${CFG.SUPABASE_URL}/rest/v1/rpc/${fn}`,{method:'POST',headers:{apikey:CFG.SUPABASE_PUBLISHABLE_KEY,Authorization:`Bearer ${session?.access_token||''}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(payload)});if(r.status===401&&retry&&session?.refresh_token){await refreshSession();return rpc(fn,payload,false)}const d=await r.json().catch(()=>({}));if(!r.ok){if(r.status===401||String(d.code||'')==='28000'){clearSession();showAuth()}throw new Error(d.message||d.msg||`HTTP ${r.status}`)}return d}
function showAuth(){$('#authScreen').classList.remove('hidden');$('#appShell').classList.add('hidden')}
function showApp(){$('#authScreen').classList.add('hidden');$('#appShell').classList.remove('hidden')}
function priority(r){const risk=Number(r.risk_score||0);if(r.status==='ATENCION URGENTE'||risk>=70)return['URGENTE','URGENTE'];if(risk>=50)return['ALTA','ALTA'];if(risk>=30)return['MEDIA','MEDIA'];if(r.status==='BAJA')return['BAJA','BAJA'];if(r.status==='POR CONFIRMAR')return['PENDIENTE','PENDIENTE'];return['SEGUIMIENTO','SEGUIMIENTO']}
function diagnosis(r){if(r.status==='BAJA')return`${fmtNum(r.total_snapshots)} de ${fmtNum(r.total_snapshots)} tomas en $0.00. Nunca registró saldo positivo.`;if(r.status==='ATENCION URGENTE')return`Tuvo actividad y actualmente está en ${fmtMoney(r.current_balance)}. ${fmtNum(r.quiebre_entries)} quiebre(s).`;if(r.status==='REACTIVADO')return`Fue baja y volvió a registrar saldo positivo.`;if(r.status==='SIN MOVIMIENTO')return`Tiene saldo positivo, pero no registra cambios en el histórico.`;if(Number(r.quiebre_entries)>=2)return`Reincidente: ${fmtNum(r.quiebre_entries)} entradas a quiebre y ${fmtNum(r.recoveries)} recuperación(es).`;if(r.last_movement_type==='DROP'||r.last_movement_type==='QUIEBRE')return`Último movimiento fue una caída. Riesgo ${Number(r.risk_score||0).toFixed(0)}.`;if(r.last_movement_type==='RECHARGE'||r.last_movement_type==='RECOVERY')return`Último movimiento fue una recarga/recuperación.`;return`${fmtNum(r.changes_count)} cambios de saldo durante el histórico.`}
function classCode(status){if(status==='BAJA')return'BAJA';if(status==='SIN MOVIMIENTO')return'SIN_MOVIMIENTO';if(status==='POR CONFIRMAR')return'POR_CONFIRMAR';return'ATENCION'}
function eventLabel(t){return({INITIAL:'INICIAL',DROP:'CAÍDA',RECHARGE:'RECARGA',QUIEBRE:'ENTRÓ A $0',RECOVERY:'RECUPERACIÓN'})[t]||t||'—'}
function eventClass(t){if(['DROP','QUIEBRE'].includes(t))return'event-bad';if(['RECHARGE','RECOVERY'].includes(t))return'event-good';return'event-neutral'}

function switchView(v){activeView=v;$$('.nav-item').forEach(b=>b.classList.toggle('active',b.dataset.view===v));$$('.view').forEach(x=>x.classList.toggle('active',x.id===`view-${v}`));$('#pageTitle').textContent={overview:'Resumen',attention:'Atención',bajas:'Bajas',explorer:'Explorador',settings:'Configuración'}[v]||'Resumen';if(v==='overview')loadOverview().catch(e=>toast(e.message,7000));if(v==='attention')loadAttention().catch(e=>toast(e.message,7000));if(v==='bajas')loadBajas().catch(e=>toast(e.message,7000));if(v==='explorer')loadExplorer().catch(e=>toast(e.message,7000));if(v==='settings')hydrateSettings()}
async function refreshSummary(){summaryData=await rpc('web_summary_deep');const s=summaryData,u=s.uploader||null;$('#sideDot').className='dot ok';$('#sideStatus').textContent='Supabase conectado';$('#sideLast').textContent=s.last_seen?`Datos ${isoLocal(s.last_seen)}`:'Sin histórico';$('#headerStatus').textContent='Base central actualizada';$('#headerMeta').textContent=s.last_seen?`Última toma ${isoLocal(s.last_seen)}`:'Sin histórico';$('#periodText').textContent=s.first_seen?`Histórico disponible del ${isoLocal(s.first_seen,true)} al ${isoLocal(s.last_seen,true)}.`:'Todavía no hay histórico cargado.';$('#snapshotCount').textContent=fmtNum(s.snapshot_count);$('#clientsCount').textContent=fmtNum(s.total_clients);$('#obsText').textContent=`${fmtNum(s.observations)} observaciones procesadas`;$('#attentionCount').textContent=fmtNum(s.movement_clients);$('#bajasCount').textContent=fmtNum(s.bajas);$('#urgentCount').textContent=fmtNum(s.urgent);$('#quiebreCount').textContent=fmtNum(s.zero_moving);$('#pendingCount').textContent=fmtNum(s.pending);$('#zeroMovingCount').textContent=fmtNum(s.zero_moving);$('#recurrentCount').textContent=fmtNum(s.recurrent);$('#recoveredCount').textContent=fmtNum(s.recovered);$('#fallingCount').textContent=fmtNum(s.falling);$('#rechargingCount').textContent=fmtNum(s.recharging);$('#noMovementCount').textContent=fmtNum(s.no_movement);hydrateSettings();return s}
async function rowsDeep(mode,query='',status='',condition='',sort='priority_score',limit=100,offset=0){return rpc('web_clients_deep',{p_mode:mode,p_query:query||null,p_status:status||null,p_condition:condition||null,p_sort:sort,p_limit:limit,p_offset:offset})}
function historyButton(r){return`<button class="history-btn" data-id="${esc(r.id_client)}">Ver historial</button>`}
function bindHistory(host){host.querySelectorAll('.history-btn').forEach(b=>b.onclick=()=>openClient(b.dataset.id).catch(e=>toast(e.message,7000)))}

function renderOverviewAttention(rows){const body=$('#overviewAttentionRows');body.innerHTML=rows.map(r=>{const[p,pc]=priority(r);return`<tr><td><span class="priority ${pc}">${p}</span></td><td><b>${esc(r.id_client)}</b></td><td>${esc(r.phone||'—')}</td><td>${esc((r.commerce||'—').slice(0,32))}</td><td class="num">${fmtMoney(r.current_balance)}</td><td class="num">${fmtNum(r.changes_count)}</td><td class="num">${fmtNum(r.quiebre_entries)}</td><td class="diagnosis-cell">${esc(diagnosis(r))}</td><td>${historyButton(r)}</td></tr>`}).join('');$('#overviewAttentionEmpty').classList.toggle('hidden',rows.length>0);bindHistory(body)}
function renderOverviewBajas(rows){const body=$('#overviewBajasRows');body.innerHTML=rows.map(r=>`<tr><td><b>${esc(r.id_client)}</b></td><td>${esc(r.phone||'—')}</td><td>${esc((r.commerce||'—').slice(0,32))}</td><td class="num">${fmtNum(r.total_snapshots)}</td><td>${isoLocal(r.first_seen,true)}</td><td>${isoLocal(r.last_seen,true)}</td><td class="diagnosis-cell">Siempre $0.00 · ${fmtNum(r.zero_snapshots)} de ${fmtNum(r.total_snapshots)} tomas</td><td>${historyButton(r)}</td></tr>`).join('');$('#overviewBajasEmpty').classList.toggle('hidden',rows.length>0);bindHistory(body)}
async function loadOverview(){await refreshSummary();const[a,b]=await Promise.all([rowsDeep('ATTENTION','','','','priority_score',12),rowsDeep('BAJAS','','','','observations',10)]);renderOverviewAttention(a.rows||[]);renderOverviewBajas(b.rows||[])}

function renderAttention(rows){const body=$('#attentionRows');body.innerHTML=rows.map(r=>{const[p,pc]=priority(r),mov=Number(r.total_consumption||0)+Number(r.total_recharges||0);return`<tr><td><span class="priority ${pc}">${p}</span></td><td><b>${esc(r.id_client)}</b></td><td>${esc(r.phone||'—')}</td><td>${esc((r.commerce||'—').slice(0,34))}</td><td class="num">${fmtMoney(r.current_balance)}</td><td class="num">${fmtNum(r.changes_count)}</td><td class="num">${fmtMoney(mov)}</td><td class="num">${fmtNum(r.quiebre_entries)}</td><td>${r.last_movement_at?`${eventLabel(r.last_movement_type)} · ${isoLocal(r.last_movement_at)}`:'—'}</td><td class="diagnosis-cell">${esc(diagnosis(r))}</td><td>${historyButton(r)}</td></tr>`}).join('');$('#attentionEmpty').classList.toggle('hidden',rows.length>0);bindHistory(body)}
async function loadAttention(){const d=await rowsDeep('ATTENTION',$('#attentionSearch').value.trim(),'',$('#attentionCondition').value,$('#attentionSort').value,3000);$('#attentionResultCount').textContent=`${fmtNum(d.total)} resultado(s)`;renderAttention(d.rows||[])}

function renderBajas(rows){const body=$('#bajasRows');body.innerHTML=rows.map(r=>`<tr><td><b>${esc(r.id_client)}</b></td><td>${esc(r.phone||'—')}</td><td>${esc((r.commerce||'—').slice(0,34))}</td><td class="num">${fmtNum(r.zero_snapshots)}</td><td class="num">${fmtMoney(r.max_balance)}</td><td>${isoLocal(r.first_seen,true)}</td><td>${isoLocal(r.last_seen,true)}</td><td class="diagnosis-cell">${esc(diagnosis(r))}</td><td>${historyButton(r)}</td></tr>`).join('');$('#bajasEmpty').classList.toggle('hidden',rows.length>0);bindHistory(body)}
async function loadBajas(){const d=await rowsDeep('BAJAS',$('#bajasSearch').value.trim(),'','',$('#bajasSort').value,3000);$('#bajasResultCount').textContent=`${fmtNum(d.total)} baja(s)`;renderBajas(d.rows||[])}

function renderExplorer(rows){const body=$('#explorerRows');body.innerHTML=rows.map(r=>`<tr><td><span class="badge ${classCode(r.status)}">${esc(r.status)}</span></td><td><b>${esc(r.id_client)}</b></td><td>${esc(r.phone||'—')}</td><td>${esc((r.commerce||'—').slice(0,34))}</td><td class="num">${fmtMoney(r.current_balance)}</td><td class="num">${fmtNum(r.total_snapshots)}</td><td class="num">${fmtNum(r.changes_count)}</td><td class="num">${fmtPct(r.zero_percentage)}</td><td class="diagnosis-cell">${esc(diagnosis(r))}</td><td>${historyButton(r)}</td></tr>`).join('');$('#explorerEmpty').classList.toggle('hidden',rows.length>0);bindHistory(body)}
async function loadExplorer(){const d=await rowsDeep('ALL',$('#explorerSearch').value.trim(),$('#classFilter').value,'',$('#explorerSort').value,3000);$('#explorerResultCount').textContent=`${fmtNum(d.total)} resultado(s)`;renderExplorer(d.rows||[])}

function hydrateSettings(){if(!summaryData)return;const s=summaryData,u=s.uploader||{},cfg=s.settings||{};$('#cfgSource').innerHTML=`${esc(u.source_folder||'No reportada')}<small>La carpeta se procesa únicamente desde el agente Windows.</small>`;$('#cfgLastUpload').innerHTML=`${u.last_upload_at?isoLocal(u.last_upload_at):'—'}<small>${esc(u.last_file_name||'Sin archivo reciente')}</small>`;$('#cfgAgent').innerHTML=`${esc(u.machine_name||'—')}<small>Agente ${esc(u.agent_version||'—')} · ${fmtNum(u.files_sent||0)} archivos enviados</small>`;$('#cfgRules').innerHTML=`Bajo ≤ ${fmtMoney(cfg.low_balance)} · Crítico ≤ ${fmtMoney(cfg.critical_balance)} · Caída fuerte ≥ ${fmtMoney(cfg.strong_drop)}<small>BAJA confirmada con ${fmtNum(cfg.min_snapshots_baja)} tomas mínimas siempre en $0.00.</small>`;$('#cfgUser').textContent=session?.user?.email||'—'}

async function openClient(id){const d=await rpc('web_client_detail',{p_id_client:id}),s=d.profile;currentClient=s;currentThresholds=d.settings||{};currentDaily=d.daily||[];currentChart=(d.events||[]).map(e=>({ts:e.captured_at,balance:Number(e.balance||0),delta:e.delta,event_type:e.event_type,previous_balance:e.previous_balance}));if(currentChart.length<2&&s.first_seen&&s.last_seen){currentChart=[{ts:s.first_seen,balance:Number(s.current_balance||0),delta:null,event_type:'INITIAL'},{ts:s.last_seen,balance:Number(s.current_balance||0),delta:0,event_type:'INITIAL'}]}$('#detailClass').textContent=s.status;$('#detailClass').className=`badge ${classCode(s.status)}`;$('#detailName').textContent=s.commerce||`ID ${s.id_client}`;const[p]=priority(s);$('#detailMeta').textContent=`ID ${s.id_client} · Tel. ${s.phone||'—'} · ${fmtNum(s.total_snapshots)} tomas · ${p}`;const bullets=[];if(s.status==='BAJA')bullets.push(`${fmtNum(s.zero_snapshots)} de ${fmtNum(s.total_snapshots)} tomas estuvieron exactamente en $0.00.`);if(Number(s.quiebre_entries)>0)bullets.push(`${fmtNum(s.quiebre_entries)} entrada(s) a quiebre y ${fmtNum(s.recoveries)} recuperación(es).`);if(Number(s.strong_drops)>0)bullets.push(`${fmtNum(s.strong_drops)} caída(s) fuerte(s) detectada(s).`);if(s.last_movement_at)bullets.push(`Último movimiento: ${eventLabel(s.last_movement_type)} el ${isoLocal(s.last_movement_at)}.`);$('#detailDiagnosis').innerHTML=`<p><b>${esc(diagnosis(s))}</b></p>${bullets.map(x=>`<p>• ${esc(x)}</p>`).join('')}`;const stats=[['Saldo actual',fmtMoney(s.current_balance)],['Saldo máximo',fmtMoney(s.max_balance)],['Saldo mínimo',fmtMoney(s.min_balance)],['Saldo promedio',fmtMoney(s.average_balance)],['Cambios de saldo',fmtNum(s.changes_count)],['Movimiento total',fmtMoney(Number(s.total_consumption||0)+Number(s.total_recharges||0))],['Entradas a quiebre',fmtNum(s.quiebre_entries)],['Recuperaciones',fmtNum(s.recoveries)],['Tomas en $0',`${fmtNum(s.zero_snapshots)} · ${fmtPct(s.zero_percentage)}`],['Caídas fuertes',fmtNum(s.strong_drops)],['Consumo acumulado',fmtMoney(s.total_consumption)],['Recargas acumuladas',fmtMoney(s.total_recharges)]];$('#detailStats').innerHTML=stats.map(([k,v])=>`<div><b>${v}</b><span>${k}</span></div>`).join('');$('#chartRange').textContent=`${isoLocal(s.first_seen)} — ${isoLocal(s.last_seen)}`;$$('.range').forEach(b=>b.classList.toggle('active',b.dataset.range==='all'));drawChart(currentChart,currentThresholds);renderDaily(currentDaily);renderEvents(d.events||[]);$('#exportBtn').onclick=()=>exportCsv(s,d.events||[],currentDaily);$('#drawerOverlay').classList.remove('hidden');$('#drawer').classList.remove('hidden')}
function closeClient(){$('#drawerOverlay').classList.add('hidden');$('#drawer').classList.add('hidden')}
function renderDaily(rows){$('#dailyRows').innerHTML=rows.slice().reverse().map(d=>`<tr><td>${esc(String(d.day))}</td><td class="num">${fmtMoney(d.opening_balance)}</td><td class="num">${fmtMoney(d.min_balance)}</td><td class="num">${fmtMoney(d.max_balance)}</td><td class="num">${fmtMoney(d.closing_balance)}</td><td class="num">${fmtNum(d.changes_count)}</td><td class="num">${fmtMoney(d.consumption)}</td><td class="num">${fmtMoney(d.recharges)}</td></tr>`).join('')}
function renderEvents(rows){$('#eventsCount').textContent=`${fmtNum(rows.length)} movimiento(s) registrado(s)`;$('#eventRows').innerHTML=rows.slice().reverse().map(e=>`<tr><td>${isoLocal(e.captured_at)}</td><td class="num">${fmtMoney(e.balance)}</td><td class="num">${e.delta==null?'—':`${Number(e.delta)>0?'+':''}${fmtMoney(e.delta)}`}</td><td class="${eventClass(e.event_type)}">${esc(eventLabel(e.event_type))}</td></tr>`).join('')}
function filterRange(points,range){if(range==='all'||!points.length)return points;const last=new Date(points[points.length-1].ts);const ms={ '24h':86400000,'7d':7*86400000,'30d':30*86400000}[range]||Infinity;return points.filter(p=>last-new Date(p.ts)<=ms)}
function drawChart(points,thr){const host=$('#chart');if(!points.length){host.innerHTML='<div class="empty">Sin datos.</div>';return}const W=920,H=295,L=58,R=18,T=18,B=34,vals=points.map(p=>Number(p.balance)),max=Math.max(...vals,Number(thr.low_balance||0),Number(thr.critical_balance||0)),min=Math.min(...vals,0),pad=Math.max(1,(max-min)*.08),yMin=Math.max(0,min-pad),yMax=max+pad,x=i=>L+(points.length===1?(W-L-R)/2:i*(W-L-R)/(points.length-1)),y=v=>T+(yMax-v)*(H-T-B)/Math.max(.001,yMax-yMin);let grid='';for(let i=0;i<=4;i++){const v=yMin+(yMax-yMin)*i/4,yy=y(v);grid+=`<line x1="${L}" y1="${yy}" x2="${W-R}" y2="${yy}" stroke="#e3e9ee"/><text x="${L-7}" y="${yy+4}" text-anchor="end" font-size="9" fill="#667788">$${v.toFixed(1)}</text>`}const thresholds=[['low_balance',thr.low_balance,'#c48b19'],['critical_balance',thr.critical_balance,'#b42318']].filter(x=>Number.isFinite(Number(x[1]))).map(([n,v,c])=>`<line x1="${L}" y1="${y(Number(v))}" x2="${W-R}" y2="${y(Number(v))}" stroke="${c}" stroke-dasharray="5 4"/><text x="${W-R-4}" y="${y(Number(v))-4}" text-anchor="end" font-size="8" fill="${c}">${n==='low_balance'?'Saldo bajo':'Crítico'} $${Number(v).toFixed(2)}</text>`).join('');const poly=points.map((p,i)=>`${x(i).toFixed(1)},${y(Number(p.balance)).toFixed(1)}`).join(' '),start=isoLocal(points[0].ts),end=isoLocal(points[points.length-1].ts);host.innerHTML=`<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">${grid}${thresholds}<polyline points="${poly}" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke"/><text x="${L}" y="${H-8}" font-size="8" fill="#6b7885">${esc(start)}</text><text x="${W-R}" y="${H-8}" text-anchor="end" font-size="8" fill="#6b7885">${esc(end)}</text></svg>`}
function exportCsv(s,events,daily){const rows=[['ID','Telefono','Comercio','Estado'],[s.id_client,s.phone||'',s.commerce||'',s.status],[],['MOVIMIENTOS'],['FechaHora','Saldo','SaldoAnterior','Variacion','Evento'],...events.map(e=>[isoLocal(e.captured_at),e.balance,e.previous_balance??'',e.delta??'',eventLabel(e.event_type)]),[],['RESUMEN DIARIO'],['Fecha','Inicio','Minimo','Maximo','Cierre','Cambios','Consumo','Recargas'],...daily.map(d=>[d.day,d.opening_balance,d.min_balance,d.max_balance,d.closing_balance,d.changes_count,d.consumption,d.recharges])];const csv=rows.map(r=>r.map(v=>`"${String(v??'').replaceAll('"','""')}"`).join(',')).join('\r\n');const blob=new Blob(['\ufeff'+csv],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`historial_${s.id_client}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}

$('#loginForm').onsubmit=async e=>{
  e.preventDefault();
  $('#loginError').textContent='';
  $('#loginBtn').disabled=true;
  try{
    if(!configReady()) throw new Error('La página no pudo leer Project URL o Publishable Key desde config.js.');
    await login($('#loginEmail').value.trim(),$('#loginPassword').value);
    showApp();
    await loadOverview();
  }catch(err){
    $('#loginError').textContent=err?.message || 'No se pudo iniciar sesión.';
  }finally{
    $('#loginBtn').disabled=false;
  }
}
$('#logoutBtn').onclick=()=>{clearSession();showAuth()}
$$('.nav-item').forEach(b=>b.onclick=()=>switchView(b.dataset.view));
$$('[data-goto]').forEach(b=>b.onclick=()=>switchView(b.dataset.goto));
$('#scanBtn').onclick=async()=>{try{await refreshSummary();if(activeView==='overview')await loadOverview();else if(activeView==='attention')await loadAttention();else if(activeView==='bajas')await loadBajas();else if(activeView==='explorer')await loadExplorer();toast('Vista actualizada desde Supabase.')}catch(e){toast(e.message,7000)}};
$('#closeDetailBtn').onclick=closeClient;$('#drawerOverlay').onclick=closeClient;document.addEventListener('keydown',e=>{if(e.key==='Escape')closeClient()});
$$('.range').forEach(b=>b.onclick=()=>{$$('.range').forEach(x=>x.classList.remove('active'));b.classList.add('active');drawChart(filterRange(currentChart,b.dataset.range),currentThresholds)});
[['attentionSearch',loadAttention],['bajasSearch',loadBajas],['explorerSearch',loadExplorer]].forEach(([id,fn])=>$('#'+id).addEventListener('input',()=>{clearTimeout(searchTimer);searchTimer=setTimeout(()=>fn().catch(e=>toast(e.message,7000)),280)}));
['attentionCondition','attentionSort'].forEach(id=>$('#'+id).onchange=()=>loadAttention().catch(e=>toast(e.message,7000)));
$('#bajasSort').onchange=()=>loadBajas().catch(e=>toast(e.message,7000));
['classFilter','explorerSort'].forEach(id=>$('#'+id).onchange=()=>loadExplorer().catch(e=>toast(e.message,7000)));

(async()=>{
  try{
    await loadConfig();
  }catch(err){
    showAuth();
    $('#loginError').textContent=err?.message||'No se pudo leer config.json.';
    return;
  }

  if(!configReady()){
    showAuth();
    $('#loginError').textContent='config.json existe, pero Project URL o Publishable Key no son válidos.';
    return;
  }

  session=loadSession();
  if(!session){
    showAuth();
    $('#loginError').textContent='';
    return;
  }

  try{
    await refreshSession();
    showApp();
    await loadOverview();
  }catch(err){
    showAuth();
    $('#loginError').textContent=err?.message||'';
  }
})();
})();
