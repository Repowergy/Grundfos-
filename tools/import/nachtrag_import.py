#!/usr/bin/env python3
"""
Grundfos-PIM – Import 7: Nachtrag nach der Vollständigkeitsprüfung Drive ↔ Supabase (26.10.2026)

Prüfung: jede Datei der „GRUNDFOS – Zentrale Projektablage“ (alle Unterordner, 3.670 Dateien) gegen raw.quelldatei.
Es fehlten:
  1. DATANORM 2016 (Original DATANORM 2016: datanorm.002/.rab/.wrg) – Kopf „V 161215GF alle Preisangaben…“ wurde
     nicht als Grundfos-Quelle erkannt (Muster korrigiert in datanorm_import)
  2. DATANORM 2015 in GF_DNM4_MP.zip (Historische Grundfos-Daten) – nur verzeichnet, nie eingelesen
  3. Access-Datenbanken ETB_DTXT, ETB_WAE, ETBv und GPIUser.mdb (Historische Grundfos-Software) → je eigenes Schema
  4. alles, was am 26.10. neu hochgeladen wurde: „Bildzuordnungen und Bildquellen (Shopify 2026)“ (≈ 2.990 Dateien:
     Bilder, Bildzuordnungs-CSV/XLSX, PDFs, ZIP/RAR-Archive) und Dateien im Hauptordner

Ablauf (nichts wird verändert, Quelldateien werden nur gelesen):
  - Dateien, deren Pfad schon in raw.quelldatei steht, werden ohne Lesen übersprungen; inhaltsgleiche (SHA-256) ebenso
  - DATANORM-Dateien (auch in ZIP/RAR) → datanorm_import (Grundfos-Quellen vollständig, sonst übersprungen)
  - Access-Datenbanken → gpi_import (Schema = Dateiname, z. B. etb_dtxt; Kopien mit gleichem Inhalt einmal)
  - alle übrigen Dateien → projektablage_import (Tabellen zeilenweise, Texte als Text, Bilder/PDF/EXE nur verzeichnet)
  - Programmdateien (.exe usw.) werden nie ausgeführt, nur mit Name/Größe verzeichnet

Voraussetzungen (Colab): mdbtools, unrar (für .rar), psycopg 3, rarfile; Secret SUPABASE_DB_URL.
"""

import os
import shutil
import sys
import tempfile
import time
import zipfile

import psycopg

import datanorm_import
import gpi_import
import projektablage_import
from datanorm_import import conn_params, db_url, sha256_of
from datenaudit import log, looks_like_datanorm

BASIS = projektablage_import.BASIS
# außerhalb der Projektablage: weitere Grundfos-Ordner (Prüfung 26.10.: Grundfos_FULL.csv, GRUNDFOS_Prices_de_DE_MASTER.csv,
# vollständiges Pumpe↔Ersatzteil-Mapping als CSV fehlten); (Ordner, ausgelassene Unterordner)
WEITERE_ORDNER = [
    ("02 Grundfos", ("02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC",   # GPC 2023: eigener Import (gpc2023.datei)
                     "02 Grundfos/00_Datenaudit")),                   # Prüfberichte, selbst erzeugt
]
WEITERE_DATEIEN = [   # aus gemischten Ordnern nur die Grundfos-Dateien
    "06 CSV-Sammlungen & Exporte (Arbeitsstände)/Produktdaten/ParserPricesGrundfos_v12.zip",
    "06 CSV-Sammlungen & Exporte (Arbeitsstände)/Produktdaten/ParserPricesGrundfos_v12 (1).zip",
]
ACCESS = (".mdb", ".accdb")
ARCHIV = (".zip", ".rar")


def schon_da(cur, rel):
    cur.execute("select 1 from raw.quelldatei where pfad = %s or pfad like %s limit 1",
                (rel, rel.replace("%", r"\%").replace("_", r"\_") + "!/%"))
    return cur.fetchone() is not None


