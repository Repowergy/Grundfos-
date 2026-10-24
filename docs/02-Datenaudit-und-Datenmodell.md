# Datenaudit (Schritt 1) – Ergebnis und Datenmodell für Supabase

Stand: 24.10.2026 · Quelle: Audit-Lauf in Colab (12 Minuten), Berichte unter `02 Grundfos/00_Datenaudit/ergebnis/`

> Dieses Dokument korrigiert Abschnitt 2 und 3 der Analyse (`01-Analyse.md`). Die DATANORM-Dateien enthalten deutlich mehr als dort angenommen: Beschreibungen, Langtexte, EAN, Listenpreise und technische Werte je Artikel.

---

## 1. Ergebnis in Kürze

| Bedarf | Quelle | Bewertung |
|---|---|---|
| **Artikelstamm, Kurz- und Langtext, EAN, Listenpreis** | DATANORM „Artikel 2016“ von Grundfos GmbH (12.231 Artikel), „Artikel 2014“ (11.630), „Ersatzteile 2016“ (3.348), „Verpackungseinheiten 2016“ (614), „GF“-Datei 12/2015 (8.662) | ✅ **Gute Basis.** Alle Artikel mit EAN und Preis; Langtexte gelten je Baureihe. Die technischen Werte je Artikel stehen in D-/E-Sätzen und lassen sich zusammenführen. ⚠️ **Stand Januar 2016**: Preise veraltet, neue Modelle (z. B. ALPHA GO) fehlen. |
| **Aktuelle Daten?** | Großhändler-DATANORM vom **05.09.2025** mit 1.046.049 Artikeln (Hersteller im Kopf nicht genannt) | 🔍 **Wichtigste offene Spur:** Prüfen, ob dort aktuelle Grundfos-Artikel enthalten sind. |
| **Bilder** | GPC `ProdPic.zip` (722 MB) | 🔍 Vorhanden, Benennung noch nicht ausgewertet |
| **Montage- und Betriebsanleitungen** | GPC InstOper DEU/ENU/COMMON (ca. 1.600 PDFs, 3 GB), Service-PDFs (ca. 500) | ✅ Vorhanden (Stand 2019). ⚠️ Benannt nach Dokumentnummer; welche Anleitung zu welchem Artikel gehört, stand in der fehlenden Datenbank. |
| **Explosionszeichnungen** | GPC Service: ca. 1.400 Zeichnungen (NP2/TIF) und ca. 400 Dateien mit klickbaren Positionsnummern | ✅ Zeichnungen da. ⚠️ Zuordnung Pumpe → Zeichnung → Position → Ersatzteilnummer fehlt (ebenfalls in der Datenbank). |
| **Austausch alt → neu** | GPC `QuickReplacement.cache` (gzip-JSON, 72 MB entpackt, ca. 42.000 Nummern), Filterregeln, Wettbewerbs-Umwälzpumpen (KSB u. a.) | 🔍 Muss entpackt werden. Eine fertige Liste „alt → neu“ ist noch nicht bestätigt. |
| **Zubehör** | GPC `ACCLINK2.csv` (Baureihe → Zubehörgruppe) und Regeldateien | ⚠️ Nur auf Ebene Baureihe, nicht je Artikel |
| **Sortiment Deutschland** | GPC `ProductRange_ggd.txt` (vermutlich Deutschland, ca. 230.000 Zeilen, Stand 2019) | ✅ Vorhanden; Landescode noch bestätigen |
| **Technische Daten, Kennlinien, Stücklisten, Dokument-Verknüpfungen** | GPC-Produktdatenbank **`GPI.MDF`** (SQL Server LocalDB) | ❌ **Nicht in der Kopie im Drive.** Die Software meldet beim Start, dass der Datenserver fehlt. |

**Fazit:**
- Du hattest recht: Die Daten reichen für einen soliden Start mit rund 12.000 bis 20.000 Artikeln, inklusive Beschreibung, EAN und technischer Werte.
- Die eigentlichen **Verlinkungen** (Ersatzteile je Pumpe, Dokumente je Artikel, Kennlinien) stecken in der Produktdatenbank `GPI.MDF`, und die fehlt in der Drive-Kopie.

