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

## Direkte Einlieferung (OpenClaw / Scraper) – 0041
`select marktbegleiter.einliefern('<json>'::jsonb)` – ein Aufruf je Shop und Lauf, gleiche Verarbeitung wie Import 9
(Prüfung, USt/EUR, Dubletten, Historie, Zuordnung). Gleicher Lauf (Stand + Positionen) für dieselbe Firma wird nur einmal gespeichert
(`schon_eingeliefert`). Rolle **`openclaw_import`** darf nur diese Funktion aufrufen (keine Tabellen, kein `pim`, keine öffentliche API);
Passwort setzt der Betreiber: `alter role openclaw_import with password '…';` · Verbindung: Session pooler mit Benutzer
`openclaw_import.xgpkjxjwcxelskygojvl`.

```json
{ "firma": {"name": "Selfio", "domain": "selfio.de", "land": "DE"},
  "stand": "2026-10-27", "preisart": "oeffentlich", "lauf": "OpenClaw",
  "positionen": [ {"hersteller": "Grundfos", "artikelnummer": "99411165", "ean": "…", "bezeichnung": "ALPHA2 25-40 180",
                   "preis": 206.80, "preis_typ": "brutto", "waehrung": "EUR", "versand": 0, "lieferbar": true,
                   "lieferzeit": "1-3 Tage", "staffel_ab": 1, "url": "https://…"} ] }
```
Pflicht: `firma.land` (ISO, UK → GB), `firma.domain` oder `firma.name`, je Position `preis` und `preis_typ` (netto|brutto).
`domain` = Shop, nie das Preisportal. `artikelnummer` = Herstellernummer; Platzhalter wie „unbekannt“, „n/a“ werden ignoriert.
Optional je Position: `ust_satz`, `preiseinheit`, `mengeneinheit`, `mindestmenge`, `lagerbestand`, `gueltig_ab/bis`, `erfasst_am`,
`baureihe`, `kategorie`, `preisart`. Antwort: `status` (fertig | teilweise | fehler | schon_eingeliefert), `ergebnis`, `fehler`.
Getestet 27.10.2026 (Staffel, CHF, Wilo, „unbekannt“ + Bezeichnung → Vorschlag, Dublette, ohne preis_typ, ohne Land, Doppellauf,
Folgetag nur mit Domain); Testdaten entfernt.

## Prüfung 27.10.2026 (0041)
EZB-Referenzkurse 26.10.2026 für CHF, GBP, DKK, SEK, NOK, PLN, CZK, HUF, RON, ISK, USD (+ BGN fest) statt CHF-Annahme; 41 CHF-Preise
neu umgerechnet · Land UK → GB (8 Firmen) · 6 Recherche-Shops, die unter der Domain des Preisportals angelegt waren (selfio.de,
heizungsdiscount24.de, Kaufland.de, Raleo, Amazon.de, Galaxus.ch), in den vorhandenen Firmeneintrag zusammengeführt → 301 Firmen.

## Übernahme 27.10.2026
279 Firmen aus `pim.wettbewerber` (gleiche IDs) + 28 Shops aus Preisen ohne Firmenzuordnung → 307 Firmen; 195 Preise aus
`pim.marktpreis` (alte ID in `alt_marktpreis_id`); 177 Produkte: 132 eindeutig über Artikelnummer (26 Grundfos-Artikel), 45 Vorschlag.
Testimport (11 Fälle: Artikelnummer, EAN, Großhandelsnummer, Bezeichnung, unbekannt, ohne Preis, Dublette, Staffel, CHF, Wilo,
falsche EAN-Prüfziffer) sowie Doppelimport, Preishistorie, Änderungssperre und Auswertungen geprüft; Testdaten entfernt.

Hinweis: 0036 hatte die Recherche-Tabellen kurzzeitig in ein Schema „markt“ verschoben; 0037 hat den ursprünglichen Zustand
exakt wiederhergestellt.
