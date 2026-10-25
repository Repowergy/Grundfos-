# Grundfos-PIM – Konzept für eine mehrsprachige, „intelligente“ Produktdatenbank

Stand: 24.10.2026 · Basis: Supabase-Projekt `Grundfos-PIM` (Schema `raw` + `pim`, siehe `supabase/migrations/`)

---

## 1. Zwischenstand nach Import 1

| Quelle | Artikel | Bemerkung |
|---|---|---|
| Grundfos-Artikelliste (Sitemap 08/2026) | 806.105 | Nummer, Name, Familie/Serie, Kategorie, Link |
| DATANORM Grundfos GmbH 2014 + 2016, Ersatzteile 2016, VPE 2016 | ca. 28.000 | EAN, Listenpreis, Kurz-, Lang- und Techniktext |
| DATANORM „GF“ 12/2015 | 8.662 | Grundfos-Nummern und -EAN, Langtexte |

**Stand nach Bereinigung (24.10.2026, Notebook `tools/import/DB_Pflege_Colab.ipynb`):**
Großhändler und Fremdhersteller sind aus `pim` entfernt; die Rohdaten in `raw` bleiben erhalten.
Danach: 15 Quellen (12 Grundfos-DATANORM, „GF“-Datei, 2 Artikellisten) · **811.769 Artikel** · 15.623 Grundfos-EAN ·
20.301 Artikel mit Listenpreis · je 23.861 Lang- und Techniktexte (2014: 11.630, 2016: 12.231), Techniktexte
korrekt aus Vorlage + Werten, keine offenen `$`, Silbentrennung aufgelöst (übrig nur Ergänzungsstriche wie „Saug- und“).

### Was die Großhändler zusätzlich liefern (nicht übernommen, Rohdaten vorhanden)

| Großhändler | Grundfos-Artikel | davon in Liste | davon in DATANORM 2014/16 | **nur hier** | Zuordnung |
|---|---|---|---|---|---|
| Datei 09/2025 („Datanorm Neuanlage/Änderung“) | 17.175 | 15.392 | 6.018 | **1.190**, davon 801 Ersatzteile | Grundfos-Nummer steht im Datensatz ✅ |
| Heinrich Taxis 11/2015 | 16.611 | – | 14.432 über EAN | **ca. 2.179**, davon 1.979 mit Grundfos-EAN | nur EAN, **ohne Grundfos-Nummer** ⚠️ |
| Deinzer + Weyland 11/2015 | 17.762 | – | – | ? | weder Grundfos-Nummer noch EAN ❌ |

Der größte Gewinn liegt in der Datei von 2025:
- **9.967 Artikel** aus der Artikelliste hatten bisher keine Beschreibung und keinen Preis. Diese Datei liefert beides, mit Stand 2025.
- **1.190 Artikel** stehen in keiner anderen Quelle: vor allem Ersatzteile, Sensoren und Druckerhöhungsanlagen.

Bei Taxis sind es vor allem Industriepumpen: NK/NKE-Normpumpen, NB-Blockpumpen, MTR/SPK-Eintauchpumpen und Feuerlöschanlagen. Die Grundfos-Nummer fehlt dort. Sie lässt sich aber vermutlich über die Typbezeichnung finden, z. B. „NK80-200/214 A2F2AE-SGQQE“ gegen die Namen in der Artikelliste.

---

## 1b. Access-Datenbanken der alten Grundfos-Software (Inventar 24.10.2026)

Ordner *GRUNDFOS – Zentrale Projektablage / Historische Grundfos-Software und Access-Datenbanken*.

### `gpi.mdb` – Grundfos Product Center, Export 10.10.2015 (989 MB, 153 Tabellen) ⭐
Das ist die Quelle für die **Verlinkungen**:

| Bereich | Tabellen (Zeilen) | Nutzen für den Shop |
|---|---|---|
| Produkte | `Products2` (427.538: Nummer, EAN, Produktgruppe, 50/60 Hz, Status, Typname, 88 Datenspalten), `Prodnames` (60.289), `PG` (1.351 Produktgruppen mit Beschreibung), `ColText` (133.505 Werte) | Artikel, EAN, Typbezeichnung, technische Daten |
| Merkmalskatalog | `DL` (2.438 Merkmale mit Name, Beschreibung, Einheit), `DLPoss`, `Domain`, `Clas` | sprachneutrale Merkmale (Kap. 3.2), Filter |
| **Ersatzteile** | `Master` (391.683 Teile), `PartList` (**7.042.649** Stücklistenzeilen), `PartDetails` (198.371: Menge, Position), `PartValidity` (2.032 Gültigkeitszeiträume), `ChangeNote` (853), `PLText` (3.305 Teilebezeichnungen), `BULKS`, `PACKAGINGNUMBERS` (10.841) | Ersatzteil je Pumpe **mit Positionsnummer und Produktionszeitraum** |
| Zeichnungen & Dokumente | `PartDrawingLink` (446.639), `DF` (15.897 Dateien mit Sprache), `ProdDF`, `IT`/`ITDF` (Infobaum), `Literature` (5.816), `LiteratureFile` (32.379, **je Sprache**), `LiteraturePGLink` (20.088) | Explosionszeichnung, Datenblatt, Anleitung je Artikel/Sprache |
| Zubehör | `ACCLINK` (32.149) | Zubehör je Pumpe |
| **Austausch Wettbewerb** | `ReplSystem50` (15.335 Fremdpumpen: Hersteller, Typ, Anschluss, Baulänge, Leistung), `ReplPumps50` (83.040 Grundfos-Ersatz), `ReplManufactName` (98 Hersteller), 60-Hz-Varianten, `CompetitorProducts` (7.982) + `CompetitorProductData` (162.075) | „Wilo/KSB/DAB XY ersetzen durch …“ – Austauschfinder |
| Kennlinien | `HydraulicObject` (56.475), `HydraulicLink` (287.396), `Curve2`, `Curveset`, `Polynom` (50.136), Motor-Kennlinien | Pumpenauslegung (Q/H), Energieberechnung |
| Länder-Sortimente | `ProductRange_*` (je Land: Nummer, Preis, Status), z. B. `General` 212.337, `gnl` 206.889 | Sortiment/Status je Markt, Altpreise als Referenz |
| Sonstiges | `LANG` (35 Sprachen), `LIQUIDS` (187 Medien) + `LIQUIDSYNONYMS` (607), `Application` (220 Anwendungen) | Anwendungs- und Medienfilter |

Import: `tools/import/Import_GPI_Colab.ipynb` → Schema `gpi` (1:1, alle Spalten als Text, Schlüssel indiziert).
Danach Zuordnung nach `pim` (Artikel, `artikel_beziehung` Ersatzteil/Zubehör/Nachfolger, `medium`, `zeichnung_position`,
`querverweis_wettbewerb`) per SQL.

### Übrige Dateien
- **`ETB.MDB` (43 MB): kein Grundfos!** Inhalt sind KSB-Baureihen (Amarex, Ama-Drainer, Etabloc, Multitec) mit
  Teileliste (278.291), Teilestamm (13.952, Preise in DM) und Zeichnungs-Hotspots. Sie wird als Rohdaten in das
  Schema `etb` übernommen (Grundsatz „nichts wegwerfen“), aber nicht in den Grundfos-Stamm `pim`.
  Die Kopien `ETB (1)/(2).MDB` sind identisch.
- `ETBv.MDB`, `ETB_WAE.MDB`, `ETB_DTXT.MDB`: Angebots-/Bestellmasken, Währungen, Formulartexte – leer bzw. ohne Produktdaten.
- `GPIUser.mdb`: leere Benutzerdatenbank der Software.

---

## 2. Grundsatz: nichts wegwerfen

Für den Mastershop ist **jede Quelle wertvoll**. Deshalb gilt:
- **Rohdaten bleiben vollständig erhalten**: DATANORM-Zeilen in `raw`, Access-Datenbanken 1:1 in eigenen Schemas
  (`gpi`, `etb`), weitere Software-Daten folgen. Auch die Großhändler-Dateien liegen weiter in `raw`.
