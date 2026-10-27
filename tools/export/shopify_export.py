#!/usr/bin/env python3
"""
Grundfos-PIM → Shopify-Produkt-CSV (Mastershop). Liest pim.v_shop_export_de für einen Kanal und schreibt eine CSV
im Shopify-Importformat (Produkte → Importieren).

  python3 -I tools/export/shopify_export.py <ausgabe.csv> [kanal]     # Standard-Kanal: mastershop_pilot

Festlegungen Pilot (26.10.2026):
  - Status „draft“, Published FALSE – nichts ist sofort sichtbar
  - kein Preis (Preisentscheidung offen) – Variant Price bleibt leer
  - Bilder: eigene Produktbilder (Supabase Storage, öffentliche URL), sonst Explosionszeichnung (Ersatzteile, mit
    Positionsnummer im Alt-Text) bzw. Bild der Baureihe (pim.shop_bilder); weitere Bilder als Zusatzzeilen
  - Metafelder im Namensraum „grundfos“ (Definitionen siehe docs/06-Shop-Export.md):
      typbezeichnung (Text), technische_daten (JSON [{code, name, wert}]), ersatzteile / zubehoer / nachfolger /
      ersetzt_grundfos / ersetzt_wettbewerb / passt_zu (JSON-Listen), dokumente (JSON [{typ, titel, sprache, url}]),
      kategorien (JSON „Anwendung > Unteranwendung“), produktart
  - zusätzlich <ausgabe>.uebersetzungen.json: je Handle und Sprache Titel, Beschreibung und technische Daten
    (für Shopify „Translate & Adapt“ / translationsRegister, sobald die Produkt-IDs des neuen Shops feststehen)

Die CSV enthält Grundfos-Daten und gehört NICHT ins (öffentliche) Repository.
"""
import csv
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql"))
import supa  # noqa: E402

META = "product.metafields.grundfos."
SPALTEN = [
    "Handle", "Title", "Body (HTML)", "Vendor", "Type", "Tags", "Published",
    "Option1 Name", "Option1 Value", "Variant SKU", "Variant Grams", "Variant Weight Unit",
    "Variant Inventory Tracker", "Variant Inventory Policy", "Variant Fulfillment Service", "Variant Price",
    "Variant Requires Shipping", "Variant Taxable", "Variant Barcode", "SEO Title", "SEO Description", "Status",
    f"Typbezeichnung ({META}typbezeichnung)",
    f"Technische Daten ({META}technische_daten)",
    f"Ersatzteile ({META}ersatzteile)",
    f"Zubehör ({META}zubehoer)",
    f"Nachfolger ({META}nachfolger)",
    f"Ersetzt Grundfos ({META}ersetzt_grundfos)",
    f"Ersetzt Wettbewerb ({META}ersetzt_wettbewerb)",
    f"Datenqualität ({META}score)",
    f"Produktart ({META}produktart)",
    f"Passt zu ({META}passt_zu)",
    f"Dokumente ({META}dokumente)",
    f"Kategorien ({META}kategorien)",
    "Image Src", "Image Position", "Image Alt Text",
]
SPRACHEN = ["en", "fr", "it", "nl", "pl"]


def seo_beschreibung(r):
    t = " ".join(x for x in (r["kurz1"], r["kurz2"]) if x) or r["titel"]
    return t[:320]


def zeile(r):
    return [
        r["handle"], r["titel"], r["body_html"] or "", "Grundfos", r["produktgruppe"] or "", r["tags"] or "", "FALSE",
        "Title", "Default Title", r["artikelnummer"], r["gramm"] or "", "kg",
        "", "deny", "manual", "",
        "TRUE", "TRUE", r["ean"] or "", r["titel"][:70], seo_beschreibung(r), "draft",
        r["typbezeichnung"] or "",
        json.dumps(r["technische_daten"], ensure_ascii=False),
        json.dumps(r["ersatzteile"], ensure_ascii=False),
        json.dumps(r["zubehoer"], ensure_ascii=False),
        json.dumps(r["nachfolger"], ensure_ascii=False),
        json.dumps(r["ersetzt_grundfos"], ensure_ascii=False),
        json.dumps(r["ersetzt_wettbewerb"], ensure_ascii=False),
        r["score"] if r["score"] is not None else "",
        r["produktart"] or "",
        json.dumps(r["passt_zu"], ensure_ascii=False),
        json.dumps(r["dokumente"], ensure_ascii=False),
        json.dumps(r["kategorien"], ensure_ascii=False),
        (r["bilder"] or [""])[0], 1 if r["bilder"] else "", bildtext(r) if r["bilder"] else "",
    ]


