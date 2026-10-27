#!/usr/bin/env python3
"""
Grundfos-PIM – Import 10: Shop-Exporte (Scraper) aus Google Drive → Supabase (Schema marktbegleiter, vertraulich)

Quelle: die in „Marktbegleiter aus Drive“ angehakten Shops (Auswahl 27.10.2026). Je Shop eine Exportdatei im
Scraper-Standardformat (source_url, shop_name, manufacturer, brand, product_name, manufacturer_article_number,
shop_article_number, sku, ean, gtin, price, currency, vat_info, availability, delivery_time, product_url, scraped_at …).
Andere Formate (eigene Spaltennamen) laufen über die Spaltenerkennung von Import 9.

Je Datei:
  1. per Drive-ID herunterladen (nur lesen), Prüfsumme – dieselbe Datei wird je Firma nur einmal importiert
  2. Firma über Domain der Produkt-URLs bzw. Name + Land (marktbegleiter.firma_ermitteln)
  3. Zeilen streamen und filtern (FILTER): "alle" = gesamtes Sortiment (Standard), "pumpen" = nur Produkte von
     Pumpenherstellern, "grundfos" = nur Grundfos
  4. Zuordnung der Spalten: Hersteller = manufacturer/brand (sonst aus dem Produktnamen), Artikelnummer = NUR
     manufacturer_article_number (nie Shop-Nummer/SKU), EAN = ean/gtin, Preis netto/brutto aus vat_info,
     Datum = scraped_at → marktbegleiter.import_zeilen → marktbegleiter.import_verarbeiten()
Das Original bleibt in Drive; gespeichert werden Produkte und Preise. Aus der Zwischenablage (import_zeilen) werden die
fehlerfrei verarbeiteten Zeilen danach entfernt – sie stehen vollständig in preise; Fehler und Dubletten bleiben zur Kontrolle.
Marktpreise werden nie als eigene Preise übernommen; der Grundfos-Stamm (pim) wird nur gelesen.

Voraussetzung (Colab): Secret SUPABASE_DB_URL, Drive-Anmeldung (auth.authenticate_user).
"""

import csv
import datetime as dt
import hashlib
import itertools
import json
import os
import re
import sys
from urllib.parse import urlparse

import psycopg

import marktbegleiter_import as mbi
from datanorm_import import conn_params, db_url
from datenaudit import log

FILTER = "alle"            # "alle" (gesamtes Sortiment, Auswahl 27.10.2026) | "pumpen" | "grundfos"
ZIEL = "/content/shopexporte"

