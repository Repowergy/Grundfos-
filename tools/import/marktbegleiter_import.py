#!/usr/bin/env python3
"""
Grundfos-PIM – Import 9: Preislisten der Marktbegleiter → Supabase (Schema marktbegleiter, vertraulich)

Ablage in Google Drive – ein Unterordner je Marktbegleiter: „Name (Land)“ oder „domain.tld (Land)“, optional eine
Datei firma.json mit {"name", "domain", "land", "ansprechpartner", "email", "preisart", "preis_typ", "waehrung"}:

    GRUNDFOS – Marktbegleiter Preise/
        Pumpenhandel Muster (DE)/Preisliste_2026-10.xlsx
        haustechnik-beispiel.at (AT)/preise.csv
        Scraping Export (EU)/export.jsonl

Formate: CSV, XLSX/XLSM, JSON/JSONL (strukturierte Scraping-Exporte: Liste von Objekten).
Je Datei:
  1. Original unverändert nach raw.quelldatei/raw.tabellen_zeile; dieselbe Datei (Prüfsumme) wird je Firma nur einmal importiert
  2. Firma über Domain bzw. Name + Land erkennen (marktbegleiter.firma_ermitteln) – keine Dubletten
  3. Spalten erkennen (Hersteller, Artikelnummer/MPN, EAN, Bezeichnung, Baureihe, Kategorie, Preis netto/brutto, MwSt, Währung,
     Preiseinheit, Mindestmenge, Staffel, Versand, Lager, Lieferzeit, gültig ab/bis, URL) → marktbegleiter.import_zeilen
  4. marktbegleiter.import_verarbeiten(): Prüfung, Produkte, Preise (Historie, Dubletten übersprungen), Zuordnung zum Grundfos-Stamm
Ergebnis je Datei und Firma wird ausgegeben (zugeordnet / Vorschläge / nicht zugeordnet / fehlerhaft / Dubletten).
Marktpreise werden nie als eigene Preise übernommen; der Grundfos-Stamm (pim) wird nur gelesen.

Voraussetzung (Colab): Secret SUPABASE_DB_URL. Quelldateien werden nur gelesen.
"""

import datetime as dt
import hashlib
import json
import os
import re
import sys

import psycopg

import projektablage_import
from datanorm_import import conn_params, db_url
from datenaudit import log

ORDNER = "GRUNDFOS – Marktbegleiter Preise"
ENDUNGEN = (".csv", ".xlsx", ".xlsm", ".txt", ".json", ".jsonl")

# Spaltenname (klein) → Feld; Reihenfolge = Vorrang. Preis-Spalten müssen überwiegend Zahlen enthalten.
MUSTER = {
    "hersteller": [r"^hersteller$", r"hersteller(name)?$", r"manufacturer", r"brand", r"marke"],
    "mpn": [r"hersteller.?art", r"herst.?nr", r"\bmpn\b", r"werks.?art", r"grundfos.?(nr|nummer|art)", r"art(ikel)?[ ._-]*n(umme)?r",
            r"artnr", r"material", r"produktnummer", r"product.?(no|number)", r"\bsku\b", r"item.?(no|number)"],
    "ean": [r"\bean\b", r"gtin", r"barcode", r"ean"],
    "bezeichnung": [r"bezeichnung", r"beschreibung", r"artikeltext", r"kurztext", r"produktname", r"titel", r"title", r"name",
                    r"description", r"text"],
    "baureihe": [r"baureihe", r"serie", r"series", r"familie", r"family"],
    "kategorie": [r"kategorie", r"category", r"warengruppe", r"gruppe"],
    "preis_netto": [r"netto", r"\bek\b", r"einkauf", r"net.?price", r"\bnet\b", r"exkl"],
    "preis_brutto": [r"brutto", r"\bvk\b", r"verkauf", r"inkl", r"gross", r"listenpreis", r"\bupe\b", r"\buvp\b", r"preis", r"price"],
    "ust_satz": [r"mwst", r"ust", r"vat", r"steuer"],
    "waehrung": [r"w(ä|ae)hrung", r"currency", r"\bwhg\b"],
    "preiseinheit": [r"preiseinheit", r"\bpe\b", r"price.?unit", r"per\b"],
    "mengeneinheit": [r"mengeneinheit", r"\bme\b", r"einheit", r"unit"],
    "mindestmenge": [r"mindest", r"\bmoq\b", r"min.?(menge|qty|order)"],
    "staffel_ab": [r"staffel", r"ab.?menge", r"tier", r"break"],
    "versand": [r"versand", r"fracht", r"shipping", r"delivery.?cost"],
    "lagerbestand": [r"lager", r"bestand", r"verf(ü|ue)gbar", r"stock", r"availability"],
    "lieferzeit": [r"lieferzeit", r"lead.?time", r"delivery.?time"],
    "gueltig_ab": [r"g(ü|ue)ltig.?(ab|von)", r"valid.?from"],
    "gueltig_bis": [r"g(ü|ue)ltig.?bis", r"valid.?(to|until)"],
    "quelle_url": [r"\burl\b", r"link", r"produktseite"],
}
ZAHLEN = ("preis_netto", "preis_brutto", "ust_satz", "preiseinheit", "mindestmenge", "staffel_ab", "versand")


