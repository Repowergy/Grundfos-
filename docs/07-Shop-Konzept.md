# Grundfos-Ersatzteileshop – Konzept und Vorgehen

Stand: 26.10.2026 · Grundlage: Gutachten „Überprüfung Grundfos-Pumpen.de Shop“ von E-Com Consult (26.10.2021), Stand der Datenbank (`05-Stand-2026-10-25.md`), Shop-Export (`06-Shop-Export.md`)

---

## 1. Was das Gutachten 2021 sagt

Der erste Anlauf (Shopware 6, externe Agentur) ist an fünf Stellen gescheitert:

| Pos. | Auftrag 2021 | Befund des Gutachtens |
|---|---|---|
| 1 | Technisches Konzept auf Basis eines gemeinsamen Pflichtenhefts, Releaseplan | **Kein gemeinsames Pflichtenheft** vorhanden |
| 2 | Shopware 6, Produktdaten-Migration, logische Zugehörigkeiten, DE/EN, Shopfunktionen | Shop installiert, aber **nur 3 kopierte Produkte**. Keine Zugehörigkeiten Pumpe → Ersatzteil. Sprachumschalter da, **englische Übersetzung fehlt**. Plugin „Techparts“ (Explosionszeichnungen) installiert, **nicht umgesetzt** |
| 3 | Frontend Desktop nach Vorlagen | Header ok. **Footer weicht stark ab** (Bezahl-/Versand-Icons unvollständig, „Aktuelle Kundenmeinungen“ und „Aktuelle Support-Anfragen“ fehlen). Mehrere Seiten unvollständig. **Fehlend:** FAQ, Ersatzteile-Produktseite, Ersatzteil-Informationen, Ersatzteil-Bilder |
| 4 | Frontend Mobil | **Nicht mobile-friendly** (Grafiken verschwinden, Blöcke zu groß, Schrift zu klein) |
| 5 | SCRUM, Meilensteine, Testingenieure | Kaum Zwischenpräsentationen. Vermutung: Know-how für **Ersatzteil-Darstellung und Datenimport** reichte nicht. Empfehlung: neu und sauber aufsetzen |

**Kern des Scheiterns:** Das Herzstück – vom Produkt direkt zum passenden Ersatzteil und sofort in den Warenkorb – war ein Daten- und Logikproblem. Die Agentur hat ein Shopsystem aufgesetzt, aber keine Daten und keine Ersatzteillogik gehabt. Genau dieser Teil ist heute in der Datenbank gelöst.

---

## 2. Abgleich: Befund 2021 ↔ Stand heute

| Punkt aus dem Gutachten | Stand 26.10.2026 | Was noch fehlt |
|---|---|---|
| Pflichtenheft | – | **Pflichtenheft mit Abnahmekriterien je Seite** (Abschnitt 8), dieses Dokument ist die Vorstufe |
| Produktdaten | ✅ 1,1 Mio. Artikel, Golden Record, Qualitäts-Score; Pilot 3.354 Produkte als Shopify-CSV | Shop anlegen, Import, Preise |
| Zugehörigkeiten Pumpe ↔ Ersatzteil | ✅ 6,99 Mio. Verknüpfungen mit Position, Menge, Produktionszeitraum; Zubehör, Nachfolger, Wettbewerbs-Austausch | Darstellung im Shop (Ersatzteilfinder, Abschnitt 4) |
| Grafische Ersatzteil-Darstellung („Techparts“) | ⚠️ Explosionszeichnungen als Bild/PDF vorhanden, `.np2`-Zeichnungen nicht lesbar | Klickbare Positionen (Hotspots), Abschnitt 4.3 |
| Mehrsprachigkeit DE/EN | ✅ Texte de/en (283.000 Pumpen), Merkmale in 30 Sprachen, Übersetzungsdatei je Sprache | Theme-Texte übersetzen, automatische Prüfung „keine fehlende Übersetzung“ |
| Frontend Desktop/Mobil | – | Theme (Abschnitt 3 und 6) |
| Projekt- und Qualitätsmanagement | – | Releaseplan, Demo je Sprint, automatische Tests (Abschnitt 8) |

Die Reihenfolge ist diesmal umgekehrt: **erst die Daten, dann der Shop.** Damit ist das größte Risiko von 2021 bereits abgebaut.

