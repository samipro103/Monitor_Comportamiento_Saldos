from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import socket
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import zipfile
from datetime import datetime, timezone, timedelta
from pathlib import Path

APP_NAME = "Monitor Saldos - Agente Supabase"
VERSION = "1.1"

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"
STATE_PATH = BASE_DIR / "agent_state.json"
LOG_PATH = BASE_DIR / "agent.log"

SUPPORTED = {".csv", ".zip"}

ALIASES = {
    "day": {
        "dia", "fecha", "fecha reporte", "fecha de reporte"
    },
    "time": {
        "hora", "hora reporte", "hora de reporte"
    },
    "phone": {
        "telefono", "tel", "telefono epin", "numero telefono",
        "numero de telefono", "movil"
    },
    "commerce": {
        "nombre de comercio", "comercio", "punto", "nombre comercio",
        "nombre del comercio"
    },
    "balance": {
        "balance billetera", "balance de billetera", "balance",
        "saldo", "saldo billetera", "saldo de billetera"
    },
    "id_client": {
        "id cliente", "idcliente", "id dms", "id_dms",
        "codigo cliente", "cod cliente", "cod point", "cod.point"
    },
}

def log(msg: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    print(line, flush=True)
    try:
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass

def normalize(text: str | None) -> str:
    text = "" if text is None else str(text)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.strip().lower()
    out = []
    last_space = False
    for ch in text:
        if ch.isalnum() or ch in {"_", "."}:
            out.append(ch)
            last_space = False
        else:
            if not last_space:
                out.append(" ")
                last_space = True
    return " ".join("".join(out).split())

def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)

def load_config() -> dict:
    cfg = load_json(CONFIG_PATH, {})
    required = ["supabase_url", "publishable_key", "ingest_key", "source_folder"]
    missing = [x for x in required if not str(cfg.get(x, "")).strip()]
    if missing:
        raise RuntimeError(
            "Falta configuración: " + ", ".join(missing) +
            ". Ejecuta CONFIGURAR_AGENTE.bat."
        )
    cfg.setdefault("interval_minutes", 5)
    cfg.setdefault("utc_offset", "-06:00")
    cfg["supabase_url"] = cfg["supabase_url"].rstrip("/")
    return cfg

def machine_id() -> str:
    state = load_json(STATE_PATH, {})
    mid = state.get("machine_id")
    if mid:
        return mid
    mid = str(uuid.uuid4())
    state["machine_id"] = mid
    state.setdefault("files", {})
    save_json(STATE_PATH, state)
    return mid

def read_text_bytes(data: bytes) -> str:
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")

def read_csv_text(path: Path) -> str:
    if path.suffix.lower() == ".csv":
        return read_text_bytes(path.read_bytes())

    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path, "r") as zf:
            csv_names = [
                n for n in zf.namelist()
                if not n.endswith("/") and Path(n).suffix.lower() == ".csv"
            ]
            if not csv_names:
                raise RuntimeError("El ZIP no contiene ningún CSV.")
            if len(csv_names) > 1:
                csv_names.sort()
            return read_text_bytes(zf.read(csv_names[0]))

    raise RuntimeError("Tipo de archivo no soportado.")

def map_headers(fieldnames) -> dict:
    normalized = {normalize(h): h for h in (fieldnames or [])}
    result = {}

    for logical, names in ALIASES.items():
        for alias in names:
            if alias in normalized:
                result[logical] = normalized[alias]
                break

    required = ["day", "time", "balance", "id_client"]
    missing = [x for x in required if x not in result]
    if missing:
        raise RuntimeError(
            "Faltan columnas requeridas: " + ", ".join(missing) +
            ". Columnas encontradas: " + ", ".join(fieldnames or [])
        )
    return result

def parse_number(value) -> float:
    if value is None:
        raise ValueError("saldo vacío")
    s = str(value).strip().replace("$", "").replace(" ", "")
    if not s:
        raise ValueError("saldo vacío")

    # Maneja tanto 1,234.56 como 1.234,56 y números simples.
    if "," in s and "." in s:
        if s.rfind(",") > s.rfind("."):
            s = s.replace(".", "").replace(",", ".")
        else:
            s = s.replace(",", "")
    elif "," in s:
        # Si solo hay coma, asumimos coma decimal.
        s = s.replace(",", ".")

    return round(float(s), 2)

def parse_date_time(day: str, tm: str, utc_offset: str) -> str:
    day = str(day).strip()
    tm = str(tm).strip()

    dt = None
    patterns = [
        "%d/%m/%Y %H:%M:%S",
        "%d/%m/%Y %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%d-%m-%Y %H:%M:%S",
        "%d-%m-%Y %H:%M",
    ]
    combo = f"{day} {tm}"
    for p in patterns:
        try:
            dt = datetime.strptime(combo, p)
            break
        except ValueError:
            pass

    if dt is None:
        raise ValueError(f"Fecha/hora no reconocida: {combo}")

    sign = 1 if utc_offset.startswith("+") else -1
    hh, mm = utc_offset[1:].split(":")
    offset = timezone(sign * timedelta(hours=int(hh), minutes=int(mm)))
    dt = dt.replace(tzinfo=offset)
    return dt.isoformat(timespec="seconds")

