-- ============================================================
-- MONITOR DE SALDOS
-- 04 - API DE LECTURA SEGURA PARA LA WEB
-- ============================================================
-- OBJETIVO:
-- La web NO tendrá acceso directo a las tablas.
-- Solo usuarios autenticados podrán ejecutar estas funciones.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- RESUMEN GENERAL
-- ------------------------------------------------------------
create or replace function public.web_summary()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_result jsonb;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    select jsonb_build_object(
        'total_clients', count(*),

        'bajas', count(*) filter (where status = 'BAJA'),

        'attention_urgent',
            count(*) filter (where status = 'ATENCION URGENTE'),

        'attention',
            count(*) filter (where status = 'ATENCION'),

        'with_movement',
            count(*) filter (where status = 'CON MOVIMIENTO'),

        'reactivated',
            count(*) filter (where status = 'REACTIVADO'),

        'no_movement',
            count(*) filter (where status = 'SIN MOVIMIENTO'),

        'pending',
            count(*) filter (where status = 'POR CONFIRMAR'),

        'zero_now',
            count(*) filter (
                where current_balance = 0
                  and positive_snapshots > 0
            ),

        'low_now',
            count(*) filter (
                where current_balance > 0
                  and current_balance <= (
                      select low_balance
                      from public.app_settings
                      where id = 1
                  )
            ),

        'recurrent',
            count(*) filter (where quiebre_entries >= 2),

        'repeated_strong_drops',
            count(*) filter (where strong_drops >= 2),

        'avg_risk',
            coalesce(
                round(
                    avg(risk_score)
                    filter (where status <> 'BAJA'),
                    1
                ),
                0
            ),

        'first_seen',
            min(first_seen),

        'last_seen',
            max(last_seen),

        'total_snapshots',
            coalesce(sum(total_snapshots), 0),

        'settings',
            (
                select jsonb_build_object(
                    'low_balance', low_balance,
                    'critical_balance', critical_balance,
                    'strong_drop', strong_drop,
                    'min_snapshots_baja', min_snapshots_baja
                )
                from public.app_settings
                where id = 1
            ),

        'uploader',
            (
                select coalesce(
                    jsonb_agg(
                        jsonb_build_object(
                            'machine_name', machine_name,
                            'source_folder', source_folder,
                            'agent_version', agent_version,
                            'last_seen_at', last_seen_at,
                            'last_scan_at', last_scan_at,
                            'last_upload_at', last_upload_at,
                            'last_file_name', last_file_name,
                            'files_sent', files_sent,
                            'rows_sent', rows_sent,
                            'last_error', last_error
                        )
                        order by last_seen_at desc nulls last
                    ),
                    '[]'::jsonb
                )
                from public.uploader_status
            )
    )
    into v_result
    from public.v_client_dashboard;

    return v_result;
end;
$$;


