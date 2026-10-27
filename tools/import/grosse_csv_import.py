#!/usr/bin/env python3
"""
Grundfos-PIM – Import 8: große CSV-Dateien stückweise → Supabase (raw.tabellen_zeile)

Import 7 liest Dateien komplett in den Speicher; Grundfos_FULL.csv (191 MB, ≈ 806.000 Zeilen) ist dabei nicht angekommen.
Hier wird die Datei zeilenweise gelesen und in Paketen zu 50.000 Zeilen geschrieben (je Paket ein Commit).
Bricht der Lauf ab, setzt ein neuer Start nach dem letzten gespeicherten Paket fort.

Voraussetzung: Secret SUPABASE_DB_URL. Quelldateien werden nur gelesen.
"""

import csv
import json
import os
import sys
import time

import psycopg

from datanorm_import import conn_params, db_url, sha256_of
from datenaudit import guess_encoding, log

DATEIEN = [   # erste vorhandene Kopie wird genommen (alle drei sind gleich groß)
    "02 Grundfos/Grundfos Daten X Shopify/Grundfos_FULL.csv",
    "06 CSV-Sammlungen & Exporte (Arbeitsstände)/Datenbank/Grundfos-FULL/Grundfos_FULL.csv",
]
PAKET = 50_000
csv.field_size_limit(sys.maxsize)


def dialekt(head):
    try:
        return csv.Sniffer().sniff(head[:20000], delimiters=";,\t|")
    except csv.Error:
        return csv.excel if head.count(",") >= head.count(";") else type("semi", (csv.excel,), {"delimiter": ";"})


def importiere(con, root, rel):
    p = os.path.join(root, rel)
    t0 = time.time()
    with open(p, "rb") as fh:
        head_b = fh.read(200_000)
    enc = guess_encoding(head_b)
    d = dialekt(head_b.decode(enc, errors="replace").lstrip("﻿"))
    sha = sha256_of(p)

    with con.cursor() as cur:
        cur.execute("set statement_timeout = 0")
        cur.execute("select id, coalesce(zeilen, 0) from raw.quelldatei where sha256 = %s", (sha,))
        alt = cur.fetchone()
        if alt:
            datei_id = alt[0]
            cur.execute("select coalesce(max(zeile), 0) from raw.tabellen_zeile where datei_id = %s", (datei_id,))
            fertig = cur.fetchone()[0]
            log(f"{rel}: schon angelegt (id {datei_id}), {fertig:,} Zeilen gespeichert – setze fort")
        else:
            cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                        ("grosse_csv_import v1", f"{rel} stückweise"))
            lauf_id = cur.fetchone()[0]
            cur.execute("""insert into raw.quelldatei (lauf_id, pfad, sha256, groesse, format, lieferant, sprache, kopfzeile)
                           values (%s,%s,%s,%s,'csv','Projektablage','de',%s) returning id""",
                        (lauf_id, rel, sha, os.path.getsize(p), enc))
            datei_id = cur.fetchone()[0]
            fertig = 0
        con.commit()

    name = os.path.basename(rel)
    n, puffer = 0, []
    with open(p, encoding=enc, errors="replace", newline="") as fh:
        reader = csv.reader(fh, d)
        kopf = [h.strip().lstrip("﻿") or f"spalte_{i + 1}" for i, h in enumerate(next(reader))]
        for r in reader:
            if not any(c.strip() for c in r):
                continue
            n += 1
            if n <= fertig:
                continue
            puffer.append((datei_id, name, n, json.dumps(dict(zip(kopf, r)), ensure_ascii=False)))
            if len(puffer) >= PAKET:
                schreibe(con, puffer)
                log(f"  {n:,} Zeilen · {(time.time() - t0) / 60:.1f} min")
                puffer = []
    if puffer:
        schreibe(con, puffer)
    with con.cursor() as cur:
        cur.execute("update raw.quelldatei set zeilen = %s where id = %s", (n, datei_id))
    con.commit()
    log(f"FERTIG {rel}: {n:,} Zeilen in {(time.time() - t0) / 60:.1f} min")


def schreibe(con, rows):
    with con.cursor() as cur, cur.copy("COPY raw.tabellen_zeile (datei_id, tabelle, zeile, daten) FROM STDIN") as cp:
        for row in rows:
            cp.write_row(row)
    con.commit()


def run(root="/content/drive/MyDrive"):
    rel = next((r for r in DATEIEN if os.path.isfile(os.path.join(root, r))), None)
    if not rel:
        raise SystemExit("Grundfos_FULL.csv nicht gefunden")
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        importiere(con, root, rel)


if __name__ == "__main__":
    run(*sys.argv[1:2])