def inspect_file(path: Path, utc_offset: str) -> dict:
    text = read_csv_text(path)
    reader = csv.DictReader(io.StringIO(text))
    headers = map_headers(reader.fieldnames)
    first = None
    for row in reader:
        if str(row.get(headers["id_client"], "")).strip():
            first = row
            break
    if first is None:
        raise RuntimeError("El archivo no contiene filas de datos.")

    stamp = parse_date_time(
        first.get(headers["day"], ""),
        first.get(headers["time"], ""),
        utc_offset,
    )
    return {"snapshot_at": stamp}

def parse_file(path: Path, utc_offset: str) -> tuple[str, list[dict], int]:
    text = read_csv_text(path)
    reader = csv.DictReader(io.StringIO(text))
    headers = map_headers(reader.fieldnames)

    rows = []
    invalid = 0
    timestamps = set()

    for raw in reader:
        try:
            id_client = str(raw.get(headers["id_client"], "")).strip()
            if not id_client:
                raise ValueError("ID vacío")

            balance = parse_number(raw.get(headers["balance"]))

            stamp = parse_date_time(
                raw.get(headers["day"], ""),
                raw.get(headers["time"], ""),
                utc_offset,
            )
            timestamps.add(stamp)

            phone = ""
            if "phone" in headers:
                phone = str(raw.get(headers["phone"], "") or "").strip()

            commerce = ""
            if "commerce" in headers:
                commerce = str(raw.get(headers["commerce"], "") or "").strip()

            rows.append({
                "id_client": id_client,
                "phone": phone or None,
                "commerce": commerce or None,
                "balance": balance,
            })
        except Exception:
            invalid += 1

    if not rows:
        raise RuntimeError("No se encontró ninguna fila válida.")

    if len(timestamps) != 1:
        sample = ", ".join(sorted(timestamps)[:5])
        raise RuntimeError(
            "El archivo contiene más de una fecha/hora de toma. "
            f"Encontradas: {sample}"
        )

    return next(iter(timestamps)), rows, invalid

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def rpc(cfg: dict, fn: str, payload: dict, timeout: int = 180):
    url = f"{cfg['supabase_url']}/rest/v1/rpc/{fn}"
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "apikey": cfg["publishable_key"],
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": f"MonitorSaldosAgent/{VERSION}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"No se pudo conectar: {e.reason}") from e

def test_connection(cfg: dict) -> None:
    log("Probando conexión segura con Supabase...")
    result = rpc(cfg, "ingest_ping", {"p_ingest_key": cfg["ingest_key"]}, timeout=30)
    if result.get("ok"):
        log(
            f"CONEXIÓN CORRECTA. Archivos centralizados: "
            f"{result.get('files_loaded', 0)}"
        )
    else:
        raise RuntimeError(f"Respuesta inesperada: {result}")

def scan_files(folder: Path) -> list[Path]:
    files = []
    for p in folder.rglob("*"):
        try:
            if p.is_file() and p.suffix.lower() in SUPPORTED:
                files.append(p)
        except OSError:
            pass
    return files