# (Schlüssel, Name, Domain, Land, Drive-Datei-ID, Dateiname) – angehakt in „Marktbegleiter aus Drive“
SHOPS = [
    ("1a_pumpen", "1A-Pumpen", "1a-pumpen.de", "DE", "1SlE96gJ30KgsJKy__cjgXtHjOw-3jBQC", "1a_pumpen_products_complete.csv"),
    ("ar_store_shop", "ar-storeshop.com", "ar-storeshop.com", "IT", "1FNDWrMwcsBhAjoBejrNYVd4BpYqKMkaI", "ar_store_shop_products_complete.csv"),
    ("baumarkteu", "BaumarktEU", "baumarkteu.de", "DE", "1KVupWBR4lxeE37LaNE2uZvyjBwjMZX-V", "baumarkteu_products_complete.csv"),
    ("esc_grossiste", "ESC Grossiste", "esc-grossiste.fr", "FR", "1m-zt4wb1yunn1Tz-e0yyNmAfXYgu7h-6", "esc_grossiste_products_complete.csv"),
    ("glo24", "glo24.de", "glo24.de", "DE", "1-gy7z8RT4r6p3aWlxf8kcQIU8qeIUf-l", "glo24_products_complete.csv"),
    ("heima24", "heima24", "heima24.de", "DE", "1wNRfOD6IQGgTqGlJ1-QBrdSY4R0u-oiR", "heima24_products_complete.csv"),
    ("heizung_billiger", "heizung-billiger.de", "heizung-billiger.de", "DE", "11duwuHRS0oS7BqH0C6ZYLoBYJ1NNJ4Z2", "heizung_billiger_products_complete.csv"),
    ("heizungsdiscount24", "heizungsdiscount24", "heizungsdiscount24.de", "DE", "1S_wtWOBDHQjBim42BZ6qS4BdFJGa0PbK", "heizungsdiscount24_products_complete.csv"),
    ("loebbeshop", "Loebbeshop", "loebbeshop.de", "DE", "1esM6Cpy497Xz-kk5nywmOXKM2wxMGwlc", "loebbeshop_products_complete.csv"),
    ("profluid", "Profluid", "", "", "1CzVDiRNZHgoeaLEghQC0Xs33GOPQhN_D", "profluid_products_complete (1).csv"),
    ("promoclima_it", "Promoclima", "promoclima.it", "IT", "1HWjJfMw4kfi6HSgp-g626rDe-ez0In8C", "promoclima_it_full_products.csv"),
    ("psw_shop_fast", "PSW-Shop", "psw-shop.de", "DE", "1KmFbxqkOu02T1ohwhZxHe4TfhqDAYLOV", "psw_shop_fast_products.csv"),
    ("pumpalia", "Pumpalia", "pumpalia.com", "ES", "1A98CuAowATfvvYfGUkm-stFqvQLCcHlD", "pumpalia_products_complete.csv"),
    ("pumpen24_b2c_de", "pumpen24.de", "pumpen24.de", "DE", "1iA8OspUJEkf5b03sqZut-sD3A7a3RhpL", "pumpen24_b2c_de_products_complete.csv"),
    ("pumpen_grosshandel", "pumpen-grosshandel.de", "pumpen-grosshandel.de", "DE", "1yhCPX8IluQ7VaH9W7WQVusXnwNc0jMSM", "pumpen_grosshandel_products_complete (1).csv"),
    ("pumpen_guru", "pumpen-guru.de", "pumpen-guru.de", "DE", "1BeTtU0i9U1i4C1Risr9rFnPZRq6rWExN", "pumpen_guru_products_complete.csv"),
    ("pumpen_heizung", "pumpen-heizung.de", "pumpen-heizung.de", "DE", "1JFBz3EvS0qgpSufx8xpO2ZYuIAcnqKg0", "pumpen_heizung_products.csv"),
    ("pumpendiscounter", "Pumpendiscounter (Reiga GbR)", "pumpendiscounter.de", "DE", "1VR_k03RV9xcARZD2OAV7SOldR5GizD0s", "pumpendiscounter_products_complete.csv"),
    ("pumpengermany", "pumpengermany.de", "pumpengermany.de", "DE", "1iSxgMvkpFay_OgFiS-5aVcTrrn_69qli", "pumpengermany_products_complete.csv"),
    ("salvador_escoda", "Salvador Escoda", "salvadorescoda.com", "ES", "1JdXTFNr0Jxfv1Bt4WDGSjzm1CLy9ZY6g", "salvador_escoda_products_batch_003.csv"),
    ("sanundo", "Sanundo", "sanundo.de", "DE", "1caaJtyzGp60dZnHZhNDe5Z9YSMczhBM4", "sanundo_products_complete.csv"),
    ("sealing", "Sealing", "sealing.com.ua", "UA", "1gnzj1BnHzjSWJ_AKMexv7YLoI10M8OUz", "sealing_products_complete.csv"),
    ("selfio", "Selfio", "selfio.de", "DE", "1YvueanMM6Ha44m8amqmg-xsfGMHv3PSL", "1selfio_products_titel_hersteller_artikelnummer_ean_preis.csv"),
    ("shkhelden", "shkhelden.de", "shkhelden.de", "DE", "1X47NOOVa_Qllxun1RwlOfHCvGrudZ1HQ", "shkhelden_products_complete.csv"),
    ("st_shop24", "st-shop24.de", "st-shop24.de", "DE", "1M6A1-xqnQtItTfYuc82cn635nd5qKkDD", "st_shop24_products_complete.csv"),
    ("tem_srl", "TEM Srl", "temsrl.it", "IT", "1ak8JYMc3KQwhIu2JycUbh705Y5rm1izo", "tem_srl_products_complete.csv"),
    ("tga_shop", "TGA-Shop", "", "DE", "1VKlAj-3yI2nPYyk_NmLloQfyu699iDBd", "tga_shop_products_complete.csv"),
    ("weinmann_schanz", "Weinmann & Schanz", "weinmann-schanz.de", "DE", "1lHigBOXqZu7h59qT0badG2qua-zvZOlY", "weinmann_schanz_products.csv"),
    ("wida_handel", "WIDA Handel", "", "DE", "1XRRF6g_ULcT3OCxkU0p0ovvA4nfdmF1f", "wida_handel_products_complete.csv"),
]

