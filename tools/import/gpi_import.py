#!/usr/bin/env python3
"""
Grundfos-PIM – Import 2: Access-Datenbanken → Supabase (Grundsatz: nichts wegwerfen)

  gpi.mdb  (Grundfos Product Center, Export 10.10.2015) → Schema `gpi`
  ETB.MDB  (Ersatzteil-Datenbank eines Fremdherstellers, KSB-Baureihen) → Schema `etb`
           nur als Rohdaten; geht NICHT in den Grundfos-Stamm (pim)

Jede Datenbank wird 1:1 übernommen: jede Tabelle, jede Zeile,
alle Spalten als Text (leere Felder = NULL). Umwandlung in pim.* (Artikel, Ersatzteillisten,
Dokumente, Wettbewerber-Austausch, Kennlinien) folgt danach per SQL – so bleibt die Quelle
unverändert und jeder Schritt nachvollziehbar.

Je Datenbank eine Transaktion: bricht etwas ab, bleibt die Datenbank unverändert.
Eine bereits importierte Datei (gleiche SHA-256) wird übersprungen.

Voraussetzungen: mdbtools (apt-get install mdbtools), psycopg 3, Secret SUPABASE_DB_URL.
Die Quelldatei wird nur gelesen (lokale Kopie, weil mdbtools wahlfrei liest).
"""

import csv
import glob
import os
import re
import shutil
import subprocess
import sys
import time

import tempfile

import psycopg
from psycopg import sql

from datanorm_import import conn_params, db_url, new_quelle, register_file
from datenaudit import log

DATENSTAND = "2015-10-10"   # gpi.mdb, Tabelle ExtrDates: DB2015.10.10
csv.field_size_limit(sys.maxsize)

# Schlüsselspalten, die später für Verknüpfungen gebraucht werden (Tabelle → Spalten, klein geschrieben)
INDEXE = {
    "products2": ["id", "productno", "pgid", "prodnameid", "eanno", "curvesetid"],
    "prodnames": ["id"],
    "pg": ["id", "code"],
    "coltext": ["id"],
    "master": ["partid", "partnum"],
    "partlist": ["plid", "partdetailid"],
    "partdetails": ["id", "partid"],
    "partdrawinglink": ["partid", "dfid"],
    "df": ["id"],
    "proddf": ["prodid", "dfid"],
    "itdf": ["itid", "dfid"],
    "literature": ["id"],
    "literaturefile": ["litid"],
    "literaturepglink": ["pgcode", "litid"],
    "acclink": ["accprodid"],
    "replsystem50": ["replid"],
    "replpumps50": ["replid", "productno"],
    "replsystem60": ["replid"],
    "replpumps60": ["replid", "productno"],
    "hydrauliclink": ["hydraulicid", "productid"],
    "hydraulicobject": ["id", "curvesetid"],
    "packagingnumbers": ["originalpartno", "packagingno"],
    "productelectricalvariation": ["productnumber"],
    "competitorproducts": ["id"],
    "competitorproductdata": ["productid"],
    # ETB.MDB
    "teileliste": ["identnummer", "teilenummer"],
    "teilestamm": ["identnr"],
    "variante": ["zeichnung"],
    "zeichnung": ["zeichnung"],
    "idnrhist": ["idnr_alt", "idnr_neu"],
}

# Datenbanken: Dateiname, Schema, Lieferant, Datenstand, Beschreibung, pim.quelle (typ, prio) oder None
DATENBANKEN = [
    ("gpi.mdb", "gpi", "GRUNDFOS", DATENSTAND,
     "Grundfos Product Center (GPC) – gpi.mdb, Export 10.10.2015", ("gpc", 75)),
    ("ETB.MDB", "etb", "KSB (Fremdhersteller)", None,
     "ETB.MDB – Ersatzteil-Datenbank KSB-Baureihen (Preise DM); nur Rohdaten, nicht im Grundfos-Stamm", None),
]


def ident(name, used=None):
    s = re.sub(r"[^a-z0-9_]+", "_", name.strip().lower()).strip("_") or "spalte"
    if s[0].isdigit():
        s = "c_" + s
    if used is not None:
        base, i = s, 2
        while s in used:
            s, i = f"{base}_{i}", i + 1
        used.add(s)
    return s


def mdb(*args, timeout=900):
    return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout,
                          encoding="utf-8", errors="replace").stdout


def find_db(root, dateiname):
    treffer = sorted(glob.glob(os.path.join(root, "*", "Historische Grundfos-Software*", dateiname)) +
                     glob.glob(os.path.join(root, "*", "*", "Historische Grundfos-Software*", dateiname)))
    return treffer[0] if treffer else None