def zahl(v):
    if v is None:
        return None
    s = re.sub(r"[^\d,.\-]", "", str(v))
    if not s or s in "-.,":
        return None
    if "," in s and "." in s:
        s = s.replace(".", "").replace(",", ".") if s.rfind(",") > s.rfind(".") else s.replace(",", "")
    elif "," in s:
        s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def datum(v):
    if not v:
        return None
    s = str(v).strip()[:10]
    for f in ("%Y-%m-%d", "%d.%m.%Y", "%d/%m/%Y", "%d.%m.%y"):
        try:
            return dt.datetime.strptime(s, f).date()
        except ValueError:
            pass
    return None


def spalten(zeilen):
    """→ {feld: spaltenname}"""
    kopf = list(zeilen[0].keys()) if zeilen else []
    probe = zeilen[:300]
    rollen, belegt = {}, set()
    for feld, muster in MUSTER.items():
        for m in muster:
            treffer = [k for k in kopf if k not in belegt and re.search(m, str(k).lower())]
            if feld in ZAHLEN:   # Preise: überwiegend Zahlen; Nebenspalten (Versand, Staffel …) dürfen lückenhaft sein
                anteil = 0.6 if feld.startswith("preis_") else 0.1
                treffer = [k for k in treffer if sum(zahl(z.get(k)) is not None for z in probe) >= anteil * max(len(probe), 1)]
            if treffer:
                rollen[feld] = treffer[0]
                belegt.add(treffer[0])
                break
    return rollen


def lese_tabelle(name, data):
    ext = os.path.splitext(name)[1].lower()
    if ext in (".json", ".jsonl"):
        text = data.decode("utf-8", errors="replace")
        objs = [json.loads(z) for z in text.splitlines() if z.strip()] if ext == ".jsonl" else json.loads(text)
        if isinstance(objs, dict):
            objs = next((v for v in objs.values() if isinstance(v, list)), [objs])
        return [{k: (json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else v) for k, v in o.items()}
                for o in objs if isinstance(o, dict)]
    _fmt, _enc, tabellen = projektablage_import.lese(name, data)
    return max(tabellen.values(), key=len) if tabellen else []    # größtes Blatt


def firma_info(ordnername, pfad):
    info = {}
    fj = os.path.join(pfad, "firma.json")
    if os.path.exists(fj):
        info = json.load(open(fj, encoding="utf-8"))
    m = re.match(r"^(.*?)\s*\(([A-Za-z]{2,3})\)\s*$", ordnername)
    name, land = (m.group(1).strip(), m.group(2).upper()) if m else (ordnername.strip(), None)
    domain = name if re.match(r"^[\w.-]+\.[a-z]{2,}$", name, re.I) else None
    return {"name": info.get("name") or name, "domain": info.get("domain") or domain, "land": info.get("land") or land,
            **{k: info.get(k) for k in ("ansprechpartner", "email", "preisart", "preis_typ", "waehrung")}}