---

## 3. Plattform und Architektur

### 3.1 Entscheidung: Shopify + Supabase (nicht wieder Shopware)

| | Shopify (Online Store 2.0) | Shopware 6 |
|---|---|---|
| Betrieb, Hosting, Updates, Checkout, Zahlungen | inklusive | selbst betreiben |
| Ersatzteillogik | eigene App-Erweiterung, Daten aus Supabase | Plugin (2021 gescheitert) |
| Mehrsprachigkeit | Markets + Translate & Adapt, Import per Datei | Plugin |
| Vorhandene Arbeit | Export, Metafelder, Pilot-CSV fertig | – |
| Grenze | Import ab 50.000 Varianten gedrosselt (außer Plus), B2B nativ nur in Plus | – |

Shopify bleibt das **Schaufenster mit Kasse**, Supabase bleibt das **Gehirn**. Alles, was viele Daten braucht (7 Mio. Ersatzteil-Verknüpfungen, Austauschfinder, Suche, 290.000 Pumpenseiten), läuft in Supabase und wird über eine eigene App in den Shop eingeblendet.

### 3.2 Bausteine

```
                 Supabase (Grundfos-PIM)
   Artikel · Ersatzteile · Austausch · Medien · Texte · Suche
        │                         │
        │ Export (CSV/API)        │ Edge Functions (JSON / Liquid)
        ▼                         ▼
 ┌──────────────────┐     ┌────────────────────────────────┐
 │ Shopify-Produkte │     │ Shopify-App „Grundfos-Finder“   │
 │ (kaufbar: Pumpen,│◄───►│ · Theme-App-Blöcke (Finder,     │
 │  Ersatzteile,    │     │   Explosionszeichnung, Suche)   │
 │  Zubehör)        │     │ · App-Proxy: /tools/…  Seiten   │
 └────────┬─────────┘     │   für Long Tail (alle Pumpen)   │
          │               └────────────────────────────────┘
          ▼
  Checkout · Konto · Bestellungen · Google Merchant · Preisvergleich
```

- **Kaufbare Artikel** (Pilot 3.354, später Stufe A/B, ca. 30.000) sind echte Shopify-Produkte.
- **Alle übrigen Pumpen** bekommen eine Seite über den **App-Proxy**: Shopify ruft z. B. `/tools/ersatzteile/alpha2-25-40-180` bei uns ab. Antworten wir mit `Content-Type: application/liquid`, rendert Shopify die Seite im normalen Shop-Layout (Header, Footer, Warenkorb). So entstehen Ersatzteil- und Austauschseiten für jede Pumpe, ohne 290.000 Produkte anzulegen.
- **Warenkorb:** Der Finder kennt zu jeder Artikelnummer die Shopify-Varianten-ID (Abgleichtabelle `pim.shopify_variante`, wird nach jedem Import aktualisiert) und legt per AJAX-Warenkorb (`/cart/add.js`) direkt ab. Teile, die (noch) nicht kaufbar sind, bekommen „Anfrage senden“.

---

## 4. Ersatzteilfinder – das Herzstück

Das, was 2021 komplett fehlte („vom Produkt direkt zum Ersatzteil und sofort in den Warenkorb“).

### 4.1 Ablauf für den Kunden

1. **Pumpe finden** – ein Suchfeld für alles (`pim.suche`): Artikelnummer, Typ („UPS 25-60 180“), EAN, Fremdtyp. Später: **Typenschild fotografieren** (Texterkennung liest Typ, Artikelnummer und Produktionscode).
2. **Baujahr eingrenzen** – Produktionscode vom Typenschild (Jahr/Woche, Format je Baureihe prüfen) oder Auswahl „vor/nach 2015“. Die Datenbank kennt zu jedem Teil den Produktionszeitraum.
3. **Explosionszeichnung** – Zeichnung links, Positionsliste rechts. Klick auf eine Positionsnummer markiert die Zeile und umgekehrt.
4. **In den Warenkorb** – je Position: Bild, Name, Artikelnummer, Menge in der Pumpe, Preis, Lieferzeit, Button. **Reparatursätze (Kits) zuerst**, weil sie meist die richtige Wahl sind.
5. **Sonderfälle** – Teil nicht mehr lieferbar → Nachfolgeteil; Reparatur lohnt sich nicht → „Neue Pumpe statt Reparatur“ mit Austausch-Vorschlag.