- **Der Stamm `pim` wählt aus**: Nur geprüfte Grundfos-Daten bilden den „Golden Record“; jede andere Quelle kann
  später per SQL zugeschaltet werden (z. B. Großhandel 2025 für fehlende Texte, Taxis über Typbezeichnung).
- Jede Zeile behält Herkunft, Datenstand und Priorität – so ist jede Entscheidung umkehrbar.

---

## 3. Leitidee: Daten statt Texte

Andere Shops übersetzen Texte. Wir speichern **Fakten sprachneutral** und erzeugen daraus Texte in jeder Sprache.

```
             sprachneutral                          sprach-/marktabhängig
┌───────────────────────────────────┐   ┌──────────────────────────────────────────┐
│ Artikel (Grundfos-Nr., EAN)        │   │ Texte je Locale (de-DE, de-AT, de-CH,     │
│ Merkmale: 0,3 kW · 230 V · DN32 …  │──►│   fr-CH, it-CH, en, …) mit Status         │
│ Beziehungen: Ersatzteil, Zubehör,  │   │ Textvorlagen je Sprache                   │
│   Nachfolger, Wettbewerber-Pendant │   │ Preise, Verfügbarkeit, Sortiment je Markt │
│ Medien (Bild, Zeichnung, PDF/Spr.) │   │ Synonyme / Suchbegriffe je Sprache        │
└───────────────────────────────────┘   └──────────────────────────────────────────┘
```

---

## 3. Bausteine

### 3.1 Sprache und Markt getrennt
- **Locale** = Sprache + Region: `de-DE`, `de-AT`, `de-CH`, `fr-CH`, `it-CH`, `en-GB` …
- **Markt** = Land mit Währung, Steuer, Sortiment und Preisen: `DE`, `AT`, `CH`.
- Eine Sprache kann in mehreren Märkten gelten, und ein Markt kann mehrere Sprachen haben (CH: de/fr/it).
- **Fallback-Kette** je Locale, z. B. `de-AT → de-DE → de` und `fr-CH → fr-FR → fr → en`. Fehlt ein Text in Österreich, wird der deutsche verwendet. Das Feld bleibt nie leer.

### 3.2 Merkmale als Zahl mit Einheit (ETIM-fähig)
- Der D-Satz `Unilift KP 150 M 1$300$8$1 x 220-230$` wird zu einzelnen Merkmalen: `typ=KP 150 M1`, `foerderhoehe_max=8 m`, `spannung=1x220-230 V`.
- Jedes Merkmal hat Code, Datentyp, Einheit, Übersetzungen und optional eine ETIM-Klasse.
- Damit funktionieren **Filter** (Förderhöhe ≥ 8 m), **Vergleiche**, die **Austauschsuche** („gleiche Einbaulänge 180 mm, 1x230 V“) und Google-Shopping-Attribute.

### 3.3 Texte aus Vorlagen erzeugen
- Je Produkttyp und Sprache gibt es eine Vorlage, z. B. `Max. Förderhöhe: {foerderhoehe_max} m` bzw. `Max. head: {foerderhoehe_max} m`.
- Der Techniktext entsteht für **jede Sprache automatisch und fehlerfrei aus den Merkmalen**. Zahlen werden nie übersetzt und können deshalb nicht falsch werden.
- Fließtexte (Langtext, Vorteile, SEO) kommen aus offiziellen Quellen: DATANORM DE, die mehrsprachige Grundfos-Datei 2016, GPC-Sprachtabellen (33 Sprachen). Was fehlt, wird maschinell übersetzt und als `maschinell` markiert, bis jemand es prüft.

### 3.4 Status je Text
`quelle` (offiziell) · `maschinell` · `geprueft` · `gesperrt`. In den Shop gehen nur geprüfte oder offizielle Texte. Maschinelle Texte kommen nur mit Freigabe in den Shop.

### 3.5 „Golden Record“ mit Herkunft
- Jeder Wert behält seine Quelle, Priorität und seinen Datenstand.
- Eine Ansicht `pim.v_artikel_<locale>` wählt je Feld automatisch den besten Wert: höchste Priorität, dann neuester Stand, dann geprüft.
- Neue Quellen (aktuelle DATANORM, BMEcat von Grundfos) verbessern so automatisch den Shop, ohne dass etwas überschrieben wird.

