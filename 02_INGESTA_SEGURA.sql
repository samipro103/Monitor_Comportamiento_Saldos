-- ============================================================
-- MONITOR DE SALDOS
-- 02 - INGESTA SEGURA DESDE WINDOWS
-- ============================================================
-- IMPORTANTE:
-- 1) Antes de ejecutar, reemplaza:
--      PEGA_AQUI_TU_CLAVE_DE_INGESTA
--    por una clave larga aleatoria.
-- 2) Esa misma clave se colocará en el agente Windows.
-- 3) En la base SOLO guardamos el hash de la clave.
-- ============================================================

begin;

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

create table if not exists private.monitor_secrets (
    name text primary key,
    secret_hash text not null,
    updated_at timestamptz not null default now()
);

revoke all on private.monitor_secrets from public;
revoke all on private.monitor_secrets from anon;
revoke all on private.monitor_secrets from authenticated;


create table if not exists private.ingest_state (
    id smallint primary key default 1,
    latest_snapshot_at timestamptz,
    updated_at timestamptz not null default now(),
    constraint ingest_state_one_row check (id = 1)
);

insert into private.ingest_state(id, latest_snapshot_at)
values (1, null)
on conflict (id) do nothing;

revoke all on private.ingest_state from public;
revoke all on private.ingest_state from anon;
revoke all on private.ingest_state from authenticated;

insert into private.monitor_secrets(name, secret_hash)
values (
    'ingest_key',
    encode(digest('PEGA_AQUI_TU_CLAVE_DE_INGESTA', 'sha256'), 'hex')
)
on conflict (name)
do update set
    secret_hash = excluded.secret_hash,
    updated_at = now();


-- ============================================================
-- FUNCIÓN DE PRUEBA
-- ============================================================