def platzhalter_entfernen(cur, path):
    """GF_DNM4_MP.zip-Inhalte stehen als leere Einträge (nur Name/Größe) in raw.quelldatei – die blockieren sonst
    das Einlesen (gleiche Prüfsumme). Nur Einträge ohne jeden Inhalt werden entfernt."""
    cur.execute("""delete from raw.quelldatei q
                    where q.sha256 = %s and q.format <> 'datanorm4'
                      and not exists (select 1 from raw.datanorm_satz s where s.datei_id = q.id)
                      and not exists (select 1 from raw.tabellen_zeile t where t.datei_id = q.id)
                      and not exists (select 1 from pim.quelle p where p.datei_id = q.id)""", (sha256_of(path),))
    return cur.rowcount


def archiv_mitglieder(path):
    """→ Liste (name, lesefunktion) der Dateien in ZIP/RAR"""
    if path.lower().endswith(".zip"):
        zf = zipfile.ZipFile(path)
        return [(i.filename, (lambda i=i: zf.read(i))) for i in zf.infolist() if not i.is_dir()]
    try:
        import rarfile
        rf = rarfile.RarFile(path)
        return [(i.filename, (lambda i=i: rf.read(i))) for i in rf.infolist() if not i.is_dir()]
    except Exception as e:  # noqa: BLE001 – ohne unrar nur verzeichnen
        log(f"  RAR nicht lesbar ({e!r}) – wird nur verzeichnet: {path}")
        return None


def datanorm_einlesen(con, root, lauf_id, path, known):
    with con.cursor() as cur:
        n = platzhalter_entfernen(cur, path)
        if n:
            log(f"  {n} leerer Platzhalter ersetzt: {os.path.relpath(path, root)}")
    datanorm_import.import_datanorm_file(con, root, lauf_id, path, known)
    con.commit()


def dateien(root):
    """→ (pfad, name) aller zu prüfenden Dateien: Projektablage komplett, weitere Grundfos-Ordner, Einzeldateien"""
    for ordner, auslassen in [(BASIS, ())] + WEITERE_ORDNER:
        base = os.path.join(root, ordner)
        if not os.path.isdir(base):
            log(f"  (Ordner fehlt, übersprungen: {ordner})")
            continue
        for dp, dn, fn in os.walk(base):
            rel_dir = os.path.relpath(dp, root)
            dn[:] = sorted(d for d in dn if not os.path.join(rel_dir, d).startswith(auslassen))
            for name in sorted(fn):
                yield os.path.join(dp, name), name
    for rel in WEITERE_DATEIEN:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            yield p, os.path.basename(p)
        else:
            log(f"  (Datei fehlt, übersprungen: {rel})")


