# Grundfos-Onlineshop – Analyse: Wie wir die Nr. 1 werden

**Neues, eigenständiges Projekt** (nicht auf solarics.de oder der bisherigen Scraper-Pipeline aufgebaut)
Stand: 24.10.2026 · Grundlagen: PDF „Grundfos Pumpen – Data crawling“ (12.03.2021), kompletter Google-Drive-Ordner, Marktrecherche

> **Korrektur nach dem Datenaudit (24.10.2026):** Abschnitt 2 und 3 unterschätzen die vorhandenen Daten. Die DATANORM-Dateien von Grundfos (Stand 2014–01/2016) enthalten für rund 12.000–20.000 Artikel Kurz- und Langtexte, EAN, Listenpreise und technische Werte. Die GPC-Software liefert Anleitungen, Explosionszeichnungen und Sortimentslisten; ihre Produktdatenbank `GPI.MDF` fehlt aber in der Drive-Kopie. Details: [`02-Datenaudit-und-Datenmodell.md`](02-Datenaudit-und-Datenmodell.md).

---

## 1. Kurzfazit

1. **Die Nachfrage ist belegt.** Grundfos-Produktseiten bekommen schon ohne Preis und Bild 1.100 bis 3.200 Google-Besuche im Monat.
2. **Das Kernsortiment ist umkämpft.** Die Alpha2 25-60 180 bieten 15 bis 16 Händler an, die günstigsten ab rund 223 bis 229 € (Geizhals, guenstiger.de). Dazu kommen Baumärkte und Amazon. Über den Preis allein wird man hier nicht Nr. 1.
3. **Die Lücke liegt in der Service-Tiefe.** Kein deutscher Shop vereint einen vollständigen Katalog mit einem Austauschfinder (altes Modell → neues Modell), einem Ersatzteilfinder je Pumpe mit Explosionszeichnung, Kennlinien und einem B2B-Bereich. Genau dort ist die Nr.-1-Position frei.
4. **Der Zeitpunkt ist günstig.** ALPHA1 GO und ALPHA2 GO ersetzen 2025/26 die Alpha1/2/3, UPS und UPM3/4. In Deutschland laufen Millionen alter Heizungspumpen, und für jede wird irgendwann nach „Ersatz für …“ gesucht.
5. **Der Engpass sind Daten und Einkauf, nicht die Shop-Software.** Zu 806.105 Grundfos-Artikelnummern ist nur das Gerüst vorhanden: Nummer, Name, Kategorie und Link. Beschreibungen, technische Daten, Dokumente, Ersatzteil-Zuordnungen, EAN und Preise fehlen vollständig.
6. **Die Daten kommen von Grundfos selbst oder vom Großhandel, nicht per Scraping.** Infrage kommen Extranet und MyGrundfos, die Preisliste 2026, DATANORM/BMEcat und die Bildlizenz des Marketing Centers. Scraping ist gescheitert und rechtlich riskant (siehe Abschnitt 3).
7. **Empfehlung:**
   - zum Start 2.000 bis 3.000 Top-Artikel plus Ersatzteil-Kits, vollständig gepflegt;
   - den übrigen Katalog als durchsuchbares Verzeichnis mit Anfragefunktion;
   - eine eigene Produktdatenbank als Herzstück und Shopify als Verkaufskanal.

---

## 2. Was an Rohmaterial vorhanden ist