---

## 2. DATANORM im Detail

- **Format:** DATANORM 4.0 mit Semikolon als Trennzeichen, Zeichensatz CP850, alle Umlaute korrekt.
- **Satzarten der Grundfos-Dateien:**

| Satz | Inhalt | Beispiel |
|---|---|---|
| A | Artikel: Nummer, Textkennzeichen, Kurztext 1+2, Preiskennzeichen, Preiseinheit, Mengeneinheit, Preis (2 Nachkommastellen implizit), Rabattgruppe, Hauptwarengruppe, Langtext-Schlüssel | `A;N;011H1300;60;GRUNDFOS Kellerentwässerungsp. Unilift;KP150-M1 Rp5/4 1x230V 0,3kW 10m Kabel;1;0;PCE;31137;D2;SAP;TKP0M;` → 311,37 € |
| B | Zusatzdaten: EAN, Unterwarengruppe, Verpackungsmenge | `B;N;011H1300; ; ; ;0;0;0;5700391115400; ;58;0;1; ; ;` |
| T | Langtext je Baureihe (Schlüssel aus A-Satz), zwei Zeilen je Satz | `T;N;TPT10;;1;;Temperaturfühler Pt100 für;2;;Außentemperatur in Verkleidung;` |
| E | Textbausteine mit Platzhaltern `$` | `E;N;EKP0M;;3;;Maximale Korngröße: 10 mm;…` |
| D | Werte je Artikel für die Platzhalter (Spannung, kW, Kabellänge …) | `D;N;011H1300;1;E;EKP0M;Unilift KP 150 M 1$300$8$1 x 220-230$;…` |
| S (.WRG) | Warengruppen-Namen | `S;;HA;;192;Hebeanlage MLD/MOG/MDG;` |
| R (.RAB) | Rabattgruppen-Namen | `R;;A1;1;0000;Nassläuferpumpen mit Verschr. ALPHA2;` |

- **Langtexte sind brauchbar.** Beispiel Unilift KP 150 (011H1300): „1-stufige, vertikale Tauchmotorpumpe aus Chrom-Nickel-Stahl … halboffenes Laufrad mit 10 mm freiem Durchgang … geeignet zur Förderung von Grundwasser, Oberflächenwasser und Regenwasser …“
- **Einschränkungen:**
  - Die Langtexte der Datei von 2014 sind teils nur Platzhalter („Produktbezeichnung: EAN Nummer :“).
  - Ersatzteile 2016 und Verpackungseinheiten haben nur Kurztexte.
  - Die Langtexte der „GF“-Datei liegen in einer separaten Datei (`datanorm (23).002`).
- **Ordner insgesamt:** 463 DATANORM-Dateien von etwa 150 Lieferanten, 87 davon doppelt. Grundfos-Dateien gibt es nur bis 28.01.2016.

---

## 3. GPC-Software im Detail

- **Version:** Programm 2019.6, Produktdatenbank DB2019.09.16.1, zuletzt benutzt 2023; 3.507 Dateien, ca. 6,9 GB.
- **Vorhanden:** Anleitungen und Service-PDFs, Explosionszeichnungen mit Positions-Hotspots, Maß- und Schaltbilder (DrawDim, DrawElc), Produktbilder (ProdPic), Ausschreibungstext-Regeln (HybrisQt), Sortimentslisten je Land, Austausch-Cache, Zubehörregeln, Konfigurator-Modelle (NK/NKG).
- **Fehlt:** `GPI.MDF` (Produktdatenbank) und `GPIUser.MDF`. Laut Programmprotokoll lagen sie unter `C:\Grundfos\2019.06.001.001\GPC\datafile\`.

---

## 4. Datenmodell für Supabase (Entwurf)

Grundsatz: **Jeder Wert weiß, woher er stammt und von wann.** So können später neuere Quellen (aktuelle DATANORM, Grundfos-Datenpaket) ältere Werte ersetzen, ohne dass etwas verloren geht.

```
quelle ─┐
        ▼
