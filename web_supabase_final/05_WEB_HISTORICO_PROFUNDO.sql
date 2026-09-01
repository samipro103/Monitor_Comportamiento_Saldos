-- ============================================================
-- MONITOR DE SALDOS
-- 05 - API WEB HISTÓRICO PROFUNDO (DISEÑO v1.4)
-- Ejecutar DESPUÉS de 04_WEB_READ_API.sql
-- ============================================================

begin;

create or replace function public.web_summary_deep()
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
        'observations', coalesce(sum(total_snapshots),0),
        'snapshot_count', coalesce(max(total_snapshots),0),
        'first_seen', min(first_seen),
        'last_seen', max(last_seen),

        'movement_clients', count(*) filter (
            where status <> 'BAJA'
              and (
                changes_count > 0
                or status in ('ATENCION URGENTE','ATENCION','REACTIVADO','CON MOVIMIENTO')
              )
        ),

        'bajas', count(*) filter (where status = 'BAJA'),
        'urgent', count(*) filter (where status = 'ATENCION URGENTE'),
        'pending', count(*) filter (where status = 'POR CONFIRMAR'),

        'zero_moving', count(*) filter (
            where current_balance = 0
              and positive_snapshots > 0
        ),

        'recurrent', count(*) filter (where quiebre_entries >= 2),
        'recovered', count(*) filter (where recoveries > 0),

        'falling', count(*) filter (
            where last_movement_type in ('DROP','QUIEBRE')
        ),

        'recharging', count(*) filter (
            where last_movement_type in ('RECHARGE','RECOVERY')
        ),

        'no_movement', count(*) filter (
            where status = 'SIN MOVIMIENTO'
        ),

        'settings', (
            select jsonb_build_object(
                'low_balance', low_balance,
                'critical_balance', critical_balance,
                'strong_drop', strong_drop,
                'min_snapshots_baja', min_snapshots_baja
            )
            from public.app_settings
            where id=1
        ),

        'uploader', (
            select to_jsonb(u)
            from public.uploader_status u
            order by last_seen_at desc nulls last
            limit 1
        )
    )
    into v_result
    from public.v_client_dashboard;

    return v_result;
end;
$$;


