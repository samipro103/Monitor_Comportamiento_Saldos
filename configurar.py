import json
import tkinter as tk
from tkinter import filedialog, messagebox
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.json"

def load():
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}

cfg = load()

root = tk.Tk()
root.title("Configurar Monitor de Saldos - Supabase")
root.geometry("720x500")
root.resizable(False, False)

frame = tk.Frame(root, padx=24, pady=22)
frame.pack(fill="both", expand=True)

tk.Label(frame, text="Monitor de Saldos", font=("Segoe UI", 18, "bold")).grid(
    row=0, column=0, columnspan=3, sticky="w", pady=(0, 4)
)
tk.Label(
    frame,
    text="Conecta la carpeta de Drive Desktop con Supabase.",
    font=("Segoe UI", 10),
).grid(row=1, column=0, columnspan=3, sticky="w", pady=(0, 20))

labels = [
    ("Carpeta de reportes", "source_folder"),
    ("Project URL de Supabase", "supabase_url"),
    ("Publishable Key", "publishable_key"),
    ("Clave privada de ingesta", "ingest_key"),
    ("Frecuencia (minutos)", "interval_minutes"),
    ("Zona horaria UTC", "utc_offset"),
]

entries = {}

for i, (label, key) in enumerate(labels, start=2):
    tk.Label(frame, text=label, font=("Segoe UI", 10, "bold")).grid(
        row=i, column=0, sticky="w", pady=7
    )

    show = "*" if key == "ingest_key" else None
    ent = tk.Entry(frame, width=60, font=("Segoe UI", 10), show=show)
    ent.grid(row=i, column=1, sticky="we", padx=(12, 8), pady=7)
    entries[key] = ent

    default = cfg.get(key, "")
    if key == "interval_minutes" and default == "":
        default = 5
    if key == "utc_offset" and default == "":
        default = "-06:00"
    ent.insert(0, str(default))

def choose_folder():
    folder = filedialog.askdirectory(title="Selecciona Saldos_Bitacora_Quiebre")
    if folder:
        entries["source_folder"].delete(0, tk.END)
        entries["source_folder"].insert(0, folder)

tk.Button(
    frame,
    text="Seleccionar...",
    command=choose_folder,
    font=("Segoe UI", 9),
).grid(row=2, column=2, sticky="w")

def save():
    out = {k: e.get().strip() for k, e in entries.items()}

    if not out["source_folder"]:
        messagebox.showerror("Falta dato", "Selecciona la carpeta de reportes.")
        return
    if not out["supabase_url"].startswith("https://"):
        messagebox.showerror(
            "Project URL",
            "La URL debe comenzar con https://"
        )
        return
    if not out["publishable_key"]:
        messagebox.showerror("Falta dato", "Pega la Publishable Key.")
        return
    if len(out["ingest_key"]) < 24:
        messagebox.showerror(
            "Clave de ingesta",
            "La clave de ingesta debe tener al menos 24 caracteres."
        )
        return
    try:
        out["interval_minutes"] = max(1, int(out["interval_minutes"]))
    except Exception:
        messagebox.showerror("Frecuencia", "Escribe un número de minutos.")
        return

    if not (
        len(out["utc_offset"]) == 6
        and out["utc_offset"][0] in "+-"
        and out["utc_offset"][3] == ":"
    ):
        messagebox.showerror(
            "Zona horaria",
            "Usa formato -06:00. Para El Salvador déjalo en -06:00."
        )
        return

    CONFIG_PATH.write_text(
        json.dumps(out, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    messagebox.showinfo(
        "Guardado",
        "Configuración guardada.\n\n"
        "Ahora ejecuta PROBAR_CONEXION.bat."
    )

tk.Button(
    frame,
    text="GUARDAR CONFIGURACIÓN",
    command=save,
    font=("Segoe UI", 10, "bold"),
    padx=14,
    pady=8,
).grid(row=9, column=0, columnspan=3, sticky="w", pady=(24, 8))

tk.Label(
    frame,
    text=(
        "La Publishable Key puede estar en este programa. "
        "La clave administrativa/Secret Key de Supabase NO se utiliza aquí."
    ),
    font=("Segoe UI", 9),
    wraplength=650,
    justify="left",
).grid(row=10, column=0, columnspan=3, sticky="w", pady=(12, 0))

root.mainloop()