# Pumpenhersteller (Anzeige-Name → Suchmuster); erster Treffer im Produktnamen gilt, wenn manufacturer/brand leer ist
PUMPEN = [
    ("Grundfos", r"grundfos"), ("Wilo", r"\bwilo\b"), ("KSB", r"\bksb\b"), ("DAB", r"\bdab\b"), ("Lowara", r"lowara"),
    ("Xylem", r"xylem"), ("Flygt", r"\bflygt\b"), ("Ebara", r"\bebara\b"), ("Pedrollo", r"pedrollo"), ("Calpeda", r"calpeda"),
    ("Speck", r"\bspeck\b"), ("Biral", r"\bbiral\b"), ("Homa", r"\bhoma\b"), ("Jung Pumpen", r"jung\s*pumpen|pentair\s*jung"),
    ("Zehnder Pumpen", r"zehnder\s*pumpen"), ("Salmson", r"salmson"), ("Espa", r"\bespa\b"), ("Sulzer", r"\bsulzer\b"),
    ("Pentair", r"pentair"), ("Kessel", r"\bkessel\b"), ("SFA", r"\bsfa\b|sanibroy|sanifos|saniflo"), ("Caprari", r"caprari"),
    ("Saer", r"\bsaer\b"), ("Nocchi", r"nocchi"), ("Rovatti", r"rovatti"), ("Zenit", r"\bzenit\b"), ("Tsurumi", r"tsurumi"),
    ("Pentax", r"\bpentax\b"), ("Leo", r"\bleo\s+pump"), ("Smedegaard", r"smedegaard"), ("Taco", r"\btaco\b"),
    ("Deutsche Vortex", r"vortex"), ("Laing", r"\blaing\b"), ("Halm", r"\bhalm\b"), ("T.I.P.", r"\bt\.?i\.?p\.?\b"),
    ("Sterling", r"sterling\s*sihi|\bsihi\b"), ("Oase", r"\boase\b"), ("Gardena", r"gardena"), ("Einhell", r"einhell"),
    ("Metabo", r"metabo"), ("Kärcher", r"k(ä|ae)rcher"), ("Aquatechnik", r"aquatechnik"), ("Elpumps", r"elpumps"),
    ("Ferroli", r"\bferroli\b"), ("Lowara/Vogel", r"\bvogel\b"),
]
PUMPEN_RE = [(n, re.compile(m, re.I)) for n, m in PUMPEN]
GF_NR = re.compile(r"(?<![\d.,])(9\d{7}|[1-9]\d{7})(?![\d.,])")
BRUTTO = re.compile(r"inkl|incl|inclus|incluid|ttc|iva\s*inc|mit\s*mwst|gross|brutto", re.I)
NETTO = re.compile(r"exkl|excl|zzgl|zuzgl|\bht\b|esclus|sin\s*iva|ohne\s*mwst|netto|\bnet\b|plus\s*vat", re.I)
LAENDER = {"germany": "DE", "deutschland": "DE", "austria": "AT", "österreich": "AT", "switzerland": "CH", "schweiz": "CH",
           "france": "FR", "italy": "IT", "italia": "IT", "spain": "ES", "españa": "ES", "netherlands": "NL", "belgium": "BE",
           "poland": "PL", "czech republic": "CZ", "czechia": "CZ", "romania": "RO", "ukraine": "UA", "united kingdom": "GB"}


