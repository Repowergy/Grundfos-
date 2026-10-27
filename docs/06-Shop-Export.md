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
| Image Src / Position / Alt | `pim.shop_bilder()`: eigenes Bild, sonst Explosionszeichnung (Ersatzteile), sonst Baureihenbild |
| Metafeld `dokumente` | `pim.shop_dokumente(artikel, produktart, sprache)` |

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
- ~~Bild- und Dokumentrechte~~ – Freigabe liegt vor (26.10.); Upload per Colab
- Shop anlegen und hier verbinden (Shopify-Connector zeigt derzeit solarics.de)
- ~~Weitere Sprachen~~ – siehe Abschnitt 5


## 5. Ausbau 26.10.2026 (Schritte 1–4)

**Bilder und Dokumente** (Freigabe zur vollständigen Nutzung liegt vor)
- Bucket `medien` in Supabase Storage (öffentlich lesbar), `pim.medium_datei`: 26.706 Medien → 11.846 Dateien (4,4 GB)
- Hochladen: Colab `tools/import/Medien_Upload_Colab.ipynb` (Secrets `SUPABASE_DB_URL`, `SUPABASE_SERVICE_KEY`), TIF → PNG;
  `.np2` (Grundfos-Zeichnungsformat) wird geprüft und ggf. als „format_unbekannt“ markiert
- Export: `Image Src` (erstes Bild, weitere als Zusatzzeilen), Metafeld `dokumente` (Datenblätter, Anleitungen, Maß-/Schaltbilder)
- `pim.shop_dokumente()` (0033): Dokumente in der Shop-Sprache, sonst Englisch, mehrsprachige GPC-Dokumente („COMMON“)
  immer; Ersatzteile erhalten zusätzlich Service-Kataloge und Explosionszeichnungen der Baureihen der passenden Pumpen.
  Fehler bis 0032 behoben: der Filter erwartete `de`/`en`, die GPC-Dokumente tragen `DEU`/`ENU` → Anleitungen fehlten
- `.np2` (Grundfos-Zeichnungsformat, ca. 4.000 Maß-, Schalt- und Explosionszeichnungen): proprietäres, bitweise
  kodiertes Format, in der Zeitbox nicht entschlüsselbar → bleiben `format_unbekannt`; Ersatz: Service-PDFs (s. o.),
  Baureihenbild; Option: Zeichnungen bei Grundfos als PNG/PDF anfragen

**Mehrsprachigkeit**
- `pim.uebersetzung`: 1,11 Mio. Einträge aus den 33 GPC-Sprachpaketen (Produktgruppen, Anwendungen, Ersatzteil- und
  Zubehörnamen, Merkmalswerte, Dokumentarten …), doppelte Kodierung repariert (`pim.cp850_reparieren`)
- `pim.shop_produkt(artikel, sprache)`: Titel, Beschreibung, technische Daten (Namen **und Werte** übersetzt) je Sprache
- Text-Engine läuft für fr, it, nl, pl (de, en fertig)
- Export schreibt zusätzlich `<datei>.uebersetzungen.json` (en, fr, it, nl, pl) für Shopify „Translate & Adapt“

**Kategorien**
- `pim.shop_kategorie` (+ `_text`, `_gruppe`): Anwendungsbaum der GPC-Datenbank, 220 Knoten, Namen in allen Sprachen
  (Heizung › Zirkulation bei Heizungsanlagen › ALPHA, MAGNA …), Metafeld `kategorien`
- zusätzlich `pim.artikel_webkategorie`: Kategoriepfad der Grundfos-Website 08/2026 für 290.000 Artikel

**Ersatzteile und Zubehör als Produkte**
- Pilot erweitert auf **3.354 Produkte**: 537 Pumpen + 1.297 Ersatzteile + 1.520 Zubehör (`pim.shop_pilot_teile_anlegen`)
- Ersatzteile: Titel aus übersetztem Teilenamen („Grundfos Gleitringdichtung (96810169)“), Beschreibung
  „Original-Grundfos-Ersatzteil … Passend für: CM, CME“, Metafeld `passt_zu` (Pumpen-Artikelnummern)
- Verknüpfung Pumpe ↔ Ersatzteil fest im Stamm: 6.988.538 Verknüpfungen, 336.307 Pumpen, 86.815 Teile, alle mit
  Produktionszeitraum, 3,2 Mio. mit Positionsnummer; dazu 100.000 Service-Sonderausführungen (Website 2026, Kandidaten)

**Ersatzteil-Kategorien** (27.10.2026, 0041/0042)
- `pim.ersatzteil_baureihe`: je Ersatzteil die Baureihen der passenden Pumpen mit Anzahl (138.665 Zeilen, 67.929 von 86.815 Teilen;
  übrige Teile passen nur zu Pumpen ohne Produktgruppe)
- `pim.shop_ersatzteil_kategorien(artikel, sprache)`: bis zu 3 Pfade „Ersatzteile > Bereich > Baureihe“ (häufigste zuerst), in allen
  Shop-Sprachen; Pilot: alle 1.297 Ersatzteile eingeordnet, 151 Pfade in 9 Bereichen
