import json
import tkinter as tk
from tkinter import messagebox
from pathlib import Path

BASE = Path(__file__).resolve().parent
P = BASE / "config.json"

def current():
    try:
        d = json.loads(P.read_text(encoding="utf-8"))
        return str(d.get("supabase_url","")), str(d.get("supabase_publishable_key",""))
    except Exception:
        return "", ""

root = tk.Tk()
root.title("Configurar Web Histórico Profundo v2.3")
root.geometry("780x350")
root.resizable(False, False)

f = tk.Frame(root, padx=26, pady=24)
f.pack(fill="both", expand=True)

tk.Label(f,text="Control de Saldos · Web",font=("Segoe UI",18,"bold")).grid(
    row=0,column=0,columnspan=2,sticky="w"
)
tk.Label(
    f,
    text="Esta versión guarda la conexión en config.json.",
    font=("Segoe UI",10)
).grid(row=1,column=0,columnspan=2,sticky="w",pady=(4,22))

u0,k0=current()

tk.Label(f,text="Project URL",font=("Segoe UI",10,"bold")).grid(row=2,column=0,sticky="w",pady=8)
u=tk.Entry(f,width=75,font=("Segoe UI",10))
u.grid(row=2,column=1,padx=(12,0))
u.insert(0,u0)

tk.Label(f,text="Publishable Key",font=("Segoe UI",10,"bold")).grid(row=3,column=0,sticky="w",pady=8)
k=tk.Entry(f,width=75,font=("Segoe UI",10))
k.grid(row=3,column=1,padx=(12,0))
k.insert(0,k0)

def save():
    url=u.get().strip().rstrip("/")
    key=k.get().strip()

    if not url.startswith("https://") or ".supabase.co" not in url:
        messagebox.showerror("Project URL","Revisa la Project URL.")
        return

    if not key.startswith("sb_publishable_"):
        messagebox.showerror(
            "Publishable Key",
            "Pega únicamente la Publishable Key real."
        )
        return

    P.write_text(
        json.dumps({
            "supabase_url":url,
            "supabase_publishable_key":key
        },indent=2,ensure_ascii=False),
        encoding="utf-8"
    )

    messagebox.showinfo(
        "Guardado",
        "config.json guardado.\n\nAhora ejecuta VERIFICAR_CONFIG.bat."
    )

tk.Button(
    f,text="GUARDAR CONFIGURACIÓN",command=save,
    font=("Segoe UI",10,"bold"),padx=18,pady=8
).grid(row=5,column=0,columnspan=2,sticky="w",pady=(24,0))

root.mainloop()