def import_table(cur, path, table, schema, label):
    """Eine Access-Tabelle per mdb-export (CSV) streamen und mit COPY nach <schema>.<tabelle> schreiben."""
    err = tempfile.TemporaryFile(mode="w+")  # stderr in Datei, damit die Pipe nie blockiert
    proc = subprocess.Popen(["mdb-export", "-b", "strip", "-D", "%Y-%m-%d %H:%M:%S", path, table],
                            stdout=subprocess.PIPE, stderr=err, text=True,
                            encoding="utf-8", errors="replace")
    reader = csv.reader(proc.stdout)
    try:
        header = next(reader)
    except StopIteration:
        proc.wait()
        err.seek(0)
        raise RuntimeError(f"{table}: keine Ausgabe ({err.read()[:300]})")
    used = set()
    cols = [ident(c, used) for c in header]
    tname = ident(table)
    cur.execute(f'drop table if exists {schema}."{tname}"')
    cur.execute(f'create table {schema}."{tname}" (' + ", ".join(f'"{c}" text' for c in cols) + ")")
    cur.execute(f'alter table {schema}."{tname}" enable row level security')
    cur.execute(sql.SQL("comment on table {}.{} is {}").format(
        sql.Identifier(schema), sql.Identifier(tname), sql.Literal(f"{label} · Tabelle {table}")))
    n, w = 0, len(cols)
    with cur.copy(f'COPY {schema}."{tname}" ({", ".join(chr(34) + c + chr(34) for c in cols)}) FROM STDIN') as cp:
        for row in reader:
            if len(row) != w:
                row = (row + [""] * w)[:w]
            cp.write_row([v if v != "" else None for v in row])
            n += 1
    proc.wait()
    if proc.returncode:
        err.seek(0)
        raise RuntimeError(f"{table}: mdb-export Fehler {proc.returncode}: {err.read()[:300]}")
    return tname, cols, n


def import_db(root, src, schema, lieferant, datenstand, beschreibung, quelle, cache_dir):
    t0 = time.time()
    rel = os.path.relpath(src, root)
    name = os.path.basename(src)
    os.makedirs(cache_dir, exist_ok=True)
    local = os.path.join(cache_dir, name)
    if not os.path.exists(local) or os.path.getsize(local) != os.path.getsize(src):
        log(f"kopiere {rel} ({os.path.getsize(src) / 1e9:.2f} GB) …")
        shutil.copyfile(src, local)
    tables = [t for t in mdb("mdb-tables", "-1", local).split("\n") if t.strip()]
    log(f"{name}: {len(tables)} Tabellen → Schema {schema}")

    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con, con.cursor() as cur:
        cur.execute("set statement_timeout = 0")
        cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                    ("gpi_import v2", f"{name} → Schema {schema} (1:1)"))
        lauf_id = cur.fetchone()[0]
        datei_id = register_file(cur, lauf_id, local, rel, "mdb", lieferant, datenstand, beschreibung)
        if datei_id is None:
            log(f"{name} ist bereits importiert – nichts zu tun.")
            con.rollback()
            return
        cur.execute(f"create schema if not exists {schema}")
        cur.execute(f"revoke all on schema {schema} from anon, authenticated")
        cur.execute(sql.SQL("comment on schema {} is {}").format(sql.Identifier(schema), sql.Literal(
            f"Rohdaten 1:1 aus {beschreibung}; nur lesen")))
        bericht, gesamt = [], 0
        for t in tables:
            soll = mdb("mdb-count", local, t).strip()
            t1 = time.time()
            tname, cols, n = import_table(cur, local, t, schema, name)
            gesamt += n
            ok = "" if soll == str(n) else f"  ⚠ mdb-count {soll}"
            bericht.append((t, n, ok))
            log(f"  {t:<34} {n:>9} Zeilen  {time.time() - t1:5.1f}s{ok}")
            for c in INDEXE.get(tname, []):
                if c in cols:
                    cur.execute(f'create index on {schema}."{tname}" ("{c}")')
        cur.execute("update raw.quelldatei set zeilen = %s where id = %s", (gesamt, datei_id))
        if quelle:
            new_quelle(cur, datei_id, quelle[0], beschreibung, datenstand, quelle[1])
        cur.execute("update raw.import_lauf set beendet_am = now() where id = %s", (lauf_id,))
        con.commit()
    abw = [b for b in bericht if b[2]]
    log(f"FERTIG {name} in {(time.time() - t0) / 60:.1f} min · {len(tables)} Tabellen · {gesamt:,} Zeilen"
        + (f" · {len(abw)} Tabellen mit abweichender Zeilenzahl: {abw}" if abw else " · alle Zeilenzahlen stimmen"))


def run(root="/content/drive/MyDrive", cache_dir="/content/mdb_cache"):
    for dateiname, schema, lieferant, datenstand, beschreibung, quelle in DATENBANKEN:
        src = find_db(root, dateiname)
        if not src:
            log(f"{dateiname} nicht gefunden – übersprungen")
            continue
        import_db(root, src, schema, lieferant, datenstand, beschreibung, quelle, cache_dir)


if __name__ == "__main__":
    run(*sys.argv[1:2])
