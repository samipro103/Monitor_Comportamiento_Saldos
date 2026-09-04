-- ============================================================
-- MONITOR DE SALDOS
-- 09 - INFORME DE VENTAS POR CIRCUITO
--
-- Solo DMS con Estado DMS = VENDE.
-- Venta observada = suma de client_daily_stats.consumption,
-- es decir, disminuciones de balance observadas por el monitor.
--
-- Julio y Agosto: meses completos.
-- Septiembre: al último día disponible.
-- Septiembre se compara con los mismos días de Agosto.
--
-- No borra ni modifica histórico.
-- Requiere 07_MAESTROS_RUTAS_Y_QUIEBRE.sql.
-- ============================================================

begin;

create index if not exists idx_client_daily_stats_day_client
    on public.client_daily_stats (day, id_client);

create index if not exists idx_clients_phone
    on public.clients (phone);

create index if not exists idx_monitor_client_master_status
    on public.monitor_client_master (dms_status);

create or replace function public.web_sales_circuit_report(
    p_year integer default 2026,
    p_territory text default null,
    p_route text default null,
    p_circuit text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_territory text := nullif(btrim(coalesce(p_territory, '')), '');
    v_route text := nullif(btrim(coalesce(p_route, '')), '');
    v_circuit text := nullif(upper(btrim(coalesce(p_circuit, ''))), '');

    v_jul_start date;
    v_aug_start date;
    v_sep_start date;
    v_oct_start date;

    v_sep_data_through date;
    v_sep_days integer := 0;
    v_aug_compare_end date;

    v_result jsonb;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    if p_year is null or p_year < 2020 or p_year > 2100 then
        raise exception 'ANIO_INVALIDO';
    end if;

    v_jul_start := make_date(p_year, 7, 1);
    v_aug_start := make_date(p_year, 8, 1);
    v_sep_start := make_date(p_year, 9, 1);
    v_oct_start := make_date(p_year, 10, 1);

    -- Último día con datos de septiembre para clientes que hoy están VENDE.
    select max(ds.day)
    into v_sep_data_through
    from public.client_daily_stats ds
    join public.clients c
      on c.id_client = ds.id_client
    join public.monitor_client_master cm
      on cm.epin_phone = regexp_replace(
            coalesce(c.phone, ''),
            '[^0-9]',
            '',
            'g'
         )
    where ds.day >= v_sep_start
      and ds.day < v_oct_start
      and upper(btrim(coalesce(cm.dms_status, ''))) = 'VENDE';

    if v_sep_data_through is not null then
        v_sep_days := extract(day from v_sep_data_through)::integer;
    end if;

    -- Exclusivo: si hay datos hasta 04/Sep, usa 01/Ago <= día < 05/Ago.
    v_aug_compare_end := v_aug_start + v_sep_days;

    with
    eligible as (
        select distinct
            c.id_client,
            cm.id_dms,
            upper(nullif(btrim(cm.circuit), '')) as circuit,
            cr.id_route,
            nullif(btrim(cr.route), '') as route,
            nullif(btrim(cr.territory), '') as territory
        from public.clients c
        join public.monitor_client_master cm
          on cm.epin_phone = regexp_replace(
                coalesce(c.phone, ''),
                '[^0-9]',
                '',
                'g'
             )
        left join public.monitor_circuit_master cr
          on cr.circuit = upper(nullif(btrim(cm.circuit), ''))
        where upper(btrim(coalesce(cm.dms_status, ''))) = 'VENDE'
          and nullif(btrim(cm.circuit), '') is not null
          and (
                v_territory is null
                or nullif(btrim(cr.territory), '') = v_territory
          )
          and (
                v_route is null
                or nullif(btrim(cr.route), '') = v_route
          )
          and (
                v_circuit is null
                or upper(nullif(btrim(cm.circuit), '')) = v_circuit
          )
    ),

    circuit_base as (
        select
            territory,
            route,
            id_route,
            circuit,
            count(distinct id_dms)::integer as vende_clients,
            count(distinct id_client)::integer as epins
        from eligible
        group by territory, route, id_route, circuit
    ),

    sales as (
        select
            e.circuit,

            coalesce(sum(ds.consumption) filter (
                where ds.day >= v_jul_start
                  and ds.day < v_aug_start
            ), 0)::numeric as july_sales,

            coalesce(sum(ds.consumption) filter (
                where ds.day >= v_aug_start
                  and ds.day < v_sep_start
            ), 0)::numeric as august_sales,

            coalesce(sum(ds.consumption) filter (
                where ds.day >= v_sep_start
                  and ds.day < v_oct_start
            ), 0)::numeric as september_sales,

            coalesce(sum(ds.consumption) filter (
                where v_sep_days > 0
                  and ds.day >= v_aug_start
                  and ds.day < v_aug_compare_end
            ), 0)::numeric as august_same_days_sales

        from eligible e
        left join public.client_daily_stats ds
          on ds.id_client = e.id_client
         and ds.day >= v_jul_start
         and ds.day < v_oct_start
        group by e.circuit
    ),

    report as (
        select
            cb.territory,
            cb.route,
            cb.id_route,
            cb.circuit,
            cb.vende_clients,
            cb.epins,

            round(coalesce(s.july_sales, 0), 2) as july_sales,
            round(coalesce(s.august_sales, 0), 2) as august_sales,
            round(coalesce(s.september_sales, 0), 2) as september_sales,
            round(coalesce(s.august_same_days_sales, 0), 2) as august_same_days_sales,

            case
                when coalesce(s.july_sales, 0) > 0 then
                    round(
                        (
                            (coalesce(s.august_sales, 0) - s.july_sales)
                            / s.july_sales
                        ) * 100.0,
                        2
                    )
                else null
            end as aug_vs_jul_pct,

            case
                when v_sep_days > 0
                 and coalesce(s.august_same_days_sales, 0) > 0 then
                    round(
                        (
                            (
                                coalesce(s.september_sales, 0)
                                - s.august_same_days_sales
                            )
                            / s.august_same_days_sales
                        ) * 100.0,
                        2
                    )
                else null
            end as sep_vs_aug_same_pct,

            case
                when coalesce(s.july_sales, 0) = 0
                 and coalesce(s.august_sales, 0) > 0 then 'NUEVO'
                when coalesce(s.july_sales, 0) = 0
                 and coalesce(s.august_sales, 0) = 0 then 'SIN BASE'
                when (
                    (coalesce(s.august_sales, 0) - s.july_sales)
                    / nullif(s.july_sales, 0)
                ) * 100.0 > 5 then 'CRECE'
                when (
                    (coalesce(s.august_sales, 0) - s.july_sales)
                    / nullif(s.july_sales, 0)
                ) * 100.0 < -5 then 'CAE'
                else 'ESTABLE'
            end as aug_vs_jul_status,

            case
                when v_sep_days = 0 then 'SIN DATOS'
                when coalesce(s.august_same_days_sales, 0) = 0
                 and coalesce(s.september_sales, 0) > 0 then 'NUEVO'
                when coalesce(s.august_same_days_sales, 0) = 0
                 and coalesce(s.september_sales, 0) = 0 then 'SIN BASE'
                when (
                    (
                        coalesce(s.september_sales, 0)
                        - s.august_same_days_sales
                    )
                    / nullif(s.august_same_days_sales, 0)
                ) * 100.0 > 5 then 'CRECE'
                when (
                    (
                        coalesce(s.september_sales, 0)
                        - s.august_same_days_sales
                    )
                    / nullif(s.august_same_days_sales, 0)
                ) * 100.0 < -5 then 'CAE'
                else 'ESTABLE'
            end as sep_vs_aug_status

        from circuit_base cb
        left join sales s
          on s.circuit = cb.circuit
    )

    select jsonb_build_object(
        'year', p_year,
        'only_dms_status', 'VENDE',
        'sales_definition', 'SUMA DE DISMINUCIONES DE BALANCE OBSERVADAS',
        'september_data_through', v_sep_data_through,
        'september_days_observed', v_sep_days,

        'summary', (
            select jsonb_build_object(
                'circuits', count(*),
                'vende_clients', coalesce(sum(vende_clients), 0),

                'july_sales', round(coalesce(sum(july_sales), 0), 2),
                'august_sales', round(coalesce(sum(august_sales), 0), 2),
                'september_sales', round(coalesce(sum(september_sales), 0), 2),
                'august_same_days_sales',
                    round(coalesce(sum(august_same_days_sales), 0), 2),

                'aug_vs_jul_pct',
                    case
                        when coalesce(sum(july_sales), 0) > 0 then
                            round(
                                (
                                    (sum(august_sales) - sum(july_sales))
                                    / sum(july_sales)
                                ) * 100.0,
                                2
                            )
                        else null
                    end,

                'sep_vs_aug_same_pct',
                    case
                        when v_sep_days > 0
                         and coalesce(sum(august_same_days_sales), 0) > 0 then
                            round(
                                (
                                    (
                                        sum(september_sales)
                                        - sum(august_same_days_sales)
                                    )
                                    / sum(august_same_days_sales)
                                ) * 100.0,
                                2
                            )
                        else null
                    end,

                'growing_aug_vs_jul',
                    count(*) filter (where aug_vs_jul_pct > 5),

                'falling_aug_vs_jul',
                    count(*) filter (where aug_vs_jul_pct < -5),

                'stable_aug_vs_jul',
                    count(*) filter (
                        where aug_vs_jul_pct between -5 and 5
                    ),

                'growing_sep_vs_aug',
                    count(*) filter (where sep_vs_aug_same_pct > 5),

                'falling_sep_vs_aug',
                    count(*) filter (where sep_vs_aug_same_pct < -5),

                'stable_sep_vs_aug',
                    count(*) filter (
                        where sep_vs_aug_same_pct between -5 and 5
                    )
            )
            from report
        ),

        'filters', jsonb_build_object(
            'territories',
            coalesce((
                select jsonb_agg(x.territory order by x.territory)
                from (
                    select distinct
                        nullif(btrim(cr.territory), '') as territory
                    from public.monitor_client_master cm
                    left join public.monitor_circuit_master cr
                      on cr.circuit = upper(nullif(btrim(cm.circuit), ''))
                    where upper(btrim(coalesce(cm.dms_status, ''))) = 'VENDE'
                      and nullif(btrim(cr.territory), '') is not null
                ) x
            ), '[]'::jsonb),

            'routes',
            coalesce((
                select jsonb_agg(
                    jsonb_build_object(
                        'territory', x.territory,
                        'route', x.route
                    )
                    order by x.territory, x.route
                )
                from (
                    select distinct
                        nullif(btrim(cr.territory), '') as territory,
                        nullif(btrim(cr.route), '') as route
                    from public.monitor_client_master cm
                    left join public.monitor_circuit_master cr
                      on cr.circuit = upper(nullif(btrim(cm.circuit), ''))
                    where upper(btrim(coalesce(cm.dms_status, ''))) = 'VENDE'
                      and nullif(btrim(cr.route), '') is not null
                ) x
            ), '[]'::jsonb),

            'circuits',
            coalesce((
                select jsonb_agg(
                    jsonb_build_object(
                        'territory', x.territory,
                        'route', x.route,
                        'circuit', x.circuit
                    )
                    order by x.territory, x.route, x.circuit
                )
                from (
                    select distinct
                        nullif(btrim(cr.territory), '') as territory,
                        nullif(btrim(cr.route), '') as route,
                        upper(nullif(btrim(cm.circuit), '')) as circuit
                    from public.monitor_client_master cm
                    left join public.monitor_circuit_master cr
                      on cr.circuit = upper(nullif(btrim(cm.circuit), ''))
                    where upper(btrim(coalesce(cm.dms_status, ''))) = 'VENDE'
                      and nullif(btrim(cm.circuit), '') is not null
                ) x
            ), '[]'::jsonb)
        ),

        'rows',
        coalesce((
            select jsonb_agg(
                to_jsonb(r)
                order by
                    r.sep_vs_aug_same_pct asc nulls last,
                    r.aug_vs_jul_pct asc nulls last,
                    r.territory,
                    r.route,
                    r.circuit
            )
            from report r
        ), '[]'::jsonb)
    )
    into v_result;

    return v_result;
end;
$$;

revoke all on function public.web_sales_circuit_report(
    integer, text, text, text
) from public, anon;

grant execute on function public.web_sales_circuit_report(
    integer, text, text, text
) to authenticated;

alter function public.web_sales_circuit_report(
    integer, text, text, text
) set statement_timeout = '30s';

commit;
