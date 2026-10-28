#!/usr/bin/env python3
"""
Grundfos-PIM – Import 11: Brücke PriceClaw (Supabase „solarics-produktdaten“, Tabelle public.offers) → marktbegleiter

OpenClaw liefert Scrapes an PriceClaw (offers je Quelle und Lieferung = file_id). Diese Brücke übernimmt die Lieferungen
der Marktbegleiter-Shops (QUELLEN) ins Schema marktbegleiter des Grundfos-PIM – über dieselbe Verarbeitung wie Import 9/10
(Prüfung, USt/EUR, Dubletten, Preis-Historie, Zuordnung zum Grundfos-Stamm).

  • nur herkunft = 'scrape' – eigene Einkaufspreise (eigener_ek) und Einzelfunde (live_fund) werden NIE übernommen
  • je Lieferung (file_id) genau ein Import; schon übernommene Lieferungen werden übersprungen → regelmäßig ausführbar
  • netto/brutto aus price_tax (gross/net), sonst Standard der Quelle
  • PriceClaw wird nur gelesen

Voraussetzung (Colab): Secrets SUPABASE_DB_URL (Grundfos-PIM) und SOLARICS_DB_URL (solarics-produktdaten, Session pooler).
"""

import json
import os
import re
import sys
from urllib.parse import urlparse

import psycopg

import marktbegleiter_import as mbi
import shop_exporte_import as sei
from datanorm_import import conn_params, db_url
from datenaudit import log

# (Name, Domain, Land, Standard netto/brutto, Suchmuster für Slug/Domain in quellen_stand) – Auswahl 27.10.2026
QUELLEN = [
    ("1A-Pumpen", "1a-pumpen.de", "DE", "brutto", "1a-pumpen"),
    ("ar-storeshop.com", "ar-storeshop.com", "IT", "brutto", "ar-storeshop"),
    ("BaumarktEU", "baumarkteu.de", "DE", "brutto", "baumarkteu"),
    ("ESC Grossiste", "esc-grossiste.fr", "FR", "brutto", "esc-grossiste"),
    ("glo24.de", "glo24.de", "DE", "brutto", "glo24"),
    ("heima24", "heima24.de", "DE", "brutto", "heima24"),
    ("heizung-billiger.de", "heizung-billiger.de", "DE", "brutto", "heizung-billiger"),
    ("heizungsdiscount24", "heizungsdiscount24.de", "DE", "brutto", "heizungsdiscount24"),
    ("Loebbeshop", "loebbeshop.de", "DE", "brutto", "loebbeshop"),
    ("Profluid", "profluid.de", "DE", "netto", "profluid"),
    ("Promoclima", "promoclima.it", "IT", "brutto", "promoclima"),
    ("PSW-Shop", "psw-shop.de", "DE", "netto", "psw-shop"),
    ("Pumpalia", "pumpalia.com", "ES", "brutto", "pumpalia"),
    ("pumpen24.de", "pumpen24.de", "DE", "brutto", "pumpen24"),
    ("pumpen-grosshandel.de", "pumpen-grosshandel.de", "DE", "brutto", "pumpen-grosshandel"),
    ("pumpen-guru.de", "pumpen-guru.de", "DE", "brutto", "pumpen-guru"),
    ("pumpen-heizung.de", "pumpen-heizung.de", "DE", "brutto", "pumpen-heizung"),
    ("Pumpendiscounter (Reiga GbR)", "pumpendiscounter.de", "DE", "brutto", "pumpendiscounter"),
    ("pumpengermany.de", "pumpengermany.de", "DE", "brutto", "pumpengermany"),
    ("Salvador Escoda", "salvadorescoda.com", "ES", "brutto", "salvador"),
    ("Sanundo", "sanundo.de", "DE", "brutto", "sanundo"),
    ("Sealing", "sealing.com.ua", "UA", "netto", "sealing"),
    ("Selfio", "selfio.de", "DE", "brutto", "selfio"),
    ("st-shop24.de", "st-shop24.de", "DE", "brutto", "st-shop24"),
    ("TEM Srl", "temsrl.it", "IT", "brutto", "temsrl"),
    ("TGA-Shop", "tga-shop.de", "DE", "netto", "tga-shop"),
    ("Weinmann & Schanz", "weinmann-schanz.de", "DE", "netto", "weinmann"),
    ("WIDA Handel", "wida-handel.de", "DE", "brutto", "wida"),
    ("shkhelden.de", "shkhelden.de", "DE", "brutto", "shkhelden"),
]
STEUER = {"gross": "brutto", "net": "netto"}


