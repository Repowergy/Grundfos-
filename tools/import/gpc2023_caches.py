#!/usr/bin/env python3
"""
Grundfos-PIM – GPC-Software 2023: die beiden JSON-Caches stückweise in gpc2023.vvs / gpc2023.schnellaustausch laden.

  VVSNo.cache            Produktliste (EAN, VVS-Nr., Typ, Kennlinie), DB-Stand 16.09.2019
  QuickReplacement.cache Pumpen für den Schnellaustausch (Grundfos + 34 Wettbewerber, Eckdaten je Pumpe)

Beide liegen entpackt als je EINE Textzeile (bis 75 MB) in gpc2023.zeile. Ein Zerlegen per jsonb in der Datenbank
hat den Server wegen Speichermangel neu starten lassen – deshalb: in 4-MB-Stücken holen, lokal zerlegen und in
Paketen von ca. 1,5 MB zurückschreiben. Läuft über die Management-API (tools/sql/supa.py).

  python3 -I tools/import/gpc2023_caches.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql"))
import supa  # noqa: E402

STUECK = 4_000_000
PAKET = 1_500_000


def lade_zeile(pfad):
    where = f"from gpc2023.zeile z join gpc2023.datei d on d.id = z.datei_id where d.pfad = '{pfad}' and z.nr = 2"
    laenge = supa.sql(f"select length(z.text) l {where}")[0]["l"]
    teile = [supa.sql(f"select substring(z.text from {s} for {STUECK}) t {where}")[0]["t"]
             for s in range(1, laenge + 1, STUECK)]
    text = "".join(teile)
    assert len(text) == laenge, (len(text), laenge)
    return json.loads(text)


def pakete(eintraege):
    paket, groesse = [], 0
    for e in eintraege:
        s = json.dumps(e, ensure_ascii=False)
        paket.append(s)
        groesse += len(s)
        if groesse > PAKET:
            yield "[" + ",".join(paket) + "]"
            paket, groesse = [], 0
    if paket:
        yield "[" + ",".join(paket) + "]"


def schreibe(insert, eintraege):
    for p in pakete(eintraege):
        assert "$j$" not in p
        supa.sql(insert.replace("{json}", f"$j${p}$j$"))


def run():
    vvs = lade_zeile("datafile/VVSNo.cache!/entpackt")
    supa.sql("truncate gpc2023.vvs")
    schreibe("insert into gpc2023.vvs (nr, daten) select (e->>'nr')::int, e->'d' "
             "from jsonb_array_elements({json}::jsonb) e",
             ({"nr": i + 1, "d": x} for i, x in enumerate(vvs)))

    qr = lade_zeile("datafile/QuickReplacement.cache!/entpackt")
    supa.sql("truncate gpc2023.schnellaustausch")
    schreibe("insert into gpc2023.schnellaustausch (cache_id, daten) select (e->>'CacheId')::int, e "
             "from jsonb_array_elements({json}::jsonb) e", qr.values())

    print(supa.sql("select (select count(*) from gpc2023.vvs) vvs, (select count(*) from gpc2023.schnellaustausch) qr"))


if __name__ == "__main__":
    run()