| Quelle | Inhalt | Für das neue Projekt |
|---|---|---|
| **PDF „Data crawling“ (2021)** | Beschreibt die Schnittstellen des alten „Product Selection Classic“ (US-Version 1.61.05): Katalogbaum, Spezifikationen, Ausschreibungstext, Dokumente, CAD, Kennlinie, Maßzeichnung, Motorkurve, Schaltbild und Ersatzteillisten. Die Ersatzteillisten sind nach Produktionsdatum gegliedert und hierarchisch aufgebaut: Satz → Teil → Positionsnummer → Klassifizierung. | ✅ **Als Vorlage für das Datenmodell.** Es zeigt, welche Felder und Beziehungen ein vollständiger Grundfos-Datensatz hat. ❌ **Als Datenquelle unbrauchbar:** Das Tool ist abgelöst, die Endpunkte liegen hinter einer Akamai-Firewall. |
| **Artikelliste: 806.105 Nummern und 899 Produktgruppen** (129 Familien, 770 Serien) | Nummer, Name, Familie, Serie, Kategorie, Link zum Grundfos Product Center | ✅ **Kategoriebaum und Deep-Links.** Mehr als die Hälfte sind allerdings Industrie- und Serviceartikel: Service-Special 239.953, NK 90.842, CR 85.232, NKG 50.921. Das ist kein Endkundensortiment. |
| Batch-Exporte (330.000 Zeilen, 87 Spalten) und `Grundfos_FULL.csv` (186.000 Zeilen) | Nur Struktur. Beschreibung, Technik, EAN und Preis sind leer oder als „BLOCKED“ markiert. | ❌ Nicht importieren. |
| `GRUNDFOS_Prices_de_DE_MASTER.csv` (98 MB) | Platzhalter, keine Preise | ❌ |
| `GRUNDFOS_Pump_SparePart_Mapping…` (56 MB, ca. 210.000 Zeilen) | Ordnet über gleiche Modellnamen zu, enthält keine Stücklisten. Das eigene Audit der Pipeline meldet 0 echte Beziehungen. | ❌ **Gefährlich:** Falsche Ersatzteil-Zuordnungen führen zu Fehlkäufen und Retouren. |
| **DATANORM „Ersatzteile 2016“** (Datenstand 15.12.2015) | Offizielle Grundfos-Daten mit EAN, Bruttolistenpreis, Rabatt- und Warengruppe, ca. 5.000 Ersatzteile | ✅ **EANs bleiben gültig.** ⚠️ Die Preise sind zehn Jahre alt und müssen ersetzt werden. |
| Ordner „Datanorm X Shopify“ (über 50 Rohdateien verschiedener Hersteller, erkennbar 2014–2016) | DATANORM-Rohdaten (.001/.002/.WRG/.RAB) | 🔍 Prüfen, ob neuere Grundfos-Stände dabei sind. Dafür muss man die Dateien lokal auswerten. |
| **GPC-Ordner** (Desktop-Installation Grundfos Product Center 2019, 4,4 GB) | Produktbilder (722 MB), Montage- und Betriebsanleitungen DE/EN, ca. 190 Service-Zeichnungen, Austausch-Cache, Zubehörregeln, Länder-Sortimentslisten | ⚠️ **Inhaltlich die wertvollste Quelle,** aber Eigentum von Grundfos und Stand 2019. Nur nach schriftlicher Freigabe durch Grundfos verwenden. |
| CR-Teilprojekt | `grundfos_cr_pumpen.csv` mit Katalog-Technikdaten der CR-Baureihe. `grundfos_cr_reparatursaetze.csv` ist synthetisch erzeugt („PENDING“). | ✅ Die Technikdaten taugen als Muster für die Datenstruktur. ❌ Die Reparatursätze nicht verwenden. |
| `shopify_import.csv` / `shopify_1000.csv` | Siemens- und Bosch-Rexroth-Artikel | ➖ Gehören nicht zu diesem Projekt. |
| GitHub-Repo `Grundfos-` | leer | ✅ Sauberer Start |