def quellen_finden(pc, muster):
    """source_ids in PriceClaw, deren Slug oder Domain zum Muster passt (Bindestrich/Unterstrich egal)."""
    rx = muster.replace("-", "[-_ ]?")
    with pc.cursor() as cur:
        cur.execute("""select source_id, slug, domain from public.quellen_stand
                        where slug ~* %s or coalesce(domain, '') ~* %s""", (rx, rx))
        return cur.fetchall()


def lieferungen(pc, source_ids):
    with pc.cursor() as cur:
        cur.execute("""select file_id, count(*), count(price_amount), max(scraped_at)::date, min(created_at)
                         from public.offers where source_id = any(%s) and herkunft = 'scrape' and file_id is not null
                        group by file_id order by min(created_at)""", (source_ids,))
        return cur.fetchall()


def zeile(o, land, standard_typ):
    (hersteller, mpn, ean, artikelnr, name, serie, preis, whg, steuer, verf, lieferzeit, kat, ukat, url, scraped) = o
    leer = lambda v: None if v is None or str(v).strip().lower() in sei.LEER else str(v).strip()  # noqa: E731
    f = {"hersteller": leer(hersteller), "mpn": leer(mpn), "ean": leer(ean), "bezeichnung": leer(name) or sei.name_aus_url(url),
         "baureihe": leer(serie), "kategorie": " > ".join(x for x in (leer(kat), leer(ukat)) if x) or None, "url": leer(url),
         "preis": float(preis) if preis is not None else None, "preis_typ": STEUER.get((steuer or "").lower(), standard_typ),
         "waehrung": (leer(whg) or "EUR")[:3].upper(), "lagerbestand": sei.lager(leer(verf)), "lieferzeit": leer(lieferzeit),
         "erfasst_am": scraped.date() if scraped else None, "shop_nr": leer(artikelnr)}
    ph = sei.pumpenhersteller(f["hersteller"], f["bezeichnung"])
    if not f["hersteller"] and ph:
        f["hersteller"] = ph
    if not f["mpn"] and ph == "Grundfos":           # Grundfos-Nummer aus Name, URL oder Shop-Nummer
        for q in (f["bezeichnung"], f["url"] and urlparse(f["url"]).path, f["shop_nr"]):
            m = sei.GF_NR.search(q or "")
            if m:
                f["mpn"] = m.group(1)
                break
    return f


def uebernehmen(pc, con, quelle, source_ids, file_id, n, n_preis, stand):
    name, domain, land, standard_typ, _ = quelle
    with con.cursor() as cur:
        cur.execute("select marktbegleiter.firma_ermitteln(%s, %s, %s)", (name, domain, land))
        firma_id = cur.fetchone()[0]
        kennung = f"priceclaw:{file_id}"
        cur.execute("""select i.id, (select count(*) from marktbegleiter.preise p where p.import_id = i.id)
                         from marktbegleiter.importe i where i.firma_id = %s and i.datei_sha256 = %s""", (firma_id, kennung))
        alt = cur.fetchone()
        if alt and alt[1] > 0:
            con.commit()
            return None
        # derselbe Scrape (gleicher Stand) schon über den Drive-Export (Import 10) übernommen? → nicht doppelt erfassen
        cur.execute("""select i.id, (select count(*) from marktbegleiter.preise p where p.import_id = i.id)
                         from marktbegleiter.importe i
                        where i.firma_id = %s and i.format = 'csv' and i.quelle = 'scraping' and i.stand = %s
                        order by 2 desc limit 1""", (firma_id, stand))
        drive = cur.fetchone()
        if drive and drive[1] >= 0.5 * n_preis:
            con.commit()
            return f"schon über Drive-Export übernommen (Import {drive[0]}, {drive[1]} Preise)"
        if alt:                                     # früherer Versuch ohne Preise → neu
            cur.execute("delete from marktbegleiter.import_zeilen where import_id = %s", (alt[0],))
            cur.execute("delete from marktbegleiter.importe where id = %s", (alt[0],))
        cur.execute("""insert into marktbegleiter.importe (firma_id, dateiname, datei_sha256, format, quelle, preisart, stand,
                                                          spalten, notiz)
                       values (%s, %s, %s, 'priceclaw', 'scraping', 'oeffentlich', %s, %s, %s) returning id""",
                    (firma_id, f"PriceClaw {domain} {stand}", kennung, stand,
                     json.dumps({"format": "priceclaw-offers", "file_id": str(file_id), "zeilen": n, "mit_preis": n_preis}),
                     "Import 11 (Brücke PriceClaw → marktbegleiter), nur herkunft = scrape"))
        import_id = cur.fetchone()[0]
        with pc.cursor(name=f"offers_{import_id}") as oc, \
                cur.copy("""COPY marktbegleiter.import_zeilen (import_id, zeile, rohdaten, hersteller, mpn, ean, bezeichnung,
                            baureihe, kategorie, url, preis, preis_typ, waehrung, lagerbestand, lieferzeit, erfasst_am,
                            quelle_url, land) FROM STDIN""") as cp:
            oc.itersize = 5000
            oc.execute("""select manufacturer_raw, mpn, ean, article_number, product_name, series, price_amount, currency,
                                 price_tax, availability_raw, delivery_time_raw, category_raw, subcategory_raw, product_url,
                                 scraped_at
                            from public.offers where source_id = any(%s) and file_id = %s and herkunft = 'scrape'
                           order by row_no nulls last, id""", (source_ids, file_id))
            for i, o in enumerate(oc, 1):
                f = zeile(o, land, standard_typ)
                roh = {k: f[k] for k in ("shop_nr", "hersteller", "mpn", "ean", "bezeichnung", "url") if f.get(k)}
                roh.update({"preis": f["preis"], "waehrung": f["waehrung"], "preis_typ": f["preis_typ"], "file_id": str(file_id)})
                cp.write_row((import_id, i, json.dumps(roh, ensure_ascii=False, default=str), f["hersteller"], f["mpn"],
                              f["ean"], f["bezeichnung"], f["baureihe"], f["kategorie"], f["url"], f["preis"], f["preis_typ"],
                              f["waehrung"], f["lagerbestand"], f["lieferzeit"], f["erfasst_am"] or stand, f["url"], land))
        cur.execute("select schritt, anzahl from marktbegleiter.import_verarbeiten(%s)", (import_id,))
        erg = dict(cur.fetchall())
        cur.execute("delete from marktbegleiter.import_zeilen where import_id = %s and status = 'ok'", (import_id,))
    con.commit()
    return erg