def synchronize_once(cfg: dict, dry_run: bool = False) -> dict:
    folder = Path(cfg["source_folder"])
    if not folder.exists():
        raise RuntimeError(f"La carpeta no existe: {folder}")

    state = load_json(STATE_PATH, {"files": {}})
    state.setdefault("machine_id", machine_id())
    state.setdefault("files", {})
    files_state = state["files"]

    found = scan_files(folder)
    log(f"Archivos CSV/ZIP encontrados: {len(found)}")

    pending = []

    for path in found:
        key = str(path.resolve())
        try:
            st = path.stat()
        except OSError:
            continue

        meta = files_state.get(key, {})
        same = (
            meta.get("size") == st.st_size
            and meta.get("mtime_ns") == st.st_mtime_ns
            and meta.get("uploaded") is True
        )
        if same:
            continue

        try:
            info = inspect_file(path, cfg["utc_offset"])
            pending.append((info["snapshot_at"], path, st))
        except Exception as exc:
            log(f"OMITIDO {path.name}: {exc}")
            files_state[key] = {
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "uploaded": False,
                "error": str(exc),
            }

    pending.sort(key=lambda x: (x[0], str(x[1]).lower()))

    # ---------------------------------------------------------
    # UNA SOLA FOTO POR FECHA/HORA
    #
    # En algunas carpetas existen descargas repetidas del mismo
    # reporte horario con distinto nombre. Contarlas dos veces
    # falsearía total_snapshots, quiebres y porcentajes.
    #
    # Para cada timestamp conservamos el archivo de mayor tamaño
    # (normalmente la exportación más completa) y omitimos el resto.
    # ---------------------------------------------------------
    by_snapshot = {}
    duplicate_snapshot_files = []

    for stamp, path, st in pending:
        current = by_snapshot.get(stamp)
        if current is None:
            by_snapshot[stamp] = (stamp, path, st)
            continue

        _, current_path, current_st = current

        choose_new = (
            st.st_size > current_st.st_size
            or (
                st.st_size == current_st.st_size
                and st.st_mtime_ns > current_st.st_mtime_ns
            )
        )

        if choose_new:
            duplicate_snapshot_files.append((stamp, current_path, current_st))
            by_snapshot[stamp] = (stamp, path, st)
        else:
            duplicate_snapshot_files.append((stamp, path, st))

    pending = sorted(
        by_snapshot.values(),
        key=lambda x: (x[0], str(x[1]).lower())
    )

    if duplicate_snapshot_files:
        log(
            f"Duplicados por misma fecha/hora omitidos: "
            f"{len(duplicate_snapshot_files)}"
        )
        for stamp, path, st in duplicate_snapshot_files:
            key = str(path.resolve())
            files_state[key] = {
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "uploaded": True,
                "ignored": True,
                "reason": "DUPLICADO_MISMA_TOMA",
                "snapshot_at": stamp,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            }

    log(f"Tomas únicas pendientes: {len(pending)}")

    ok_count = 0
    dup_count = 0
    err_count = 0
    sent_rows = 0

    for idx, (stamp_preview, path, st) in enumerate(pending, 1):
        key = str(path.resolve())
        log(
            f"[{idx}/{len(pending)}] Procesando {path.name} "
            f"({stamp_preview})"
        )

        try:
            file_hash = sha256_file(path)
            snapshot_at, rows, invalid_local = parse_file(
                path, cfg["utc_offset"]
            )

            log(
                f"  Filas válidas locales: {len(rows):,}"
                + (f" | inválidas omitidas: {invalid_local:,}" if invalid_local else "")
            )

            if dry_run:
                log("  DRY-RUN: no se envió a Supabase.")
                files_state[key] = {
                    "size": st.st_size,
                    "mtime_ns": st.st_mtime_ns,
                    "uploaded": False,
                    "hash": file_hash,
                    "snapshot_at": snapshot_at,
                    "dry_run": True,
                }
                continue

            result = rpc(
                cfg,
                "ingest_snapshot",
                {
                    "p_ingest_key": cfg["ingest_key"],
                    "p_file_name": path.name,
                    "p_file_hash": file_hash,
                    "p_snapshot_at": snapshot_at,
                    "p_machine_id": state["machine_id"],
                    "p_machine_name": socket.gethostname(),
                    "p_source_path": str(folder),
                    "p_rows": rows,
                },
                timeout=300,
            )

            if not result.get("ok"):
                raise RuntimeError(result.get("error") or str(result))

            duplicate = bool(result.get("duplicate"))
            if duplicate:
                dup_count += 1
                log("  Ya existía en Supabase. No se duplicó.")
            else:
                ok_count += 1
                n = int(result.get("rows_valid", len(rows)))
                sent_rows += n
                log(
                    f"  OK: {n:,} filas incorporadas "
                    f"| toma {result.get('snapshot_at', snapshot_at)}"
                )

            files_state[key] = {
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "uploaded": True,
                "hash": file_hash,
                "snapshot_at": snapshot_at,
                "last_result": result,
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            }
            save_json(STATE_PATH, state)

        except Exception as exc:
            err_count += 1
            log(f"  ERROR: {exc}")
            files_state[key] = {
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "uploaded": False,
                "error": str(exc),
                "updated_at": datetime.now().isoformat(timespec="seconds"),
            }
            save_json(STATE_PATH, state)

    save_json(STATE_PATH, state)

    summary = {
        "found": len(found),
        "pending": len(pending),
        "uploaded": ok_count,
        "duplicates": dup_count,
        "errors": err_count,
        "rows": sent_rows,
    }
    log(
        "RESUMEN: "
        f"{ok_count} nuevos | {dup_count} duplicados | "
        f"{err_count} errores | {sent_rows:,} filas"
    )
    return summary

def main():
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--once", action="store_true", help="Sincroniza una vez y sale")
    parser.add_argument("--test", action="store_true", help="Prueba conexión")
    parser.add_argument("--dry-run", action="store_true", help="Lee archivos sin subir")
    args = parser.parse_args()

    cfg = load_config()

    if args.test:
        test_connection(cfg)
        return

    if args.once or args.dry_run:
        synchronize_once(cfg, dry_run=args.dry_run)
        return

    minutes = max(1, int(cfg.get("interval_minutes", 5)))
    log(f"{APP_NAME} v{VERSION}")
    log(f"Carpeta: {cfg['source_folder']}")
    log(f"Frecuencia: cada {minutes} minuto(s)")
    test_connection(cfg)

    while True:
        try:
            synchronize_once(cfg)
        except KeyboardInterrupt:
            log("Agente detenido por el usuario.")
            return
        except Exception as exc:
            log(f"ERROR GENERAL: {exc}")

        log(f"Esperando {minutes} minuto(s)...")
        try:
            time.sleep(minutes * 60)
        except KeyboardInterrupt:
            log("Agente detenido por el usuario.")
            return

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log(f"ERROR FATAL: {exc}")
        sys.exit(1)