**Lehre aus solarics.de (nur als Erfahrungswert):**
- Dort stehen rund 1.950 Grundfos-Artikel für 0,01 € mit Platzhalterbestand.
- Sie bringen 1.100 bis 3.200 Google-Besuche im Monat, aber nur 3 Warenkorb-Aktionen in sechs Monaten.
- Folgerung: Die Nachfrage ist da. Gekauft wird erst mit echtem Preis, Lieferzeit, Bild und Vertrauen.
- Am häufigsten aufgerufen werden Altmodelle wie UPS 25-40, UPS 15-40 und UP 15-14 sowie Hauswasserprodukte wie Scala2, JP, MQ, Sololift2 und SBA. Das sind genau die Felder „Ersatz finden“ und „Haus/Garten“.

---

## 3. Der Engpass: Daten, Einkauf, Preise

| Datenfeld | Wichtig für Nr. 1 | Vorhanden | Legale Quelle |
|---|---|---|---|
| Artikelnummer, Name, Kategorie | Pflicht | ✅ 100 % | vorhanden |
| EAN/GTIN | Pflicht (Google Shopping, Preisvergleich) | ⚠️ nur Ersatzteile 2016 | aktuelles DATANORM/BMEcat von Grundfos oder vom Großhandel |
| Listenpreis (UVP) | Pflicht | ❌ | Grundfos-Preisliste 2026 (online veröffentlicht) |
| Einkaufspreis und Verfügbarkeit | Pflicht | ❌ | Händlervertrag oder Großhandel; MyGrundfos „Preis & Verfügbarkeit“ |
| Beschreibung, technische Daten | Pflicht | ❌ | BMEcat/ETIM bzw. Datenpaket von Grundfos |
| Produktbilder | Pflicht | ⚠️ Links generiert, Nutzungsrechte offen | **Grundfos Marketing Center**: kostenlose, jederzeit widerrufliche Lizenz nur für den Verkauf von Grundfos-Produkten, Bilder dürfen nicht bearbeitet werden |
| Datenblatt, Anleitung | Soll | ❌ | auf die PDFs bei Grundfos verlinken statt sie selbst zu hosten |
| Kennlinie (Q/H) | Unterscheidungsmerkmal | ⚠️ nur Bild-Link | Grundfos-Bildschnittstelle (Erlaubnis klären) |
| **Ersatzteile je Pumpe** (Explosionszeichnung, Positionsnummer, Produktionsdatum) | **Alleinstellungsmerkmal** | ❌ | MyGrundfos-Ersatzteilfinder bzw. Extranet; Status als Service-Partner |
| **Nachfolger alt → neu** | **Alleinstellungsmerkmal** | ❌ | Grundfos Replacement / GO Replace, Austauschlisten von Grundfos |

**Warum Scraping keine Option ist:**
- Laut Nutzungsbedingungen hält Grundfos alle Rechte an seinen digitalen Lösungen. Jede andere Nutzung braucht vorherige schriftliche Zustimmung.
- Der vorhandene Scraper umgeht die Akamai-Firewall gezielt (Stealth-Browser, Residential-Proxys). Das ist rechtlich heikel: Datenbankherstellerrecht nach §§ 87a ff. UrhG und Wettbewerbsrecht. Das sollte ein Anwalt bewerten.
- Selbst ein Residential-Proxy wurde geblockt. Die Pipeline steht seit dem 03.08.2026.
- Selbst vollständig gescrapte Daten enthielten weder Einkaufspreise noch Bestände.

➡️ **Die Scraper-Pipeline nicht ins neue Projekt übernehmen.**

---

## 4. Markt und Wettbewerb (Deutschland)

> Hinweis zur Methode: Die Websites ließen sich aus der Arbeitsumgebung nicht direkt öffnen. Die Zahlen stammen aus Suchergebnissen und sind Momentaufnahmen. Quellen stehen in Abschnitt 11.

### 4.1 Wettbewerber