def verarbeite(con, root, pfad, fi):
    rel = os.path.relpath(pfad, root)
    with open(pfad, "rb") as fh:
        data = fh.read()
    sha = hashlib.sha256(data).hexdigest()
    with con.cursor() as cur:
        cur.execute("select marktbegleiter.firma_ermitteln(%s, %s, %s)", (fi["name"], fi["domain"], fi["land"]))
        firma_id = cur.fetchone()[0]
        if fi.get("ansprechpartner") or fi.get("email"):
            cur.execute("""update marktbegleiter.firmen set ansprechpartner = coalesce(%s, ansprechpartner),
                           email = coalesce(%s, email), geaendert_am = now() where id = %s""",
                        (fi.get("ansprechpartner"), fi.get("email"), firma_id))
        cur.execute("select id, status from marktbegleiter.importe where firma_id = %s and datei_sha256 = %s", (firma_id, sha))
        alt = cur.fetchone()
        if alt:
            con.commit()
            log(f"  schon importiert (Import {alt[0]}, {alt[1]}): {rel}")
            return
        # Original sichern (raw; gleiche Datei aus anderem Ordner wird dort nicht doppelt abgelegt)
        cur.execute("insert into raw.import_lauf (werkzeug, notiz) values ('marktbegleiter_import v2', %s) returning id", (rel,))
        lauf_id = cur.fetchone()[0]
        projektablage_import.speichere(cur, lauf_id, rel, data, os.path.basename(pfad))
        cur.execute("select id from raw.quelldatei where sha256 = %s", (sha,))
        datei_id = cur.fetchone()[0]

        zeilen = lese_tabelle(os.path.basename(pfad), data)
        rollen = spalten(zeilen)
        preis_typ = fi.get("preis_typ") or ("netto" if "preis_netto" in rollen and "preis_brutto" not in rollen else "brutto")
        preis_sp = rollen.get("preis_" + preis_typ) or rollen.get("preis_brutto") or rollen.get("preis_netto")
        if preis_sp == rollen.get("preis_netto") and preis_sp != rollen.get("preis_brutto"):
            preis_typ = "netto"
        stand = dt.date.fromtimestamp(os.path.getmtime(pfad))
        cur.execute("""insert into marktbegleiter.importe (firma_id, dateiname, datei_sha256, datei_id, format, quelle, preisart,
                                                          stand, spalten)
                       values (%s, %s, %s, %s, %s, %s, %s, %s, %s) returning id""",
                    (firma_id, os.path.basename(pfad), sha, datei_id, os.path.splitext(pfad)[1].lstrip(".").lower(),
                     "scraping" if pfad.lower().endswith((".json", ".jsonl")) else "preisliste",
                     fi.get("preisart") or "haendlerpreis", stand, json.dumps({**rollen, "preis": preis_sp, "preis_typ": preis_typ},
                                                                               ensure_ascii=False)))
        import_id = cur.fetchone()[0]
        g = lambda z, f: z.get(rollen[f]) if f in rollen else None   # noqa: E731
        with cur.copy("""COPY marktbegleiter.import_zeilen (import_id, zeile, rohdaten, hersteller, mpn, ean, bezeichnung, baureihe,
                          kategorie, url, preis, preis_typ, ust_satz, waehrung, preiseinheit, mengeneinheit, mindestmenge, staffel_ab,
                          versand, lagerbestand, lieferzeit, gueltig_ab, gueltig_bis, erfasst_am, quelle_url, land) FROM STDIN""") as cp:
            for i, z in enumerate(zeilen, 1):
                whg = (str(g(z, "waehrung") or "").strip().upper()[:3] or fi.get("waehrung") or "EUR")
                cp.write_row((import_id, i, json.dumps(z, ensure_ascii=False), g(z, "hersteller"),
                              str(g(z, "mpn")).strip() if g(z, "mpn") not in (None, "") else None,
                              str(g(z, "ean")).strip() if g(z, "ean") not in (None, "") else None,
                              g(z, "bezeichnung"), g(z, "baureihe"), g(z, "kategorie"), g(z, "quelle_url"),
                              zahl(z.get(preis_sp)) if preis_sp else None, preis_typ, zahl(g(z, "ust_satz")), whg,
                              zahl(g(z, "preiseinheit")), g(z, "mengeneinheit"), zahl(g(z, "mindestmenge")), zahl(g(z, "staffel_ab")),
                              zahl(g(z, "versand")), g(z, "lagerbestand"), g(z, "lieferzeit"), datum(g(z, "gueltig_ab")),
                              datum(g(z, "gueltig_bis")), stand, g(z, "quelle_url"), fi["land"]))
        cur.execute("select schritt, anzahl from marktbegleiter.import_verarbeiten(%s)", (import_id,))
        erg = dict(cur.fetchall())
    con.commit()
    log(f"  {rel}: {erg} · Spalten {rollen}")