SCHEMA_LAGER = {"instock": "in stock", "outofstock": "out of stock", "soldout": "ausverkauft", "discontinued": "nicht lieferbar",
                "preorder": "vorbestellbar", "backorder": "nachbestellt", "limitedavailability": "available, begrenzt",
                "instoreonly": "nur im Laden"}


def lager(v):
    """schema.org-Werte (http://schema.org/InStock) lesbar machen, damit „lieferbar“ erkannt wird."""
    if not v:
        return None
    k = re.sub(r"^https?://schema\.org/", "", v.strip(), flags=re.I)
    return SCHEMA_LAGER.get(k.lower(), k)


LEER = {"", "-", "--", "n/a", "na", "none", "null", "not_found", "not found", "unknown", "unbekannt", "k.a.", "0"}


def name_aus_url(url):
    """Produktname aus der URL, wenn der Export keinen hat: …/12027-grundfos-pompa-cm-a-3-4-cod-92889472.html"""
    if not url:
        return None
    teil = urlparse(url).path.rstrip("/").rsplit("/", 1)[-1]
    teil = re.sub(r"\.(html?|php|aspx?)$", "", teil, flags=re.I)
    teil = re.sub(r"^\d+[-_]", "", teil)
    teil = re.sub(r"[-_+]+", " ", teil).strip()
    return teil or None


def pumpenhersteller(hersteller, name):
    """→ Anzeige-Name des Pumpenherstellers oder None"""
    for txt in (hersteller, name):
        if txt:
            for n, rx in PUMPEN_RE:
                if rx.search(txt):
                    return n
    return None


def lade(file_id, datei):
    """Datei per Drive-API (nur lesen) nach ZIEL laden; vorhandene Kopie wird wiederverwendet."""
    os.makedirs(ZIEL, exist_ok=True)
    pfad = os.path.join(ZIEL, re.sub(r"[^\w.() -]", "_", datei))
    if os.path.exists(pfad) and os.path.getsize(pfad) > 0:
        return pfad
    from googleapiclient.discovery import build  # type: ignore
    from googleapiclient.http import MediaIoBaseDownload  # type: ignore
    svc = build("drive", "v3", cache_discovery=False)
    req = svc.files().get_media(fileId=file_id, supportsAllDrives=True)
    with open(pfad + ".part", "wb") as fh:
        dl, fertig = MediaIoBaseDownload(fh, req, chunksize=64 * 1024 * 1024), False
        while not fertig:
            _status, fertig = dl.next_chunk()
    os.replace(pfad + ".part", pfad)
    return pfad


def zeilen(pfad):
    """CSV streamen (Trennzeichen erkennen, sehr lange Felder erlauben)."""
    csv.field_size_limit(sys.maxsize)
    fh = open(pfad, encoding="utf-8-sig", errors="replace", newline="")
    probe = fh.read(20000)
    fh.seek(0)
    trenner = max((",", ";", "\t"), key=lambda t: probe.split("\n", 1)[0].count(t))
    return csv.DictReader(fh, delimiter=trenner)