### 3.6 Identitäten und Querverweise
- **Alias** je Artikel: EAN, alte Nummern, Großhändler-Nummern, Typbezeichnung in Schreibvarianten („UPS25-60“, „UPS 25-60 180“).
- **Querverweise** mit Status `Kandidat / geprüft` und Nachweis:
  - Nachfolger (UPS → ALPHA1 GO);
  - Wettbewerber-Pendant (Wilo Stratos PICO 25/1-6 → ALPHA2 GO 25-60);
  - Ersatzteil je Produktionszeitraum (PC-Code / Baujahr);
  - Reparatursatz;
  - Zubehör.

### 3.7 Intelligente Suche
- **Fehlertolerant** über Trigramme für Typbezeichnungen und Nummern; bereits angelegt.
- **Synonyme je Sprache**, z. B. Heizungspumpe = Umwälzpumpe = Nassläufer = circulator = circulateur.
- **Semantische Suche** mit Vektoren (pgvector in Supabase). Sie versteht Anfragen wie „Pumpe für 30 m tiefen Brunnen 230 V“ oder „pompe puits 30 m“ in jeder Sprache und schlägt passende Pumpen vor.
- **Typenschild-Erkennung** später: Foto → OCR → Alias-Suche → passender Artikel bzw. Nachfolger.

### 3.8 Qualitäts-Score je Artikel und Markt
- Punkte für Preis, EAN, Bild, Langtext, Merkmale, Dokument, Übersetzung, Beziehungen.
- Der Shop-Export nimmt nur Artikel ab einer Mindestpunktzahl. Ein Dashboard zeigt, wo Daten fehlen. Das ist die Arbeitsliste für die Datenpflege.

---

## 4. Erweiterungen am Schema (Vorschlag)

| Tabelle / Objekt | Zweck |
|---|---|
| `pim.locale` (code, sprache, region, fallback) | Sprachen und Fallback-Kette |
| `pim.markt` (code, waehrung, mwst, locales[]) | Länder DE/AT/CH |
| `pim.merkmal_uebersetzung` | Merkmalsnamen und Einheiten je Sprache |
| `pim.textvorlage` (produkttyp, locale, vorlage) | Techniktexte aus Merkmalen |
| `artikel_text.status`, `artikel_text.locale` statt nur `sprache` | Freigabe-Workflow, Regionalvarianten |
| `pim.synonym` (locale, begriff, normbegriff) | Suche |
| `pim.artikel_embedding` (artikel_id, locale, vector) | semantische Suche |
| `pim.querverweis_wettbewerb` (fremdhersteller, typ, artikel_id, status, nachweis) | markenübergreifender Austauschfinder |
| `pim.v_artikel_<locale>` (View) | Golden Record je Sprache/Markt für Shop und Feeds |
| `pim.artikel_qualitaet` (View/Materialized) | Qualitäts-Score und Lücken |

---

## 5. Offene Entscheidungen

1. **Großhändler-Datei 09/2025:**
   - Sollen die **1.190 zusätzlichen Artikel** als Grundfos-Artikel übernommen werden (Nummer, Bezeichnung, EAN falls vorhanden)?
   - Sollen die **Beschreibungen für die 9.967 Artikel** ohne Text übernommen werden?
   - Sollen die Preise von 2025 als „Referenzpreis Großhandel 2025“ übernommen werden? Sie würden nicht als Grundfos-Listenpreis gelten.
2. **Taxis:** Soll ich die Grundfos-Nummern über die Typbezeichnung ermitteln? Übernommen würden dann nur die sicheren Treffer.
3. **Sprachen für den Start:** Welche Locales zuerst? Vorschlag: `de-DE`, `de-AT`, `de-CH`, danach `fr-CH`, `it-CH` und `en`.
4. **Die mehrsprachige Grundfos-Datei 2016:** Wo liegt sie? Sie ist die wichtigste Quelle für offizielle Übersetzungen.
