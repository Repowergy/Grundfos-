#!/usr/bin/env python3
"""
Grundfos-PIM – Import 11: Grundfos-Angebote aus den OpenClaw-Lieferungen (Supabase „solarics-produktdaten“)
→ Marktbegleiter-Datenbank (Schema marktbegleiter, vertraulich)

OpenClaw liefert Shop-Exporte per Drive/rclone nach solarics-produktdaten (public.source_files „openclaw_<shop>_<zeit>“,
public.offers). Dieses Werkzeug liest dort nur (Lese-Transaktion) und übernimmt je Lieferdatei die Grundfos-Angebote:
  1. Firma über Domain/Name + Land erkennen (marktbegleiter.firma_ermitteln) – vorhandene Firmen werden weiterverwendet
  2. je Lieferdatei ein Import (Prüfsumme der OpenClaw-Datei → dieselbe Lieferung wird nur einmal übernommen)
  3. Zeilen → marktbegleiter.import_zeilen, dann marktbegleiter.import_verarbeiten (Prüfung, Produkte, Preis-Historie, Zuordnung)
Netto/Brutto: Angabe der Lieferung bzw. der Quelle; „unknown“ → brutto (öffentliche Shop-Preise), im Import vermerkt.
Marktpreise werden nie als eigene Preise übernommen; der Grundfos-Stamm (pim) wird nur gelesen.

Voraussetzung (Colab): Secrets SUPABASE_DB_URL (Grundfos-PIM) und SOLARICS_DB_URL (solarics-produktdaten, Session pooler).

    python3 openclaw_uebernahme.py [ab-datum, Standard: vor 3 Tagen]
"""

import datetime as dt
import hashlib
import json
import os
import re
import sys

import psycopg

from datanorm_import import conn_params, db_url
from datenaudit import log

QUELLE_SQL = """
select f.id::text datei, f.checksum, f.original_filename, f.received_at,
       s.slug, s.name, s.website, s.country, s.price_tax quelle_steuer,
       o.row_no, o.manufacturer_raw, o.mpn, o.ean, o.product_name, o.series, o.category_raw, o.product_url,
       o.price_amount, o.currency, o.price_tax, o.availability_raw, o.stock_qty, o.delivery_time_raw, o.scraped_at
  from public.offers o
  join public.source_files f on f.id = o.file_id
  join public.price_sources s on s.id = o.source_id
 where f.original_filename like 'openclaw\\_%%' and f.received_at >= %s and o.manufacturer_raw ilike '%%grundfos%%'
 order by f.received_at, f.id, o.row_no
"""

STEUER = {"gross": "brutto", "net": "netto"}


def quelle_url():
    url = os.environ.get("SOLARICS_DB_URL")
    if not url:
        try:
            from google.colab import userdata  # type: ignore
            url = userdata.get("SOLARICS_DB_URL")
        except Exception:  # noqa: BLE001
            url = None
    if not url:
        raise SystemExit("SOLARICS_DB_URL fehlt (Colab: Schlüssel-Symbol → Secret anlegen, Session pooler von solarics-produktdaten).")
    return url.strip()


def domain(website):
    h = re.sub(r"^https?://", "", (website or "").strip().lower())
    h = re.sub(r"^www\.", "", h).split("/")[0]
    return h or None


def lesen(ab):
    with psycopg.connect(**conn_params(quelle_url())) as src:
        src.read_only = True          # Lese-Transaktion: in solarics-produktdaten wird nichts verändert
        with src.cursor() as cur:
            cur.execute(QUELLE_SQL, (ab,))
            namen = [d.name for d in cur.description]
            return [dict(zip(namen, r)) for r in cur.fetchall()]