### 4.2 Seiten rund um das Ersatzteil (die 2021 fehlenden Seiten)

| Seite aus der Vorlage | Umsetzung |
|---|---|
| **Ersatzteile Produkt-Seite** | Shopify-Produktseite des Teils: Titel, Preis, Lieferzeit, Warenkorb |
| **Ersatzteile Informationen** | Reiter „Informationen“: Beschreibung, technische Daten, Inhalt des Satzes, **„Passt zu“** (Pumpen mit Position und Baujahr, Metafeld `passt_zu`) |
| **Ersatzteile Bilder** | Reiter „Bilder“: eigenes Teilebild, sonst Explosionszeichnung mit markierter Position (`pim.shop_bilder`), Service-Katalog als PDF (`pim.shop_dokumente`) |
| Ersatzteile je Pumpe | Pumpen-Produktseite, Block „Ersatzteile“ + Proxy-Seite `/tools/ersatzteile/<pumpe>` |

### 4.3 Klickbare Positionen auf der Zeichnung

Die Zeichnungen sind Bilder ohne Koordinaten. Vorschlag in zwei Stufen:

1. **Automatisch:** Texterkennung (z. B. Tesseract) sucht die Positionsnummern auf jeder Explosionszeichnung und speichert ihre Lage (`pim.zeichnung_position`: Medium, Position, x, y). Nur Nummern, die in der Ersatzteilliste der Pumpe vorkommen, zählen – das filtert Fehltreffer.
2. **Nacharbeit:** Kleines Pflegewerkzeug (Zeichnung anklicken → Position zuordnen) für die Zeichnungen, bei denen die Erkennung unvollständig ist, Bestseller-Baureihen zuerst.

Fallback ohne Koordinaten: Zeichnung groß + Positionsliste. Das ist bereits besser als alle Wettbewerber außer pumpengermany.de.

---

## 5. Shop-Aufbau

### 5.1 Startseite: vier Einstiege statt Produktkacheln

1. **Suchfeld** (groß, oben): „Artikelnummer, Typ oder Pumpe eines anderen Herstellers“
2. **Ersatzteil finden** → Ersatzteilfinder
3. **Pumpe ersetzen** → Austauschfinder („Meine alte Pumpe: UPS 25-60 / Wilo Star …“)
4. **Nach Anwendung** → Heizung · Trinkwasser/Hauswasser · Abwasser · Industrie · Dosierung (Kategoriebaum `pim.shop_kategorie`)

Darunter: Bestseller (`pim.artikel_beliebt`), Vorteile (Originalteile, Lieferzeit, Fachberatung), Kundenmeinungen.

### 5.2 Seitenübersicht (alle Seiten aus dem Gutachten + neue)

| Bereich | Seiten | Quelle der Inhalte |
|---|---|---|
| Katalog | Anwendung › Baureihe (z. B. Heizung › ALPHA2) › Produkt | Kollektionen aus `shop_kategorie`, Filter über Metafelder (Search & Discovery) |
| Pumpe | Produktseite mit Reitern: Übersicht · Technische Daten · **Ersatzteile** · Zubehör · Dokumente · Ersetzt (alt/Wettbewerb) | Metafelder aus dem Export |
| Ersatzteil | Produktseite mit Reitern: **Informationen** · **Bilder** · Passt zu | s. 4.2 |
| Finder | Ersatzteilfinder, Austauschfinder, **Produktauswahl** (geführt: Anwendung → Anschluss → Leistung) | App + Supabase |
| SEO-Seiten | „UPS 25-60 180 ersetzen“, „Ersatzteile für MAGNA3 32-100“ (App-Proxy) | Nachfolger, Wettbewerbs-Austausch |
| Vergleich | Produkte vergleichen (bis 4, gleiche Merkmale nebeneinander, Unterschiede hervorgehoben) | Metafeld `technische_daten` |
| Service | **Reparatur** (mit Kopfbild und Icon-Stichpunkten wie Vorlage), **FAQ**, Kontakt, Versand und Lieferung (mit Kopfbild), Über uns | Shopify-Seiten / Metaobjekte |
| Konto | Registrierung, Kontoübersicht, Bestellhistorie, später B2B: Schnellbestellung per Artikelnummer, Nachbestellen | Shopify-Kundenkonten |
| Kasse | Warenkorb, Bezahlvorgang | Shopify Checkout |
| Recht | Impressum, AGB, Widerruf, Datenschutz, Versandkosten | Shopify-Richtlinien |

