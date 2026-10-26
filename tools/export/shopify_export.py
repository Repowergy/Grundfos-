#!/usr/bin/env python3
"""
Grundfos-PIM → Shopify-Produkt-CSV (Mastershop). Liest pim.v_shop_export_de für einen Kanal und schreibt eine CSV
im Shopify-Importformat (Produkte → Importieren).

  python3 -I tools/export/shopify_export.py <ausgabe.csv> [kanal]     # Standard-Kanal: mastershop_pilot

Festlegungen Pilot (26.10.2026):
  - Status „draft“, Published FALSE – nichts ist sofort sichtbar
  - kein Preis (Preisentscheidung offen) – Variant Price bleibt leer
  - keine Bilder/Dokumente (Nutzungsrechte offen)
  - Metafelder im Namensraum „grundfos“ (Definitionen siehe docs/06-Shop-Export.md):
      typbezeichnung (Text), technische_daten (JSON [{code, name, wert}]), ersatzteile / zubehoer / nachfolger /
      ersetzt_grundfos / ersetzt_wettbewerb (JSON-Listen mit Artikelnummern bzw. „Hersteller Typ“)

Die CSV enthält Grundfos-Daten und gehört NICHT ins (öffentliche) Repository.
"""
import csv
import json
import os
import sys

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
]


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
    ]


def run(ausgabe, kanal="mastershop_pilot"):
    zeilen = []
    stand = 0
    while True:   # in Paketen, damit jede Abfrage unter dem API-Zeitlimit bleibt
        paket = supa.sql(f"select * from pim.v_shop_export_de where kanal = '{kanal}' and rang > {stand} "
                         f"order by rang limit 100")
        if not paket:
            break
        zeilen += paket
        stand = paket[-1]["rang"]
    with open(ausgabe, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(SPALTEN)
        for r in zeilen:
            w.writerow(zeile(r))
    print(f"{len(zeilen)} Produkte → {ausgabe}")


if __name__ == "__main__":
    run(*sys.argv[1:3])
