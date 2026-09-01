-- ============================================================
-- MONITOR DE SALDOS
-- REINICIO LIMPIO DE LA PRIMERA CARGA
--
-- USAR SOLO DURANTE ESTA CARGA INICIAL.
-- NO BORRA:
--   - app_settings
--   - funciones
--   - vistas
--   - clave privada de ingesta
--   - estructura de la base
--
-- Sí borra únicamente los datos históricos parcialmente cargados.
-- ============================================================

begin;

truncate table
    public.balance_events,
    public.client_daily_stats,
    public.client_stats,
    public.import_batches,
    public.uploader_status,
    public.clients
restart identity cascade;

insert into private.ingest_state(id, latest_snapshot_at)
values (1, null)
on conflict (id)
do update set latest_snapshot_at = null;

commit;


-- COMPROBACIÓN
select
    (select count(*) from public.clients) as clientes,
    (select count(*) from public.import_batches) as archivos,
    (select count(*) from public.balance_events) as eventos,
    (select latest_snapshot_at
       from private.ingest_state
      where id = 1) as ultima_toma;