### 5.3 Footer (2021 stark abweichend)

Vier Spalten wie die Vorlage, auf Mobil als aufklappbare Abschnitte:
- Service-Links · Rechtliches · Kontakt/Telefon/Öffnungszeiten · **vollständige** Zahlungs- und Versand-Icons (aus den tatsächlich aktiven Zahlarten, nicht fest eingebaut)
- **„Aktuelle Kundenmeinungen“**: Bewertungs-Widget (Trusted Shops oder Judge.me), letzte 3 Bewertungen
- **„Aktuelle Support-Anfragen“**: die letzten beantworteten Fragen (anonymisiert, aus einem Metaobjekt „Frage & Antwort“, verlinkt auf die FAQ). Zeigt, dass der Shop lebt und berät

### 5.4 URL-Schema (sprechend, je Sprache)

- `/products/grundfos-alpha2-25-40-180-99411165` (schon im Export so angelegt)
- `/collections/heizung-umwaelzpumpen-alpha2`
- `/tools/ersatzteile/magna3-32-100-f` · `/tools/ersatz/ups-25-60-180` · `/tools/ersatz/wilo-stratos-pico-25-1-6`
- Englisch unter `/en/…` (Shopify Markets)

---

## 6. Mobil zuerst

2021 war die Website nicht mobile-friendly. Diesmal gilt jedes Seitenlayout erst als fertig, wenn es auf dem Telefon stimmt.

- Theme auf Basis von Dawn (Shopify-Standard, schnell, barrierearm), eigene Abschnitte nur wo nötig
- Prüfbreiten: **360, 390, 768, 1024, 1440 px** – automatische Bildschirmfotos je Seite und Breite (Playwright)
- Explosionszeichnung auf Mobil: Zeichnung mit Zoom (Zwei-Finger), Positionsliste darunter, Klick auf Zeile springt zur Stelle
- Ziele: Lighthouse mobil ≥ 90 (Leistung, Barrierefreiheit, SEO), keine horizontale Scrollleiste, Schrift ≥ 16 px, Klickflächen ≥ 44 px
- Bilder über Shopify-CDN in passenden Größen (`image_url` mit Breite), nie ausgeblendet, sondern umgebrochen

---

## 7. Mehrsprachigkeit

- **Deutsch** zum Start, **Englisch** im zweiten Release, danach fr, it, nl, pl (Texte laufen bereits)
- Produkte: Übersetzungsdatei aus dem Export (`<datei>.uebersetzungen.json`) → Translate & Adapt
- Theme-Texte (Buttons, Footer, Finder): Sprachdateien des Themes, vollständig gepflegt
- **Automatische Prüfung:** Ein Test ruft jede Seitenart in jeder Sprache auf und schlägt fehl, wenn deutscher Text auf einer englischen Seite steht oder ein Übersetzungsschlüssel fehlt. Genau dieser Fehler („nach Klick auf Englisch fehlt die komplette Übersetzung“) war 2021 sichtbar.

---

## 8. Vorgehen

### 8.1 Pflichtenheft zuerst (Lehre aus Pos. 1)

Ein gemeinsames Dokument, das wir beide abnehmen, bevor Code entsteht:
- je Seite: Zweck, Inhalte, Datenquelle, Desktop- und Mobil-Skizze, **Abnahmekriterien** (prüfbar, z. B. „Footer zeigt alle aktiven Zahlarten“, „Ersatzteilfinder legt Teil mit einem Klick in den Warenkorb“)
- je Funktion: Testfall (Eingabe → erwartetes Ergebnis), z. B. „Magna3 32-100 F, Baujahr 2016 → Elektronikmodul Pos. 158 erscheint“
- Releaseplan mit Umfang je Release

### 8.2 Releases

