#!/usr/bin/env python3
"""
Grundfos-PIM – Import 4: Grundfos-Stammdaten 2015 (ARGE-Format) → Supabase (raw.tabellen_zeile)

Ordner „GRUNDFOS – Zentrale Projektablage / Historische Grundfos-Daten – Stammdaten, Bilder, EOL 2015“:
  GF_CSV_GESAMT_MP.zip   artikel.csv (Nachfolger 1–3, Baujahr, Ersatzteilliste, URL, Auslauf …),
                         artikeldokumentenzuordnungen.csv, artikelmasse.csv, artikelattribute.csv,
                         langtexte.csv, gruppen.csv, kopfdaten.csv
  GF_BILDZ*.zip, GF_BILDER_*.zip  Bildzuordnungen (CSV) + Bilder (nur verzeichnet)
  GF_Auslauf/Neue_Artikel/Kits/Verpackungseinheiten *.xlsx  Listen 2015
  GF_DNM4_MP.zip (DATANORM, bereits importiert), GF_STAMMDATEN.zip (XML, gleicher Inhalt wie CSV – nur verzeichnet)

Jede CSV-/Excel-Tabelle wird zeilenweise als JSON (Spaltenname → Wert) gespeichert – nichts geht verloren.
Bilder werden mit Name und Größe verzeichnet (raw.tabellen_zeile, tabelle '_dateien').
Bereits importierte Dateien (gleiche SHA-256) werden übersprungen. Quelldateien werden nur gelesen.
"""

import csv
import glob
import hashlib
import io
import json
import os
import sys
import time
import zipfile

import psycopg

from datanorm_import import conn_params, db_url
from datenaudit import guess_encoding, log

DATENSTAND = "2015-10-01"
BILD = {".jpg", ".jpeg", ".png", ".gif", ".tif", ".tiff", ".bmp", ".eps"}
csv.field_size_limit(sys.maxsize)


def tabelle_csv(data):
    enc = guess_encoding(data[:200000])
    text = data.decode(enc, errors="replace").lstrip("﻿")
    dialect = csv.Sniffer().sniff(text[:5000], delimiters=";,\t|") if text.strip() else csv.excel
    rows = list(csv.reader(io.StringIO(text), dialect))
    if not rows:
        return enc, []
    kopf = [h.strip() or f"spalte_{i + 1}" for i, h in enumerate(rows[0])]
    return enc, [dict(zip(kopf, r)) for r in rows[1:] if any(c.strip() for c in r)]


def tabelle_xlsx(data):
    import openpyxl
    wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    blaetter = {}
    for ws in wb.worksheets:
        rows = [["" if v is None else str(v).strip() for v in r] for r in ws.iter_rows(values_only=True)]
        # Kopfzeile = erste Zeile mit mindestens 3 gefüllten Zellen (darüber stehen Titelzeilen)
        k = next((i for i, r in enumerate(rows) if sum(1 for c in r if c) >= 3), None)
        if k is None:
            continue
        kopf = [h or f"spalte_{i + 1}" for i, h in enumerate(rows[k])]
        blaetter[ws.title] = [dict(zip(kopf, r)) for r in rows[k + 1:] if any(r)]
    wb.close()
    return blaetter


def run(root="/content/drive/MyDrive"):
    t0 = time.time()
    ordner = sorted(glob.glob(os.path.join(root, "*", "Historische Grundfos-Daten*")))
    if not ordner:
        raise SystemExit("Ordner „Historische Grundfos-Daten …“ nicht gefunden")
    base = ordner[0]
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con, con.cursor() as cur:
        cur.execute("set statement_timeout = 0")
        cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                    ("arge_import v1", "Grundfos-Stammdaten 2015 (ARGE) → raw.tabellen_zeile"))
        lauf_id = cur.fetchone()[0]
        con.commit()
        gesamt = 0
        for zpfad in sorted(glob.glob(os.path.join(base, "*.zip"))):
            zname = os.path.basename(zpfad)
            with zipfile.ZipFile(zpfad) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    ext = os.path.splitext(info.filename)[1].lower()
                    rel = os.path.relpath(zpfad, root) + "!/" + info.filename
                    if ext in BILD:
                        tabellen = {"_dateien": [{"name": os.path.basename(info.filename), "pfad": info.filename,
                                                  "groesse": info.file_size}]}
                        sha = hashlib.sha256(rel.encode() + str(info.CRC).encode()).hexdigest()
                        fmt, enc = "bild", None
                    else:
                        data = zf.read(info)
                        sha = hashlib.sha256(data).hexdigest()
                        if ext in (".csv", ".txt"):
                            enc, rows = tabelle_csv(data)
                            tabellen, fmt = {os.path.basename(info.filename): rows}, "csv"
                        elif ext in (".xlsx", ".xlsm"):
                            tabellen, fmt, enc = tabelle_xlsx(data), "xlsx", None
                        else:  # DATANORM (bereits importiert), XML: nur verzeichnen
                            tabellen, fmt, enc = {}, ext.lstrip(".") or "datei", None
                    cur.execute("select 1 from raw.quelldatei where sha256 = %s", (sha,))
                    if cur.fetchone():
                        continue
                    cur.execute("""insert into raw.quelldatei (lauf_id, pfad, sha256, groesse, format, lieferant,
                                                               datenstand, sprache, kopfzeile)
                                   values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
                                (lauf_id, rel, sha, info.file_size, fmt, "GRUNDFOS GMBH", DATENSTAND, "de",
                                 f"{zname} · {enc or ''}"))
                    datei_id = cur.fetchone()[0]
                    n = 0
                    with cur.copy("COPY raw.tabellen_zeile (datei_id, tabelle, zeile, daten) FROM STDIN") as cp:
                        for tab, rows in tabellen.items():
                            for i, r in enumerate(rows, 1):
                                cp.write_row((datei_id, tab, i, json.dumps(r, ensure_ascii=False)))
                                n += 1
                    cur.execute("update raw.quelldatei set zeilen = %s where id = %s", (n, datei_id))
                    gesamt += n
                    if fmt != "bild":
                        log(f"  {zname} › {info.filename}: {n:,} Zeilen")
            con.commit()
        cur.execute("update raw.import_lauf set beendet_am = now() where id = %s", (lauf_id,))
        con.commit()
    log(f"FERTIG in {(time.time() - t0) / 60:.1f} min · {gesamt:,} Zeilen")


if __name__ == "__main__":
    run(*sys.argv[1:2])