def bildtext(r):
    """Alt-Text: Hinweis der Ersatzlösung (z. B. „Explosionszeichnung – Position 49“) vor dem Produkttitel"""
    return f"{r['titel']} – {r['bild_alt']}" if r.get("bild_alt") else r["titel"]


def bildzeilen(r):
    """Shopify-CSV: weitere Bilder als eigene Zeilen mit Handle + Bild"""
    for i, url in enumerate((r["bilder"] or [])[1:], 2):
        z = [""] * len(SPALTEN)
        z[0] = r["handle"]
        z[-3], z[-2], z[-1] = url, i, bildtext(r)
        yield z


def abfrage(q, versuche=4):
    """supa.sql mit Wiederholung (das API-Zeitlimit liegt bei ca. 30 s; parallel laufende Jobs bremsen)"""
    for i in range(versuche):
        try:
            return supa.sql(q)
        except SystemExit as e:
            if i == versuche - 1 or "502" not in str(e) and "544" not in str(e):
                raise
            time.sleep(5 * (i + 1))
        except OSError:   # Verbindung abgebrochen (z. B. Connection reset by peer)
            if i == versuche - 1:
                raise
            time.sleep(5 * (i + 1))


def run(ausgabe, kanal="mastershop_pilot"):
    zeilen = []
    stand, groesse = 0, 40
    while True:   # in Paketen, damit jede Abfrage unter dem API-Zeitlimit bleibt
        try:
            paket = abfrage(f"select * from pim.v_shop_export_de where kanal = '{kanal}' and rang > {stand} "
                            f"order by rang limit {groesse}")
        except SystemExit:
            if groesse == 1:
                raise
            groesse = max(1, groesse // 2)   # Ersatzteile mit sehr vielen Pumpen brauchen länger → kleinere Pakete
            continue
        if not paket:
            break
        zeilen += paket
        stand = paket[-1]["rang"]
    with open(ausgabe, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(SPALTEN)
        for r in zeilen:
            w.writerow(zeile(r))
            for z in bildzeilen(r):
                w.writerow(z)
    print(f"{len(zeilen)} Produkte → {ausgabe}", flush=True)
    uebersetzungen(ausgabe, {r["artikel_id"]: r["handle"] for r in zeilen})


def uebersetzungen(ausgabe, handle):
    """<ausgabe>.uebersetzungen.json: Titel, Texte, technische Daten und Dokumente je Sprache und Handle"""
    ue = {h: {} for h in handle.values()}
    ids = list(handle)
    for sp in SPRACHEN:
        for i in range(0, len(ids), 40):
            teil = ",".join(str(x) for x in ids[i:i + 40])
            for r in abfrage(f"select id, d, pim.shop_dokumente(id, d->>'produktart', '{sp}') dok, "
                             f"case when d->>'produktart' = 'ersatzteil' then pim.shop_ersatzteil_kategorien(id, '{sp}') end kat from "
                             f"(select id, pim.shop_produkt(id, '{sp}') d from unnest(array[{teil}]::bigint[]) id) x"):
                d = r["d"] or {}
                ue[handle[r["id"]]][sp] = {k: d.get(k) for k in ("titel", "body_html", "kurz", "baureihe_text",
                                                                  "technische_daten")}
                ue[handle[r["id"]]][sp]["dokumente"] = r["dok"]
                if r.get("kat"):   # Ersatzteile: Kategoriepfad je Sprache
                    ue[handle[r["id"]]][sp]["kategorien"] = r["kat"]
        print(f"  {sp}: {len(ids)} Produkte", flush=True)
    with open(ausgabe + ".uebersetzungen.json", "w", encoding="utf-8") as f:
        json.dump(ue, f, ensure_ascii=False)
    print(f"Übersetzungen ({', '.join(SPRACHEN)}) → {ausgabe}.uebersetzungen.json", flush=True)


def nur_uebersetzungen(ausgabe, kanal="mastershop_pilot"):
    """Übersetzungen zu einer vorhandenen CSV neu erzeugen (Handles aus der CSV, Zuordnung über die SKU)"""
    with open(ausgabe, encoding="utf-8") as f:
        sku_handle = {r["Variant SKU"]: r["Handle"] for r in csv.DictReader(f) if r["Variant SKU"]}
    ids = abfrage(f"select s.artikel_id, a.artikelnummer from pim.shop_auswahl s join pim.artikel a on a.id = s.artikel_id "
                  f"where s.kanal = '{kanal}'")
    uebersetzungen(ausgabe, {r["artikel_id"]: sku_handle[r["artikelnummer"]] for r in ids
                             if r["artikelnummer"] in sku_handle})


if __name__ == "__main__":
    if sys.argv[1:2] == ["--nur-uebersetzungen"]:
        nur_uebersetzungen(*sys.argv[2:4])
    else:
        run(*sys.argv[1:3])