| Shop | Stärke | Schwäche / Lücke |
|---|---|---|
| **heizungsdiscount24.de** | Breites Sortiment (Alpha, Magna3, Scala, Unilift, Conlift), aggressive Preise (Alpha1 25-40 für 131,90 €), Trusted Shops 4,78 bei 37.502 Bewertungen | Kein Ersatzteilsortiment gefunden |
| **wasserpumpe.de** | Versandkostenfrei; bis 18 Uhr bestellt, nach 1–2 Tagen da; Trusted Shops 4,63 bei 39.126 Bewertungen; verkauft auch über den Hornbach-Marktplatz | Schwerpunkt Wasser |
| **pumpe24.de** | Brunnenpumpen-Pakete (SQ mit Kabel), Kategorie Grundfos-Ersatzteile, über 10.000 Artikel | Gemischte Bewertungen außerhalb des eigenen Shops |
| **heizung-billiger.de** | Tiefstes Ersatzteilsortiment: 1.016 Ersatzteile und 836 Zubehörartikel | Keine Suche „nach Pumpe“ erkennbar |
| **st-shop24.de** (autorisierter Grundfos-Servicepartner) | Ersatzteile nach Baureihe sortiert (Alpha/Magna3, TP, CR), Versand am selben oder nächsten Tag | Kleiner Shop |
| **pumpengermany.de** | Einziger Shop mit Explosionszeichnung und Positionsnummern (Scala2, MQ, Sololift2, Magna3) | Nur wenige Baureihen |
| Hornbach, OBI, Bauhaus, Amazon | Reichweite; Alpha2 für ca. 220–280 € | Keine Beratung, keine Ersatzteile |
| Großhandel (GC-Gruppe, Richter+Frenzel) | Vollsortiment für das Fachhandwerk | Nur für Gewerbekunden, nicht für Endkunden |
| Industrie (CR/CM) | Kaum deutsche Shops mit CR-Preisen (CR5-10: 1.185 € netto bis 2.026 € brutto) | **Preistransparenz fehlt** |

### 4.2 Was Grundfos selbst anbietet

- **Keinen öffentlichen Webshop.** Bestellt wird über das Grundfos-Extranet, für registrierte Kunden.
- **Preisliste 2026** online, mit Verknüpfung zum Product Center.
- **Product Center:** Auslegung, geführter Austausch, Kennlinien, CAD/BIM, Dokumente.
- **GO Replace** in der Grundfos-GO-App: Typenschild fotografieren, passende Nachfolgepumpe erhalten. Deckt über 10.000 Umwälzpumpen ab.
- **MyGrundfos** (kostenloses Konto): Listenpreise und Verfügbarkeit, Ersatzteilfinder, Austauschfinder, Auftragsverfolgung.
- **Modellwechsel:**
  - ALPHA1 GO ersetzt UPS und ALPHA1 L.
  - ALPHA2 GO ersetzt UPM3/UPM4 und ALPHA2/3.
  - Zwei Modelle plus Signaladapter decken rund 70 % der in Geräte eingebauten Umwälzpumpen ab.
- **Installateurprogramm** „Grundfos für Installateure“ mit Punktesystem und Ecademy-Schulungen.
- **Ansprechpartner für den Händlerstatus:** Grundfos GmbH, Schlüterstraße 33, 40699 Erkrath, Tel. +49 211 929 69 0, infoservice@grundfos.com.

### 4.3 Nachfrage

- **Austauschmarkt:** Ein Papier des Bayerischen Landtags aus einer früheren Wahlperiode nennt rund 42 Mio. Heizungspumpen. Über 85 % davon seien ungeregelte Altpumpen, 52 % älter als 10 Jahre.
- **Wirtschaftlichkeit:** Ein Pumpentausch kostet laut co2online rund 300–400 € inklusive Einbau und spart über 150 € im Jahr.
- **Suchverhalten:** „UPS 25-60 Ersatz“ ist ein häufiges Forenthema. Wilo veröffentlicht sogar einen Austauschleitfaden von Grundfos auf Wilo.
- **Förderung:** BAFA fördert den Pumpentausch als „Heizungsoptimierung“ mit 15 %, mit Mindestinvestition und Pflicht zum hydraulischen Abgleich. Den Antrag stellt man vor Beginn, und es muss ein Fachbetrieb beteiligt sein. Wer selbst einbaut, bekommt also keine Förderung. Das spricht für ein Paket mit Installateur.
- **Online-Anteil im Handwerk:** Laut einer Umfrage kaufen Installateure 41 % ihres Materials online.
- **Suchvolumen:** Konkrete Zahlen ließen sich nicht ermitteln. Dafür Google Keyword Planner bzw. Search Console einsetzen.

