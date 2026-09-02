-- ============================================================
-- MONITOR DE SALDOS
-- 07 - MAESTRO EPIN / DMS + RUTAS / CIRCUITOS + INFORME QUIEBRE
--
-- REGLA DE QUIEBRE:
--   saldo <= $4.99  -> EN QUIEBRE
--   saldo >= $5.00  -> FUERA DE QUIEBRE
--
-- Este script:
-- 1) crea tablas maestras privadas para relacionar EPIN -> DMS
-- 2) crea tabla Circuito -> Ruta -> Territorio
-- 3) crea RPC seguras para importar ambas bases desde la web
-- 4) reemplaza web_quiebre_monthly para incluir ID DMS,
--    Territorio, Ruta y Circuito
-- 5) mantiene el histórico actual sin borrarlo
-- ============================================================

begin;

create index if not exists idx_balance_events_client_captured_at
    on public.balance_events (id_client, captured_at);

-- ------------------------------------------------------------
-- MAESTRO: EPIN -> DMS / CLIENTE / CIRCUITO
-- ------------------------------------------------------------
create table if not exists public.monitor_client_master (
    epin_phone text primary key,
    id_dms text not null,
    point_name text,
    owner_name text,
    circuit text,
    department text,
    city text,
    dms_status text,
    source_updated_at text,
    import_id uuid not null,
    imported_at timestamptz not null default now()
);

create index if not exists idx_monitor_client_master_id_dms
    on public.monitor_client_master (id_dms);

create index if not exists idx_monitor_client_master_circuit
    on public.monitor_client_master (circuit);

-- ------------------------------------------------------------
-- MAESTRO: CIRCUITO -> RUTA -> TERRITORIO
-- ------------------------------------------------------------
create table if not exists public.monitor_circuit_master (
    circuit text primary key,
    id_route text,
    route text,
    territory text,
    status text,
    monday boolean,
    tuesday boolean,
    wednesday boolean,
    thursday boolean,
    friday boolean,
    saturday boolean,
    sunday boolean,
    import_id uuid not null,
    imported_at timestamptz not null default now()
);

create index if not exists idx_monitor_circuit_master_route
    on public.monitor_circuit_master (route);

create index if not exists idx_monitor_circuit_master_territory
    on public.monitor_circuit_master (territory);

-- Datos maestros no se exponen por REST directo.
alter table public.monitor_client_master enable row level security;
alter table public.monitor_circuit_master enable row level security;

revoke all on table public.monitor_client_master from anon, authenticated;
revoke all on table public.monitor_circuit_master from anon, authenticated;

-- ------------------------------------------------------------
-- IMPORTAR CLIENTES EN LOTES
-- ------------------------------------------------------------
create or replace function public.web_master_upsert_clients(
    p_import_id uuid,
    p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_count integer := 0;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    if p_import_id is null then
        raise exception 'IMPORT_ID_REQUERIDO';
    end if;

    insert into public.monitor_client_master (
        epin_phone,
        id_dms,
        point_name,
        owner_name,
        circuit,
        department,
        city,
        dms_status,
        source_updated_at,
        import_id,
        imported_at
    )
    select
        regexp_replace(coalesce(x.epin_phone, ''), '[^0-9]', '', 'g') as epin_phone,
        nullif(btrim(x.id_dms), '') as id_dms,
        nullif(btrim(x.point_name), '') as point_name,
        nullif(btrim(x.owner_name), '') as owner_name,
        upper(nullif(btrim(x.circuit), '')) as circuit,
        nullif(btrim(x.department), '') as department,
        nullif(btrim(x.city), '') as city,
        nullif(btrim(x.dms_status), '') as dms_status,
        nullif(btrim(x.source_updated_at), '') as source_updated_at,
        p_import_id,
        now()
    from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb)) as x(
        epin_phone text,
        id_dms text,
        point_name text,
        owner_name text,
        circuit text,
        department text,
        city text,
        dms_status text,
        source_updated_at text
    )
    where regexp_replace(coalesce(x.epin_phone, ''), '[^0-9]', '', 'g') <> ''
      and nullif(btrim(x.id_dms), '') is not null
    on conflict (epin_phone) do update
    set
        id_dms = excluded.id_dms,
        point_name = excluded.point_name,
        owner_name = excluded.owner_name,
        circuit = excluded.circuit,
        department = excluded.department,
        city = excluded.city,
        dms_status = excluded.dms_status,
        source_updated_at = excluded.source_updated_at,
        import_id = excluded.import_id,
        imported_at = now();

    get diagnostics v_count = row_count;

    return jsonb_build_object(
        'ok', true,
        'processed', v_count
    );
