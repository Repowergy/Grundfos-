#!/usr/bin/env python3
"""
Grundfos-PIM – GPC-Software 2023: Sprachpakete (datafile/ctf/<SPRACHE>.zip) → pim.merkmal_uebersetzung

  <SPR>_DB_DL.CTF   Merkmalsnamen (kurz, max. 30 Zeichen)
  <SPR>_DB_DLD.CTF  Merkmalsbeschreibungen (max. 80 Zeichen)

Aufbau: Kopf bis zur ersten Zeile '#', danach Blöcke „Schlüssel / Text … / #“.
Die Texte sind in der Quelle doppelt kodiert (UTF-8-Bytes als cp850 gelesen, z. B. „ð▓ð©ðÂ“ = „виж“) –
sie werden hier repariert. Übernommen wird nur, was im Merkmalskatalog existiert; vorhandene Übersetzungen
bleiben unverändert. Im Datenordner 2023 liegt nur das bulgarische Paket (BGR).

  python3 -I tools/import/gpc2023_ctf.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql"))
import supa  # noqa: E402


def repariere(t):
    try:
        return t.encode("cp850").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return t


def bloecke(pfad):
    rows = supa.sql(f"select z.nr, z.text from gpc2023.zeile z join gpc2023.datei d on d.id = z.datei_id "
                    f"where d.pfad = '{pfad}' order by z.nr")
    zeilen = [r["text"] for r in rows]
    if "#" not in zeilen:
        return {}
    zeilen = zeilen[zeilen.index("#") + 1:]
    out, block = {}, []
    for z in zeilen + ["#"]:
        if z.strip() == "#":
            if len(block) >= 2 and block[0].strip():
                out[block[0].strip()] = repariere(" ".join(b.strip() for b in block[1:]).strip())
            block = []
        else:
            block.append(z)
    return out


def run():
    pakete = supa.sql("select distinct substring(pfad from 'ctf/([A-Z]{3})\\.zip!') sp from gpc2023.datei "
                      "where pfad ~ '^datafile/ctf/[A-Z]{3}\\.zip!/'")
    for p in pakete:
        sp = p["sp"]
        iso = supa.sql(f"select iso from pim.sprache where gpc_code = '{sp}'")[0]["iso"]
        namen = bloecke(f"datafile/ctf/{sp}.zip!/{sp}_DB_DL.CTF")
        beschr = bloecke(f"datafile/ctf/{sp}.zip!/{sp}_DB_DLD.CTF")
        daten = [{"c": c, "b": namen.get(c) or beschr.get(c), "e": beschr.get(c)} for c in set(namen) | set(beschr)]
        t = json.dumps(daten, ensure_ascii=False)
        assert "$j$" not in t
        res = supa.sql(f"""
          with x as (select e->>'c' c, e->>'b' b, e->>'e' e from jsonb_array_elements($j${t}$j$::jsonb) e),
          ins as (
            insert into pim.merkmal_uebersetzung (merkmal_code, sprache, bezeichnung, erklaerung, status, quelle_id)
            select x.c, '{iso}', x.b, nullif(x.e, x.b), 'quelle', q.id
              from x join pim.merkmal m on m.code = x.c
              cross join (select id from pim.quelle where typ = 'gpc2023' limit 1) q
             where coalesce(x.b, '') <> ''
            on conflict do nothing returning 1)
          select (select count(*) from x) gelesen, (select count(*) from ins) neu""")
        print(sp, iso, res)


if __name__ == "__main__":
    run()