def zuordnen(z, standard, generisch):
    """Eine Zeile → Felder für import_zeilen (Scraper-Standard oder Spaltenerkennung von Import 9)."""
    if standard:
        g = lambda *ks: next((z[k].strip() for k in ks if (z.get(k) or "").strip().lower() not in LEER), None)  # noqa: E731
        vat = g("vat_info") or ""
        url = g("product_url", "canonical_url")
        return {
            "hersteller": g("manufacturer", "brand"), "mpn": g("manufacturer_article_number"), "ean": g("ean", "gtin"),
            "bezeichnung": g("product_full_name", "product_name") or name_aus_url(url), "baureihe": g("product_series"),
            "kategorie": g("product_category", "category_path", "breadcrumb"), "url": url,
            "preis": mbi.zahl(g("price")), "preis_typ": "netto" if NETTO.search(vat) and not BRUTTO.search(vat) else "brutto",
            "waehrung": (g("currency") or "EUR")[:3].upper(),
            "lagerbestand": lager(g("availability", "stock_status")),
            "lieferzeit": g("delivery_time"), "erfasst_am": mbi.datum(g("scraped_at")),
            "land": LAENDER.get((g("source_country") or "").lower()),
            "shop": g("shop_name", "supplier"), "shop_nr": g("shop_article_number", "sku", "article_number"),
        }
    r = generisch
    w = lambda f: (z.get(r[f]) or "").strip() or None if f in r else None  # noqa: E731
    return {"hersteller": w("hersteller"), "mpn": w("mpn"), "ean": w("ean"), "bezeichnung": w("bezeichnung"),
            "baureihe": w("baureihe"), "kategorie": w("kategorie"), "url": w("quelle_url"),
            "preis": mbi.zahl(w("preis_brutto") or w("preis_netto")),
            "preis_typ": "netto" if "preis_netto" in r and "preis_brutto" not in r else "brutto",
            "waehrung": (w("waehrung") or "EUR")[:3].upper(), "lagerbestand": w("lagerbestand"), "lieferzeit": w("lieferzeit"),
            "erfasst_am": None, "land": None, "shop": None, "shop_nr": None}


