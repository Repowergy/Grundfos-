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
Danach zusätzlich `ETB.MDB` (Ersatzteile KSB-Baureihen) als Rohdaten in das Schema `etb` – nichts geht verloren,
es landet aber nicht im Grundfos-Stamm.

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

# ── Verknüpfen: gpi → pim (Migration 0005) ──
def sql_notebook(datei, titel, intro, migs, aufruf, zahlen, beispiele):
    zellen = [
        md(f"# {titel}\n\n{intro}\n\nAlles läuft in **einer Transaktion**: Bei einem Fehler wird nichts geändert.\n"
           "Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.**"),
        py('from google.colab import userdata\n!pip -q install "psycopg[binary]>=3.1"'),
        py("%%writefile /content/datenaudit.py\n" + helpers),
        py("%%writefile /content/datanorm_import.py\n" + code),
    ] + [py(f"%%writefile /content/{m}\n" + (mig / m).read_text(encoding="utf-8")) for m in migs] + [
        py(f"""
import sys, importlib, psycopg, pathlib, time
sys.path.insert(0, '/content')
import datanorm_import; importlib.reload(datanorm_import)
params = datanorm_import.conn_params(userdata.get('SUPABASE_DB_URL') or '')
MIGS = {migs!r}
ZAHLEN = {zahlen!r}
BEISPIELE = {beispiele!r}
t0 = time.time()
with psycopg.connect(**params) as con:
    con.execute('set statement_timeout = 0')
    hat_log = con.execute("select to_regclass('supabase_migrations.schema_migrations') is not null").fetchone()[0]
    for m in MIGS:
        sql = pathlib.Path('/content/' + m).read_text(encoding='utf-8')
        con.execute(sql)
        if hat_log:
            con.execute('insert into supabase_migrations.schema_migrations (version, name, statements) '
                        'values (%s, %s, array[%s]) on conflict do nothing', (m[:14], m[15:-4], sql))
        print('ausgeführt:', m)
    print('vorher:', con.execute(ZAHLEN).fetchone())
    for schritt, n in con.execute({aufruf!r}).fetchall():
        print(f'{{schritt:<32}} {{n:>10,}}   ({{(time.time() - t0) / 60:.1f}} min)')
    con.commit()
    print('nachher:', con.execute(ZAHLEN).fetchone())
    for titel, sql in BEISPIELE:
        print('\\n──', titel, '──')
        for r in con.execute(sql).fetchall():
            print(' | '.join('' if v is None else str(v) for v in r))
"""),
        md("## Fertig – Claude kurz Bescheid geben."),
    ]
    (here / datei).write_text(json.dumps(dict(nb, cells=zellen), ensure_ascii=False, indent=1), encoding="utf-8")
    print("geschrieben:", here / datei)