---

## 5. Was uns zur Nr. 1 macht

**„Nr. 1“ messbar gemacht (Vorschlag):**
- Top-3 bei Google für „[Modell] Ersatz“ und „Grundfos [Modell] Ersatzteil“, für die 500 wichtigsten Modelle;
- größter sofort lieferbarer Grundfos-Katalog mit vollständig verknüpften Ersatzteilen;
- Trusted Shops ≥ 4,8;
- führend bei Installateuren als Stammkunden.

### Die sechs Säulen

1. **Austauschfinder** (Hauptattraktion)
   - Altmodell eingeben oder Typenschild fotografieren, passende Neupumpe angezeigt bekommen. Anschlussmaße, Einbaulänge und elektrische Daten werden geprüft.
   - Funktioniert markenübergreifend: Grundfos UPS/UPM/Alpha, aber auch Wilo und andere Hersteller → passende Grundfos-Pumpe.
   - Für jedes Altmodell eine eigene Seite, z. B. „UPS 25-60 180 → ALPHA1 GO 25-60 180“. Das bringt dauerhaften SEO-Traffic.
2. **Ersatzteilfinder je Pumpe**
   - Pumpe auswählen, Produktionsdatum bzw. PC-Code angeben, dann die Explosionszeichnung sehen. Teile per Klick auf die Positionsnummer in den Warenkorb legen.
   - Ziel: so tief wie heizung-billiger.de, so bequem wie pumpengermany.de.
3. **Vollständige Verlinkung** (siehe Abschnitt 6). Jedes Produkt verweist auf seine Ersatzteile, sein Zubehör, seinen Nachfolger, das Datenblatt und die Originalseite bei Grundfos.
4. **Preistransparenz bei Industriepumpen**
   - Für CR/CRE und CM/CME echte Preise und Lieferzeiten.
   - Später ein Konfigurator. Hier sind die Wettbewerber am schwächsten.
5. **B2B für Installateure**
   - Nettopreise, Schnellbestellung per Artikelnummer, DATANORM-Export, Nachbestellung mit einem Klick.
   - **Förderpaket**: Pumpentausch plus hydraulischer Abgleich zusammen mit Partnerbetrieben.
6. **Vertrauen und Tempo**
   - Trusted Shops vom ersten Tag an.
   - „Bis 18 Uhr bestellt, in 1–2 Tagen da“.
   - Fachberatung per Telefon und Chat, Reparatur- und Austauschservice.

**Darüber ein Content-Bereich:** Ratgeber „Heizungspumpe tauschen“, Förderung, Kennlinien-Vergleiche, Nachfolgertabellen, Auswahlhilfen für Brunnenpumpen und Hebeanlagen.

---

## 6. Sortiment und „vollständige Verlinkung“

### 6.1 Sortiment in Stufen