end;
$$;

-- ------------------------------------------------------------
-- IMPORTAR CIRCUITOS EN LOTES
-- ------------------------------------------------------------
create or replace function public.web_master_upsert_circuits(
    p_import_id uuid,
    p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_count integer := 0;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    if p_import_id is null then
        raise exception 'IMPORT_ID_REQUERIDO';
    end if;

    insert into public.monitor_circuit_master (
        circuit,
        id_route,
        route,
        territory,
        status,
        monday,
        tuesday,
        wednesday,
        thursday,
        friday,
        saturday,
        sunday,
        import_id,
        imported_at
    )
    select
        upper(nullif(btrim(x.circuit), '')) as circuit,
        nullif(btrim(x.id_route), '') as id_route,
        nullif(btrim(x.route), '') as route,
        nullif(btrim(x.territory), '') as territory,
        nullif(btrim(x.status), '') as status,
        coalesce(nullif(btrim(x.lunes), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.martes), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.miercoles), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.jueves), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.viernes), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.sabado), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        coalesce(nullif(btrim(x.domingo), ''), '0') in ('1','true','TRUE','SI','SÍ','si','sí'),
        p_import_id,
        now()
    from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb)) as x(
        circuit text,
        id_route text,
        route text,
        territory text,
        status text,
        lunes text,
        martes text,
        miercoles text,
        jueves text,
        viernes text,
        sabado text,
        domingo text
    )
    where nullif(btrim(x.circuit), '') is not null
    on conflict (circuit) do update
    set
        id_route = excluded.id_route,
        route = excluded.route,
        territory = excluded.territory,
        status = excluded.status,
        monday = excluded.monday,
        tuesday = excluded.tuesday,
        wednesday = excluded.wednesday,
        thursday = excluded.thursday,
        friday = excluded.friday,
        saturday = excluded.saturday,
        sunday = excluded.sunday,
        import_id = excluded.import_id,
        imported_at = now();

    get diagnostics v_count = row_count;

    return jsonb_build_object(
        'ok', true,
        'processed', v_count
    );
end;
$$;

