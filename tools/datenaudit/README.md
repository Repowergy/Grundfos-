# Datenaudit (Schritt 1)

Prüft, **was tatsächlich in den Rohdaten steckt**, bevor etwas nach Supabase importiert wird.
Das Skript liest nur und verändert keine Quelldateien.

| Quelle (Google Drive) | Was geprüft wird |
|---|---|
| `04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify` | jede DATANORM-Datei, auch in ZIPs: Hersteller, Datenstand, Version, Format, Satzarten (A/B/T/P/…), Kurz- und Langtexte, EAN, Preise, Duplikate |
| `02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC` | Dateitypen, ZIP-Inhalte (Bilder, Anleitungen), Datenbanken, Austausch-, Zubehör-, Sortiments- und Servicedateien |
| `02 Grundfos/GRUNDFOS/de_DE/checkpoints/product_list.jsonl` | Abgleich mit den 806.105 Artikelnummern |

## Ausführen

**Google Colab (empfohlen):**
1. In Google mit dem Konto anmelden, dem der Drive-Ordner gehört.
2. Öffnen: <https://colab.research.google.com/github/Repowergy/Grundfos-/blob/claude/grundfos-shop-analyse/tools/datenaudit/Datenaudit_Colab.ipynb>
3. Menü **Laufzeit → Alle ausführen** und den Drive-Zugriff bestätigen.

**Lokal mit Google Drive für Desktop:**
```bash
python datenaudit.py --root "G:/Meine Ablage"
```

## Ergebnis

Die Berichte landen in `02 Grundfos/00_Datenaudit/ergebnis/`:

| Datei | Inhalt |
|---|---|
| `00_zusammenfassung.md` | Überblick mit Kennzahlen |
| `01_datanorm_dateien.csv` | eine Zeile je Datei: Hersteller, Datum, Version, Satzarten, Artikel, EAN, Preis, Langtext |
| `02_datanorm_beispiele.txt` | Beispielzeilen je Satzart und zusammengesetzte Beispielartikel |
| `03_gpc_dateien.csv` | alle GPC-Dateien mit Typ und Kopf-Bytes |
| `04_gpc_details.md` | ZIP-Inhalte, Datenbanktabellen, Textköpfe, Strings aus Binärdateien |
| `05_abdeckung.json` | Abdeckung gegen die Artikelliste, auch je Produktfamilie |
| `06_datanorm_grundfos_stichprobe.csv` | bis zu 600 Grundfos-Artikel mit Kurztext, Langtext, EAN und Preis |
| `07_gpc_schluesseldateien.txt` | Hex-Dump und Strings der Austausch-, Zubehör- und Sortimentsdateien |

## Hinweise

- **Keine Rohdaten oder Zugangsdaten in dieses Repository legen.** Es ist öffentlich.
- `Datenaudit_Colab.ipynb` wird mit `python build_notebook.py` aus `datenaudit.py` erzeugt. Änderungen nur in `datenaudit.py` machen und danach neu erzeugen.