create or replace function public.ingest_ping(
    p_ingest_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
    v_hash text;
    v_files bigint;
begin
    select secret_hash
    into v_hash
    from private.monitor_secrets
    where name = 'ingest_key';

    if v_hash is null
       or encode(digest(coalesce(p_ingest_key,''), 'sha256'), 'hex') <> v_hash then
        raise exception 'CLAVE DE INGESTA INVALIDA'
            using errcode = '28000';
    end if;

    select count(*)
    into v_files
    from public.import_batches
    where status = 'COMPLETED';

    return jsonb_build_object(
        'ok', true,
        'server_time', now(),
        'files_loaded', v_files
    );
end;
$$;


-- ============================================================
-- FUNCIÓN PRINCIPAL DE INGESTA
--
-- Recibe una "foto" horaria:
-- ID + Teléfono + Comercio + Balance.
--
-- No guarda filas repetidas sin necesidad:
-- - client_stats cuenta TODAS las tomas
-- - balance_events guarda solo INICIAL o CAMBIOS
-- - client_daily_stats resume por día
-- ============================================================

create or replace function public.ingest_snapshot(
    p_ingest_key text,
    p_file_name text,
    p_file_hash text,
    p_snapshot_at timestamptz,
    p_machine_id text,
    p_machine_name text,
    p_source_path text,
    p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
    v_hash text;
    v_batch_id uuid;
    v_existing_status text;
    v_rows_received integer;
    v_rows_valid integer;
    v_rows_invalid integer;

    v_low numeric(14,2);
    v_critical numeric(14,2);
    v_strong_drop numeric(14,2);
    v_min_baja integer;
    v_latest_snapshot timestamptz;
begin
    -- --------------------------------------------------------
    -- SEGURIDAD
    -- --------------------------------------------------------
    select secret_hash
    into v_hash
    from private.monitor_secrets
    where name = 'ingest_key';

    if v_hash is null
       or encode(digest(coalesce(p_ingest_key,''), 'sha256'), 'hex') <> v_hash then
        raise exception 'CLAVE DE INGESTA INVALIDA'
            using errcode = '28000';
    end if;

    if p_file_name is null or btrim(p_file_name) = '' then
        raise exception 'NOMBRE DE ARCHIVO VACIO';
    end if;

    if p_file_hash is null or btrim(p_file_hash) = '' then
        raise exception 'HASH DE ARCHIVO VACIO';
    end if;

    if p_snapshot_at is null then
        raise exception 'FECHA/HORA DE TOMA VACIA';
    end if;

    if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
        raise exception 'p_rows DEBE SER UN ARRAY JSON';
    end if;

    v_rows_received := jsonb_array_length(p_rows);

    if v_rows_received = 0 then
        raise exception 'EL ARCHIVO NO CONTIENE REGISTROS';
    end if;

    if v_rows_received > 25000 then
        raise exception 'DEMASIADOS REGISTROS EN UNA SOLA TOMA: %', v_rows_received;
    end if;

    select
        low_balance,
        critical_balance,
        strong_drop,
        min_snapshots_baja
    into
        v_low,
        v_critical,
        v_strong_drop,
        v_min_baja
    from public.app_settings
    where id = 1;

    -- --------------------------------------------------------
    -- SI YA FUE PROCESADO, NO LO DUPLICAMOS
    -- --------------------------------------------------------
    select id, status
    into v_batch_id, v_existing_status
    from public.import_batches
    where file_hash = p_file_hash;

    if found and v_existing_status = 'COMPLETED' then
        return jsonb_build_object(
            'ok', true,
            'duplicate', true,
            'message', 'Archivo ya procesado',
            'file_name', p_file_name,
            'file_hash', p_file_hash
        );
    end if;

    -- Protege las estadísticas acumuladas contra cargas fuera de orden.
    -- La primera carga debe hacerse de la toma más antigua a la más nueva.
    select latest_snapshot_at
    into v_latest_snapshot
    from private.ingest_state
    where id = 1;

    if v_latest_snapshot is not null
       and p_snapshot_at <= v_latest_snapshot then
        return jsonb_build_object(
            'ok', false,
            'file_name', p_file_name,
            'error', 'TOMA_FUERA_DE_ORDEN',
            'message',
                'La toma debe ser posterior a la última ya centralizada',
            'snapshot_at', p_snapshot_at,
            'latest_snapshot_at', v_latest_snapshot
        );
    end if;

    if found then
        update public.import_batches
        set
            file_name = p_file_name,
            snapshot_at = p_snapshot_at,
            source_machine = p_machine_name,
            source_path = p_source_path,
            rows_received = v_rows_received,
            rows_valid = 0,
            rows_invalid = 0,
            status = 'PROCESSING',
            error_message = null,
            processed_at = null
        where id = v_batch_id;
    else
        insert into public.import_batches(
            file_name,
            file_hash,
            snapshot_at,
            source_machine,
            source_path,
            rows_received,
            status
        )
        values(
            p_file_name,
            p_file_hash,
            p_snapshot_at,
            p_machine_name,
            p_source_path,
            v_rows_received,
            'PROCESSING'
        )
        returning id into v_batch_id;
    end if;

    -- Todo el procesamiento queda dentro de este sub-bloque.
    -- Si algo falla, se revierte solamente esta parte y podemos
    -- dejar el archivo marcado como ERROR.
    begin

        drop table if exists pg_temp.tmp_snapshot;

        create temporary table pg_temp.tmp_snapshot (
            id_client text primary key,
            phone text,
            commerce text,
            balance numeric(14,2) not null
        ) on commit drop;

        insert into pg_temp.tmp_snapshot(
            id_client,
            phone,
            commerce,
            balance
        )
        select distinct on (btrim(x.id_client))
            btrim(x.id_client),
            nullif(btrim(x.phone), ''),
            nullif(btrim(x.commerce), ''),
            x.balance
        from jsonb_to_recordset(p_rows) as x(
            id_client text,
            phone text,
            commerce text,
            balance numeric
        )
        where
            x.id_client is not null
            and btrim(x.id_client) <> ''
            and x.balance is not null
        order by btrim(x.id_client);

        select count(*)
        into v_rows_valid
        from pg_temp.tmp_snapshot;

        v_rows_invalid := greatest(v_rows_received - v_rows_valid, 0);

        if v_rows_valid = 0 then
            raise exception 'NO HAY REGISTROS VALIDOS EN EL ARCHIVO';
        end if;


        -- ----------------------------------------------------
        -- GUARDAR ESTADO ANTERIOR ANTES DE ACTUALIZAR
        -- ----------------------------------------------------
        drop table if exists pg_temp.tmp_calc;

        create temporary table pg_temp.tmp_calc
        on commit drop
        as
        select
            t.id_client,
            t.phone,
            t.commerce,
            t.balance,

            s.current_balance as previous_balance,
            s.total_snapshots as previous_snapshots,
            s.positive_snapshots as previous_positive_snapshots,
            s.ever_confirmed_baja as previous_ever_baja,
            s.zero_streak_snapshots as previous_zero_streak,
            s.zero_streak_since as previous_zero_streak_since,
            s.last_movement_at as previous_last_movement_at,
            s.last_movement_type as previous_last_movement_type,
            s.reactivated_at as previous_reactivated_at

        from pg_temp.tmp_snapshot t
        left join public.client_stats s
            on s.id_client = t.id_client;


        -- ----------------------------------------------------
        -- CLIENTES
        -- ----------------------------------------------------
        insert into public.clients(
            id_client,
            phone,
            commerce,
            first_seen,
            last_seen
        )
        select
            id_client,
            phone,
            commerce,
            p_snapshot_at,
            p_snapshot_at
        from pg_temp.tmp_snapshot

        on conflict (id_client)
        do update set
            phone = coalesce(excluded.phone, public.clients.phone),
            commerce = coalesce(excluded.commerce, public.clients.commerce),

            first_seen = case
                when public.clients.first_seen is null
                    then excluded.first_seen
                else least(public.clients.first_seen, excluded.first_seen)
            end,

            last_seen = case
                when public.clients.last_seen is null
                    then excluded.last_seen
                else greatest(public.clients.last_seen, excluded.last_seen)
            end;


        -- ----------------------------------------------------
        -- EVENTOS
        -- SOLO INSERTA INICIAL O CUANDO EL SALDO CAMBIA
        -- ----------------------------------------------------
        insert into public.balance_events(
            id_client,
            import_id,
            captured_at,
            balance,
            previous_balance,
            delta,
            event_type
        )
        select
            c.id_client,
            v_batch_id,
            p_snapshot_at,
            c.balance,
            c.previous_balance,

            case
                when c.previous_balance is null then null
                else c.balance - c.previous_balance
            end,

            case
                when c.previous_balance is null
                    then 'INITIAL'

                when c.previous_balance > 0
                     and c.balance = 0
                    then 'QUIEBRE'

                when c.previous_balance = 0
                     and c.balance > 0
                    then 'RECOVERY'

                when c.balance < c.previous_balance
                    then 'DROP'

                when c.balance > c.previous_balance
                    then 'RECHARGE'
            end

        from pg_temp.tmp_calc c
        where
            c.previous_balance is null
            or c.balance <> c.previous_balance;


        -- ----------------------------------------------------
        -- ESTADISTICA CENTRAL
        -- ----------------------------------------------------
        insert into public.client_stats(
            id_client,
            current_balance,
            previous_balance,
            first_balance,
            min_balance,
            max_balance,
            sum_balance,
            total_snapshots,
            zero_snapshots,
            positive_snapshots,
            changes_count,
            quiebre_entries,
            recoveries,
            strong_drops,
            total_consumption,
            total_recharges,
            zero_streak_snapshots,
            zero_streak_since,
            first_seen,
            last_seen,
            last_movement_at,
            last_movement_type,
            ever_confirmed_baja,
            reactivated_at,
            risk_score
        )
        select
            c.id_client,
            c.balance,
            null,
            c.balance,
            c.balance,
            c.balance,
            c.balance,
            1,

            case when c.balance = 0 then 1 else 0 end,
            case when c.balance > 0 then 1 else 0 end,

            0,
            0,
            0,
            0,
            0,
            0,

            case when c.balance = 0 then 1 else 0 end,
            case when c.balance = 0 then p_snapshot_at else null end,

            p_snapshot_at,
            p_snapshot_at,

            null,
            null,

            case
                when c.balance = 0 and v_min_baja <= 1
                    then true
                else false
            end,

            null,
            0

        from pg_temp.tmp_calc c

        on conflict (id_client)
        do update set

            previous_balance = public.client_stats.current_balance,
            current_balance = excluded.current_balance,

            first_balance = coalesce(
                public.client_stats.first_balance,
                excluded.current_balance
            ),

            min_balance = case
                when public.client_stats.min_balance is null
                    then excluded.current_balance
                else least(
                    public.client_stats.min_balance,
                    excluded.current_balance
                )
            end,

            max_balance = case
                when public.client_stats.max_balance is null
                    then excluded.current_balance
                else greatest(
                    public.client_stats.max_balance,
                    excluded.current_balance
                )
            end,

            sum_balance =
                public.client_stats.sum_balance
                + excluded.current_balance,

            total_snapshots =
                public.client_stats.total_snapshots + 1,

            zero_snapshots =
                public.client_stats.zero_snapshots
                + case
                    when excluded.current_balance = 0 then 1
                    else 0
                  end,

            positive_snapshots =
                public.client_stats.positive_snapshots
                + case
                    when excluded.current_balance > 0 then 1
                    else 0
                  end,

            changes_count =
                public.client_stats.changes_count
                + case
                    when excluded.current_balance
                         <> public.client_stats.current_balance
                    then 1
                    else 0
                  end,

            quiebre_entries =
                public.client_stats.quiebre_entries
                + case
                    when public.client_stats.current_balance > 0
                         and excluded.current_balance = 0
                    then 1
                    else 0
                  end,

            recoveries =
                public.client_stats.recoveries
                + case
                    when public.client_stats.current_balance = 0
                         and excluded.current_balance > 0
                    then 1
                    else 0
                  end,

            strong_drops =
                public.client_stats.strong_drops
                + case
                    when (
                        public.client_stats.current_balance
                        - excluded.current_balance
                    ) >= v_strong_drop
                    then 1
                    else 0
                  end,

            total_consumption =
                public.client_stats.total_consumption
                + greatest(
                    public.client_stats.current_balance
                    - excluded.current_balance,
                    0
                ),

            total_recharges =
                public.client_stats.total_recharges
                + greatest(
                    excluded.current_balance
                    - public.client_stats.current_balance,
                    0
                ),

            zero_streak_snapshots =
                case
                    when excluded.current_balance = 0
                    then
                        case
                            when public.client_stats.current_balance = 0
                            then public.client_stats.zero_streak_snapshots + 1
                            else 1
                        end
                    else 0
                end,

            zero_streak_since =
                case
                    when excluded.current_balance = 0
                    then
                        case
                            when public.client_stats.current_balance = 0
                            then coalesce(
                                public.client_stats.zero_streak_since,
                                p_snapshot_at
                            )
                            else p_snapshot_at
                        end
                    else null
                end,

            first_seen =
                case
                    when public.client_stats.first_seen is null
                    then p_snapshot_at
                    else least(
                        public.client_stats.first_seen,
                        p_snapshot_at
                    )
                end,

            last_seen =
                case
                    when public.client_stats.last_seen is null
                    then p_snapshot_at
                    else greatest(
                        public.client_stats.last_seen,
                        p_snapshot_at
                    )
                end,

            last_movement_at =
                case
                    when excluded.current_balance
                         <> public.client_stats.current_balance
                    then p_snapshot_at
                    else public.client_stats.last_movement_at
                end,

            last_movement_type =
                case
                    when excluded.current_balance
                         = public.client_stats.current_balance
                    then public.client_stats.last_movement_type

                    when public.client_stats.current_balance > 0
                         and excluded.current_balance = 0
                    then 'QUIEBRE'

                    when public.client_stats.current_balance = 0
                         and excluded.current_balance > 0
                    then 'RECOVERY'

                    when excluded.current_balance
                         < public.client_stats.current_balance
                    then 'DROP'

                    else 'RECHARGE'
                end,

            ever_confirmed_baja =
                public.client_stats.ever_confirmed_baja
                or (
                    public.client_stats.positive_snapshots = 0
                    and excluded.current_balance = 0
                    and (
                        public.client_stats.total_snapshots + 1
                    ) >= v_min_baja
                ),

            reactivated_at =
                case
                    when public.client_stats.ever_confirmed_baja = true
                         and public.client_stats.current_balance = 0
                         and excluded.current_balance > 0
                    then p_snapshot_at
                    else public.client_stats.reactivated_at
                end;


        -- ----------------------------------------------------
        -- RIESGO OPERATIVO 0 - 100
        -- Se recalcula solo para IDs presentes en esta toma.
        -- ----------------------------------------------------
        update public.client_stats s
        set risk_score = least(
            100,

            -- Tuvo saldo alguna vez y ahora está en cero.
            case
                when s.positive_snapshots > 0
                     and s.current_balance = 0
                then 40
                else 0
            end

            +

            -- Reincidencias.
            least(s.quiebre_entries * 8, 24)

            +

            -- Caídas fuertes.
            least(s.strong_drops * 4, 16)

            +

            -- Mucho tiempo en cero.
            case
                when s.total_snapshots > 0
                     and (
                        s.zero_snapshots::numeric
                        / s.total_snapshots::numeric
                     ) >= 0.50
                then 12

                when s.total_snapshots > 0
                     and (
                        s.zero_snapshots::numeric
                        / s.total_snapshots::numeric
                     ) >= 0.25
                then 6

                else 0
            end

            +

            -- Actualmente bajo pero no en cero.
            case
                when s.current_balance > 0
                     and s.current_balance <= v_low
                then 8
                else 0
            end
        )
        where exists (
            select 1
            from pg_temp.tmp_snapshot t
            where t.id_client = s.id_client
        );


        -- ----------------------------------------------------
        -- RESUMEN DIARIO
        -- ----------------------------------------------------
        insert into public.client_daily_stats(
            id_client,
            day,
            opening_balance,
            closing_balance,
            min_balance,
            max_balance,
            snapshots_count,
            zero_snapshots,
            changes_count,
            consumption,
            recharges,
            quiebre_entries,
            recoveries,
            first_capture_at,
            last_capture_at
        )
        select
            c.id_client,
            (p_snapshot_at at time zone 'America/El_Salvador')::date,

            c.balance,
            c.balance,
            c.balance,
            c.balance,

            1,

            case when c.balance = 0 then 1 else 0 end,

            case
                when c.previous_balance is not null
                     and c.balance <> c.previous_balance
                then 1
                else 0
            end,

            case
                when c.previous_balance is not null
                then greatest(
                    c.previous_balance - c.balance,
                    0
                )
                else 0
            end,

            case
                when c.previous_balance is not null
                then greatest(
                    c.balance - c.previous_balance,
                    0
                )
                else 0
            end,

            case
                when c.previous_balance > 0
                     and c.balance = 0
                then 1
                else 0
            end,

            case
                when c.previous_balance = 0
                     and c.balance > 0
                then 1
                else 0
            end,

            p_snapshot_at,
            p_snapshot_at

        from pg_temp.tmp_calc c

        on conflict (id_client, day)
        do update set

            opening_balance =
                case
                    when excluded.first_capture_at
                         < public.client_daily_stats.first_capture_at
                    then excluded.opening_balance
                    else public.client_daily_stats.opening_balance
                end,

            closing_balance =
                case
                    when excluded.last_capture_at
                         >= public.client_daily_stats.last_capture_at
                    then excluded.closing_balance
                    else public.client_daily_stats.closing_balance
                end,

            min_balance = least(
                public.client_daily_stats.min_balance,
                excluded.min_balance
            ),

            max_balance = greatest(
                public.client_daily_stats.max_balance,
                excluded.max_balance
            ),

            snapshots_count =
                public.client_daily_stats.snapshots_count
                + excluded.snapshots_count,

            zero_snapshots =
                public.client_daily_stats.zero_snapshots
                + excluded.zero_snapshots,

            changes_count =
                public.client_daily_stats.changes_count
                + excluded.changes_count,

            consumption =
                public.client_daily_stats.consumption
                + excluded.consumption,

            recharges =
                public.client_daily_stats.recharges
                + excluded.recharges,

            quiebre_entries =
                public.client_daily_stats.quiebre_entries
                + excluded.quiebre_entries,

            recoveries =
                public.client_daily_stats.recoveries
                + excluded.recoveries,

            first_capture_at = least(
                public.client_daily_stats.first_capture_at,
                excluded.first_capture_at
            ),

            last_capture_at = greatest(
                public.client_daily_stats.last_capture_at,
                excluded.last_capture_at
            );


        -- ----------------------------------------------------
        -- ESTADO DEL AGENTE
        -- ----------------------------------------------------
        insert into public.uploader_status(
            machine_id,
            machine_name,
            source_folder,
            agent_version,
            last_seen_at,
            last_scan_at,
            last_upload_at,
            last_file_name,
            files_sent,
            rows_sent,
            last_error
        )
        values(
            coalesce(nullif(p_machine_id,''), 'unknown'),
            p_machine_name,
            p_source_path,
            '1.0',
            now(),
            now(),
            now(),
            p_file_name,
            1,
            v_rows_valid,
            null
        )
        on conflict (machine_id)
        do update set
            machine_name = excluded.machine_name,
            source_folder = excluded.source_folder,
            agent_version = excluded.agent_version,
            last_seen_at = now(),
            last_scan_at = now(),
            last_upload_at = now(),
            last_file_name = excluded.last_file_name,
            files_sent = public.uploader_status.files_sent + 1,
            rows_sent = public.uploader_status.rows_sent + v_rows_valid,
            last_error = null;


        update public.import_batches
        set
            rows_received = v_rows_received,
            rows_valid = v_rows_valid,
            rows_invalid = v_rows_invalid,
            status = 'COMPLETED',
            error_message = null,
            processed_at = now()
        where id = v_batch_id;

        update private.ingest_state
        set
            latest_snapshot_at = p_snapshot_at,
            updated_at = now()
        where id = 1;


    exception when others then

        update public.import_batches
        set
            status = 'ERROR',
            error_message = sqlerrm,
            processed_at = now()
        where id = v_batch_id;

        insert into public.uploader_status(
            machine_id,
            machine_name,
            source_folder,
            agent_version,
            last_seen_at,
            last_scan_at,
            last_error
        )
        values(
            coalesce(nullif(p_machine_id,''), 'unknown'),
            p_machine_name,
            p_source_path,
            '1.0',
            now(),
            now(),
            sqlerrm
        )
        on conflict (machine_id)
        do update set
            machine_name = excluded.machine_name,
            source_folder = excluded.source_folder,
            agent_version = excluded.agent_version,
            last_seen_at = now(),
            last_scan_at = now(),
            last_error = sqlerrm;

        return jsonb_build_object(
            'ok', false,
            'file_name', p_file_name,
            'error', sqlerrm
        );
    end;


    return jsonb_build_object(
        'ok', true,
        'duplicate', false,
        'file_name', p_file_name,
        'snapshot_at', p_snapshot_at,
        'rows_received', v_rows_received,
        'rows_valid', v_rows_valid,
        'rows_invalid', v_rows_invalid,
        'batch_id', v_batch_id
    );
end;
$$;


-- ============================================================
-- PERMISOS
--
-- La Publishable Key trabaja como rol anon cuando no hay login.
-- Solo le permitimos ejecutar ESTAS funciones.
-- No obtiene SELECT/INSERT directo sobre las tablas.
-- ============================================================

revoke all on function public.ingest_ping(text) from public;
revoke all on function public.ingest_snapshot(
    text,text,text,timestamptz,text,text,text,jsonb
) from public;

grant execute on function public.ingest_ping(text) to anon;

grant execute on function public.ingest_snapshot(
    text,text,text,timestamptz,text,text,text,jsonb
) to anon;


commit;


-- ============================================================
-- PRUEBA MANUAL OPCIONAL
-- Reemplaza la clave y ejecuta SOLO este SELECT después.
-- ============================================================
-- select public.ingest_ping('PEGA_AQUI_TU_CLAVE_DE_INGESTA');
