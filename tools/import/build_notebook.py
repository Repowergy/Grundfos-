"""Erzeugt Import_DATANORM_Colab.ipynb aus datanorm_import.py (+ datenaudit.py für Hilfsfunktionen)."""
import json, pathlib

here = pathlib.Path(__file__).parent
helpers = (here.parent / "datenaudit" / "datenaudit.py").read_text(encoding="utf-8")
code = (here / "datanorm_import.py").read_text(encoding="utf-8")

def md(src):
    return {"cell_type": "markdown", "metadata": {}, "source": src.strip("\n").splitlines(True)}

def py(src):
    return {"cell_type": "code", "metadata": {}, "execution_count": None, "outputs": [],
            "source": src.strip("\n").splitlines(True)}

cells = [
    md("""
# Grundfos-PIM – Import 1: DATANORM, Artikelliste, Kategorien → Supabase

Liest die Quelldateien im Drive **nur** und schreibt in die Supabase-Datenbank `Grundfos-PIM`:

- **Rohdaten 1:1** (`raw`): jede Datei mit Prüfsumme; bereits importierte Dateien werden übersprungen
- **Stammdaten** (`pim`): Artikel, EAN, Kurz-/Lang-/Techniktexte, Listenpreise, Waren- und Rabattgruppen, Kategoriebaum

**Vorher einmalig:** links auf das **Schlüssel-Symbol** → Secret `SUPABASE_DB_URL` anlegen
(Verbindungszeile „Session pooler“ aus Supabase → Connect, mit Passwort) → **Notebook-Zugriff** einschalten.

Dann **Laufzeit → Alle ausführen**. Dauer: ca. 15–40 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1"
"""),
    md("## Verbindung prüfen"),
    py("""
import psycopg
from urllib.parse import urlsplit
url = (userdata.get('SUPABASE_DB_URL') or '').strip()
u = urlsplit(url)
print('Host:', u.hostname, '| Port:', u.port, '| Benutzer:', u.username)  # Passwort wird nicht angezeigt
if not url.startswith('postgresql://'):
    raise SystemExit('Der Wert muss mit postgresql:// beginnen – bitte die komplette Verbindungszeile einfügen.')
if '[YOUR-PASSWORD]' in url:
    raise SystemExit('Im Secret steht noch [YOUR-PASSWORD] – bitte durch das Datenbank-Passwort ersetzen.')
if (u.hostname or '').startswith('db.'):
    raise SystemExit('Das ist die direkte Verbindung (db.…supabase.co), die Colab nicht erreicht. '
                     'Bitte in Supabase → Connect → Direct → „Session pooler“ wählen (Host …pooler.supabase.com).')
with psycopg.connect(url, connect_timeout=20) as con:
    print(con.execute('select version()').fetchone()[0][:60])
    print(con.execute("select count(*) from information_schema.tables where table_schema in ('raw','pim')").fetchone()[0], 'Tabellen in raw/pim')
"""),
    md("## Code (muss nicht verändert werden)"),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    md("## Import starten"),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import
importlib.reload(datenaudit); importlib.reload(datanorm_import)
datanorm_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben. Die Ergebnisse prüft Claude direkt in Supabase."),
]
nb = {"cells": cells,
      "metadata": {"colab": {"provenance": []}, "kernelspec": {"name": "python3", "display_name": "Python 3"},
                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 0}
(here / "Import_DATANORM_Colab.ipynb").write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_DATANORM_Colab.ipynb")