create or replace function public.web_clients_deep(
    p_mode text default 'ALL',
    p_query text default null,
    p_status text default null,
    p_condition text default null,
    p_sort text default 'priority_score',
    p_limit integer default 100,
    p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_mode text := upper(coalesce(p_mode,'ALL'));
    v_query text := nullif(btrim(coalesce(p_query,'')),'');
    v_status text := nullif(upper(btrim(coalesce(p_status,''))),'');
    v_condition text := lower(coalesce(p_condition,''));
    v_sort text := lower(coalesce(p_sort,'priority_score'));
    v_limit integer := greatest(1, least(coalesce(p_limit,100), 3000));
    v_offset integer := greatest(0, coalesce(p_offset,0));
    v_total bigint;
    v_rows jsonb;
begin
    if auth.uid() is null then
        raise exception 'NO_AUTORIZADO' using errcode = '28000';
    end if;

    with filtered as (
        select d.*
        from public.v_client_dashboard d
        where
            (
                v_mode='ALL'
                or (v_mode='BAJAS' and d.status='BAJA')
                or (
                    v_mode='ATTENTION'
                    and d.status <> 'BAJA'
                    and (
                        d.changes_count > 0
                        or d.status in ('ATENCION URGENTE','ATENCION','REACTIVADO','CON MOVIMIENTO')
                    )
                )
            )
            and (v_status is null or upper(d.status)=v_status)
            and (
                v_query is null
                or d.id_client ilike '%'||v_query||'%'
                or coalesce(d.phone,'') ilike '%'||v_query||'%'
                or coalesce(d.commerce,'') ilike '%'||v_query||'%'
            )
            and (
                v_condition=''
                or (v_condition='quiebre' and d.current_balance=0 and d.positive_snapshots>0)
                or (v_condition='reincidente' and d.quiebre_entries>=2)
                or (v_condition='cayendo' and d.last_movement_type in ('DROP','QUIEBRE'))
                or (v_condition='recargando' and d.last_movement_type in ('RECHARGE','RECOVERY'))
                or (v_condition='recuperado' and (d.recoveries>0 or d.status='REACTIVADO'))
            )
    )
    select count(*) into v_total from filtered;

    with filtered as (
        select d.*
        from public.v_client_dashboard d
        where
            (
                v_mode='ALL'
                or (v_mode='BAJAS' and d.status='BAJA')
                or (
                    v_mode='ATTENTION'
                    and d.status <> 'BAJA'
                    and (
                        d.changes_count > 0
                        or d.status in ('ATENCION URGENTE','ATENCION','REACTIVADO','CON MOVIMIENTO')
                    )
                )
            )
            and (v_status is null or upper(d.status)=v_status)
            and (
                v_query is null
                or d.id_client ilike '%'||v_query||'%'
                or coalesce(d.phone,'') ilike '%'||v_query||'%'
                or coalesce(d.commerce,'') ilike '%'||v_query||'%'
            )
            and (
                v_condition=''
                or (v_condition='quiebre' and d.current_balance=0 and d.positive_snapshots>0)
                or (v_condition='reincidente' and d.quiebre_entries>=2)
                or (v_condition='cayendo' and d.last_movement_type in ('DROP','QUIEBRE'))
                or (v_condition='recargando' and d.last_movement_type in ('RECHARGE','RECOVERY'))
                or (v_condition='recuperado' and (d.recoveries>0 or d.status='REACTIVADO'))
            )
    ),
    ordered as (
        select *
        from filtered
        order by
            case when v_sort='current_balance' then current_balance end asc nulls last,
            case when v_sort='stockout_events' then quiebre_entries end desc nulls last,
            case when v_sort='changes_count' then changes_count end desc nulls last,
            case when v_sort='total_movement' then (total_consumption+total_recharges) end desc nulls last,
            case when v_sort='last_movement_ts' then last_movement_at end desc nulls last,
            case when v_sort='observations' then total_snapshots end desc nulls last,
            case when v_sort='last_ts' then last_seen end desc nulls last,
            risk_score desc nulls last,
            id_client
        limit v_limit offset v_offset
    )
    select coalesce(jsonb_agg(to_jsonb(ordered)),'[]'::jsonb)
    into v_rows
    from ordered;

    return jsonb_build_object(
        'total',v_total,
        'rows',v_rows,
        'limit',v_limit,
        'offset',v_offset
    );
end;
$$;


-- Actualizamos detalle para incluir reglas en la misma respuesta.
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
    v_settings jsonb;
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

    select coalesce(jsonb_agg(to_jsonb(e) order by captured_at),'[]'::jsonb)
    into v_events
    from (
        select captured_at,balance,previous_balance,delta,event_type
        from public.balance_events
        where id_client=p_id_client
        order by captured_at
        limit 2000
    ) e;

    select coalesce(jsonb_agg(to_jsonb(d) order by day),'[]'::jsonb)
    into v_daily
    from (
        select day,opening_balance,closing_balance,min_balance,max_balance,
               snapshots_count,zero_snapshots,changes_count,consumption,recharges,
               quiebre_entries,recoveries,first_capture_at,last_capture_at
        from public.client_daily_stats
        where id_client=p_id_client
        order by day
        limit 730
    ) d;

    select jsonb_build_object(
        'low_balance',low_balance,
        'critical_balance',critical_balance,
        'strong_drop',strong_drop,
        'min_snapshots_baja',min_snapshots_baja
    )
    into v_settings
    from public.app_settings where id=1;

    return jsonb_build_object(
        'profile',v_profile,
        'events',v_events,
        'daily',v_daily,
        'settings',v_settings
    );
end;
$$;


revoke all on function public.web_summary_deep() from public, anon;
revoke all on function public.web_clients_deep(text,text,text,text,text,integer,integer) from public, anon;

grant execute on function public.web_summary_deep() to authenticated;
grant execute on function public.web_clients_deep(text,text,text,text,text,integer,integer) to authenticated;

alter function public.web_summary_deep() set statement_timeout='15s';
alter function public.web_clients_deep(text,text,text,text,text,integer,integer) set statement_timeout='15s';
alter function public.web_client_detail(text) set statement_timeout='15s';

commit;