| Release | Inhalt | Abnahme |
|---|---|---|
| **R0 – Grundgerüst** (2 Wochen) | Shop anlegen, Theme-Basis, Header/Footer nach Vorlage, rechtliche Seiten, Zahlung/Versand, Pilot-Import (3.354 Produkte als Entwurf) | Footer- und Header-Abnahme Desktop + Mobil |
| **R1 – Katalog** (3 Wochen) | Kategorien, Baureihen, Produktseiten Pumpe und Ersatzteil mit allen Reitern, Suche, Vergleich, Service-Seiten inkl. FAQ und Reparatur | Alle Seiten aus 5.2, Testkäufe |
| **R2 – Ersatzteilfinder** (4 Wochen) | App mit Finder, Positionsliste, Baujahr, Warenkorb; Hotspot-Erkennung; Proxy-Seiten je Pumpe | 50 Testfälle aus dem Pflichtenheft |
| **R3 – Austausch und SEO** (3 Wochen) | Austauschfinder (Grundfos alt + Wettbewerb), SEO-Seiten, Google Merchant Feed, Englisch | Übersetzungstest, Feed ohne Fehler |
| **R4 – Ausbau** | Typenschild-Foto, B2B (Schnellbestellung, Nettopreise), weitere Sprachen, mehr Sortiment | nach Bedarf |

Live gehen kann der Shop nach R1, sobald **Preise** feststehen. R2 ist das Alleinstellungsmerkmal.

### 8.3 Qualität (Lehre aus Pos. 5)

- **Demo am Ende jedes Sprints** (alle 2 Wochen) auf einem Vorschau-Theme mit **echten Daten**, nie mit Kopien
- **Automatische Tests**, die vor jeder Demo laufen:
  - Klickpfad: Suche → Pumpe → Ersatzteil → Warenkorb → Kasse (Desktop und Mobil)
  - Bildschirmfotos aller Seitenarten in 5 Breiten, Vergleich mit dem letzten Stand
  - Linkprüfung (keine toten Links, keine leeren Reiter)
  - Übersetzungstest (Abschnitt 7)
  - Datenprüfung: jedes Teil im Finder ist kaufbar oder hat „Anfrage“; jede Produktseite hat Bild, EAN, Preis
- **Definition of Done:** Abnahmekriterien erfüllt, Tests grün, auf Telefon und Desktop vorgeführt
- Dieses Gutachten wird zur **Checkliste**: Jeder Punkt muss im neuen Shop nachweisbar erledigt sein

---

## 9. Was ich von dir brauche

1. **Vorlagen und Pflichtenheft von 2021** (Design-Dateien, z. B. Figma/Adobe XD/PDF). Das Gutachten bezieht sich darauf; damit bauen wir das Frontend 1:1 nach, statt neu zu entwerfen. Falls es sie nicht mehr gibt: neues Design auf Basis von Dawn.
2. **Neuen Shopify-Shop** anlegen und den Connector darauf umstellen (zeigt derzeit solarics.de); Tarif-Entscheidung (Plus erst bei B2B nötig).
3. **Preise und Lieferzeiten:** Einkaufsquelle und Kalkulation – ohne Preise kein Livegang.
4. **Name und Domain** (ohne „Grundfos“ im Namen, s. `01-Analyse.md` Abschnitt 8). Das Gutachten nennt „Grundfos-Pumpen.de“ – das sollte anwaltlich geprüft werden.
5. **Bewertungsdienst:** Trusted Shops oder Judge.me.

## 10. Nächste Schritte, die ich sofort umsetzen kann

1. **Pflichtenheft** als Entwurf mit Abnahmekriterien und Testfällen je Seite
2. **Datenbasis für den Finder:** Funktion `pim.finder_ersatzteile(pumpe, baujahr)` (Positionsliste mit Kits zuerst, Nachfolger, Kaufbarkeit) und Edge Function dazu
3. **Hotspot-Erkennung** als Colab: Positionsnummern auf den Explosionszeichnungen der Pilot-Baureihen erkennen, Trefferquote messen
4. **Theme-Grundgerüst** im Repository (`theme/`): Header, Footer nach 5.3, Produktseiten mit Reitern, Testsuite (Playwright)