def run(root="/content/drive/MyDrive", cache_dir="/content/mdb_cache"):
    t0 = time.time()
    base = os.path.join(root, BASIS)
    if not os.path.isdir(base):
        raise SystemExit(f"Ordner „{BASIS}“ nicht gefunden")
    tmp = tempfile.mkdtemp(prefix="nachtrag_")
    zaehler = {"neu": 0, "zeilen": 0, "vorhanden": 0, "datanorm": 0, "access": 0, "fehler": 0}

    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("set statement_timeout = 0")
            cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                        ("nachtrag_import v1", "Nachtrag nach Vollständigkeitsprüfung Drive ↔ Supabase (26.10.2026)"))
            lauf_id = cur.fetchone()[0]
            cur.execute("select artikelnummer_norm from pim.artikel where hersteller_id = 1")
            known = {r[0] for r in cur.fetchall()}
        con.commit()

        access = []
        for p, name in dateien(root):
            rel = os.path.relpath(p, root)
            ext = os.path.splitext(name)[1].lower()
            try:
                if ext not in ARCHIV:   # Archive: Prüfung je enthaltener Datei (s. u.)
                    with con.cursor() as cur:
                        if schon_da(cur, rel):
                            zaehler["vorhanden"] += 1
                            continue
                if ext in ACCESS:
                    access.append(p)
                    continue
                if ext in ARCHIV:
                    mitglieder = archiv_mitglieder(p)
                    if mitglieder is None:   # RAR ohne unrar: Archiv selbst verzeichnen
                        with open(p, "rb") as fh:
                            data = fh.read()
                        with con.cursor() as cur:
                            n = projektablage_import.speichere(cur, lauf_id, rel, data, name)
                        con.commit()
                        zaehler["neu"] += n is not None
                        continue
                    for mname, lies in mitglieder:
                        mrel = rel + "!/" + mname
                        ist_dn = looks_like_datanorm(os.path.basename(mname), b"") and \
                            os.path.splitext(mname)[1].lower() not in (".txt", ".pdf")
                        if not ist_dn:
                            with con.cursor() as cur:
                                if schon_da(cur, mrel):
                                    zaehler["vorhanden"] += 1
                                    continue
                        data = lies()
                        if looks_like_datanorm(os.path.basename(mname), data[:4096]) and \
                                os.path.splitext(mname)[1].lower() not in (".txt", ".pdf"):
                            # DATANORM aus dem Archiv: in ein Spiegelverzeichnis schreiben, damit der relative
                            # Pfad „…/Archiv.zip!/datanorm.001“ lautet und .002 die .001 daneben findet
                            ziel = os.path.join(tmp, mrel)
                            os.makedirs(os.path.dirname(ziel), exist_ok=True)
                            with open(ziel, "wb") as fh:
                                fh.write(data)
                            continue
                        with con.cursor() as cur:
                            n = projektablage_import.speichere(cur, lauf_id, mrel, data, mname)
                        con.commit()
                        if n is not None:
                            zaehler["neu"] += 1
                            zaehler["zeilen"] += n
                    continue
                with open(p, "rb") as fh:
                    head = fh.read(4096)
                if looks_like_datanorm(name, head) and ext not in (".txt", ".pdf", ".csv", ".xlsx"):
                    datanorm_einlesen(con, root, lauf_id, p, known)
                    zaehler["datanorm"] += 1
                    continue
                with open(p, "rb") as fh:
                    data = fh.read()
                with con.cursor() as cur:
                    n = projektablage_import.speichere(cur, lauf_id, rel, data, name)
                con.commit()
                if n is None:
                    zaehler["vorhanden"] += 1
                else:
                    zaehler["neu"] += 1
                    zaehler["zeilen"] += n
                    log(f"  neu: {rel} ({n:,} Zeilen)")
            except Exception as e:  # noqa: BLE001 – eine kaputte Datei soll den Lauf nicht stoppen
                con.rollback()
                zaehler["fehler"] += 1
                log(f"  ⚠ Fehler bei {rel}: {e!r}")

        # DATANORM aus Archiven (Spiegelverzeichnis; .001 vor .002)
        for dp, _dn, fn in os.walk(tmp):
            for name in sorted(fn):
                p = os.path.join(dp, name)
                try:
                    datanorm_einlesen(con, tmp, lauf_id, p, known)
                    zaehler["datanorm"] += 1
                except Exception as e:  # noqa: BLE001
                    con.rollback()
                    zaehler["fehler"] += 1
                    log(f"  ⚠ Fehler bei {os.path.relpath(p, tmp)}: {e!r}")
        datanorm_import.link_cross_file_langtexts(con)
        con.commit()

        with con.cursor() as cur:
            cur.execute("update raw.import_lauf set beendet_am = now() where id = %s", (lauf_id,))
        con.commit()
    shutil.rmtree(tmp, ignore_errors=True)

    # Access-Datenbanken: eigenes Schema je Datei (Kopien mit gleichem Inhalt werden über die Prüfsumme übersprungen)
    for p in access:
        # „ETB_WAE (1).MDB“ → etb_wae_1; inhaltsgleiche Kopien legen kein Schema an (Prüfsumme)
        schema = gpi_import.ident(os.path.splitext(os.path.basename(p))[0])
        try:
            gpi_import.import_db(root, p, schema, "Grundfos-Software (historisch)", None,
                                 f"{os.path.basename(p)} (Historische Grundfos-Software)", None, cache_dir)
            zaehler["access"] += 1
        except Exception as e:  # noqa: BLE001
            zaehler["fehler"] += 1
            log(f"  ⚠ Fehler bei {os.path.relpath(p, root)}: {e!r}")

    log(f"FERTIG in {(time.time() - t0) / 60:.1f} min · {zaehler['neu']} neue Dateien ({zaehler['zeilen']:,} Zeilen) · "
        f"{zaehler['datanorm']} DATANORM-Dateien geprüft · {zaehler['access']} Access-Datenbanken geprüft · "
        f"{zaehler['vorhanden']} schon vorhanden · {zaehler['fehler']} Fehler")


if __name__ == "__main__":
    run(*sys.argv[1:2])