def verarbeite(con, shop):
    key, name, domain, land, file_id, datei = shop
    pfad = lade(file_id, datei)
    sha = hashlib.sha256()
    with open(pfad, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            sha.update(block)
    sha = sha.hexdigest()

    rd = zeilen(pfad)
    kopf = rd.fieldnames or []
    standard = {"price", "product_url"} <= set(kopf) and ("manufacturer_article_number" in kopf or "manufacturer" in kopf)
    generisch = {} if standard else mbi.spalten(list(itertools.islice(zeilen(pfad), 300)))

    auszug, gelesen, domains, laender, staende = [], 0, {}, {}, []
    for z in rd:
        gelesen += 1
        f = zuordnen(z, standard, generisch)
        ph = pumpenhersteller(f["hersteller"], f["bezeichnung"])
        if FILTER == "pumpen" and not ph:
            continue
        if FILTER == "grundfos" and ph != "Grundfos":
            continue
        if not f["hersteller"] and ph:
            f["hersteller"] = ph
        if not f["mpn"] and ph == "Grundfos":       # Grundfos-Nummer steht oft nur im Namen, in der URL oder als Shop-Nummer
            for quelle in (f["bezeichnung"], f["url"] and urlparse(f["url"]).path, f.get("shop_nr")):
                m = GF_NR.search(quelle or "")
                if m:
                    f["mpn"] = m.group(1)
                    break
        if f["url"]:
            h = urlparse(f["url"]).hostname or ""
            domains[h] = domains.get(h, 0) + 1
        if f["land"]:
            laender[f["land"]] = laender.get(f["land"], 0) + 1
        if f["erfasst_am"]:
            staende.append(f["erfasst_am"])
        auszug.append((z, f))

    dom = domain or (max(domains, key=domains.get) if domains else None)
    lnd = land or (max(laender, key=laender.get) if laender else "DE")
    stand = max(staende) if staende else dt.date.fromtimestamp(os.path.getmtime(pfad))
    if not auszug:
        log(f"  {name}: {gelesen} Zeilen gelesen, keine passenden Produkte (Filter {FILTER}) – übersprungen")
        return

    with con.cursor() as cur:
        cur.execute("select marktbegleiter.firma_ermitteln(%s, %s, %s)", (name, dom, lnd))
        firma_id = cur.fetchone()[0]
        cur.execute("""select i.id, i.status, (select count(*) from marktbegleiter.preise p where p.import_id = i.id)
                         from marktbegleiter.importe i where i.firma_id = %s and i.datei_sha256 = %s""", (firma_id, sha))
        alt = cur.fetchone()
        if alt and alt[2] == 0:      # früherer Lauf ohne einen einzigen Preis (z. B. Spalten nicht erkannt) → neu einlesen
            cur.execute("delete from marktbegleiter.import_zeilen where import_id = %s", (alt[0],))
            cur.execute("delete from marktbegleiter.importe where id = %s", (alt[0],))
            log(f"  {name}: früherer Import {alt[0]} ohne Preise – wird neu eingelesen")
            alt = None
        if alt:
            con.commit()
            log(f"  {name}: schon importiert (Import {alt[0]}, {alt[1]})")
            return
        cur.execute("""insert into marktbegleiter.importe (firma_id, dateiname, datei_sha256, format, quelle, preisart, stand,
                                                          spalten, notiz)
                       values (%s, %s, %s, 'csv', 'scraping', 'oeffentlich', %s, %s, %s) returning id""",
                    (firma_id, datei, sha, stand,
                     json.dumps({"format": "scraper-standard" if standard else "erkannt", "filter": FILTER,
                                 "zeilen_gelesen": gelesen, "zeilen_uebernommen": len(auszug),
                                 **({} if standard else generisch)}, ensure_ascii=False),
                     f"Drive-Datei {file_id}; Import 10 (Shop-Exporte)"))
        import_id = cur.fetchone()[0]
        with cur.copy("""COPY marktbegleiter.import_zeilen (import_id, zeile, rohdaten, hersteller, mpn, ean, bezeichnung,
                          baureihe, kategorie, url, preis, preis_typ, waehrung, lagerbestand, lieferzeit, erfasst_am,
                          quelle_url, land) FROM STDIN""") as cp:
            for i, (_z, f) in enumerate(auszug, 1):
                roh = {k: f[k] for k in ("shop", "shop_nr", "hersteller", "mpn", "ean", "bezeichnung", "url") if f.get(k)}
                roh.update({"preis": f["preis"], "waehrung": f["waehrung"], "preis_typ": f["preis_typ"]})
                cp.write_row((import_id, i, json.dumps(roh, ensure_ascii=False, default=str), f["hersteller"], f["mpn"],
                              f["ean"], f["bezeichnung"], f["baureihe"], f["kategorie"], f["url"], f["preis"], f["preis_typ"],
                              f["waehrung"], f["lagerbestand"], f["lieferzeit"], f["erfasst_am"] or stand, f["url"], lnd))
        cur.execute("select schritt, anzahl from marktbegleiter.import_verarbeiten(%s)", (import_id,))
        erg = dict(cur.fetchall())
        cur.execute("delete from marktbegleiter.import_zeilen where import_id = %s and status = 'ok'", (import_id,))
    con.commit()
    log(f"  {name} ({dom}, {lnd}): {gelesen} gelesen → {len(auszug)} übernommen · {erg}")


def run(nur=None):
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("set statement_timeout = 0")
        con.commit()
        for shop in SHOPS:
            if nur and shop[0] not in nur:
                continue
            log(f"{shop[1]} – {shop[5]}")
            try:
                verarbeite(con, shop)
            except Exception as e:  # noqa: BLE001 – ein kaputter Export soll den Lauf nicht stoppen
                con.rollback()
                log(f"  ⚠ Fehler bei {shop[1]}: {e!r}")
        with con.cursor() as cur:
            cur.execute("""select f.name, f.land, i.status, i.positionen, i.zugeordnet, i.vorschlaege, i.nicht_zugeordnet,
                                  i.fehlerhaft, i.dubletten
                             from marktbegleiter.importe i join marktbegleiter.firmen f on f.id = i.firma_id
                            where i.quelle = 'scraping' and i.importiert_am > now() - interval '1 day' order by f.name""")
            log("Ergebnis je Shop: Firma · Land · Status · Positionen · zugeordnet · Vorschläge · nicht zugeordnet · "
                "fehlerhaft · Dubletten")
            for r in cur.fetchall():
                log("  " + " · ".join(str(x) for x in r))
    log("FERTIG")


if __name__ == "__main__":
    run(sys.argv[1:] or None)