-- ------------------------------------------------------------
-- LISTADO PAGINADO / FILTRADO
-- ------------------------------------------------------------
create or replace function public.web_clients(
    p_mode text default 'ALL',
    p_query text default null,
    p_status text default null,
    p_sort text default 'RISK',
    p_limit integer default 50,
    p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
    v_offset integer := greatest(0, coalesce(p_offset, 0));
    v_query text := nullif(btrim(coalesce(p_query, '')), '');
    v_mode text := upper(coalesce(p_mode, 'ALL'));
    v_sort text := upper(coalesce(p_sort, 'RISK'));
    v_total bigint;
    v_rows jsonb;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    with filtered as (
        select *
        from public.v_client_dashboard d
        where
            (
                v_mode = 'ALL'
                or (
                    v_mode = 'ATTENTION'
                    and d.status in (
                        'ATENCION URGENTE',
                        'ATENCION',
                        'CON MOVIMIENTO',
                        'REACTIVADO'
                    )
                    and (
                        d.changes_count > 0
                        or d.status in ('ATENCION URGENTE', 'REACTIVADO')
                    )
                )
                or (
                    v_mode = 'BAJAS'
                    and d.status = 'BAJA'
                )
            )
            and (
                p_status is null
                or btrim(p_status) = ''
                or upper(d.status) = upper(btrim(p_status))
            )
            and (
                v_query is null
                or d.id_client ilike '%' || v_query || '%'
                or coalesce(d.phone, '') ilike '%' || v_query || '%'
                or coalesce(d.commerce, '') ilike '%' || v_query || '%'
            )
    )
    select count(*)
    into v_total
    from filtered;

    with filtered as (
        select *
        from public.v_client_dashboard d
        where
            (
                v_mode = 'ALL'
                or (
                    v_mode = 'ATTENTION'
                    and d.status in (
                        'ATENCION URGENTE',
                        'ATENCION',
                        'CON MOVIMIENTO',
                        'REACTIVADO'
                    )
                    and (
                        d.changes_count > 0
                        or d.status in ('ATENCION URGENTE', 'REACTIVADO')
                    )
                )
                or (
                    v_mode = 'BAJAS'
                    and d.status = 'BAJA'
                )
            )
            and (
                p_status is null
                or btrim(p_status) = ''
                or upper(d.status) = upper(btrim(p_status))
            )
            and (
                v_query is null
                or d.id_client ilike '%' || v_query || '%'
                or coalesce(d.phone, '') ilike '%' || v_query || '%'
                or coalesce(d.commerce, '') ilike '%' || v_query || '%'
            )
    ),
    paged as (
        select *
        from filtered
        order by
            case when v_sort = 'RISK' then risk_score end desc nulls last,
            case when v_sort = 'QUIEBRES' then quiebre_entries end desc nulls last,
            case when v_sort = 'CHANGES' then changes_count end desc nulls last,
            case when v_sort = 'STRONG_DROPS' then strong_drops end desc nulls last,
            case when v_sort = 'BALANCE_ASC' then current_balance end asc nulls last,
            case when v_sort = 'BALANCE_DESC' then current_balance end desc nulls last,
            case when v_sort = 'LAST_MOVEMENT' then last_movement_at end desc nulls last,
            risk_score desc nulls last,
            id_client
        limit v_limit
        offset v_offset
    )
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id_client', id_client,
                'phone', phone,
                'commerce', commerce,
                'circuit', circuit,
                'route', route,
                'zone', zone,
                'current_balance', current_balance,
                'previous_balance', previous_balance,
                'min_balance', min_balance,
                'max_balance', max_balance,
                'average_balance', average_balance,
                'total_snapshots', total_snapshots,
                'zero_snapshots', zero_snapshots,
                'positive_snapshots', positive_snapshots,
                'zero_percentage', zero_percentage,
                'changes_count', changes_count,
                'quiebre_entries', quiebre_entries,
                'recoveries', recoveries,
                'strong_drops', strong_drops,
                'total_consumption', total_consumption,
                'total_recharges', total_recharges,
                'zero_streak_snapshots', zero_streak_snapshots,
                'zero_streak_since', zero_streak_since,
                'first_seen', first_seen,
                'last_seen', last_seen,
                'last_movement_at', last_movement_at,
                'last_movement_type', last_movement_type,
                'ever_confirmed_baja', ever_confirmed_baja,
                'reactivated_at', reactivated_at,
                'risk_score', risk_score,
                'status', status
            )
        ),
        '[]'::jsonb
    )
    into v_rows
    from paged;

    return jsonb_build_object(
        'total', v_total,
        'limit', v_limit,
        'offset', v_offset,
        'rows', v_rows
    );
end;
$$;


-- ------------------------------------------------------------
-- DETALLE PROFUNDO DE UN CLIENTE
-- ------------------------------------------------------------
create or replace function public.web_client_detail(
    p_id_client text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_profile jsonb;
    v_events jsonb;
    v_daily jsonb;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    select to_jsonb(d)
    into v_profile
    from public.v_client_dashboard d
    where d.id_client = p_id_client;

    if v_profile is null then
        raise exception 'CLIENTE_NO_ENCONTRADO';
    end if;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'captured_at', captured_at,
                'balance', balance,
                'previous_balance', previous_balance,
                'delta', delta,
                'event_type', event_type
            )
            order by captured_at
        ),
        '[]'::jsonb
    )
    into v_events
    from (
        select
            captured_at,
            balance,
            previous_balance,
            delta,
            event_type
        from public.balance_events
        where id_client = p_id_client
        order by captured_at desc
        limit 1500
    ) e;

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'day', day,
                'opening_balance', opening_balance,
                'closing_balance', closing_balance,
                'min_balance', min_balance,
                'max_balance', max_balance,
                'snapshots_count', snapshots_count,
                'zero_snapshots', zero_snapshots,
                'changes_count', changes_count,
                'consumption', consumption,
                'recharges', recharges,
                'quiebre_entries', quiebre_entries,
                'recoveries', recoveries,
                'first_capture_at', first_capture_at,
                'last_capture_at', last_capture_at
            )
            order by day
        ),
        '[]'::jsonb
    )
    into v_daily
    from (
        select *
        from public.client_daily_stats
        where id_client = p_id_client
        order by day desc
        limit 730
    ) d;

    return jsonb_build_object(
        'profile', v_profile,
        'events', v_events,
        'daily', v_daily
    );
end;
$$;


-- ------------------------------------------------------------
-- PERMISOS
-- SOLO USUARIOS CON LOGIN
-- ------------------------------------------------------------
revoke all on function public.web_summary() from public;
revoke all on function public.web_clients(text,text,text,text,integer,integer) from public;
revoke all on function public.web_client_detail(text) from public;

revoke all on function public.web_summary() from anon;
revoke all on function public.web_clients(text,text,text,text,integer,integer) from anon;
revoke all on function public.web_client_detail(text) from anon;

grant execute on function public.web_summary() to authenticated;
grant execute on function public.web_clients(text,text,text,text,integer,integer) to authenticated;
grant execute on function public.web_client_detail(text) to authenticated;

alter function public.web_summary()
set statement_timeout = '15s';

alter function public.web_clients(text,text,text,text,integer,integer)
set statement_timeout = '15s';

alter function public.web_client_detail(text)
set statement_timeout = '15s';

commit;
