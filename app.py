from __future__ import annotations

import csv
import io
import json
import math
import os
import sqlite3
import subprocess
import threading
import time
import traceback
import urllib.parse
import zipfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"
DATA_DIR = ROOT / "data"
# New database name on purpose: v1.4 changes the entity key and classification model.
DB_PATH = DATA_DIR / "balances_v14.db"
CONFIG_PATH = ROOT / "config.json"
DATA_DIR.mkdir(exist_ok=True)

DEFAULT_CONFIG = {
    "carpeta_reportes": "",
    "puerto": 43120,
    "escaneo_segundos": 300,
    "saldo_bajo": 5.0,
    "saldo_critico": 1.0,
    "caida_fuerte": 20.0,
    "min_tomas_baja": 3,
}

EPS_ZERO = 0.005
EPS_MOVE = 0.01

SCAN_LOCK = threading.Lock()
STATUS_LOCK = threading.Lock()
REQUEST_LOCK = threading.Lock()
SCAN_REQUEST_EVENT = threading.Event()
SCAN_REQUEST = {"rebuild": False, "reset_source": False}
RUNTIME_STATUS = {
    "scanning": False,
    "scan_pending": False,
    "phase": "IDLE",
    "last_scan_started": None,
    "last_scan_finished": None,
    "last_scan_message": "Aún no se ha escaneado la carpeta.",
    "last_error": None,
    "files_found": 0,
    "files_processed": 0,
    "rows_read": 0,
    "errors": 0,
    "current_file": None,
}


def load_config() -> dict:
    cfg = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        try:
            loaded = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                cfg.update(loaded)
        except Exception:
            pass
    return cfg


def save_config(cfg: dict) -> None:
    clean = DEFAULT_CONFIG.copy()
    clean.update(cfg)
    CONFIG_PATH.write_text(json.dumps(clean, indent=2, ensure_ascii=False), encoding="utf-8")


def db_connect() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, timeout=60)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.execute("PRAGMA temp_store=MEMORY")
    return con


