#!/usr/bin/env python3
"""
Grundfos-PIM – Import 3: Datenordner der Grundfos-Software (GPC, Stand 09/2023) → Supabase-Schema gpc2023

Grundsatz „nichts wegwerfen“: Jede Datei des Ordners wird verzeichnet – auch Dateien in ZIP-/VTZ-Archiven.
Textinhalte (Sprachpakete ctf, HybrisQt-Texte in 27 Sprachen, Länder-Sortimente, Regeln, entpackte Caches …)
werden zeilenweise gespeichert und sind danach per SQL auswertbar. Bilder, Zeichnungen, PDFs und Programme
werden nur mit Pfad, Name und Größe verzeichnet (Index für die spätere Zuordnung zu Artikeln).

  gpc2023.datei  (id, pfad, container, name, ext, groesse, art, kodierung, zeilen)
  gpc2023.zeile  (datei_id, nr, text)

Programmdateien werden nie gestartet. Inhalte aus `bin` und *.config werden nicht gespeichert
(dort können Zugangsschlüssel der Software stehen), nur verzeichnet.
Jede oberste Datei ist eine eigene Transaktion; ein erneuter Lauf überspringt Erledigtes.
"""

import gzip
import io
import os
import sys
import time
import zipfile

import psycopg

from datanorm_import import conn_params, db_url
from datenaudit import guess_encoding, log

SCHEMA = "gpc2023"
BINAER = {".jpg", ".jpeg", ".png", ".gif", ".tif", ".tiff", ".bmp", ".ico", ".np2", ".pdf", ".exe", ".dll",
          ".msi", ".cab", ".ocx", ".chm", ".dwg", ".dxf", ".stp", ".step", ".igs", ".wav", ".mp4", ".ttf",
          ".otf", ".db", ".mdb", ".mdf", ".ldf", ".pfx", ".cer", ".snk"}
GEHEIM = {".config", ".pfx", ".cer", ".key", ".snk"}
OHNE_INHALT_ORDNER = {"bin"}
MAX_TEXT = 300 * 1024 * 1024

DDL = f"""
create schema if not exists {SCHEMA};
revoke all on schema {SCHEMA} from anon, authenticated;
create table if not exists {SCHEMA}.datei (
  id        bigint generated always as identity primary key,
  pfad      text not null unique,   -- relativ zum GPC-Ordner; Archivinhalt als 'archiv.zip!/innen/datei.txt'
  container text,                   -- oberste Datei im Ordner (für Wiederaufnahme)
  name      text not null,
  ext       text,
  groesse   bigint,
  art       text not null check (art in ('text','binaer','archiv','gzip','geschuetzt','fehler')),
  kodierung text,
  zeilen    integer
);
create index if not exists datei_name_idx on {SCHEMA}.datei (name);
create index if not exists datei_container_idx on {SCHEMA}.datei (container);
create table if not exists {SCHEMA}.zeile (
  datei_id bigint not null references {SCHEMA}.datei(id) on delete cascade,
  nr       integer not null,
  text     text,
  primary key (datei_id, nr)
);
alter table {SCHEMA}.datei enable row level security;
alter table {SCHEMA}.zeile enable row level security;
comment on schema {SCHEMA} is 'Rohdaten: Datenordner der Grundfos-Software GPC (Stand 09/2023); nur lesen';
"""


def dekodieren(data):
    """Bytes → (kodierung, text) oder (None, None) bei Binärdaten."""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16", data.decode("utf-16", errors="replace")
    if data[:3] == b"\xef\xbb\xbf":
        return "utf-8-sig", data.decode("utf-8-sig", errors="replace")
    if b"\x00" in data[:8192]:
        return None, None
    enc = guess_encoding(data[:200000])
    return enc, data.decode(enc, errors="replace")


