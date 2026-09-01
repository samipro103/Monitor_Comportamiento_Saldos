-- ============================================================
-- MONITOR DE SALDOS
-- 06 - INFORME DE QUIEBRE ACUMULADO POR MES
--
-- Calcula tiempo observado con saldo $0.00 a partir de
-- balance_events. Solo considera quiebre real: transición
-- positiva -> $0.00 (evento QUIEBRE). Si el quiebre comenzó
-- el mes anterior, cuenta únicamente la parte que cae dentro
-- del mes solicitado.
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
    v_low numeric(14,2);
    v_critical numeric(14,2);
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

    -- El mes se interpreta en hora de El Salvador.
    v_start := make_timestamptz(p_year, p_month, 1, 0, 0, 0, 'America/El_Salvador');
    v_end := v_start + interval '1 month';

    select min(first_seen), max(last_seen)
    into v_data_from, v_data_to
    from public.v_client_dashboard;

    select low_balance, critical_balance
    into v_low, v_critical
    from public.app_settings
    where id = 1;

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
            d.positive_snapshots
        from public.v_client_dashboard d
        where d.positive_snapshots > 0
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
            e.balance as source_balance,
            e.event_type as source_event_type
        from base b
        left join lateral (
            select be.captured_at, be.balance, be.event_type
            from public.balance_events be
            where be.id_client = b.id_client
              and be.captured_at < v_start
            order by be.captured_at desc
            limit 1
        ) e on true
    ),
    timeline as (
        -- Ancla al inicio del mes para poder continuar un quiebre
        -- que comenzó en el mes anterior.
        select
            b.id_client,
            v_start as captured_at,
            p.source_balance as balance,
            case
                when p.source_balance = 0
                 and p.source_event_type = 'QUIEBRE'
                    then 'QUIEBRE_CARRY'
                else 'ANCHOR'
            end as event_type
        from base b
        join prior_state p on p.id_client = b.id_client
        where p.source_balance is not null

        union all

        select
            be.id_client,
            be.captured_at,
            be.balance,
            be.event_type
        from public.balance_events be
        join base b on b.id_client = be.id_client
        where be.captured_at >= v_start
          and be.captured_at < v_end
    ),
    sequenced as (
        select
            t.*,
            lead(t.captured_at, 1, v_end) over (
                partition by t.id_client
                order by t.captured_at,
                         case when t.event_type = 'ANCHOR' then 0 else 1 end
            ) as next_at
        from timeline t
    ),
    zero_intervals as (
        select
            s.id_client,
            greatest(s.captured_at, v_start) as started_at,
            least(s.next_at, v_end) as ended_at,
            extract(
                epoch from (
                    least(s.next_at, v_end)
                    - greatest(s.captured_at, v_start)
                )
            )::numeric as seconds_in_zero,
            s.event_type
        from sequenced s
        where s.balance = 0
          and s.event_type in ('QUIEBRE', 'QUIEBRE_CARRY')
          and least(s.next_at, v_end) > greatest(s.captured_at, v_start)
    ),
    agg as (
        select
            z.id_client,
            count(*) filter (where z.event_type = 'QUIEBRE')::integer as quiebre_entries,
            bool_or(z.event_type = 'QUIEBRE_CARRY') as came_in_quiebre,
            sum(z.seconds_in_zero)::numeric as total_seconds,
            max(z.seconds_in_zero)::numeric as longest_seconds,
            min(z.started_at) as first_quiebre_at,
            max(z.started_at) as last_quiebre_at
        from zero_intervals z
        group by z.id_client
    ),
    recoveries as (
        select
            be.id_client,
            count(*)::integer as recoveries,
            max(be.captured_at) as last_recovery_at
        from public.balance_events be
        join base b on b.id_client = be.id_client
        where be.event_type = 'RECOVERY'
          and be.captured_at >= v_start
          and be.captured_at < v_end
        group by be.id_client
    ),
    period_close as (
        select
            b.id_client,
            e.balance as closing_balance,
            e.captured_at as closing_observed_at
        from base b
        left join lateral (
            select be.balance, be.captured_at
            from public.balance_events be
            where be.id_client = b.id_client
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
            coalesce(r.recoveries, 0) as recoveries,
            a.came_in_quiebre,
            a.total_seconds,
            round((a.total_seconds / 3600.0)::numeric, 2) as total_hours,
            round((a.total_seconds / 86400.0)::numeric, 2) as equivalent_days,
            a.longest_seconds,
            round((a.longest_seconds / 3600.0)::numeric, 2) as longest_hours,
            a.first_quiebre_at,
            a.last_quiebre_at,
            r.last_recovery_at,
            case
                when a.total_seconds >= 72 * 3600 then 'CRITICO'
                when a.total_seconds >= 48 * 3600 then 'ALTO'
                when a.total_seconds >= 24 * 3600 then 'MEDIO'
                else 'BAJO'
            end as level,
            case
                when pc.closing_balance is null then 'SIN DATO'
                when pc.closing_balance = 0 then 'EN QUIEBRE'
                when pc.closing_balance <= coalesce(v_critical, 0) then 'SALDO CRITICO'
                when pc.closing_balance <= coalesce(v_low, 0) then 'SALDO BAJO'
                else 'CON SALDO'
            end as closing_state
        from base b
        join agg a on a.id_client = b.id_client
        left join recoveries r on r.id_client = b.id_client
        left join period_close pc on pc.id_client = b.id_client
        where a.total_seconds > 0
    )
    select jsonb_build_object(
        'year', p_year,
        'month', p_month,
        'period_start', v_start,
        'period_end', v_end,
        'coverage_from', v_data_from,
        'coverage_to', v_data_to,
        'complete_period', coalesce(v_data_from <= v_start and v_data_to >= v_end, false),
        'summary', jsonb_build_object(
            'clients_with_quiebre', (select count(*) from report),
            'total_seconds', coalesce((select sum(total_seconds) from report), 0),
            'total_hours', round((coalesce((select sum(total_seconds) from report), 0) / 3600.0)::numeric, 2),
            'over_24h', (select count(*) from report where total_seconds >= 24 * 3600),
            'over_48h', (select count(*) from report where total_seconds >= 48 * 3600),
            'over_72h', (select count(*) from report where total_seconds >= 72 * 3600),
            'in_quiebre_at_close', (select count(*) from report where closing_balance = 0)
        ),
        'rows', coalesce(
            (
                select jsonb_agg(to_jsonb(x) order by x.total_seconds desc, x.id_client)
                from report x
            ),
            '[]'::jsonb
        )
    )
    into v_result;

    return v_result;
end;
$$;

revoke all on function public.web_quiebre_monthly(integer, integer, text) from public;
revoke all on function public.web_quiebre_monthly(integer, integer, text) from anon;
grant execute on function public.web_quiebre_monthly(integer, integer, text) to authenticated;

alter function public.web_quiebre_monthly(integer, integer, text)
set statement_timeout = '30s';

commit;