sql_notebook(
    "GPI_Verknuepfen_Colab.ipynb",
    "Grundfos-PIM – gpi.mdb mit dem Shop-Stamm verknüpfen",
    """Übernimmt aus der GPC-Datenbank (Schema `gpi`, Stand 10/2015) in den Stamm `pim`:

1. **fehlende Artikel** (Produkte und Teile) mit Status „historisch“ – nichts geht verloren
2. **EAN**, wo noch keine vorhanden ist
3. **Typbezeichnung** als Suchbegriff (z. B. „Unilift KP 150 M 1“) und englische Teilebezeichnung
4. **Ersatzteillisten**: Pumpe → Teil mit Positionsnummer, Menge und Produktionszeitraum (ca. 7 Mio. Zeilen)
5. **Wettbewerber-Austausch**: Fremdpumpe (Wilo, KSB, DAB …) → Grundfos-Ersatz

Dauer ca. 15–40 Minuten. Fenster offen lassen.""",
    ["20261025000005_gpi_uebernehmen.sql"],
    "select * from pim.gpi_uebernehmen()",
    """select (select count(*) from pim.artikel) artikel,
  (select count(*) from pim.artikel where status = 'historisch') historisch,
  (select count(*) from pim.artikel where ean is not null) ean,
  (select count(*) from pim.artikel_beziehung) beziehungen,
  (select count(*) from pim.querverweis_wettbewerb) wettbewerb""",
    [("Ersatzteile 011H1300 (Unilift KP 150 M1)",
      """select z.artikelnummer, t.text, b.position, b.menge, b.produktion_von, b.produktion_bis
           from pim.artikel_beziehung b join pim.artikel v on v.id = b.von_artikel_id
           join pim.artikel z on z.id = b.zu_artikel_id
           left join pim.artikel_text t on t.artikel_id = z.id and t.art = 'titel' and t.sprache = 'en'
          where v.artikelnummer_norm = '011H1300' order by b.position limit 20"""),
     ("Austausch Wilo Star E 25/1-3",
      """select w.hersteller_name, w.fremdtyp, a.artikelnummer, al.wert, w.variante, w.kommentar
           from pim.querverweis_wettbewerb w join pim.artikel a on a.id = w.artikel_id
           left join pim.artikel_alias al on al.artikel_id = a.id and al.typ = 'typbezeichnung'
          where w.fremdtyp ilike '%Star%E 25%1-3%' order by w.variante limit 15"""),
     ("Hersteller im Austauschfinder",
      """select coalesce(hersteller_name, fremdhersteller), count(distinct fremdtyp) typen, count(*) vorschlaege
           from pim.querverweis_wettbewerb group by 1 order by 3 desc limit 30""")],
)