def _ordnername(n):
    """Vergleichsform: Groß/klein, Bindestrich-Varianten (– — -) und Leerzeichen egal."""
    return re.sub(r"[\s\-–—_]+", " ", n).strip().lower()


def finde_ordner(root, ordner=ORDNER):
    """Ordner in „Meine Ablage“ suchen – direkt oder bis zu zwei Ebenen tiefer (z. B. GRUNDFOS/…), auch geteilte Ablagen."""
    ziel = _ordnername(ordner)
    wurzeln = [root] + [d for d in ("/content/drive/Shareddrives", "/content/drive/Shared drives") if os.path.isdir(d)]
    aehnlich = []
    for w in wurzeln:
        for dp, dn, _fn in os.walk(w):
            tiefe = os.path.relpath(dp, w).count(os.sep) + (0 if dp == w else 1)
            for d in dn:
                if _ordnername(d) == ziel:
                    return os.path.join(dp, d)
                if "marktbegleiter" in d.lower():
                    aehnlich.append(os.path.join(dp, d))
            if tiefe >= 2:
                dn[:] = []
            else:
                dn[:] = [d for d in dn if not d.startswith(".")]
    passend = [a for a in aehnlich if "preis" in os.path.basename(a).lower()]
    if len(passend) == 1:
        return passend[0]
    hinweis = ("\n  Gefundene Ordner mit „Marktbegleiter“ im Namen:\n    " + "\n    ".join(aehnlich)) if aehnlich else ""
    raise SystemExit(f"Ordner „{ordner}“ nicht gefunden – bitte in Google Drive unter „Meine Ablage“ anlegen, "
                     f"darin je Marktbegleiter ein Unterordner „Name (Land)“ mit den Preislisten.{hinweis}")


def run(root="/content/drive/MyDrive", ordner=ORDNER):
    base = finde_ordner(root, ordner)
    log(f"Ordner: {base}")
    lose = [f for f in os.listdir(base) if os.path.isfile(os.path.join(base, f)) and f.lower().endswith(ENDUNGEN)]
    if lose:
        log(f"  ⚠ {len(lose)} Datei(en) liegen direkt im Ordner und werden übersprungen – bitte in den Unterordner "
            f"der jeweiligen Firma „Name (Land)“ verschieben: {', '.join(sorted(lose)[:10])}")
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("set statement_timeout = 0")
        for eintrag in sorted(os.listdir(base)):
            sub = os.path.join(base, eintrag)
            if not os.path.isdir(sub):
                continue
            fi = firma_info(eintrag, sub)
            log(f"{fi['name']} ({fi['land'] or 'Land?'})")
            for dp, _dn, fn in os.walk(sub):
                for f in sorted(fn):
                    if f.lower().endswith(ENDUNGEN) and f != "firma.json":
                        try:
                            verarbeite(con, root, os.path.join(dp, f), fi)
                        except Exception as e:  # noqa: BLE001 – eine kaputte Datei soll den Lauf nicht stoppen
                            con.rollback()
                            log(f"  ⚠ Fehler bei {f}: {e!r}")
        with con.cursor() as cur:
            cur.execute("""select f.name, f.land, i.dateiname, i.status, i.positionen, i.zugeordnet, i.vorschlaege,
                                  i.nicht_zugeordnet, i.fehlerhaft, i.dubletten
                             from marktbegleiter.importe i join marktbegleiter.firmen f on f.id = i.firma_id
                            where i.importiert_am > now() - interval '1 day' order by f.name, i.id""")
            log("Ergebnis je Firma (letzte 24 h): Firma · Land · Datei · Status · Positionen · zugeordnet · Vorschläge · "
                "nicht zugeordnet · fehlerhaft · Dubletten")
            for r in cur.fetchall():
                log("  " + " · ".join(str(x) for x in r))
    log("FERTIG")


if __name__ == "__main__":
    run(*sys.argv[1:2])
