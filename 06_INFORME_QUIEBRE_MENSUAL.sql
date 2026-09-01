-- ============================================================
-- MONITOR DE SALDOS
-- 06 - INFORME DE QUIEBRE ACUMULADO POR MES
--
-- REGLA DE NEGOCIO:
-- QUIEBRE = saldo <= $4.99
--
-- Calcula el tiempo acumulado que cada cliente permanece con
-- saldo entre $0.00 y $4.99, usando balance_events.
--
-- Si el cliente ya venia con <= $4.99 desde el mes anterior,
-- solo se contabiliza la parte correspondiente al mes solicitado.
-- Un quiebre termina cuando el saldo vuelve a ser >= $5.00.
-- ============================================================

begin;

create index if not exists idx_balance_events_client_captured_at
    on public.balance_events (id_client, captured_at);

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

    -- Mes interpretado en hora local de El Salvador.
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
            d.phone,
            d.commerce,
            d.zone,
            d.route,
            d.circuit,
            d.current_balance,
            d.status as current_status,
            d.first_seen,
            d.last_seen,
            least(v_end, d.last_seen) as observed_until
        from public.v_client_dashboard d
        where d.first_seen < v_end
          and d.last_seen >= v_start
          and (
                v_query is null
                or d.id_client ilike '%' || v_query || '%'
                or coalesce(d.phone, '') ilike '%' || v_query || '%'
                or coalesce(d.commerce, '') ilike '%' || v_query || '%'
                or coalesce(d.zone, '') ilike '%' || v_query || '%'
                or coalesce(d.route, '') ilike '%' || v_query || '%'
                or coalesce(d.circuit, '') ilike '%' || v_query || '%'
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
        -- Si ya existia un estado antes de iniciar el mes,
        -- lo anclamos exactamente al primer segundo del mes.
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
            b.phone,
            b.commerce,
            b.zone,
            b.route,
            b.circuit,

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
                 where closing_balance <= v_quiebre_limit)
        ),

        'rows',
            coalesce(
                (
                    select jsonb_agg(
                        to_jsonb(x)
                        order by x.total_seconds desc, x.id_client
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

revoke all
on function public.web_quiebre_monthly(integer, integer, text)
from public;

revoke all
on function public.web_quiebre_monthly(integer, integer, text)
from anon;

grant execute
on function public.web_quiebre_monthly(integer, integer, text)
to authenticated;

alter function public.web_quiebre_monthly(integer, integer, text)
set statement_timeout = '30s';

commit;