artikel ───< artikel_text           (Kurztext, Langtext, technischer Text; je Sprache)
   │    ───< artikel_preis          (Listenpreis, Preiseinheit, Rabattgruppe, gültig ab)
   │    ───< artikel_merkmal        (Leistung kW, Spannung, Anschluss … aus D-Sätzen / später ETIM)
   │    ───< artikel_medium ──> medium      (Bild, Anleitung, Zeichnung; Datei in Supabase Storage)
   │    ───< artikel_beziehung      (Ersatzteil, Zubehör, Nachfolger, Verpackungseinheit, Variante)
   │    ───< artikel_sortiment      (Land, Status laut ProductRange)
   └──> kategorie (899 Produktgruppen-Baum) · warengruppe · rabattgruppe
explosionszeichnung ───< zeichnung_position ──> artikel (Ersatzteil)
```

| Tabelle | Wichtige Felder |
|---|---|
| `quelle` | id, typ (DATANORM, GPC, Artikelliste, Grundfos-Paket), datei, datenstand, importiert_am |
| `artikel` | artikelnummer (PK, 8-stellig normalisiert), ean, hersteller, familie, serie, kategorie_id, status (aktiv/auslaufend/ersetzt), grundfos_url, quelle_id |
| `artikel_text` | artikelnummer, art (kurz1, kurz2, lang, technik), sprache, text, quelle_id |
| `langtext_baustein` | schluessel, zeile, text (T-/E-Sätze, einmal je Baureihe) |
| `artikel_preis` | artikelnummer, preisart (Listenpreis/EK), betrag, preiseinheit, mengeneinheit, rabattgruppe, waehrung, gueltig_ab, quelle_id |
| `artikel_merkmal` | artikelnummer, merkmal (z. B. leistung_kw), wert, einheit, quelle_id |
| `medium` | id, typ (bild, anleitung, service, massbild, schaltbild, explosionszeichnung), dokumentnummer, sprache, storage_pfad, quelle_id |
| `artikel_medium` | artikelnummer, medium_id, rolle (hauptbild, datenblatt …) |
| `artikel_beziehung` | von_artikel, zu_artikel, typ (ersatzteil, zubehoer, nachfolger, vpe, variante), position, produktionszeitraum, quelle_id, sicherheit |
| `artikel_sortiment` | artikelnummer, land, status, quelle_id |
| `kategorie`, `warengruppe`, `rabattgruppe` | Bäume und Bezeichnungen aus Produktgruppen-Master, .WRG, .RAB |

**Dateien** (PDFs, Bilder, Zeichnungen) kommen in Supabase Storage und werden über `medium` verknüpft. Nicht jede der 3 GB Anleitungen muss sofort hochgeladen werden; zuerst nur, was zu Artikeln im Shop gehört.

**Rechte:** DATANORM-Dateien tragen teils den Vermerk „Weitergabe der Daten nur mit schriftl. Genehmigung“. GPC-Inhalte gehören Grundfos. Für die interne Datenbank ist das unkritisch; vor der Veröffentlichung im Shop sollte die Freigabe im Gespräch mit Grundfos bzw. dem Großhändler geklärt werden.

---

## 5. Nächste Schritte

1. **`GPI.MDF` finden (entscheidend für die Verlinkungen):** Gibt es noch den PC bzw. die Sicherung mit `C:\Grundfos\…\GPC\datafile\GPI.MDF`? Die Datei ist vermutlich mehrere GB groß. Wenn ja: ins Drive kopieren, dann lese ich sie aus.
2. **Audit Teil 2** (kurzer zweiter Colab-Lauf):
   - Großhändler-DATANORM vom 05.09.2025 auf Grundfos-Artikel prüfen;
   - `QuickReplacement.cache` entpacken und auf Paare alt → neu prüfen;
   - `ProdPic.zip` auflisten (Benennung der Bilder);
   - Landescode `ggd` = Deutschland bestätigen.
3. **Supabase-Projekt anlegen** (nach deinem Okay) und das Schema als Migration einspielen.
4. **Import 1:** DATANORM 2016 (+ 2014 und „GF“ als Ergänzung) inklusive D-/E-Werte, Warengruppen, Rabattgruppen, Produktgruppenbaum und Artikelliste.
5. **Import 2:** GPC-Medien und Beziehungen, sobald die Zuordnungen geklärt sind.