def run(nur=None):
    pc_url = os.environ.get("SOLARICS_DB_URL")
    if not pc_url:
        try:
            from google.colab import userdata  # type: ignore
            pc_url = userdata.get("SOLARICS_DB_URL")
        except Exception:  # noqa: BLE001
            pc_url = None
    if not pc_url:
        raise SystemExit("SOLARICS_DB_URL fehlt (Colab: Schlüssel-Symbol → Secret mit der Verbindungszeile von "
                         "„solarics-produktdaten“, Session pooler).")
    with psycopg.connect(**conn_params(pc_url.strip()), autocommit=False) as pc, \
            psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        pc.read_only = True                         # PriceClaw wird nur gelesen
        with con.cursor() as c:
            c.execute("set statement_timeout = 0")
        con.commit()
        for quelle in QUELLEN:
            if nur and quelle[1] not in nur:
                continue
            treffer = quellen_finden(pc, quelle[4])
            if not treffer:
                log(f"{quelle[0]}: in PriceClaw nicht vorhanden – übersprungen")
                continue
            ids = [t[0] for t in treffer]
            log(f"{quelle[0]} – PriceClaw-Quelle(n): {', '.join(t[1] for t in treffer)}")
            for file_id, n, n_preis, stand, _erstellt in lieferungen(pc, ids):
                if not n_preis:
                    log(f"  Lieferung {file_id}: {n} Zeilen ohne Preis – übersprungen")
                    continue
                try:
                    erg = uebernehmen(pc, con, quelle, ids, file_id, n, n_preis, stand)
                except Exception as e:  # noqa: BLE001 – eine kaputte Lieferung soll den Lauf nicht stoppen
                    con.rollback()
                    log(f"  ⚠ Fehler bei Lieferung {file_id}: {e!r}")
                    continue
                log(f"  Lieferung {file_id} ({stand}): " + ("schon übernommen" if erg is None else
                                                             erg if isinstance(erg, str) else f"{n} Zeilen · {erg}"))
            pc.rollback()                           # Lese-Transaktion je Quelle beenden
        with con.cursor() as cur:
            cur.execute("""select f.name, count(*) lieferungen, sum(i.positionen), sum(i.zugeordnet),
                                  sum((select count(*) from marktbegleiter.preise p where p.import_id = i.id))
                             from marktbegleiter.importe i join marktbegleiter.firmen f on f.id = i.firma_id
                            where i.format = 'priceclaw' group by f.name order by f.name""")
            log("Übernommen aus PriceClaw: Firma · Lieferungen · Positionen · zugeordnet · Preise")
            for r in cur.fetchall():
                log("  " + " · ".join(str(x) for x in r))
    log("FERTIG")


if __name__ == "__main__":
    run(sys.argv[1:] or None)