| Stufe | Umfang | Inhalt | Darstellung |
|---|---|---|---|
| **A – Start** | ca. 2.000–3.000 Artikel | **Heizung:** ALPHA1/2 GO, Alpha-Restbestände, Magna1/3, Comfort/UP. **Hauswasser:** Scala1/2, JP, MQ, CMBE, SQ/SQE, SB/SBA. **Abwasser:** Unilift, Sololift2, Conlift, Multilift. Kleine CR/CM-Baugrößen. | Vollwertige Produktseite mit Preis, Lieferzeit, Bild, Technikdaten und allen Verknüpfungen |
| **B – Ersatzteile** | ca. 10.000–30.000 Artikel | Reparatursätze, Gleitringdichtungen, Laufräder, Kabel, Zubehör (mit EAN und Preis) | Produktseite, erreichbar über den Ersatzteilfinder |
| **C – Long Tail** | restliche ca. 770.000 Artikel | Normpumpen- und CR-Varianten, Service-Special-Artikel | **Durchsuchbares Verzeichnis mit Anfrage**, nicht als Shopify-Produkt. Die Produktseite entsteht erst bei Bedarf. |

**Warum nicht alle 806.000 Artikel als Shop-Produkte:**
- Ohne Inhalt bewertet Google solche Seiten als dünn („Thin Content“).
- Mehr als die Hälfte sind Varianten für die Industrie.
- Shopify begrenzt ab 50.000 Varianten den Import auf 1.000 neue Varianten pro Tag; Shopify Plus ist ausgenommen (Quelle: Shopify-Community, zitiert die Hilfe). Damit dauerte der Vollimport über zwei Jahre.

### 6.2 Verknüpfungen pro Produkt

| Verknüpfung | Beispiel | Datenquelle | Umsetzung |
|---|---|---|---|
| Produkt → Grundfos Product Center | Deep-Link zur Originalseite | ✅ vorhanden für alle 806.105 Artikel | Feld in den Produktdaten |
| Produkt → Datenblatt, Anleitung, CAD | PDF bei Grundfos | Grundfos-Datenpaket | Liste von Links |
| Produkt ↔ Kategorie und Anwendung | Heizung › Umwälzpumpen › ALPHA2 GO | ✅ Gruppenbaum mit 899 Gruppen | Kollektionen |
| **Pumpe ↔ Ersatzteile** (nach Produktionsdatum) | Magna3 32-100 → Elektronikmodul, Pos. 158 | MyGrundfos / Extranet | Produktverweise und Zeichnung als eigenes Datenobjekt |
| **Pumpe ↔ Zubehör** | Scala2 → Rückflussverhinderer | Zubehörregeln (GPC) / Grundfos-Daten | Produktverweise |
| **Altmodell → Nachfolger** | UPS 25-60 → ALPHA1 GO 25-60 | Grundfos Replacement, eigene Pflege | Austauschfinder und Altmodell-Seite |
| Ersatzteil → passt in | Gleitringdichtung 96525490 → CRN 32/45/64/90 | Rückrichtung der Ersatzteildaten | automatisch abgeleitet |

---

## 7. Technisches Zielbild (Neuaufbau)

```
 Grundfos (DATANORM/BMEcat, Preisliste, Extranet)   Großhandel (Bestand, EK)
                         │                                   │
                         ▼                                   ▼
            ┌─────────────────────────────────────────────────────┐
            │  Produktdatenbank / PIM (z. B. Postgres)             │
            │  Artikel · Beziehungen · Preise · Medienlinks ·       │
            │  Herkunft und Stand jedes Feldes                      │
            └──────────────┬───────────────────────┬──────────────┘
                           │                       │
              verkaufsfähige Artikel         alle Artikel (Suche)
                           ▼                       ▼
                ┌──────────────────┐     ┌──────────────────────────┐
                │ Shopify (neuer   │◄───►│ Austausch- und Ersatzteil-│
                │ Store, Checkout) │     │ finder, Long-Tail-Suche  │
                └────────┬─────────┘     └──────────────────────────┘
                         ▼
        Google Merchant Center · idealo · Geizhals · Marktplätze
```

- **Die Produktdatenbank ist die einzige Quelle der Wahrheit.** Zu jedem Feld ist gespeichert, woher es stammt und von wann. Shopify erhält nur Artikel mit echtem Preis, EAN, Bild und Verfügbarkeit. Platzhalterpreise gibt es nicht.
- **Suche:**
  - findet alte und neue Nummern;
  - toleriert Schreibweisen („UPS25-60“, „UPS 25-60 180“);
  - findet auch über EAN.
