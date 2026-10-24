"""Erzeugt Datenaudit_Colab.ipynb aus datenaudit.py (gleicher Code in beiden)."""
import json, pathlib

here = pathlib.Path(__file__).parent
code = (here / "datenaudit.py").read_text(encoding="utf-8")

def md(src):
    return {"cell_type": "markdown", "metadata": {}, "source": src.strip("\n").splitlines(True)}

def py(src):
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
            "source": src.strip("\n").splitlines(True)}

cells = [
    md("""
# Grundfos Datenaudit – Schritt 1

Dieses Notebook **liest nur** und verändert keine Quelldateien. Es untersucht:

1. **alle DATANORM-Dateien** in `04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify`
   (auch in ZIPs): Hersteller, Datenstand, Version, Satzarten, Kurz- und Langtexte, EAN, Preise
2. **die Grundfos-Product-Center-Software** in `02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC`:
   Dateitypen, ZIP-Inhalte (Bilder, Anleitungen), Datenbanken, Austausch- und Zubehördateien
3. **die Abdeckung** gegen die Liste der 806.105 Grundfos-Artikelnummern

**Ergebnis:** kleine Berichtsdateien in `02 Grundfos/00_Datenaudit/ergebnis/` (Zusammenfassung,
Dateilisten, Beispiele). Die kann Claude danach direkt lesen.

**So geht's:** Oben im Menü **Laufzeit → Alle ausführen**. Beim ersten Schritt fragt Google nach dem
Drive-Zugriff – mit dem Konto bestätigen, dem der Ordner gehört (repowergy@…).
Dauer: je nach Datenmenge ca. 10–40 Minuten. Das Fenster bitte offen lassen.
"""),
    py("""
from google.colab import drive
drive.mount('/content/drive')
"""),
    md("## Pfade (nur anpassen, falls Ordner umbenannt wurden)"),
    py("""
import os
ROOT = '/content/drive/MyDrive'
CONFIG = {
    'DATANORM_DIRS': ['04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify'],
    'GPC_DIRS': ['02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC'],
    'ARTICLE_LIST': '02 Grundfos/GRUNDFOS/de_DE/checkpoints/product_list.jsonl',
    'DATANORM_CSV': '02 Grundfos/Grundfos Daten X Shopify/GRUNDFOS_DATANORM_Gesamt.csv',
    'OUTPUT_DIR': '02 Grundfos/00_Datenaudit/ergebnis',
}
for k, v in CONFIG.items():
    for p in (v if isinstance(v, list) else [v]):
        full = os.path.join(ROOT, p)
        ok = os.path.exists(full) or k == 'OUTPUT_DIR'
        print(('OK   ' if ok else 'FEHLT'), k, '→', full)
"""),
    md("## Audit-Code (muss nicht verändert werden)"),
    py("%%writefile /content/datenaudit.py\n" + code),
    md("## Audit starten"),
    py("""
import sys, importlib
sys.path.insert(0, '/content')
import datenaudit
importlib.reload(datenaudit)
datenaudit.run(ROOT, overrides=CONFIG)
"""),
    md("""
## Fertig

Die Berichte liegen in `02 Grundfos/00_Datenaudit/ergebnis/`. Gib Claude kurz Bescheid –
die Auswertung und das Datenmodell für Supabase folgen dann.
"""),
]

nb = {"cells": cells,
      "metadata": {"colab": {"provenance": [], "name": "Datenaudit_Colab.ipynb"},
                   "kernelspec": {"name": "python3", "display_name": "Python 3"},
                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 0}
(here / "Datenaudit_Colab.ipynb").write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Datenaudit_Colab.ipynb")

# ── Teil 2 ──
code2 = (here / "datenaudit2.py").read_text(encoding="utf-8")
cells2 = [
    md("""
# Grundfos Datenaudit – Teil 2

**Liest nur**, verändert keine Quelldateien. Prüft:

1. den echten **Grundfos-Anteil jeder DATANORM-Datei** (auch Großhändler-Dateien von 2025 und `GRUNDFOS – Zentrale Projektablage/DATANORM NEU 1`)
2. die **Austausch-Caches** der GPC-Software (gzip-JSON entpacken)
3. **ProdPic**, **Qtp** und die **Sprachtabellen (CTF)**
4. **Sortimentslisten je Land** und die Austausch-Filterregeln
5. **Datenbankdateien** (`*.mdb`, `*.accdb`, `*.mdf`) in `05 Rohdaten Import`

**So geht's:** **Laufzeit → Alle ausführen**, Warnung mit „Trotzdem ausführen“ bestätigen, Drive-Zugriff erlauben.
Ergebnis: `02 Grundfos/00_Datenaudit/ergebnis_teil2/`.
"""),
    py("""
from google.colab import drive
drive.mount('/content/drive')
"""),
    py("%%writefile /content/datenaudit.py\n" + code),
    py("%%writefile /content/datenaudit2.py\n" + code2),
    py("""
import sys, importlib
sys.path.insert(0, '/content')
import datenaudit, datenaudit2
importlib.reload(datenaudit); importlib.reload(datenaudit2)
datenaudit2.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
nb2 = dict(nb, cells=cells2)
(here / "Datenaudit2_Colab.ipynb").write_text(json.dumps(nb2, ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Datenaudit2_Colab.ipynb")