class Importer:
    def __init__(self, con, root):
        self.con, self.root = con, root
        self.n_dateien = self.n_zeilen = 0

    def datei(self, cur, pfad, container, name, groesse, art, kodierung=None, zeilen=None):
        ext = os.path.splitext(name)[1].lower() or None
        cur.execute(f"""insert into {SCHEMA}.datei (pfad, container, name, ext, groesse, art, kodierung, zeilen)
                        values (%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
                    (pfad, container, name, ext, groesse, art, kodierung, zeilen))
        self.n_dateien += 1
        return cur.fetchone()[0]

    def text(self, cur, pfad, container, name, data, kodierung, text):
        lines = text.splitlines()
        did = self.datei(cur, pfad, container, name, len(data), "text", kodierung, len(lines))
        with cur.copy(f"COPY {SCHEMA}.zeile (datei_id, nr, text) FROM STDIN") as cp:
            for i, line in enumerate(lines, 1):
                cp.write_row((did, i, line.replace("\x00", "")))
        self.n_zeilen += len(lines)

    def inhalt(self, cur, pfad, container, name, data, geschuetzt=False, tiefe=0):
        """Inhalt einer Datei (aus Ordner oder Archiv) verarbeiten."""
        ext = os.path.splitext(name)[1].lower()
        if geschuetzt or ext in GEHEIM:
            self.datei(cur, pfad, container, name, len(data), "geschuetzt")
        elif data[:4] == b"PK\x03\x04" and tiefe < 3:
            self.archiv(cur, pfad, container, name, zipfile.ZipFile(io.BytesIO(data)), len(data), tiefe)
        elif data[:2] == b"\x1f\x8b":
            try:
                roh = gzip.decompress(data)
            except OSError:
                self.datei(cur, pfad, container, name, len(data), "fehler")
                return
            self.datei(cur, pfad, container, name, len(data), "gzip")
            self.inhalt(cur, pfad + "!/entpackt", container, name + ".entpackt", roh, tiefe=tiefe + 1)
        elif ext in BINAER or len(data) > MAX_TEXT:
            self.datei(cur, pfad, container, name, len(data), "binaer")
        else:
            kod, text = dekodieren(data)
            if text is None:
                self.datei(cur, pfad, container, name, len(data), "binaer")
            else:
                self.text(cur, pfad, container, name, data, kod, text)

    def archiv(self, cur, pfad, container, name, zf, groesse, tiefe):
        self.datei(cur, pfad, container, name, groesse, "archiv")
        for info in zf.infolist():
            if info.is_dir():
                continue
            innen = pfad + "!/" + info.filename
            iname = os.path.basename(info.filename)
            if os.path.splitext(iname)[1].lower() in BINAER:  # Bilder/Zeichnungen nur verzeichnen
                self.datei(cur, innen, container, iname, info.file_size, "binaer")
                continue
            self.inhalt(cur, innen, container, iname, zf.read(info), tiefe=tiefe + 1)

    def oberste_datei(self, full, rel, geschuetzt):
        with self.con.cursor() as cur:
            cur.execute(f"select 1 from {SCHEMA}.datei where pfad = %s", (rel,))
            if cur.fetchone():
                return False
            name = os.path.basename(full)
            ext = os.path.splitext(name)[1].lower()
            size = os.path.getsize(full)
            if geschuetzt or ext in GEHEIM:
                self.datei(cur, rel, rel, name, size, "geschuetzt")
            elif zipfile.is_zipfile(full):
                with zipfile.ZipFile(full) as zf:
                    self.archiv(cur, rel, rel, name, zf, size, 0)
            elif ext in BINAER or size > MAX_TEXT:
                self.datei(cur, rel, rel, name, size, "binaer")
            else:
                with open(full, "rb") as fh:
                    self.inhalt(cur, rel, rel, name, fh.read())
        self.con.commit()
        return True


def run(root="/content/drive/MyDrive", ordner="02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC"):
    t0 = time.time()
    base = os.path.join(root, ordner)
    if not os.path.isdir(base):
        raise SystemExit(f"Ordner fehlt: {base}")
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        con.execute("set statement_timeout = 0")
        con.execute(DDL)
        con.commit()
        imp = Importer(con, root)
        neu = 0
        for dp, dn, fn in os.walk(base):
            dn.sort()
            rel_dir = os.path.relpath(dp, base)
            teile = set(rel_dir.replace("\\", "/").split("/"))
            geschuetzt = bool(teile & OHNE_INHALT_ORDNER)
            for fname in sorted(fn):
                full = os.path.join(dp, fname)
                rel = os.path.normpath(os.path.join(rel_dir, fname)).replace("\\", "/")
                t1 = time.time()
                try:
                    if imp.oberste_datei(full, rel, geschuetzt):
                        neu += 1
                        if time.time() - t1 > 5:
                            log(f"  {rel}  ({time.time() - t1:.0f}s)")
                except Exception as e:  # noqa: BLE001 – eine kaputte Datei hält den Rest nicht auf
                    con.rollback()
                    log(f"  FEHLER {rel}: {e!r}")
                    with con.cursor() as cur:
                        imp.datei(cur, rel, rel, fname, os.path.getsize(full), "fehler")
                    con.commit()
            if neu and neu % 200 == 0:
                log(f"… {neu} Dateien, {imp.n_zeilen:,} Textzeilen")
        with con.cursor() as cur:
            cur.execute(f"""select art, count(*), coalesce(sum(zeilen), 0) from {SCHEMA}.datei
                            group by art order by 2 desc""")
            stand = cur.fetchall()
    log(f"FERTIG in {(time.time() - t0) / 60:.1f} min · neu: {neu} oberste Dateien, {imp.n_dateien:,} Einträge, "
        f"{imp.n_zeilen:,} Textzeilen · Bestand: " + ", ".join(f"{a} {n:,} ({z:,} Zeilen)" for a, n, z in stand))


if __name__ == "__main__":
    run(*sys.argv[1:3])