- **Feeds für Google Shopping:** GTIN, Marke und MPN.
- **Shopify-Tarif:** B2B-Funktionen gibt es nativ nur in Shopify Plus. Diese Entscheidung fällt zu Beginn von Phase 3.

---

## 8. Risiken und Recht (keine Rechtsberatung, bitte anwaltlich prüfen)

- **Markenrecht:**
  - Originalware darf mit dem Namen Grundfos beworben werden (Erschöpfung, § 24 MarkenG).
  - **„Grundfos“ gehört nicht in Domain oder Shopnamen** (BGH-Rechtsprechung zu Wiederverkäufern).
  - „Passend für“ ist nur zulässig, wenn es nötig und lauter ist.
- **Bildrechte:** Bilder nur auf Grundlage der Marketing-Center-Lizenz verwenden: widerruflich, nur für den Verkauf von Grundfos-Produkten, nicht bearbeiten. Datenblätter verlinken statt selbst hosten.
- **Preisbindung:** Grundfos darf keine Mindestverkaufspreise vorschreiben (Art. 4 lit. a Vertikal-GVO). Eine UVP ist erlaubt.
- **Ökodesign:** Ungeregelte Altpumpen, die den Energieeffizienzindex (EEI) von 0,23 nicht erreichen, dürfen nicht als Neuware verkauft werden.
- **Preisangaben:** Keine Platzhalterpreise; Grundpreise und Versandkosten korrekt angeben.
- **Datenqualität:** Falsche Ersatzteil-Zuordnungen führen zu Retouren und Vertrauensverlust. Deshalb nur offizielle Zuordnungen verwenden.
- **Abhängigkeit vom Hersteller:** Falls Grundfos keinen Direktvertrag oder Extranet-Zugang gibt, ist Plan B der Einkauf über den Großhandel.
- **Sicherheit (sofort):** In `GRUNDFOS_de_DE_DATA_COMPLETENESS_REPORT.xlsx` stehen Zugangsdaten im Klartext, in zwei Kopien. Passwort ändern und die Zeile löschen.

---

## 9. Entscheidungen, die vor dem Projektplan nötig sind

1. **Einkauf:** Direkter Händlervertrag mit Grundfos (Erkrath) anstreben, über den Großhandel einkaufen (GC, Richter+Frenzel …) oder beides? Gibt es schon Lieferantenbeziehungen?
2. **Zielgruppe zum Start:** Endkunden (Heizungspumpe tauschen, Haus und Garten), Installateure (B2B) oder Industrie (CR/CM)? Oder eine Reihenfolge?
3. **Marke und Domain:** Neue Marke? `pumpe-defekt.de` passt sehr gut zur Suchabsicht „Ersatz finden“. „Grundfos“ selbst darf nicht im Namen stehen.
4. **Sortiment:** Nur Grundfos oder später weitere Marken (Wilo, Lowara …)? Ein markenübergreifender Austauschfinder funktioniert auch, wenn nur Grundfos verkauft wird.
5. **Logistik:** Eigenes Lager für Schnelldreher, Streckengeschäft vom Großhändler oder gemischt?
6. **Budget und Team:** Shopify-Tarif (Plus ab B2B), Entwicklung der Finder, Datenpflege, Kundenservice.

---

## 10. Grobe Phasen (der Detailplan folgt als nächstes Dokument)