def init_db() -> None:
    with db_connect() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS observations (
                entity_key TEXT NOT NULL,
                id_cliente TEXT NOT NULL,
                telefono TEXT NOT NULL,
                ts TEXT NOT NULL,
                balance REAL NOT NULL,
                categoria TEXT,
                nombre TEXT,
                comercio TEXT,
                source_file TEXT NOT NULL,
                PRIMARY KEY (entity_key, ts)
            );
            CREATE INDEX IF NOT EXISTS idx_obs_id_ts ON observations(id_cliente, ts);
            CREATE INDEX IF NOT EXISTS idx_obs_phone_ts ON observations(telefono, ts);
            CREATE INDEX IF NOT EXISTS idx_obs_ts ON observations(ts);
            CREATE INDEX IF NOT EXISTS idx_obs_source ON observations(source_file);

            CREATE TABLE IF NOT EXISTS ingested_files (
                path TEXT PRIMARY KEY,
                size INTEGER NOT NULL,
                mtime_ns INTEGER NOT NULL,
                rows_loaded INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                error TEXT,
                processed_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS client_stats (
                entity_key TEXT PRIMARY KEY,
                id_cliente TEXT,
                telefono TEXT,
                categoria TEXT,
                nombre TEXT,
                comercio TEXT,
                first_ts TEXT,
                last_ts TEXT,
                observations INTEGER,
                first_balance REAL,
                current_balance REAL,
                min_balance REAL,
                max_balance REAL,
                avg_balance REAL,
                low_count INTEGER,
                zero_count INTEGER,
                low_ratio REAL,
                zero_ratio REAL,
                changes_count INTEGER,
                increase_count INTEGER,
                decrease_count INTEGER,
                total_movement REAL,
                total_drop REAL,
                total_recharge REAL,
                biggest_drop REAL,
                biggest_recharge REAL,
                sharp_drops INTEGER,
                stockout_events INTEGER,
                zero_entries INTEGER,
                recovery_events INTEGER,
                longest_low_streak INTEGER,
                longest_zero_streak INTEGER,
                current_zero_streak INTEGER,
                current_low_streak INTEGER,
                net_change REAL,
                last_delta REAL,
                last_movement_ts TEXT,
                last_positive_ts TEXT,
                classification TEXT,
                priority_label TEXT,
                priority_score REAL,
                diagnosis TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_stats_class ON client_stats(classification);
            CREATE INDEX IF NOT EXISTS idx_stats_priority ON client_stats(priority_score DESC);
            CREATE INDEX IF NOT EXISTS idx_stats_id ON client_stats(id_cliente);
            CREATE INDEX IF NOT EXISTS idx_stats_phone ON client_stats(telefono);
            """
        )


def repair_text(value: str | None) -> str:
    if not value:
        return ""
    s = str(value).strip()
    def badness(x: str) -> int:
        return sum(x.count(ch) for ch in ("Ã", "Â", "�"))
    for _ in range(2):
        if badness(s) == 0:
            break
        try:
            candidate = s.encode("latin1").decode("utf-8")
        except Exception:
            break
        if badness(candidate) < badness(s):
            s = candidate
        else:
            break
    return s


def parse_timestamp(day: str, hour: str) -> str | None:
    day = (day or "").strip()
    hour = (hour or "").strip()
    raw = f"{day} {hour}".strip()
    fmts = (
        "%d/%m/%Y %H:%M", "%d/%m/%Y %H:%M:%S",
        "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S",
        "%d/%m/%Y", "%Y-%m-%d",
    )
    for fmt in fmts:
        try:
            dt = datetime.strptime(raw, fmt)
            return dt.strftime("%Y-%m-%d %H:%M:%S")
        except ValueError:
            pass
    return None


def parse_balance(value: str) -> float | None:
    if value is None:
        return None
    s = str(value).strip().replace("$", "").replace(" ", "")
    if not s:
        return None
    if "," in s and "." in s:
        s = s.replace(",", "")
    elif "," in s:
        parts = s.split(",")
        if len(parts) == 2 and len(parts[1]) <= 2:
            s = s.replace(",", ".")
        else:
            s = s.replace(",", "")
    try:
        v = float(s)
        return v if math.isfinite(v) else None
    except ValueError:
        return None


def normalize_row(row: dict, source_file: str):
    lower = {str(k).strip().lower(): v for k, v in row.items() if k is not None}
    def get(*names):
        for n in names:
            if n.lower() in lower:
                return lower[n.lower()]
        return ""

    ts = parse_timestamp(str(get("Dia", "Día", "Fecha")), str(get("Hora")))
    id_cliente = repair_text(get("Id Cliente", "ID Cliente", "IdCliente", "ID_DMS"))
    telefono = repair_text(get("Telefono", "Teléfono", "Telefono Epin", "Telefono EPIN"))
    balance = parse_balance(get("Balance Billetera", "Balance", "Saldo"))
    if not ts or not id_cliente or not telefono or balance is None:
        return None
    entity_key = f"{id_cliente}|{telefono}"
    return (
        entity_key, id_cliente, telefono, ts, balance,
        repair_text(get("Categoria", "Categoría")),
        repair_text(get("Nombre")),
        repair_text(get("Nombre de Comercio", "Comercio", "Punto")),
        source_file,
    )


def read_csv_text(stream, source_file: str):
    wrapper = io.TextIOWrapper(stream, encoding="utf-8-sig", errors="replace", newline="")
    reader = csv.DictReader(wrapper)
    for row in reader:
        item = normalize_row(row, source_file)
        if item:
            yield item


def insert_rows(con: sqlite3.Connection, iterator) -> int:
    sql = """
        INSERT INTO observations
        (entity_key, id_cliente, telefono, ts, balance, categoria, nombre, comercio, source_file)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(entity_key, ts) DO UPDATE SET
            balance=excluded.balance,
            categoria=excluded.categoria,
            nombre=excluded.nombre,
            comercio=excluded.comercio,
            source_file=excluded.source_file
    """
    batch, count = [], 0
    for item in iterator:
        batch.append(item)
        if len(batch) >= 2500:
            con.executemany(sql, batch)
            count += len(batch)
            batch.clear()
    if batch:
        con.executemany(sql, batch)
        count += len(batch)
    return count


def delete_file_observations(con: sqlite3.Connection, path: Path) -> None:
    source = str(path)
    con.execute("DELETE FROM observations WHERE source_file=? OR source_file LIKE ?", (source, source + "::%"))


def ingest_one_file(path: Path, con: sqlite3.Connection) -> tuple[int, str | None]:
    rows_loaded = 0
    error = None
    source = str(path)
    try:
        delete_file_observations(con, path)
        if path.suffix.lower() == ".csv":
            with path.open("rb") as f:
                rows_loaded = insert_rows(con, read_csv_text(f, source))
        elif path.suffix.lower() == ".zip":
            total = 0
            with zipfile.ZipFile(path, "r") as zf:
                members = [n for n in zf.namelist() if n.lower().endswith(".csv") and not n.endswith("/")]
                for member in members:
                    with zf.open(member, "r") as f:
                        total += insert_rows(con, read_csv_text(f, f"{source}::{member}"))
            rows_loaded = total
        else:
            return 0, "Extensión no soportada"
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    return rows_loaded, error


def classify_state(s: dict, cfg: dict) -> tuple[str, str, float, str]:
    """Operational classification designed to be explainable.

    BAJA: enough historical snapshots and every single balance is exactly 0.
    ATENCION: there is real balance movement in the historical series.
    SIN_MOVIMIENTO: enough history, positive balance, but balance never changed.
    POR_CONFIRMAR: too few snapshots to assert a pattern.
    """
    n = s["n"]
    min_baja = max(2, int(cfg.get("min_tomas_baja", 3)))
    low = float(cfg.get("saldo_bajo", 5.0))
    critical = float(cfg.get("saldo_critico", 1.0))
    sharp = float(cfg.get("caida_fuerte", 20.0))
    low_ratio = s["low_count"] / n if n else 0.0
    zero_ratio = s["zero_count"] / n if n else 0.0
    all_zero = n >= min_baja and abs(s["max_balance"]) <= EPS_ZERO and abs(s["min_balance"]) <= EPS_ZERO
    has_movement = s["changes_count"] > 0

    if n < min_baja:
        classification = "POR_CONFIRMAR"
        priority = "PENDIENTE"
        score = 0.0
        if abs(s["current_balance"]) <= EPS_ZERO:
            diagnosis = f"Tiene {n} toma(s) y todas están en $0.00, pero faltan tomas para confirmar una baja."
        elif has_movement:
            diagnosis = f"Ya muestra movimiento, pero solo hay {n} toma(s); se seguirá acumulando historial."
        else:
            diagnosis = f"Solo hay {n} toma(s); todavía no se puede determinar un patrón."
        return classification, priority, score, diagnosis

    if all_zero:
        classification = "BAJA"
        priority = "BAJA"
        score = 0.0
        diagnosis = f"Baja confirmada: {n} de {n} tomas en $0.00 y nunca registró saldo positivo en el histórico cargado."
        return classification, priority, score, diagnosis

    if not has_movement:
        classification = "SIN_MOVIMIENTO"
        priority = "OBSERVAR"
        score = 10.0 if s["current_balance"] <= low else 0.0
        diagnosis = (
            f"Sin movimiento: mantiene ${s['current_balance']:.2f} sin cambios durante {n} tomas. "
            "No se clasifica como baja porque sí tiene saldo positivo."
        )
        return classification, priority, score, diagnosis

    classification = "ATENCION"
    score = 0.0
    if abs(s["current_balance"]) <= EPS_ZERO:
        score += 38
    elif s["current_balance"] <= critical:
        score += 32
    elif s["current_balance"] <= low:
        score += 22
    score += min(24.0, s["stockout_events"] * 8.0)
    score += min(18.0, s["sharp_drops"] * 6.0)
    score += min(10.0, zero_ratio * 12.0)
    score += min(8.0, low_ratio * 10.0)
    if s["last_delta"] <= -sharp:
        score += 10
    elif s["last_delta"] < -EPS_MOVE:
        score += 4
    score = round(min(100.0, score), 1)

    if abs(s["current_balance"]) <= EPS_ZERO and s["max_balance"] > EPS_ZERO:
        priority = "URGENTE"
        diagnosis = "En $0.00 ahora, pero sí tuvo saldo antes: no es baja; requiere atención porque cayó a cero después de tener movimiento."
    elif s["current_balance"] <= critical:
        priority = "URGENTE"
        diagnosis = f"Saldo crítico actual (${s['current_balance']:.2f}) con historial de movimiento."
    elif s["stockout_events"] >= 2 and s["current_balance"] <= low:
        priority = "URGENTE"
        diagnosis = f"Reincidente: entró a saldo bajo {s['stockout_events']} veces y actualmente sigue bajo el límite."
    elif s["current_balance"] <= low or s["sharp_drops"] >= 2 or s["stockout_events"] >= 2:
        priority = "ALTA"
        diagnosis = "Tiene movimiento real y señales repetidas de quiebre o caída; conviene seguimiento cercano."
    elif s["sharp_drops"] >= 1 or low_ratio >= 0.35 or s["net_change"] <= -sharp:
        priority = "MEDIA"
        diagnosis = "Tiene movimiento y señales de deterioro, aunque no está en el nivel más urgente."
    elif s["recovery_events"] > 0 and s["current_balance"] > low:
        priority = "SEGUIMIENTO"
        diagnosis = f"Con movimiento y actualmente recuperado; ha salido de saldo bajo {s['recovery_events']} vez/veces."
    else:
        priority = "SEGUIMIENTO"
        diagnosis = "Tiene movimiento de saldo. Se mantiene en atención para observar su comportamiento, aunque no presenta una alerta fuerte ahora."
    return classification, priority, score, diagnosis


def rebuild_stats(con: sqlite3.Connection, cfg: dict) -> None:
    low = float(cfg.get("saldo_bajo", 5.0))
    sharp = float(cfg.get("caida_fuerte", 20.0))
    con.execute("DELETE FROM client_stats")
    cur = con.execute(
        """
        SELECT entity_key, id_cliente, telefono, ts, balance, categoria, nombre, comercio
        FROM observations
        ORDER BY entity_key, ts
        """
    )

    insert_sql = """
        INSERT INTO client_stats (
            entity_key,id_cliente,telefono,categoria,nombre,comercio,
            first_ts,last_ts,observations,first_balance,current_balance,min_balance,max_balance,avg_balance,
            low_count,zero_count,low_ratio,zero_ratio,changes_count,increase_count,decrease_count,total_movement,
            total_drop,total_recharge,biggest_drop,biggest_recharge,sharp_drops,stockout_events,zero_entries,recovery_events,
            longest_low_streak,longest_zero_streak,current_zero_streak,current_low_streak,net_change,last_delta,
            last_movement_ts,last_positive_ts,classification,priority_label,priority_score,diagnosis
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    def finalize(s):
        if not s:
            return
        n = s["n"]
        low_ratio = s["low_count"] / n
        zero_ratio = s["zero_count"] / n
        net_change = s["current_balance"] - s["first_balance"]
        s["net_change"] = net_change
        classification, priority, score, diagnosis = classify_state(s, cfg)
        con.execute(insert_sql, (
            s["entity_key"], s["id_cliente"], s["telefono"], s["categoria"], s["nombre"], s["comercio"],
            s["first_ts"], s["last_ts"], n, s["first_balance"], s["current_balance"], s["min_balance"], s["max_balance"], s["sum_balance"] / n,
            s["low_count"], s["zero_count"], low_ratio, zero_ratio, s["changes_count"], s["increase_count"], s["decrease_count"], s["total_movement"],
            s["total_drop"], s["total_recharge"], s["biggest_drop"], s["biggest_recharge"], s["sharp_drops"], s["stockout_events"], s["zero_entries"], s["recovery_events"],
            s["max_low_streak"], s["max_zero_streak"], s["zero_streak"], s["low_streak"], net_change, s["last_delta"],
            s["last_movement_ts"], s["last_positive_ts"], classification, priority, score, diagnosis,
        ))

    state = None
    for row in cur:
        key = row["entity_key"]
        bal = float(row["balance"])
        is_low = bal <= low
        is_zero = abs(bal) <= EPS_ZERO
        if state is None or state["entity_key"] != key:
            finalize(state)
            state = {
                "entity_key": key, "id_cliente": row["id_cliente"], "telefono": row["telefono"],
                "categoria": row["categoria"], "nombre": row["nombre"], "comercio": row["comercio"],
                "first_ts": row["ts"], "last_ts": row["ts"], "n": 1,
                "first_balance": bal, "current_balance": bal, "min_balance": bal, "max_balance": bal,
                "sum_balance": bal, "low_count": 1 if is_low else 0, "zero_count": 1 if is_zero else 0,
                "changes_count": 0, "increase_count": 0, "decrease_count": 0, "total_movement": 0.0,
                "total_drop": 0.0, "total_recharge": 0.0, "biggest_drop": 0.0, "biggest_recharge": 0.0,
                "sharp_drops": 0, "stockout_events": 0, "zero_entries": 0, "recovery_events": 0,
                "low_streak": 1 if is_low else 0, "max_low_streak": 1 if is_low else 0,
                "zero_streak": 1 if is_zero else 0, "max_zero_streak": 1 if is_zero else 0,
                "prev_balance": bal, "last_delta": 0.0, "last_movement_ts": None,
                "last_positive_ts": row["ts"] if bal > EPS_ZERO else None,
            }
            continue

        prev = state["prev_balance"]
        delta = bal - prev
        moved = abs(delta) >= EPS_MOVE
        state["n"] += 1
        state["categoria"] = row["categoria"] or state["categoria"]
        state["nombre"] = row["nombre"] or state["nombre"]
        state["comercio"] = row["comercio"] or state["comercio"]
        state["last_ts"] = row["ts"]
        state["current_balance"] = bal
        state["min_balance"] = min(state["min_balance"], bal)
        state["max_balance"] = max(state["max_balance"], bal)
        state["sum_balance"] += bal
        if is_low:
            state["low_count"] += 1
            state["low_streak"] += 1
            state["max_low_streak"] = max(state["max_low_streak"], state["low_streak"])
        else:
            state["low_streak"] = 0
        if is_zero:
            state["zero_count"] += 1
            state["zero_streak"] += 1
            state["max_zero_streak"] = max(state["max_zero_streak"], state["zero_streak"])
        else:
            state["zero_streak"] = 0
            state["last_positive_ts"] = row["ts"]
        if moved:
            state["changes_count"] += 1
            state["total_movement"] += abs(delta)
            state["last_movement_ts"] = row["ts"]
            state["last_delta"] = delta
            if delta < 0:
                drop = -delta
                state["decrease_count"] += 1
                state["total_drop"] += drop
                state["biggest_drop"] = max(state["biggest_drop"], drop)
                if drop >= sharp:
                    state["sharp_drops"] += 1
            else:
                state["increase_count"] += 1
                state["total_recharge"] += delta
                state["biggest_recharge"] = max(state["biggest_recharge"], delta)
        if prev > low and bal <= low:
            state["stockout_events"] += 1
        if prev > EPS_ZERO and bal <= EPS_ZERO:
            state["zero_entries"] += 1
        if prev <= low and bal > low:
            state["recovery_events"] += 1
        state["prev_balance"] = bal

    finalize(state)
    con.commit()


def candidate_files(folder: Path):
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d.lower() not in {".trash", "$recycle.bin", "system volume information"}]
        for name in files:
            p = Path(root) / name
            if p.suffix.lower() in {".csv", ".zip"}:
                yield p


def request_scan(rebuild: bool = False, reset_source: bool = False) -> dict:
    with REQUEST_LOCK:
        if rebuild:
            SCAN_REQUEST["rebuild"] = True
        if reset_source:
            SCAN_REQUEST["reset_source"] = True
        SCAN_REQUEST_EVENT.set()
    with STATUS_LOCK:
        already = bool(RUNTIME_STATUS["scanning"])
        RUNTIME_STATUS["scan_pending"] = already
        msg = (
            "Hay un escaneo en curso. La actualización quedó en cola." if already
            else "Actualización solicitada. El monitor comenzará a leer la carpeta."
        )
        RUNTIME_STATUS["last_scan_message"] = msg
    return {"ok": True, "queued": already, "message": msg}


def run_scan(rebuild: bool = False, reset_source: bool = False) -> dict:
    with SCAN_LOCK:
        try:
            with STATUS_LOCK:
                RUNTIME_STATUS.update({
                    "scanning": True, "scan_pending": False, "phase": "DISCOVERING",
                    "last_scan_started": datetime.now().isoformat(timespec="seconds"), "last_error": None,
                    "files_found": 0, "files_processed": 0, "rows_read": 0, "errors": 0, "current_file": None,
                })
            cfg = load_config()
            raw_folder = str(cfg.get("carpeta_reportes", "")).strip()
            if not raw_folder:
                msg = "Configura primero la carpeta de reportes de Drive Desktop."
                with STATUS_LOCK: RUNTIME_STATUS["last_scan_message"] = msg
                return {"ok": False, "message": msg}
            folder = Path(os.path.expandvars(os.path.expanduser(raw_folder)))
            if not folder.exists() or not folder.is_dir():
                msg = f"La carpeta no existe o no está disponible: {folder}"
                with STATUS_LOCK: RUNTIME_STATUS["last_scan_message"] = msg
                return {"ok": False, "message": msg}

            files_to_check = list(candidate_files(folder))
            current_paths = {str(p) for p in files_to_check}
            scanned = len(files_to_check)
            processed = rows = errors = 0
            with STATUS_LOCK:
                RUNTIME_STATUS["files_found"] = scanned
                RUNTIME_STATUS["phase"] = "PROCESSING"
                RUNTIME_STATUS["last_scan_message"] = f"{scanned} archivos encontrados. Revisando histórico…"

            with db_connect() as con:
                if reset_source:
                    con.execute("DELETE FROM observations")
                    con.execute("DELETE FROM ingested_files")
                    con.execute("DELETE FROM client_stats")
                    con.commit()
                else:
                    # Remove historical rows belonging to files that were deleted from the selected folder.
                    old_paths = [r["path"] for r in con.execute("SELECT path FROM ingested_files")]
                    removed = [p for p in old_paths if p not in current_paths]
                    for old in removed:
                        con.execute("DELETE FROM observations WHERE source_file=? OR source_file LIKE ?", (old, old + "::%"))
                        con.execute("DELETE FROM ingested_files WHERE path=?", (old,))
                    if removed:
                        rebuild = True
                        con.commit()

                for index, path in enumerate(files_to_check, 1):
                    with STATUS_LOCK:
                        RUNTIME_STATUS["current_file"] = path.name
                        RUNTIME_STATUS["last_scan_message"] = f"Revisando {index} de {scanned}: {path.name}"
                    try:
                        st = path.stat()
                    except OSError:
                        errors += 1
                        continue
                    prior = con.execute("SELECT size,mtime_ns,status FROM ingested_files WHERE path=?", (str(path),)).fetchone()
                    unchanged = prior and int(prior["size"]) == int(st.st_size) and int(prior["mtime_ns"]) == int(st.st_mtime_ns) and prior["status"] == "OK"
                    if unchanged:
                        continue
                    loaded, err = ingest_one_file(path, con)
                    processed += 1
                    rows += loaded
                    status = "ERROR" if err else "OK"
                    if err: errors += 1
                    con.execute(
                        """
                        INSERT INTO ingested_files(path,size,mtime_ns,rows_loaded,status,error,processed_at)
                        VALUES(?,?,?,?,?,?,?)
                        ON CONFLICT(path) DO UPDATE SET size=excluded.size,mtime_ns=excluded.mtime_ns,
                        rows_loaded=excluded.rows_loaded,status=excluded.status,error=excluded.error,processed_at=excluded.processed_at
                        """,
                        (str(path), st.st_size, st.st_mtime_ns, loaded, status, err, datetime.now().isoformat(timespec="seconds")),
                    )
                    con.commit()
                    with STATUS_LOCK:
                        RUNTIME_STATUS["files_processed"] = processed
                        RUNTIME_STATUS["rows_read"] = rows
                        RUNTIME_STATUS["errors"] = errors

                if processed or rebuild or reset_source:
                    with STATUS_LOCK:
                        RUNTIME_STATUS["phase"] = "REBUILDING"
                        RUNTIME_STATUS["current_file"] = None
                        RUNTIME_STATUS["last_scan_message"] = "Clasificando bajas y reconstruyendo comportamiento…"
                    rebuild_stats(con, cfg)

            msg = f"Listo: {scanned} archivo(s), {processed} nuevo(s)/cambiado(s), {rows:,} filas leídas, {errors} error(es)."
            with STATUS_LOCK:
                RUNTIME_STATUS.update({
                    "last_scan_message": msg, "last_scan_finished": datetime.now().isoformat(timespec="seconds"),
                    "files_found": scanned, "files_processed": processed, "rows_read": rows, "errors": errors,
                })
            return {"ok": errors == 0, "message": msg, "files_found": scanned, "files_processed": processed, "rows_read": rows, "errors": errors}
        except Exception as exc:
            err = f"{type(exc).__name__}: {exc}"
            with STATUS_LOCK:
                RUNTIME_STATUS["last_error"] = err
                RUNTIME_STATUS["last_scan_message"] = err
            traceback.print_exc()
            return {"ok": False, "message": err}
        finally:
            with STATUS_LOCK:
                RUNTIME_STATUS["scanning"] = False
                RUNTIME_STATUS["phase"] = "IDLE"
                RUNTIME_STATUS["current_file"] = None
                if RUNTIME_STATUS["last_scan_finished"] is None:
                    RUNTIME_STATUS["last_scan_finished"] = datetime.now().isoformat(timespec="seconds")


def background_scanner():
    time.sleep(1)
    SCAN_REQUEST_EVENT.set()
    while True:
        cfg = load_config()
        seconds = max(60, int(cfg.get("escaneo_segundos", 300)))
        triggered = SCAN_REQUEST_EVENT.wait(timeout=seconds)
        rebuild = reset_source = False
        if triggered:
            with REQUEST_LOCK:
                rebuild = bool(SCAN_REQUEST.get("rebuild"))
                reset_source = bool(SCAN_REQUEST.get("reset_source"))
                SCAN_REQUEST["rebuild"] = False
                SCAN_REQUEST["reset_source"] = False
                SCAN_REQUEST_EVENT.clear()
        run_scan(rebuild=rebuild, reset_source=reset_source)
        if SCAN_REQUEST_EVENT.is_set():
            continue


def db_status() -> dict:
    cfg = load_config()
    low = float(cfg.get("saldo_bajo", 5.0))
    critical = float(cfg.get("saldo_critico", 1.0))
    with db_connect() as con:
        obs = con.execute("SELECT COUNT(*) c,COUNT(DISTINCT entity_key) clients,COUNT(DISTINCT ts) snapshots,MIN(ts) min_ts,MAX(ts) max_ts FROM observations").fetchone()
        files = con.execute("SELECT COUNT(*) c,SUM(CASE WHEN status='ERROR' THEN 1 ELSE 0 END) errors FROM ingested_files").fetchone()
        counts = {r["classification"]: r["c"] for r in con.execute("SELECT classification,COUNT(*) c FROM client_stats GROUP BY classification")}
        attention = counts.get("ATENCION", 0)
        bajas = counts.get("BAJA", 0)
        no_move = counts.get("SIN_MOVIMIENTO", 0)
        pending = counts.get("POR_CONFIRMAR", 0)
        urgent = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND priority_label='URGENTE'").fetchone()["c"]
        high = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND priority_label='ALTA'").fetchone()["c"]
        quiebre_moving = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND current_balance<=?", (low,)).fetchone()["c"]
        zero_moving = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND ABS(current_balance)<=?", (EPS_ZERO,)).fetchone()["c"]
        recovered = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND recovery_events>0 AND current_balance>?", (low,)).fetchone()["c"]
        falling = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND last_delta<?", (-EPS_MOVE,)).fetchone()["c"]
        recharging = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND last_delta>?", (EPS_MOVE,)).fetchone()["c"]
        recurrent = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND stockout_events>=2").fetchone()["c"]
        critical_now = con.execute("SELECT COUNT(*) c FROM client_stats WHERE classification='ATENCION' AND current_balance<=?", (critical,)).fetchone()["c"]
        total_balance = con.execute("SELECT SUM(current_balance) v FROM client_stats").fetchone()["v"] or 0
        movement_value = con.execute("SELECT SUM(total_movement) v FROM client_stats WHERE classification='ATENCION'").fetchone()["v"] or 0

    folder = str(cfg.get("carpeta_reportes", ""))
    resolved = Path(os.path.expandvars(os.path.expanduser(folder))) if folder else None
    with STATUS_LOCK:
        runtime = dict(RUNTIME_STATUS)
    return {
        "config": cfg, "folder_exists": bool(resolved and resolved.exists() and resolved.is_dir()),
        "observations": obs["c"] or 0, "clients": obs["clients"] or 0, "snapshots": obs["snapshots"] or 0,
        "first_ts": obs["min_ts"], "last_ts": obs["max_ts"], "files": files["c"] or 0, "file_errors": files["errors"] or 0,
        "attention": attention, "bajas": bajas, "no_movement": no_move, "pending": pending,
        "urgent": urgent, "high": high, "quiebre_moving": quiebre_moving, "zero_moving": zero_moving,
        "recovered": recovered, "falling": falling, "recharging": recharging, "recurrent": recurrent,
        "critical_now": critical_now, "total_balance": round(float(total_balance), 2), "movement_value": round(float(movement_value), 2),
        "runtime": runtime,
    }


def get_summary(params: dict) -> dict:
    q = (params.get("q", [""])[0] or "").strip()
    classification = (params.get("class", [""])[0] or "").strip().upper()
    priority = (params.get("priority", [""])[0] or "").strip().upper()
    condition = (params.get("condition", [""])[0] or "").strip().lower()
    sort = (params.get("sort", ["priority_score"])[0] or "priority_score").strip()
    direction = (params.get("dir", ["desc"])[0] or "desc").strip().lower()
    try:
        limit = min(5000, max(20, int(params.get("limit", [500])[0])))
    except Exception:
        limit = 500

    allowed_sort = {
        "priority_score": "priority_score", "current_balance": "current_balance", "changes_count": "changes_count",
        "total_movement": "total_movement", "stockout_events": "stockout_events", "sharp_drops": "sharp_drops",
        "zero_ratio": "zero_ratio", "low_ratio": "low_ratio", "observations": "observations", "last_ts": "last_ts",
        "last_movement_ts": "last_movement_ts", "net_change": "net_change",
    }
    sort_col = allowed_sort.get(sort, "priority_score")
    dir_sql = "ASC" if direction == "asc" else "DESC"
    where, args = [], []
    if q:
        where.append("(id_cliente LIKE ? OR telefono LIKE ? OR comercio LIKE ? OR nombre LIKE ?)")
        like = f"%{q}%"
        args.extend([like, like, like, like])
    if classification in {"ATENCION", "BAJA", "SIN_MOVIMIENTO", "POR_CONFIRMAR"}:
        where.append("classification=?")
        args.append(classification)
    if priority in {"URGENTE", "ALTA", "MEDIA", "SEGUIMIENTO", "OBSERVAR", "BAJA", "PENDIENTE"}:
        where.append("priority_label=?")
        args.append(priority)
    cfg = load_config(); low = float(cfg.get("saldo_bajo", 5.0))
    if condition == "quiebre":
        where.append("classification='ATENCION' AND current_balance<=?")
        args.append(low)
    elif condition == "reincidente":
        where.append("classification='ATENCION' AND stockout_events>=2")
    elif condition == "cayendo":
        where.append("classification='ATENCION' AND last_delta<?")
        args.append(-EPS_MOVE)
    elif condition == "recargando":
        where.append("classification='ATENCION' AND last_delta>?")
        args.append(EPS_MOVE)
    elif condition == "recuperado":
        where.append("classification='ATENCION' AND recovery_events>0 AND current_balance>?")
        args.append(low)
    where_sql = " WHERE " + " AND ".join(where) if where else ""
    with db_connect() as con:
        total = con.execute(f"SELECT COUNT(*) c FROM client_stats{where_sql}", args).fetchone()["c"]
        rows = con.execute(
            f"""SELECT * FROM client_stats {where_sql}
            ORDER BY {sort_col} {dir_sql}, priority_score DESC, id_cliente, telefono LIMIT ?""",
            args + [limit],
        ).fetchall()
    return {"total": total, "rows": [dict(r) for r in rows]}


def daily_aggregate(raw: list[dict]) -> list[dict]:
    days = {}
    prev_global = None
    for r in raw:
        day = r["ts"][:10]
        d = days.setdefault(day, {"date": day, "samples": 0, "open": r["balance"], "close": r["balance"], "min": r["balance"], "max": r["balance"], "changes": 0, "drops": 0.0, "recharges": 0.0})
        d["samples"] += 1
        d["close"] = r["balance"]
        d["min"] = min(d["min"], r["balance"])
        d["max"] = max(d["max"], r["balance"])
        if prev_global is not None:
            delta = r["balance"] - prev_global
            if abs(delta) >= EPS_MOVE:
                d["changes"] += 1
                if delta < 0: d["drops"] += -delta
                else: d["recharges"] += delta
        prev_global = r["balance"]
    return list(reversed(list(days.values())))


def behavior_summary(stat: dict) -> list[str]:
    bullets = []
    n = int(stat.get("observations") or 0)
    if stat.get("classification") == "BAJA":
        bullets.append(f"Baja confirmada: las {n} tomas disponibles están en $0.00.")
        bullets.append("Nunca aparece saldo positivo en el histórico cargado.")
    elif stat.get("classification") == "ATENCION":
        bullets.append(f"Registró {stat.get('changes_count',0)} cambio(s) de saldo y ${float(stat.get('total_movement') or 0):,.2f} de movimiento acumulado.")
        if int(stat.get("stockout_events") or 0) > 0:
            bullets.append(f"Entró a saldo bajo {stat.get('stockout_events')} vez/veces y se recuperó {stat.get('recovery_events')} vez/veces.")
        if abs(float(stat.get("current_balance") or 0)) <= EPS_ZERO and float(stat.get("max_balance") or 0) > EPS_ZERO:
            bullets.append("Está en $0.00 ahora, pero tuvo saldo antes: es un caso activo en atención, no una baja.")
        elif float(stat.get("last_delta") or 0) < -EPS_MOVE:
            bullets.append(f"Su último movimiento fue una caída de ${abs(float(stat.get('last_delta') or 0)):,.2f}.")
        elif float(stat.get("last_delta") or 0) > EPS_MOVE:
            bullets.append(f"Su último movimiento fue una recarga de ${float(stat.get('last_delta') or 0):,.2f}.")
    elif stat.get("classification") == "SIN_MOVIMIENTO":
        bullets.append(f"Mantiene el mismo saldo (${float(stat.get('current_balance') or 0):,.2f}) durante {n} tomas.")
        bullets.append("No es baja porque su saldo histórico no es $0.00.")
    else:
        bullets.append("Todavía no hay suficientes tomas para confirmar si es baja, atención o sin movimiento.")
    return bullets


def get_client(entity_key: str) -> dict | None:
    cfg = load_config()
    low = float(cfg.get("saldo_bajo", 5.0))
    critical = float(cfg.get("saldo_critico", 1.0))
    sharp = float(cfg.get("caida_fuerte", 20.0))
    with db_connect() as con:
        stat_row = con.execute("SELECT * FROM client_stats WHERE entity_key=? LIMIT 1", (entity_key,)).fetchone()
        if not stat_row:
            # Backward-friendly lookup by ID or phone if the UI/user supplies one.
            stat_row = con.execute("SELECT * FROM client_stats WHERE id_cliente=? OR telefono=? ORDER BY priority_score DESC LIMIT 1", (entity_key, entity_key)).fetchone()
        if not stat_row:
            return None
        stat = dict(stat_row)
        key = stat["entity_key"]
        rows = con.execute("SELECT ts,balance FROM observations WHERE entity_key=? ORDER BY ts", (key,)).fetchall()

    raw = [{"ts": r["ts"], "balance": float(r["balance"])} for r in rows]
    events = []
    prev = None
    for r in raw:
        delta = None if prev is None else r["balance"] - prev
        if prev is None:
            if abs(r["balance"]) <= EPS_ZERO:
                event = "INICIO EN $0"
            elif r["balance"] <= low:
                event = "INICIO SALDO BAJO"
            else:
                event = "INICIO"
        elif abs(r["balance"]) <= EPS_ZERO and prev > EPS_ZERO:
            event = "ENTRÓ A $0"
        elif r["balance"] <= low and prev > low:
            event = "ENTRÓ A SALDO BAJO"
        elif r["balance"] > low and prev <= low:
            event = "RECUPERACIÓN"
        elif abs(delta) < EPS_MOVE:
            event = "SIN CAMBIO"
        elif delta <= -sharp:
            event = "CAÍDA FUERTE"
        elif delta >= sharp:
            event = "RECARGA FUERTE"
        elif delta < 0:
            event = "CONSUMO"
        else:
            event = "RECARGA"
        events.append({"ts": r["ts"], "balance": r["balance"], "delta": delta, "event": event})
        prev = r["balance"]

    chart = raw
    if len(raw) > 5000:
        step = math.ceil(len(raw) / 5000)
        chart = raw[::step]
        if chart[-1] != raw[-1]: chart.append(raw[-1])
    return {
        "stats": stat, "chart": chart, "events": list(reversed(events)), "daily": daily_aggregate(raw),
        "summary": behavior_summary(stat), "thresholds": {"low": low, "critical": critical, "sharp": sharp},
    }


def export_client_csv(entity_key: str) -> bytes | None:
    data = get_client(entity_key)
    if not data:
        return None
    output = io.StringIO(newline="")
    w = csv.writer(output)
    w.writerow(["FechaHora", "IdCliente", "Telefono", "Comercio", "Balance", "Variacion", "Evento", "Clasificacion"])
    s = data["stats"]
    for e in reversed(data["events"]):
        w.writerow([e["ts"], s["id_cliente"], s["telefono"], s["comercio"], f"{e['balance']:.2f}", "" if e["delta"] is None else f"{e['delta']:.2f}", e["event"], s["classification"]])
    return output.getvalue().encode("utf-8-sig")


def pick_folder_windows() -> str:
    if os.name != "nt":
        return ""
    ps = r'''Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = "Selecciona la carpeta de reportes de saldos"
$dialog.ShowNewFolderButton = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Output $dialog.SelectedPath
}'''
    try:
        cp = subprocess.run(["powershell.exe", "-NoProfile", "-STA", "-Command", ps], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        return (cp.stdout or "").strip()
    except Exception:
        return ""


def preview_folder(raw_folder: str) -> dict:
    folder = Path(os.path.expandvars(os.path.expanduser(str(raw_folder).strip()))) if raw_folder else None
    if not folder or not folder.exists() or not folder.is_dir():
        return {"ok": False, "folder": str(raw_folder or ""), "files": 0, "message": "La carpeta no existe o no está disponible."}
    count = 0
    try:
        for _ in candidate_files(folder):
            count += 1
            if count >= 100000: break
    except Exception as exc:
        return {"ok": False, "folder": str(folder), "files": count, "message": f"No se pudo revisar la carpeta: {exc}"}
    return {"ok": True, "folder": str(folder), "files": count, "message": f"Carpeta válida: {count:,} archivo(s) CSV/ZIP encontrado(s)."}


INDEX_CACHE = None

def load_index() -> bytes:
    global INDEX_CACHE
    if INDEX_CACHE is None:
        INDEX_CACHE = (WEB_DIR / "index.html").read_bytes()
    return INDEX_CACHE


class Handler(BaseHTTPRequestHandler):
    server_version = "BalanceMonitor/1.4"

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def send_bytes(self, body: bytes, content_type: str, status=200, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra_headers:
            for k, v in extra_headers.items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_bytes(json.dumps(obj, ensure_ascii=False, default=str).encode("utf-8"), "application/json; charset=utf-8", status)

    def read_json(self):
        try: length = int(self.headers.get("Content-Length", "0"))
        except ValueError: length = 0
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path, params = parsed.path, urllib.parse.parse_qs(parsed.query)
        try:
            if path == "/": return self.send_bytes(load_index(), "text/html; charset=utf-8")
            if path == "/styles.css": return self.send_bytes((WEB_DIR / "styles.css").read_bytes(), "text/css; charset=utf-8")
            if path == "/app.js": return self.send_bytes((WEB_DIR / "app.js").read_bytes(), "text/javascript; charset=utf-8")
            if path == "/api/folder-preview": return self.send_json(preview_folder((params.get("path", [""])[0] or "").strip()))
            if path == "/api/status": return self.send_json(db_status())
            if path == "/api/summary": return self.send_json(get_summary(params))
            if path == "/api/client":
                ident = (params.get("key", [""])[0] or params.get("id", [""])[0] or "").strip()
                data = get_client(ident) if ident else None
                return self.send_json(data or {"error": "Cliente no encontrado"}, 200 if data else 404)
            if path == "/api/client-export":
                ident = (params.get("key", [""])[0] or "").strip()
                body = export_client_csv(ident) if ident else None
                if not body: return self.send_json({"error": "Cliente no encontrado"}, 404)
                safe = "historial_saldo.csv"
                return self.send_bytes(body, "text/csv; charset=utf-8", 200, {"Content-Disposition": f'attachment; filename="{safe}"'})
            return self.send_json({"error": "No encontrado"}, 404)
        except Exception as exc:
            traceback.print_exc()
            return self.send_json({"error": f"{type(exc).__name__}: {exc}"}, 500)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path == "/api/pick-folder":
                self.read_json(); chosen = pick_folder_windows()
                return self.send_json({"ok": bool(chosen), "folder": chosen, "cancelled": not bool(chosen)})
            if parsed.path == "/api/config":
                payload = self.read_json(); old = load_config(); cfg = dict(old)
                if "carpeta_reportes" in payload: cfg["carpeta_reportes"] = str(payload["carpeta_reportes"]).strip()
                for key in ("saldo_bajo", "saldo_critico", "caida_fuerte"):
                    if key in payload:
                        value = float(payload[key])
                        if value < 0: raise ValueError(f"{key} no puede ser negativo")
                        cfg[key] = value
                if "min_tomas_baja" in payload: cfg["min_tomas_baja"] = max(2, min(48, int(payload["min_tomas_baja"])))
                if "escaneo_segundos" in payload: cfg["escaneo_segundos"] = max(60, int(payload["escaneo_segundos"]))
                if float(cfg["saldo_critico"]) > float(cfg["saldo_bajo"]): raise ValueError("El saldo crítico debe ser menor o igual que el saldo bajo")
                folder_changed = cfg.get("carpeta_reportes") != old.get("carpeta_reportes")
                rules_changed = any(cfg.get(k) != old.get(k) for k in ("saldo_bajo","saldo_critico","caida_fuerte","min_tomas_baja"))
                save_config(cfg)
                result = request_scan(rebuild=rules_changed, reset_source=folder_changed)
                return self.send_json({"ok": True, "scan": result, "config": load_config()})
            if parsed.path == "/api/scan":
                self.read_json(); return self.send_json(request_scan())
            if parsed.path == "/api/rebuild":
                self.read_json(); return self.send_json(request_scan(rebuild=True, reset_source=True))
            return self.send_json({"error": "No encontrado"}, 404)
        except Exception as exc:
            traceback.print_exc(); return self.send_json({"error": f"{type(exc).__name__}: {exc}"}, 500)


def main():
    init_db()
    cfg = load_config(); port = int(cfg.get("puerto", 43120))
    threading.Thread(target=background_scanner, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("=" * 72)
    print(" MONITOR DE COMPORTAMIENTO DE SALDOS v1.4")
    print(f" Web: http://127.0.0.1:{port}")
    print(f" Base local: {DB_PATH}")
    print(" Lógica: BAJA = siempre $0.00; ATENCIÓN = existe movimiento histórico.")
    print("=" * 72)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == "__main__":
    main()