def uebernehmen(con, zeilen):
    z0 = zeilen[0]
    sha = hashlib.sha256(("openclaw:" + (z0["checksum"] or z0["datei"])).encode()).hexdigest()
    stand = z0["received_at"].date()
    with con.cursor() as cur:
        cur.execute("select marktbegleiter.firma_ermitteln(%s, %s, %s)", (z0["name"], domain(z0["website"]), z0["country"]))
        firma_id = cur.fetchone()[0]
        cur.execute("select id, status from marktbegleiter.importe where firma_id = %s and datei_sha256 = %s", (firma_id, sha))
        alt = cur.fetchone()
        if alt:
            con.commit()
            log(f"  schon übernommen (Import {alt[0]}, {alt[1]}): {z0['original_filename']}")
            return
        unklar = sum(1 for z in zeilen if z["price_tax"] not in STEUER and z["quelle_steuer"] not in STEUER)
        cur.execute("""insert into marktbegleiter.importe (firma_id, dateiname, datei_sha256, format, quelle, preisart, stand, spalten, notiz)
                       values (%s, %s, %s, 'openclaw', 'scraping', 'oeffentlich', %s, %s, %s) returning id""",
                    (firma_id, z0["original_filename"], sha, stand,
                     json.dumps({"quelle": "solarics-produktdaten", "source_file": z0["datei"], "slug": z0["slug"]}),
                     f"OpenClaw-Lieferung {z0['received_at']:%d.%m.%Y %H:%M} UTC aus solarics-produktdaten (nur Grundfos)"
                     + (f"; {unklar} Zeilen ohne Netto/Brutto-Angabe → als brutto angenommen" if unklar else "")))
        import_id = cur.fetchone()[0]
        with cur.copy("""COPY marktbegleiter.import_zeilen (import_id, zeile, rohdaten, hersteller, mpn, ean, bezeichnung, baureihe,
                          kategorie, url, preis, preis_typ, waehrung, lagerbestand, lieferzeit, erfasst_am, quelle_url, land)
                         FROM STDIN""") as cp:
            for i, z in enumerate(zeilen, 1):
                typ = STEUER.get(z["price_tax"]) or STEUER.get(z["quelle_steuer"]) or "brutto"
                lager = z["availability_raw"] or (str(z["stock_qty"]) if z["stock_qty"] is not None else None)
                cp.write_row((import_id, i, json.dumps({k: v for k, v in z.items() if k not in ("received_at", "scraped_at")},
                                                       ensure_ascii=False, default=str),
                              z["manufacturer_raw"], z["mpn"], z["ean"], z["product_name"], z["series"], z["category_raw"],
                              z["product_url"], z["price_amount"], typ, (z["currency"] or "EUR").upper()[:3], lager,
                              z["delivery_time_raw"], (z["scraped_at"] or z["received_at"]).date(), z["product_url"], z["country"]))
        cur.execute("select schritt, anzahl from marktbegleiter.import_verarbeiten(%s)", (import_id,))
        erg = dict(cur.fetchall())
    con.commit()
    log(f"  {z0['original_filename']}: {len(zeilen)} Grundfos-Angebote → {erg}")


def run(ab=None):
    ab = dt.date.fromisoformat(ab) if ab else dt.date.today() - dt.timedelta(days=3)
    log(f"OpenClaw-Lieferungen ab {ab} lesen (solarics-produktdaten, nur lesend) …")
    alle = lesen(ab)
    dateien = {}
    for z in alle:
        dateien.setdefault(z["datei"], []).append(z)
    log(f"{len(alle)} Grundfos-Angebote in {len(dateien)} Lieferdateien")
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("set statement_timeout = 0")
        for zeilen in dateien.values():
            try:
                uebernehmen(con, zeilen)
            except Exception as e:  # noqa: BLE001 – eine kaputte Lieferung soll den Lauf nicht stoppen
                con.rollback()
                log(f"  ⚠ Fehler bei {zeilen[0]['original_filename']}: {e!r}")
        with con.cursor() as cur:
            cur.execute("""select f.name, f.land, i.dateiname, i.status, i.positionen, i.zugeordnet, i.vorschlaege,
                                  i.nicht_zugeordnet, i.fehlerhaft, i.dubletten
                             from marktbegleiter.importe i join marktbegleiter.firmen f on f.id = i.firma_id
                            where i.format = 'openclaw' and i.importiert_am > now() - interval '1 day' order by f.name, i.id""")
            log("Ergebnis: Firma · Land · Datei · Status · Positionen · zugeordnet · Vorschläge · nicht zugeordnet · fehlerhaft · Dubletten")
            for r in cur.fetchall():
                log("  " + " · ".join(str(x) for x in r))
    log("FERTIG")


if __name__ == "__main__":
    run(*sys.argv[1:2])