| Phase | Zeitraum (grob) | Inhalt |
|---|---|---|
| **0 – Bezug und Daten klären** | Woche 1–4 | Termin mit Grundfos Erkrath und Großhändlern; Datenpaket (DATANORM/BMEcat, Preisliste 2026), Bildlizenz, Extranet. Marke und Domain festlegen, Rechtsprüfung. Gesundheitscheck der vorhandenen Rohdaten. |
| **1 – Fundament** | Woche 3–10 | Datenmodell und Produktdatenbank, Importe (DATANORM/BMEcat), neuer Shopify-Store, Design, rechtliche Seiten, Zahlung und Versand |
| **2 – Start mit Kernsortiment** | Woche 8–14 | Stufe A (2.000–3.000 Artikel) mit allen Verknüpfungen, Altmodell-Seiten, Feeds, Trusted Shops, erster Content |
| **3 – Alleinstellungsmerkmale** | Monat 4–6 | Austauschfinder, Ersatzteilfinder (Stufe B), B2B für Installateure, Förderpaket |
| **4 – Ausbau** | ab Monat 6 | Long-Tail-Verzeichnis (Stufe C), CR-Konfigurator, Österreich und Schweiz, Marktplätze, Content-Ausbau |

---

## 11. Quellen (Auswahl)

- Wettbewerb:
  - heizungsdiscount24: <https://www.heizungsdiscount24.de/pumpen/grundfos/unilift-cc/>
  - Trusted Shops heizungsdiscount24: <https://www.trustedshops.de/bewertung/heizungsdiscount24-de>
  - wasserpumpe.de: <https://www.wasserpumpe.de/grundfos>
  - pumpe24: <https://www.pumpe24.de/ersatzteile/grundfos.html>
  - heizung-billiger: <https://heizung-billiger.de/3845-grundfos-ersatzteile-kaufen>
  - st-shop24: <https://st-shop24.de/grundfos/grundfos-ersatzteile.html>
  - pumpengermany: <https://www.pumpengermany.de/grundfos-ersatzteile-216>
  - Geizhals Alpha2 25-60 180: <https://geizhals.de/grundfos-alpha-2-25-60-180-heizungspumpe-99261730-a2065345.html>
- Grundfos:
  - Preisliste: <https://www.grundfos.com/de/contact/where-to-buy/PriceList>
  - Extranet: <https://www.grundfos.com/uk/contact/where-to-buy/extranet>
  - MyGrundfos: <https://www.grundfos.com/uk/mygrundfos>
  - ALPHA GO: <https://www.grundfos.com/de/learn/ecademy/all-courses/alpha-go-range/alpha-go-introduction>
  - Impressum: <https://www.grundfos.com/de/legal/impressum>
  - Nutzungsbedingungen: <https://www.grundfos.com/us/legal/terms-of-use>
  - Marketing Center: <https://www.grundfos.com/de/legal/terms-of-use-for-marketing-centre>
- Recht:
  - Marke in der Domain: <https://haerting.de/wissen/duerfen-marken-in-einer-domain-verwendet-werden-grundsatz-der-erschoepfung-und-hinweis-auf-ersatzteile/>
  - Produktfotos: <https://www.it-recht-web.de/verwendung-von-produktfotos-und-logos-in-onlineshops/>
  - Preisbindung: <https://www.hb-ecommerce.eu/2024/04/26/kartellrechtliche-bussgelder-wegen-vertikaler-preisbindung-sind-im-onlinehandel-weiterhin-sehr-praxisrelevant-auch-haendlern-drohen-bussgelder/>
  - Ökodesign: <https://gesetze.legal/eu/vo_eg_2009_641/anhang_i>
- Nachfrage und Förderung:
  - co2online: <https://www.co2online.de/modernisieren-und-bauen/heizungspumpe/heizungspumpe-tauschen/>
  - Bayerischer Landtag: <https://www.bayern.landtag.de/www/ElanTextAblage_WP17/Drucksachen/Basisdrucksachen/0000014500/0000014827.pdf>
  - BEG EM: <https://www.ihk.de/lippe-detmold/hauptnavigation/beraten-und-informieren/energie/aktuelles/beg-em-und-heizungsfoerderung-7130330>