# ── Import 3: GPC-Datenordner 2023 → Schema gpc2023 ──
gpc_code = (here / "gpc_dateien_import.py").read_text(encoding="utf-8")
cells5 = [
    md("""
# Grundfos-PIM – Import 3: Daten der Grundfos-Software 2023 → Supabase

Lädt den kompletten Ordner *02 Grundfos / GRUNDFOS SOFTWARE X SHOPIFY / GPC* in das Schema `gpc2023`:

- **Texte zeilenweise**: HybrisQt-Produkttexte in 27 Sprachen, Sprachpakete `ctf`, `QtTxt`,
  Länder-Sortimente 2023 (`ProductRange_*`), Zubehör- und Austauschregeln, Produktmodelle (`*.vtz`), entpackte Caches
- **Bilder, Zeichnungen, PDFs**: nur verzeichnet (Name, Pfad, Größe) – für die spätere Zuordnung
- Programmdateien werden **nicht** gestartet; Inhalte aus `bin` und `*.config` werden nicht gespeichert

Jede Datei ist ein eigener Schritt – bricht etwas ab, einfach neu starten: Erledigtes wird übersprungen.
Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.** Dauer ca. 20–60 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1"
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/gpc_dateien_import.py\n" + gpc_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, gpc_dateien_import
for m in (datenaudit, datanorm_import, gpc_dateien_import): importlib.reload(m)
gpc_dateien_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
(here / "Import_GPC2023_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells5), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_GPC2023_Colab.ipynb")

# ── Import 4: Grundfos-Stammdaten 2015 (ARGE) → raw.tabellen_zeile ──
arge_code = (here / "arge_import.py").read_text(encoding="utf-8")
cells6 = [
    md("""
# Grundfos-PIM – Import 4: Grundfos-Stammdaten 2015 (ARGE) → Supabase

Liest die ZIP-Dateien im Ordner *GRUNDFOS – Zentrale Projektablage / Historische Grundfos-Daten – Stammdaten, Bilder, EOL 2015*
und speichert jede Tabelle zeilenweise in Supabase (`raw.tabellen_zeile`):
Artikel mit **Nachfolgern 1–3**, Baujahr, Ersatzteilliste, Link · Bild- und Dokumentzuordnungen · Abmessungen/Gewichte ·
Langtexte · Warengruppen · Auslauf-/Neuartikel-/Kit-/VPE-Listen 2015. Bilder werden nur verzeichnet.

Nur lesen, nichts wird verändert. Bereits importierte Dateien werden übersprungen.
Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.** Dauer ca. 5 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1" openpyxl
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/arge_import.py\n" + arge_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, arge_import
for m in (datenaudit, datanorm_import, arge_import): importlib.reload(m)
arge_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
(here / "Import_Stammdaten2015_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells6), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_Stammdaten2015_Colab.ipynb")

# ── Import 5: übrige Dateien der Zentralen Projektablage → raw ──
pa_code = (here / "projektablage_import.py").read_text(encoding="utf-8")
cells7 = [
    md("""
# Grundfos-PIM – Import 5: Zentrale Projektablage (übrige Dateien) → Supabase

Liest alle Dateien in *GRUNDFOS – Zentrale Projektablage*, die noch nicht in Supabase sind:
Website-Daten 08/2026 (Active Products, Ersatzteile, Pumpe↔Ersatzteil), Produkt- und Keyword-Listen,
Shopify-Archiv 2021, Bildzuordnungen 2026, OXOMI-Abgleich, Notizen und Skripte – sowie fehlende DATANORM-Teile
(z. B. *Original DATANORM 2016 / datanorm.002*). Tabellen werden zeilenweise gespeichert, PDF/EXE/Bilder nur verzeichnet.

Nur lesen, nichts wird verändert. Bereits importierte Dateien werden übersprungen.
Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.** Dauer ca. 15–30 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1" openpyxl
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/arge_import.py\n" + arge_code),
    py("%%writefile /content/projektablage_import.py\n" + pa_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, arge_import, projektablage_import
for m in (datenaudit, datanorm_import, arge_import, projektablage_import): importlib.reload(m)
projektablage_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
(here / "Import_Projektablage_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells7), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_Projektablage_Colab.ipynb")

# ── Import 6: Bilder und Dokumente → Supabase Storage ──
mu_code = (here / "medien_upload.py").read_text(encoding="utf-8")
cells8 = [
    md("""
# Grundfos-PIM – Import 6: Bilder und Dokumente → Supabase Storage

Lädt Produktbilder, Maß- und Schaltbilder, Explosionszeichnungen, Datenblätter, Anleitungen und Service-Dokumente
aus Drive (Grundfos-Software 2023, Stammdaten 2015) in den öffentlichen Supabase-Speicher `medien`.
TIF wird in PNG umgewandelt. Ein erneuter Start macht dort weiter, wo der letzte aufgehört hat.

**Einmalig zwei Secrets** (Schlüssel-Symbol links, jeweils *Notebook-Zugriff* einschalten):
- `SUPABASE_DB_URL` – wie bei den anderen Notebooks
- `SUPABASE_SERVICE_KEY` – Supabase → *Project Settings → API Keys* → Reiter *Publishable and secret API keys* → **Secret key** (`sb_secret_…`); alternativ Reiter *Legacy* → `service_role`

**Laufzeit → Alle ausführen.** Dauer: Bilder ca. 20–40 Minuten, mit allen PDFs (≈ 6 GB) 1–3 Stunden.
Tab offen lassen; bei Abbruch einfach neu starten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1" pillow
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/medien_upload.py\n" + mu_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
os.environ['SUPABASE_SERVICE_KEY'] = userdata.get('SUPABASE_SERVICE_KEY')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, medien_upload
for m in (datenaudit, datanorm_import, medien_upload): importlib.reload(m)
medien_upload.run('/content/drive/MyDrive')
"""),
    md("## Fertig – Claude kurz Bescheid geben."),
]
(here / "Medien_Upload_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells8), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Medien_Upload_Colab.ipynb")

# ── Import 7: Nachtrag nach der Vollständigkeitsprüfung Drive ↔ Supabase ──
na_code = (here / "nachtrag_import.py").read_text(encoding="utf-8")
gi_code = (here / "gpi_import.py").read_text(encoding="utf-8")
cells9 = [
    md("""
# Grundfos-PIM – Import 7: Nachtrag (Vollständigkeitsprüfung 26.10.2026)

Liest alles aus *GRUNDFOS – Zentrale Projektablage* (alle Unterordner, auch in ZIP/RAR-Archiven), was noch nicht in
Supabase ist:
- **DATANORM 2016** (Original DATANORM 2016: Folgedatei `.002`, Rabatt- und Warengruppen) und **DATANORM 2015**
  (`GF_DNM4_MP.zip`)
- **Access-Datenbanken** ETB_DTXT, ETB_WAE, ETBv, GPIUser
- alles, was am 26.10. neu hochgeladen wurde: *Bildzuordnungen und Bildquellen (Shopify 2026)* –
  Bildzuordnungs-Listen, Bilder, PDFs, Archive

Bereits importierte Dateien werden übersprungen. Nur lesen – nichts wird verändert, Programme werden nie ausgeführt.
Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.** Dauer ca. 20–40 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!apt-get -qq install -y mdbtools unrar > /dev/null
!pip -q install "psycopg[binary]>=3.1" openpyxl rarfile
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/arge_import.py\n" + arge_code),
    py("%%writefile /content/projektablage_import.py\n" + pa_code),
    py("%%writefile /content/gpi_import.py\n" + gi_code),
    py("%%writefile /content/nachtrag_import.py\n" + na_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, arge_import, projektablage_import, gpi_import, nachtrag_import
for m in (datenaudit, datanorm_import, arge_import, projektablage_import, gpi_import, nachtrag_import):
    importlib.reload(m)
nachtrag_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – die letzte Zeile (FERTIG …) an Claude schicken."),
]
(here / "Import_Nachtrag_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells9), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_Nachtrag_Colab.ipynb")

# ── Import 8: große CSV-Dateien stückweise (Grundfos_FULL.csv) ──
gc_code = (here / "grosse_csv_import.py").read_text(encoding="utf-8")
cells10 = [
    md("""
# Grundfos-PIM – Import 8: Grundfos_FULL.csv stückweise → Supabase

Die Datei *02 Grundfos / Grundfos Daten X Shopify / Grundfos_FULL.csv* (191 MB) ist für das normale Einlesen zu groß.
Hier wird sie Zeile für Zeile gelesen und in Paketen zu 50.000 Zeilen gespeichert. Bricht der Lauf ab, einfach neu
starten – er setzt nach dem letzten Paket fort.

Nur lesen, nichts wird verändert. Voraussetzung: Secret `SUPABASE_DB_URL`. **Laufzeit → Alle ausführen.** Dauer ca. 10–20 Minuten.
"""),
    py("""
from google.colab import drive, userdata
drive.mount('/content/drive')
!pip -q install "psycopg[binary]>=3.1"
"""),
    py("%%writefile /content/datenaudit.py\n" + helpers),
    py("%%writefile /content/datanorm_import.py\n" + code),
    py("%%writefile /content/grosse_csv_import.py\n" + gc_code),
    py("""
import os, sys, importlib
os.environ['SUPABASE_DB_URL'] = userdata.get('SUPABASE_DB_URL')
sys.path.insert(0, '/content')
import datenaudit, datanorm_import, grosse_csv_import
for m in (datenaudit, datanorm_import, grosse_csv_import): importlib.reload(m)
grosse_csv_import.run('/content/drive/MyDrive')
"""),
    md("## Fertig – die letzte Zeile (FERTIG …) an Claude schicken."),
]
(here / "Import_GrundfosFULL_Colab.ipynb").write_text(json.dumps(dict(nb, cells=cells10), ensure_ascii=False, indent=1), encoding="utf-8")
print("geschrieben:", here / "Import_GrundfosFULL_Colab.ipynb")
