#!/usr/bin/env python3
"""Fachwörterbuch laden: maschinelle Übersetzungen (JSON Lines) nach Grundfos-PIM schreiben.

Bestehende Einträge (Grundfos-Sprachpakete) werden nie überschrieben (on conflict do nothing).

  glossar_laden.py merkmal <datei>...              Zeilen {code, sprache, text}  → pim.merkmal_uebersetzung (status 'maschinell')
  glossar_laden.py <bereich> <feld> <datei>...     Zeilen {<feld>, sprache, text} → pim.uebersetzung (herkunft 'maschinell')
                                                   bereich "-" = Feld „bereich“ je Zeile (z. B. DB_DV<code> für Merkmalswerte)

Den Bedarf liefert pim.glossar_bedarf_sammeln() in pim._glossar_bedarf (Migration 0048).
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql"))
from supa import sql  # noqa: E402

PAKET = 300


def lesen(dateien):
    for p in dateien:
        with open(p, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    o = json.loads(line)
                    if o.get("text", "").strip():
                        yield o


def schreiben(rows, insert):
    gesamt = 0
    for i in range(0, len(rows), PAKET):
        chunk = json.dumps(rows[i:i + PAKET], ensure_ascii=False).replace("'", "''")
        gesamt += sql(f"""with d as (select * from jsonb_to_recordset('{chunk}'::jsonb) as x(b text, k text, s text, t text)),
                           ins as ({insert} returning 1) select count(*) n from ins""")[0]["n"]
    return gesamt


def main(args):
    if args[:1] == ["merkmal"]:
        rows = [{"b": None, "k": o["code"], "s": o["sprache"], "t": o["text"].strip()} for o in lesen(args[1:])]
        n = schreiben(rows, """insert into pim.merkmal_uebersetzung (merkmal_code, sprache, bezeichnung, status)
                               select d.k, d.s, d.t, 'maschinell' from d join pim.merkmal m on m.code = d.k
                               on conflict (merkmal_code, sprache) do nothing""")
    else:
        bereich, feld, dateien = args[0], args[1], args[2:]
        rows = [{"b": o["bereich"] if bereich == "-" else bereich, "k": o[feld], "s": o["sprache"], "t": o["text"].strip()}
                for o in lesen(dateien)]
        n = schreiben(rows, """insert into pim.uebersetzung (bereich, schluessel, sprache, text, herkunft)
                               select d.b, d.k, d.s, d.t, 'maschinell' from d
                               on conflict (bereich, sprache, schluessel) do nothing""")
    print(f"eingefügt {n} von {len(rows)}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(sys.argv[1:])
