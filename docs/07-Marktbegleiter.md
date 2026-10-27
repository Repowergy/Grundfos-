# Marktbegleiter- und Preisdatenbank

Stand 27.10.2026 · Projekt **Grundfos-PIM** (`xgpkjxjwcxelskygojvl`), eigenes Schema **`marktbegleiter`** – vertraulich.

## Zugriff
- Kein Zugriff über die öffentliche API (anon/authenticated haben keine Rechte auf Schema, Tabellen, Funktionen), RLS auf allen
  Tabellen ohne Freigabe-Policies, Ansichten mit `security_invoker`. Lesen/Schreiben nur intern (SQL-Editor, Colab mit
  `SUPABASE_DB_URL`, Management-API).
- Nie in Shopify, nie an Kunden; Marktpreise werden nie als eigene Einkaufs-/Verkaufspreise übernommen.
- Der Grundfos-Stamm (`pim.*`) wird nur gelesen. `pim.wettbewerber` und `pim.marktpreis` bleiben unverändert.

## Tabellen
| Tabelle | Inhalt |
|---|---|
| `firmen` | Marktbegleiter: Name, Domain, Website, Land, Ansprechpartner, E-Mail, Art, Schwerpunkt, Hersteller, aktiv, letzte Preisliste |
| `produkte` | Produkt je Firma: Hersteller, MPN, EAN (geprüft), Bezeichnung, Baureihe, Kategorie, Link, Grundfos-Artikel, Matching-Status |
| `preise` | jede Preisbeobachtung (Historie, Änderungen gesperrt): Original/netto/brutto, USt, Währung, EUR mit Kurs, Preiseinheit, Mindestmenge, Staffel, Versand, Lager, Lieferzeit, gültig ab/bis, Datum, Quelle, Preisart, Import |
| `importe` | je Datei: Firma, Datei, Prüfsumme, Zähler (Positionen, zugeordnet, Vorschläge, nicht zugeordnet, fehlerhaft, Dubletten), Status, Fehlerprotokoll |
| `import_zeilen` | Zwischenablage je Datei (Rohzeile, erkannte Felder, Ergebnis je Zeile) |
| `ust_saetze`, `wechselkurse` | Normalsätze je Land; Kurse je Datum mit Quelle |

## Zuordnung zum Grundfos-Stamm (`produkte_zuordnen`)
1. Hersteller + Artikelnummer (`eindeutig_mpn`) · 2. EAN, nur wenn eindeutig (`eindeutig_ean`) · 3. Großhandelsnummer/VVS, eindeutig
(`eindeutig_alternativ`) · 4. Bezeichnung → nur `vorschlag` · sonst `kein_treffer`. Kontrolle: `v_zuordnung_pruefen`,
`zuordnung_bestaetigen(produkt, artikel)`, `zuordnung_ablehnen(produkt)`.

## Auswertungen
`v_angebote` (alle aktuellen Angebote; Filter Hersteller, Baureihe, Land) · `anbieter('99411165', 'DE')` (alle Anbieter einer Pumpe) ·
`v_preisvergleich` (je Artikel und Land: Anbieter, min/Median/max netto, min brutto, min brutto inkl. Versand, günstigster, Spanne %,
lieferbar) · `v_preisentwicklung` (Veränderung zum vorherigen Preis) · `v_letzter_preis`.

## Import (Import 9)
Drive: `GRUNDFOS – Marktbegleiter Preise/<Firma oder Domain> (<Land>)/<Datei>` → Colab `tools/import/Import_Marktbegleiter_Colab.ipynb`.
Formate: CSV, XLSX/XLSM, JSON/JSONL. Firma über Domain bzw. Name + Land; gleiche Datei je Firma nur einmal; Dubletten (in der Datei und
gegenüber früheren Importen) werden gezählt, nicht gespeichert; Original unverändert in `raw.quelldatei`.

## Übernahme 27.10.2026
279 Firmen aus `pim.wettbewerber` (gleiche IDs) + 28 Shops aus Preisen ohne Firmenzuordnung → 307 Firmen; 195 Preise aus
`pim.marktpreis` (alte ID in `alt_marktpreis_id`); 177 Produkte: 132 eindeutig über Artikelnummer (26 Grundfos-Artikel), 45 Vorschlag.
Testimport (11 Fälle: Artikelnummer, EAN, Großhandelsnummer, Bezeichnung, unbekannt, ohne Preis, Dublette, Staffel, CHF, Wilo,
falsche EAN-Prüfziffer) sowie Doppelimport, Preishistorie, Änderungssperre und Auswertungen geprüft; Testdaten entfernt.

Hinweis: 0036 hatte die Recherche-Tabellen kurzzeitig in ein Schema „markt“ verschoben; 0037 hat den ursprünglichen Zustand
exakt wiederhergestellt.
