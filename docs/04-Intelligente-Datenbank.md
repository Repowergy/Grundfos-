# Grundfos-PIM – die „intelligente“ Datenbank

Stand: 25.10.2026 · Supabase-Projekt `Grundfos-PIM` · Migrationen `supabase/migrations/2026102500000*`

Grundsätze:
1. **Nichts wegwerfen.** Jede Quelle liegt 1:1 als Rohdaten vor (`raw`, `gpi`, `etb`, `gpc2023`).
2. **Daten statt Texte.** Fakten werden sprachneutral gespeichert (Zahl + Einheit). Texte entstehen je Sprache daraus.
3. **Herkunft je Wert.** Jeder Wert kennt Quelle, Datenstand und Priorität. Der Shop nimmt automatisch den besten Wert.

---

## 1. Bausteine

| Baustein | Tabellen / Funktionen | Was es kann |
|---|---|---|
| **Artikelstamm** | `pim.artikel`, `artikel_alias`, `artikel_text` | Aktuelle und historische Grundfos-Artikel, EAN, Typbezeichnungen, Texte je Sprache |
| **Merkmal-Modul** | `pim.merkmal` (Katalog), `merkmal_uebersetzung`, `merkmal_alias`, `artikel_merkmal` | Gemeinsamer Merkmalskatalog für **alle** Quellen, Werte als Text **und** als Zahl in einheitlicher Einheit (°C, m, m³/h, kW …) → Filter, Vergleiche |
| **Selbstlernende Merkmalsnamen** | `pim.merkmale_lernen()`, `technik_zeile` | Lernt deutsche Merkmalsnamen aus den DATANORM-Techniktexten, indem es Werte am selben Artikel vergleicht, z. B. „Leistungsaufnahme P1: 300 W“ ↔ `P1W = 300` |
| **Ersatzteile** | `pim.artikel_beziehung` (typ `ersatzteil`) | Pumpe → Teil mit Positionsnummer, Menge und **Produktionszeitraum** (Baujahr) |
| **Nachfolger** | `artikel_beziehung` (typ `nachfolger`) | Grundfos alt → neu (z. B. UPS → ALPHA2) |
| **Austausch Wettbewerb** | `pim.querverweis_wettbewerb`, `pim.fremdprodukt`, `v_fremdprodukt_merkmal` | Grundfos-Austauschlisten für Fremdpumpen (28 Hersteller) **plus** Wettbewerberpumpen mit technischen Daten im selben Merkmalskatalog |
| **Technischer Austauschfinder** | `pim.technischer_austausch(fremdprodukt_id)` | Eigene Vorschläge über Eckdaten (Baulänge, Anschluss, Phase, Förderhöhe, Förderstrom), auch wenn Grundfos keinen Austausch hinterlegt hat |
| **Medien** | `pim.medium`, `artikel_medium`, `gruppe_medium` | Bilder, Maßzeichnungen, Schaltbilder, Explosionszeichnungen, Anleitungen und Datenblätter in über 40 Sprachen |
| **Produktgruppen** | `pim.produktgruppe`, `artikel_gruppe` | GPC-Baum (z. B. ALPHA → ALPHA2). Dokumente hängen an der Gruppe statt millionenfach an Artikeln. |
| **Märkte** | `pim.markt`, `artikel_markt`, `artikel_preis` | Sortiment und Listenpreis je Land (DE = `gws`, AT = `gpo`, CH = `gps` …) |
| **Intelligente Suche** | `pim.suche(eingabe)` | Ein Suchfeld für Artikelnummer, EAN, Typbezeichnung (fehlertolerant), deutschen Volltext **und Fremdpumpen-Typ → Grundfos-Ersatz** |
| **Golden Record** | `pim.v_artikel_de` | Je Artikel der beste Text und Preis (Quelle mit der höchsten Priorität, dann der neueste Stand) |
| **Qualitäts-Score** | `pim.artikel_qualitaet` (materialisiert) | 0–100 Punkte je Artikel (Preis, EAN, Texte, Merkmale, Bild, Zeichnung, Dokument, Beziehungen). Das ist die Arbeitsliste für die Datenpflege und der Filter für den Shop-Export. |

## 2. Beispiele

```sql
-- Ein Suchfeld für alles
select * from pim.suche('wilo Stratos PICO 25/1-6');   -- → ALPHA2 25-60 180 (Ersatz)
select * from pim.suche('alpha2 25-60 180');           -- → alle Varianten
select * from pim.suche('5710620964099');              -- → EAN

-- Ersatzteile einer Pumpe mit Position und Baujahr
select z.artikelnummer, t.text, b.position, b.menge, b.produktion_von, b.produktion_bis
  from pim.artikel_beziehung b
  join pim.artikel v on v.id = b.von_artikel_id
  join pim.artikel z on z.id = b.zu_artikel_id
  left join pim.artikel_text t on t.artikel_id = z.id and t.art = 'titel'
 where v.artikelnummer = '011H1300' and b.typ = 'ersatzteil';

-- Filter: Umwälzpumpen mit 180 mm Baulänge und max. 6 m Förderhöhe
select a.artikelnummer from pim.artikel a
  join pim.artikel_merkmal l on l.artikel_id = a.id and l.merkmal_code = 'PORTPORT' and l.wert_num = 180
  join pim.artikel_merkmal h on h.artikel_id = a.id and h.merkmal_code = 'HEADMAXDM' and h.wert_num <= 6;

-- Technischer Austausch zu einer Wettbewerberpumpe
select * from pim.technischer_austausch((select id from pim.fremdprodukt where typ ilike 'Stratos PICO 25/1-6%' limit 1));
```

## 3. Hintergrund-Jobs

Große Schritte laufen als `pg_cron`-Jobs direkt in der Datenbank. Sie arbeiten in Paketen, ohne Zeitlimit, und können fortgesetzt werden. Den Fortschritt zeigen `pim.job_fortschritt` und `pim.job_protokoll`.

- `gpi_merkmale`: technische Werte aus der GPC-Datenbank (rund 27 Mio.)
- `nachlauf`: deutsche Merkmalsnamen lernen, Bild/Maßbild/Schaltbild über Merkmale zuordnen, Qualitäts-Score berechnen

## 4. Nächste Ausbaustufen

1. **Texte in 27 Sprachen** aus `HybrisQt` (GPC 2023): Textbausteine je Baureihe und Merkmal und das Regelwerk dazu, welcher Text für welche Pumpe gilt. Nach dem Import 3 wertet die Datenbank die Regeln je Artikel aus.
2. **Merkmalsnamen in allen Sprachen** aus den Sprachpaketen `ctf`.
3. **Sortimente 2023** (`Control/ProductRange`) als neuerer Marktstand. Austausch 2023 (`QuickReplacement.cache`).
4. **Semantische Suche** mit `pgvector`: Anfragen wie „Pumpe für 30 m tiefen Brunnen, 230 V“ in jeder Sprache.
5. **ETIM-Klassen** über `merkmal_alias` (Typ `etim`) für Großhandel und BMEcat-Export.
6. **Stammdaten 2015 (ARGE)**: Nachfolgeartikel, Bildzuordnungen, Abmessungen.
