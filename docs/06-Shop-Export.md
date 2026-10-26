# Shop-Export – Grundfos-Mastershop (Shopify)

Stand 26.10.2026 · Entscheidung: **eigener neuer Mastershop**, solarics.de bleibt unverändert (dort später nur fehlende Angaben ergänzen) · erste Welle: **Pilot mit 537 Artikeln**

## 1. Ablauf

1. Auswahl in Supabase: `select pim.shop_pilot_anlegen();` → `pim.shop_auswahl` (Kanal `mastershop_pilot`)
2. Datei erzeugen: `python3 -I tools/export/shopify_export.py grundfos_mastershop_pilot.csv`
3. Im neuen Shop: Metafeld-Definitionen anlegen (Abschnitt 3), dann *Produkte → Importieren* mit der CSV
4. Stichproben prüfen → Freigabe → Status von „Entwurf“ auf „Aktiv“

Die CSV enthält Grundfos-Daten und wird **nicht** ins Repository eingecheckt.

## 2. Pilot (537 Artikel)

| Gruppe | Anzahl | Auswahl |
|---|---|---|
| Bestseller Deutschland | 21 | Grundfos „Popular now“ (ALPHA2 25-40 180, MAGNA3 25-40, Grundfos GO, … SCALA2 3-45) |
| Heizung/Zirkulation | 265 | ALPHA, MAGNA, UPS, UPM, COMFORT · im DE-Sortiment 2023 · Score ≥ 80 |
| Baureihen | 251 | je bis zu 15 beste Artikel: CR, CRE, CM, CME, SP, SQ, SCALA, Sololift, Unilift, Conlift, Multilift, MTR, NB, NK, NKG, TP, TPE, SEG, DDA/DDE/DDC, Hydro MPC, Hydro Multi-E, JP |

Prüfwerte der Pilot-Datei: alle 537 mit EAN · 535 mit Beschreibung · 534 mit mindestens 10 technischen Daten · 522 mit Ersatzteilen bzw. Zubehör · 223 mit Wettbewerbs-Austausch · 516 mit Gewicht.

## 3. Felder

| Shopify | Quelle (Supabase) |
|---|---|
| Handle | `grundfos-<typ>-<artikelnummer>` |
| Title | „Grundfos “ + Typbezeichnung + „ – “ + Kurztext 1 (ohne „GRUNDFOS“) |
| Body (HTML) | Golden Record: Langtext (DATANORM) bzw. Text-Engine, + Techniktext; `>>` → `<h3>` |
| Type | Produktgruppe (z. B. ALPHA2) |
| Tags | Grundfos, Produktgruppe, ggf. Bestseller, „Text: maschinell“ |
| Variant SKU / Barcode / Grams | Artikelnummer / EAN / Bruttogewicht |
| Variant Price | **leer** – Preisentscheidung offen |
| Status / Published | draft / FALSE |
| Bilder, Dokumente | **noch nicht** – Nutzungsrechte offen |

Metafeld-Definitionen im neuen Shop (*Einstellungen → Benutzerdefinierte Daten → Produkte*), Namensraum `grundfos`:

| Schlüssel | Typ | Inhalt |
|---|---|---|
| `typbezeichnung` | Einzeiliger Text | z. B. ALPHA2 25-40 180 |
| `technische_daten` | JSON | `[{"code":"LIQUMXC","name":"Max. Medientemperatur","wert":"110 °C"}, …]` |
| `ersatzteile` | JSON | Liste der Artikelnummern |
| `zubehoer` | JSON | Liste der Artikelnummern (über Baureihe, `pim.zubehoer`) |
| `nachfolger` | JSON | Nachfolgeartikel |
| `ersetzt_grundfos` | JSON | ältere Grundfos-Artikel, die dieser ersetzt |
| `ersetzt_wettbewerb` | JSON | „Hersteller Typ“ der Fremdpumpen, für die Grundfos diesen Artikel als Ersatz nennt |
| `score` | Ganzzahl | Qualitäts-Score 0–100 |

## 4. Offen

- Preise (Listenpreise 2015/16 vorhanden, aber veraltet)
- Bild- und Dokumentrechte
- Shop anlegen und hier verbinden (Shopify-Connector zeigt derzeit solarics.de)
- Weitere Sprachen (Texte en vorhanden; fr/it/nl/pl über die Text-Engine)