-- ------------------------------------------------------------
-- FINALIZAR IMPORTACIÓN
-- Borra únicamente registros viejos que no pertenecen al último
-- archivo completo que terminó de subirse correctamente.
-- ------------------------------------------------------------
create or replace function public.web_master_finalize_import(
    p_kind text,
    p_import_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_removed integer := 0;
    v_total integer := 0;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    if p_import_id is null then
        raise exception 'IMPORT_ID_REQUERIDO';
    end if;

    if lower(coalesce(p_kind, '')) = 'clients' then
        if not exists (
            select 1
            from public.monitor_client_master
            where import_id = p_import_id
        ) then
            raise exception 'IMPORTACION_CLIENTES_VACIA';
        end if;

        delete from public.monitor_client_master
        where import_id <> p_import_id;

        get diagnostics v_removed = row_count;

        select count(*) into v_total
        from public.monitor_client_master;

    elsif lower(coalesce(p_kind, '')) = 'circuits' then
        if not exists (
            select 1
            from public.monitor_circuit_master
            where import_id = p_import_id
        ) then
            raise exception 'IMPORTACION_CIRCUITOS_VACIA';
        end if;

        delete from public.monitor_circuit_master
        where import_id <> p_import_id;

        get diagnostics v_removed = row_count;

        select count(*) into v_total
        from public.monitor_circuit_master;

    else
        raise exception 'TIPO_IMPORTACION_INVALIDO';
    end if;

    return jsonb_build_object(
        'ok', true,
        'kind', lower(p_kind),
        'removed_old', v_removed,
        'total_active', v_total
    );
end;
$$;

-- ------------------------------------------------------------
-- ESTADO DE DATOS MAESTROS
-- ------------------------------------------------------------
create or replace function public.web_master_status()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    return jsonb_build_object(
        'clients',
            (select count(*) from public.monitor_client_master),
        'circuits',
            (select count(*) from public.monitor_circuit_master),
        'client_updated_at',
            (select max(imported_at) from public.monitor_client_master),
        'circuit_updated_at',
            (select max(imported_at) from public.monitor_circuit_master)
    );
end;
$$;

-- ------------------------------------------------------------
-- INFORME DE QUIEBRE MENSUAL
-- Incluye maestro EPIN -> DMS -> Circuito -> Ruta -> Territorio
-- ------------------------------------------------------------
create or replace function public.web_quiebre_monthly(
    p_year integer,
    p_month integer,
    p_query text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_start timestamptz;
    v_end timestamptz;
    v_query text := nullif(btrim(coalesce(p_query, '')), '');
    v_result jsonb;
    v_data_from timestamptz;
    v_data_to timestamptz;
    v_quiebre_limit numeric(14,2) := 4.99;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    if p_year is null or p_year < 2020 or p_year > 2100 then
        raise exception 'ANIO_INVALIDO';
    end if;

    if p_month is null or p_month < 1 or p_month > 12 then
        raise exception 'MES_INVALIDO';
    end if;

    v_start := make_timestamptz(
        p_year, p_month, 1, 0, 0, 0, 'America/El_Salvador'
    );
    v_end := v_start + interval '1 month';

    select min(first_seen), max(last_seen)
    into v_data_from, v_data_to
    from public.v_client_dashboard;

    with
    base as (
        select
            d.id_client,
            cm.id_dms,
            d.phone,
            coalesce(
                nullif(cm.point_name, ''),
                nullif(d.commerce, ''),
                'SIN NOMBRE'
            ) as commerce,
            cm.owner_name,
            coalesce(
                nullif(cr.territory, ''),
                nullif(d.zone, ''),
                nullif(cm.department, '')
            ) as territory,
            coalesce(
                nullif(cr.route, ''),
                nullif(d.route, '')
            ) as route,
            coalesce(
                nullif(cm.circuit, ''),
                nullif(d.circuit, '')
            ) as circuit,
            cr.id_route,
            cm.department,
            cm.city,
            cm.dms_status,
            (cm.epin_phone is not null) as mapped,
            (cr.circuit is not null and nullif(cr.route, '') is not null) as route_mapped,
            d.current_balance,
            d.status as current_status,
            d.first_seen,
            d.last_seen,
            least(v_end, d.last_seen) as observed_until
        from public.v_client_dashboard d
        left join public.monitor_client_master cm
          on cm.epin_phone = regexp_replace(
                coalesce(d.phone, ''),
                '[^0-9]',
                '',
                'g'
             )
        left join public.monitor_circuit_master cr
          on cr.circuit = upper(
                coalesce(
                    nullif(cm.circuit, ''),
                    nullif(d.circuit, '')
                )
             )
        where d.first_seen < v_end
          and d.last_seen >= v_start
          and (
                v_query is null
                or d.id_client ilike '%' || v_query || '%'
                or coalesce(cm.id_dms, '') ilike '%' || v_query || '%'
                or coalesce(d.phone, '') ilike '%' || v_query || '%'
                or coalesce(cm.point_name, d.commerce, '') ilike '%' || v_query || '%'
                or coalesce(cm.owner_name, '') ilike '%' || v_query || '%'
                or coalesce(cr.territory, d.zone, cm.department, '') ilike '%' || v_query || '%'
                or coalesce(cr.route, d.route, '') ilike '%' || v_query || '%'
                or coalesce(cm.circuit, d.circuit, '') ilike '%' || v_query || '%'
          )
    ),

    prior_state as (
        select
            b.id_client,
            e.captured_at as source_at,
            e.balance as source_balance
        from base b
        left join lateral (
            select
                be.captured_at,
                be.balance
            from public.balance_events be
            where be.id_client = b.id_client
              and be.captured_at < v_start
            order by be.captured_at desc
            limit 1
        ) e on true
    ),

    timeline as (
        select
            b.id_client,
            v_start as captured_at,
            p.source_balance as balance,
            'ANCHOR'::text as source_type,
            b.observed_until
        from base b
        join prior_state p
          on p.id_client = b.id_client
        where p.source_balance is not null
          and b.observed_until > v_start

        union all

        select
            be.id_client,
            be.captured_at,
            be.balance,
            coalesce(be.event_type, 'EVENT')::text as source_type,
            b.observed_until
        from public.balance_events be
        join base b
          on b.id_client = be.id_client
        where be.captured_at >= v_start
          and be.captured_at < v_end
          and be.captured_at <= b.observed_until
    ),

    ordered as (
        select
            t.*,
            lag(t.balance) over (
                partition by t.id_client
                order by
                    t.captured_at,
                    case when t.source_type = 'ANCHOR' then 0 else 1 end
            ) as prev_balance,

            lead(t.captured_at, 1, t.observed_until) over (
                partition by t.id_client
                order by
                    t.captured_at,
                    case when t.source_type = 'ANCHOR' then 0 else 1 end
            ) as next_at
        from timeline t
    ),

    marked as (
        select
            o.*,
            case
                when o.balance <= v_quiebre_limit
                 and (
                        o.prev_balance is null
                        or o.prev_balance > v_quiebre_limit
                     )
                then 1
                else 0
            end as starts_episode
        from ordered o
    ),

    grouped as (
        select
            m.*,
            sum(m.starts_episode) over (
                partition by m.id_client
                order by
                    m.captured_at,
                    case when m.source_type = 'ANCHOR' then 0 else 1 end
                rows between unbounded preceding and current row
            ) as episode_id
        from marked m
    ),

    low_segments as (
        select
            g.id_client,
            g.episode_id,
            g.captured_at as started_at,
            least(g.next_at, g.observed_until, v_end) as ended_at,
            extract(
                epoch from (
                    least(g.next_at, g.observed_until, v_end)
                    - g.captured_at
                )
            )::numeric as seconds_in_quiebre,
            g.source_type
        from grouped g
        where g.balance <= v_quiebre_limit
          and least(g.next_at, g.observed_until, v_end) > g.captured_at
    ),

    episodes as (
        select
            l.id_client,
            l.episode_id,
            min(l.started_at) as started_at,
            max(l.ended_at) as ended_at,
            sum(l.seconds_in_quiebre)::numeric as episode_seconds,
            bool_or(l.source_type = 'ANCHOR') as came_in_quiebre
        from low_segments l
        group by l.id_client, l.episode_id
    ),

    agg as (
        select
            e.id_client,
            count(*) filter (
                where not e.came_in_quiebre
            )::integer as quiebre_entries,
            bool_or(e.came_in_quiebre) as came_in_quiebre,
            sum(e.episode_seconds)::numeric as total_seconds,
            max(e.episode_seconds)::numeric as longest_seconds,
            min(e.started_at) as first_quiebre_at,
            max(e.started_at) as last_quiebre_at
        from episodes e
        group by e.id_client
    ),

    transitions as (
        select
            o.id_client,
            count(*) filter (
                where o.prev_balance <= v_quiebre_limit
                  and o.balance > v_quiebre_limit
                  and o.source_type <> 'ANCHOR'
            )::integer as recoveries,
            max(o.captured_at) filter (
                where o.prev_balance <= v_quiebre_limit
                  and o.balance > v_quiebre_limit
                  and o.source_type <> 'ANCHOR'
            ) as last_recovery_at
        from ordered o
        group by o.id_client
    ),

    period_close as (
        select
            b.id_client,
            e.balance as closing_balance,
            b.observed_until as closing_observed_at
        from base b
        left join lateral (
            select
                be.balance,
                be.captured_at
            from public.balance_events be
            where be.id_client = b.id_client
              and be.captured_at <= b.observed_until
              and be.captured_at < v_end
            order by be.captured_at desc
            limit 1
        ) e on true
    ),

    report as (
        select
            b.id_client,
            b.id_dms,
            b.phone,
            b.commerce,
            b.owner_name,
            b.territory,
            b.route,
            b.circuit,
            b.id_route,
            b.department,
            b.city,
            b.dms_status,
            b.mapped,
            b.route_mapped,

            pc.closing_balance,
            pc.closing_observed_at,

            b.current_balance,
            b.current_status,

            a.quiebre_entries,
            coalesce(t.recoveries, 0) as recoveries,
            a.came_in_quiebre,

            a.total_seconds,
            round((a.total_seconds / 3600.0)::numeric, 2) as total_hours,
            round((a.total_seconds / 86400.0)::numeric, 2) as equivalent_days,

            a.longest_seconds,
            round((a.longest_seconds / 3600.0)::numeric, 2) as longest_hours,

            a.first_quiebre_at,
            a.last_quiebre_at,
            t.last_recovery_at,

            case
                when a.total_seconds >= 72 * 3600 then 'CRITICO'
                when a.total_seconds >= 48 * 3600 then 'ALTO'
                when a.total_seconds >= 24 * 3600 then 'MEDIO'
                else 'BAJO'
            end as level,

            case
                when pc.closing_balance is null then 'SIN DATO'
                when pc.closing_balance <= v_quiebre_limit then 'EN QUIEBRE'
                else 'FUERA DE QUIEBRE'
            end as closing_state

        from base b
        join agg a
          on a.id_client = b.id_client
        left join transitions t
          on t.id_client = b.id_client
        left join period_close pc
          on pc.id_client = b.id_client
        where a.total_seconds > 0
    )

    select jsonb_build_object(
        'year', p_year,
        'month', p_month,
        'quiebre_limit', v_quiebre_limit,
        'period_start', v_start,
        'period_end', v_end,
        'coverage_from', v_data_from,
        'coverage_to', v_data_to,

        'complete_period',
            coalesce(
                v_data_from <= v_start
                and v_data_to >= v_end,
                false
            ),

        'summary', jsonb_build_object(
            'clients_with_quiebre',
                (select count(*) from report),

            'mapped_clients',
                (select count(*) from report where mapped),

            'unmapped_clients',
                (select count(*) from report where not mapped),

            'route_mapped_clients',
                (select count(*) from report where route_mapped),

            'route_unmapped_clients',
                (select count(*) from report where not route_mapped),

            'total_seconds',
                coalesce(
                    (select sum(total_seconds) from report),
                    0
                ),

            'total_hours',
                round(
                    (
                        coalesce(
                            (select sum(total_seconds) from report),
                            0
                        ) / 3600.0
                    )::numeric,
                    2
                ),

            'over_24h',
                (select count(*) from report
                 where total_seconds >= 24 * 3600),

            'over_48h',
                (select count(*) from report
                 where total_seconds >= 48 * 3600),

            'over_72h',
                (select count(*) from report
                 where total_seconds >= 72 * 3600),

            'in_quiebre_at_close',
                (select count(*) from report
                 where closing_balance is not null
                   and closing_balance <= v_quiebre_limit)
        ),

        'rows',
            coalesce(
                (
                    select jsonb_agg(
                        to_jsonb(x)
                        order by x.total_seconds desc, x.id_dms nulls last, x.id_client
                    )
                    from report x
                ),
                '[]'::jsonb
            )
    )
    into v_result;

    return v_result;
end;
$$;

-- ------------------------------------------------------------
-- PERMISOS RPC
-- ------------------------------------------------------------
revoke all on function public.web_master_upsert_clients(uuid, jsonb) from public, anon;
revoke all on function public.web_master_upsert_circuits(uuid, jsonb) from public, anon;
revoke all on function public.web_master_finalize_import(text, uuid) from public, anon;
revoke all on function public.web_master_status() from public, anon;
revoke all on function public.web_quiebre_monthly(integer, integer, text) from public, anon;

grant execute on function public.web_master_upsert_clients(uuid, jsonb) to authenticated;
grant execute on function public.web_master_upsert_circuits(uuid, jsonb) to authenticated;
grant execute on function public.web_master_finalize_import(text, uuid) to authenticated;
grant execute on function public.web_master_status() to authenticated;
grant execute on function public.web_quiebre_monthly(integer, integer, text) to authenticated;

alter function public.web_master_upsert_clients(uuid, jsonb)
set statement_timeout = '30s';

alter function public.web_master_upsert_circuits(uuid, jsonb)
set statement_timeout = '30s';

alter function public.web_master_finalize_import(text, uuid)
set statement_timeout = '30s';

alter function public.web_master_status()
set statement_timeout = '15s';

alter function public.web_quiebre_monthly(integer, integer, text)
set statement_timeout = '45s';

commit;
