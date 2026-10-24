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
    md("## Code (muss nicht verändert werden)"),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    md("## Verbindung prüfen"),
    py("""
import sys, importlib, psycopg
sys.path.insert(0, '/content')
import datenaudit, datanorm_import
importlib.reload(datenaudit); importlib.reload(datanorm_import)
params = datanorm_import.conn_params(userdata.get('SUPABASE_DB_URL') or '')
print('Host:', params['host'], '| Port:', params['port'], '| Benutzer:', params['user'])  # Passwort wird nicht angezeigt
with psycopg.connect(**params) as con:
    print(con.execute('select version()').fetchone()[0][:60])
    print(con.execute("select count(*) from information_schema.tables where table_schema in ('raw','pim')").fetchone()[0], 'Tabellen in raw/pim')
"""),
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

# ── DB-Pflege: Migrationen 0003 + 0004 ausführen, Texte neu aufbauen ──
mig = here.parent.parent / "supabase" / "migrations"
MIGS = ["20261024000003_grosshandel_entfernen.sql", "20261024000004_texte_aufbauen.sql"]
cells2 = [
    md("""
# Grundfos-PIM – Datenbank-Pflege

Führt in Supabase `Grundfos-PIM` nacheinander aus:

1. **Großhändler und Fremdhersteller entfernen.** Behalten werden nur die Grundfos-Quellen. Die Rohdaten (`raw`) bleiben erhalten.
2. **Textfunktionen anlegen.** Techniktexte aus Vorlage und Werten, Silbentrennung auflösen.
3. **Lang- und Techniktexte neu aufbauen**, danach Kennzahlen und Beispiele zeigen.

Alles läuft in **einer Transaktion**: Bei einem Fehler wird nichts geändert.
Voraussetzung ist das Secret `SUPABASE_DB_URL` (wie beim Import). **Laufzeit → Alle ausführen.** Dauer: wenige Minuten.
"""),
    py("""
from google.colab import userdata
!pip -q install "psycopg[binary]>=3.1"
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
] + [py(f"%%writefile /content/{m}\n" + (mig / m).read_text(encoding="utf-8")) for m in MIGS] + [
    py("""
import sys, importlib, psycopg, pathlib
sys.path.insert(0, '/content')
import datanorm_import; importlib.reload(datanorm_import)
params = datanorm_import.conn_params(userdata.get('SUPABASE_DB_URL') or '')
MIGS = %r
ZAHLEN = '''select (select count(*) from pim.quelle) quellen, (select count(*) from pim.artikel) artikel,
  (select count(*) from pim.artikel where ean is not null) ean,
  (select count(distinct artikel_id) from pim.artikel_preis) mit_preis,
  (select count(*) from pim.artikel_text where art='lang') lang,
  (select count(*) from pim.artikel_text where art='technik') technik'''
with psycopg.connect(**params) as con:
    con.execute('set statement_timeout = 0')
    print('vorher:', con.execute(ZAHLEN).fetchone())
    hat_log = con.execute("select to_regclass('supabase_migrations.schema_migrations') is not null").fetchone()[0]
    for m in MIGS:
        sql = pathlib.Path('/content/' + m).read_text(encoding='utf-8')
        con.execute(sql)
        if hat_log:
            con.execute('insert into supabase_migrations.schema_migrations (version, name, statements) '
                        'values (%%s, %%s, array[%%s]) on conflict do nothing',
                        (m[:14], m[15:-4], sql))
        print('ausgeführt:', m)
    for art, n in con.execute('select * from pim.texte_neu_aufbauen()').fetchall():
        print('neu aufgebaut:', art, n)
    con.commit()
    print('nachher:', con.execute(ZAHLEN).fetchone())
    for nr, art, text in con.execute('''select a.artikelnummer, t.art, left(t.text, 400) from pim.artikel_text t
          join pim.artikel a on a.id = t.artikel_id where a.artikelnummer_norm in ('011H1300','96281368','98221340')
          order by 1, 2''').fetchall():
        print('\\n──', nr, art, '──\\n' + text)
""" % MIGS),
    md("## Fertig – Claude kurz Bescheid geben."),
]
nb2 = dict(nb, cells=cells2)
(here / "DB_Pflege_Colab.ipynb").write_text(json.dumps(nb2, ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "DB_Pflege_Colab.ipynb")

# ── Import 2: gpi.mdb → Schema gpi ──
gpi_code = (here / "gpi_import.py").read_text(encoding="utf-8")
cells3 = [
    md("""
# Grundfos-PIM – Import 2: GPC-Datenbank `gpi.mdb` → Supabase

Übernimmt die Access-Datenbank der Grundfos-Software (Export 10.10.2015, ca. 1 GB, 153 Tabellen)
**1:1** in das neue Schema `gpi`: Produkte, Ersatzteillisten mit Gültigkeitszeitraum, Zeichnungen,
Dokumente in vielen Sprachen, Zubehör, Wettbewerber-Austausch, Kennlinien, Länder-Sortimente.

- Die Quelldatei wird **nur gelesen**. Programmdateien werden nicht gestartet.
- Alles läuft in **einer Transaktion**: Bei einem Fehler wird nichts geändert.
- Voraussetzung: Secret `SUPABASE_DB_URL` (wie beim ersten Import), Notebook-Zugriff erlauben.

**Laufzeit → Alle ausführen.** Dauer ca. 20–40 Minuten (7 Mio. Zeilen Stücklisten). Fenster offen lassen.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1"
!apt-get -qq install -y mdbtools > /dev/null && mdb-ver --help 2>&1 | head -1
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/gpi_import.py\n" + gpi_code),
    md("## Verbindung prüfen"),
    py("""
import sys, importlib, psycopg
sys.path.insert(0, '/content')
import datanorm_import; importlib.reload(datanorm_import)
params = datanorm_import.conn_params(userdata.get('SUPABASE_DB_URL') or '')
print('Host:', params['host'], '| Port:', params['port'], '| Benutzer:', params['user'])
with psycopg.connect(**params) as con:
    print(con.execute('select version()').fetchone()[0][:60])
"""),
    md("## Import starten"),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, gpi_import
for m in (datenaudit, datanorm_import, gpi_import): importlib.reload(m)
gpi_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
nb3 = dict(nb, cells=cells3)
(here / "Import_GPI_Colab.ipynb").write_text(json.dumps(nb3, ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_GPI_Colab.ipynb")
