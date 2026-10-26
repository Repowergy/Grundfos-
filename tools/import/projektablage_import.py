#!/usr/bin/env python3
"""
Grundfos-PIM – Import 5: alles Übrige aus „GRUNDFOS – Zentrale Projektablage“ → Supabase (raw)

Bisher fehlten (Prüfung 26.10.2026):
  - Website-Daten 08/2026: GRUNDFOS_Active_Products_de_DE_MASTER.xlsx + 33 Teildateien GRUNDFOS_Active_de_DE_*.xlsx,
    GRUNDFOS_SpareParts_de_DE_MASTER.xlsx, GRUNDFOS_Pump_SparePart_Mapping_de_DE_MASTER.xlsx, Audits/Summary/Index
  - grundfos produkte.xlsx, keywordliste_…grundfos1.xlsx, Grundfos_Quellenabgleich_2015_2016_DATANORM_2026.csv
  - CSV Shopify auch Grundfos (Archiv 2021): First … Ninth Import
  - Bildzuordnungen und Bildquellen (Shopify 2026), VPS-Nachtlauf (OXOMI-Abgleich, Listen, Skripte, Notizen)
  - Original DATANORM 2016 / datanorm.002 (Fortsetzung der „GF“-Datei) → über datanorm_import

Tabellen (CSV/XLSX, auch in ZIPs) werden zeilenweise als JSON gespeichert (raw.tabellen_zeile), Text-Dateien
(md, txt, json, py, sh) als eine Zeile {"text": …}. PDF, EXE und Bilder werden nur verzeichnet (Name, Größe).
Bereits importierte Dateien (gleiche SHA-256) werden übersprungen. Quelldateien werden nur gelesen.
Die Ordner „Historische Grundfos-…“ sind schon mit Import 2–4 erfasst und werden hier ausgelassen.
"""

import hashlib
import io
import json
import os
import sys
import time
import zipfile

import psycopg

import arge_import
import datanorm_import
from datanorm_import import conn_params, db_url
from datenaudit import guess_encoding, log

BASIS = "GRUNDFOS – Zentrale Projektablage"
AUSLASSEN = ("Historische Grundfos-Daten", "Historische Grundfos-Software")
DATANORM_ORDNER = ("DATANORM NEU 1", "DATANORM NEU 2", "DATANORM NEU – Hauptdateien", "Original DATANORM 2016")
TABELLE = {".csv", ".xlsx", ".xlsm"}
TEXT = {".md", ".txt", ".json", ".py", ".sh", ".jsonl"}
TEXT_MAX = 5_000_000
BILD = {".jpg", ".jpeg", ".png", ".gif", ".tif", ".tiff", ".bmp", ".webp"}


def lese(name, data):
    """→ (format, encoding, {tabelle: [zeilen]})"""
    ext = os.path.splitext(name)[1].lower()
    if ext == ".csv":
        enc, rows = arge_import.tabelle_csv(data)
        return "csv", enc, {os.path.basename(name): rows}
    if ext in (".xlsx", ".xlsm"):
        return "xlsx", None, arge_import.tabelle_xlsx(data)
    if ext in TEXT and len(data) <= TEXT_MAX:
        enc = guess_encoding(data[:200000])
        return ext.lstrip("."), enc, {os.path.basename(name): [{"text": data.decode(enc, errors="replace")}]}
    fmt = "bild" if ext in BILD else (ext.lstrip(".") or "datei")   # 'bild' wie ARGE 2015 → Medienzuordnung
    return fmt, None, {"_dateien": [{"name": os.path.basename(name), "groesse": len(data)}]}


def speichere(cur, lauf_id, rel, data, name):
    sha = hashlib.sha256(data).hexdigest()
    cur.execute("select id, zeilen, format from raw.quelldatei where sha256 = %s", (sha,))
    alt = cur.fetchone()
    if alt:
        return None
    fmt, enc, tabellen = lese(name, data)
    cur.execute("""insert into raw.quelldatei (lauf_id, pfad, sha256, groesse, format, lieferant, sprache, kopfzeile)
                   values (%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
                (lauf_id, rel, sha, len(data), fmt, "Projektablage", "de", enc or ""))
    datei_id = cur.fetchone()[0]
    n = 0
    with cur.copy("COPY raw.tabellen_zeile (datei_id, tabelle, zeile, daten) FROM STDIN") as cp:
        for tab, rows in tabellen.items():
            for i, r in enumerate(rows, 1):
                cp.write_row((datei_id, tab, i, json.dumps(r, ensure_ascii=False)))
                n += 1
    cur.execute("update raw.quelldatei set zeilen = %s where id = %s", (n, datei_id))
    return n


def run(root="/content/drive/MyDrive"):
    t0 = time.time()
    base = os.path.join(root, BASIS)
    if not os.path.isdir(base):
        raise SystemExit(f"Ordner „{BASIS}“ nicht gefunden")

    # 1. DATANORM-Ordner der Projektablage (bekannte Dateien werden über die Prüfsumme übersprungen)
    datanorm_import.CONFIG["DATANORM_DIRS"] = [os.path.join(BASIS, d) for d in DATANORM_ORDNER]
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                        ("projektablage_import v1", "Zentrale Projektablage: DATANORM-Ordner + übrige Dateien"))
            lauf_id = cur.fetchone()[0]
        con.commit()
        datanorm_import.import_datanorm(con, root, lauf_id)
        datanorm_import.link_cross_file_langtexts(con)
        con.commit()

        # 2. alle übrigen Dateien
        gesamt, neu = 0, 0
        with con.cursor() as cur:
            cur.execute("set statement_timeout = 0")
            for dp, dn, fn in os.walk(base):
                rel_dir = os.path.relpath(dp, base)
                teil = rel_dir.split(os.sep)[0]
                if teil.startswith(AUSLASSEN) or teil in DATANORM_ORDNER:
                    dn[:] = []
                    continue
                for name in sorted(fn):
                    p = os.path.join(dp, name)
                    rel = os.path.relpath(p, root)
                    try:
                        if name.lower().endswith(".zip"):
                            with zipfile.ZipFile(p) as zf:
                                for info in zf.infolist():
                                    if info.is_dir():
                                        continue
                                    n = speichere(cur, lauf_id, rel + "!/" + info.filename, zf.read(info), info.filename)
                                    if n is not None:
                                        neu += 1
                                        gesamt += n
                        else:
                            with open(p, "rb") as fh:
                                data = fh.read()
                            n = speichere(cur, lauf_id, rel, data, name)
                            if n is None:
                                log(f"  bereits vorhanden: {rel}")
                                continue
                            neu += 1
                            gesamt += n
                            log(f"  {rel}: {n:,} Zeilen")
                        con.commit()
                    except Exception as e:  # noqa: BLE001 – eine kaputte Datei soll den Lauf nicht stoppen
                        con.rollback()
                        log(f"  ⚠ Fehler bei {rel}: {e!r}")
            cur.execute("update raw.import_lauf set beendet_am = now() where id = %s", (lauf_id,))
        con.commit()
    log(f"FERTIG in {(time.time() - t0) / 60:.1f} min · {neu} neue Dateien · {gesamt:,} Zeilen")


if __name__ == "__main__":
    run(*sys.argv[1:2])
