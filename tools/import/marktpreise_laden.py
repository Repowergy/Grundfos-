#!/usr/bin/env python3
"""
Marktpreis-Recherche (JSON je Land) → pim.wettbewerber / pim.marktpreis

  python3 tools/import/marktpreise_laden.py <ordner mit DE.json AT.json CH.json EUROPA.json>

Warenkorb: produkt_nr 1–16 → Grundfos-Artikelnummer (Recherche 27.10.2026). Preise stammen aus Suchergebnissen
und Preisportalen (Quelle wird mitgeschrieben); ein erneuter Lauf mit demselben Datum ersetzt die Preise dieses Tages.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sql"))
import supa  # noqa: E402

WARENKORB = {1: "97914903", 2: "99411175", 3: "99371956", 4: "97924623", 5: "97924858", 6: "96281486",
             7: "98562862", 8: "97775315", 9: "97775317", 10: "97936156", 11: "96280966", 12: "97896335",
             13: "99458767", 14: "96524440", 15: "97722210", 16: "98390045"}


def ja_nein(v):
    if isinstance(v, bool):
        return v
    s = str(v or "").lower()
    return True if s.startswith(("ja", "yes", "true")) else False if s.startswith(("nein", "no", "false")) else None


def lade(ordner):
    shops, preise = [], []
    for land in ("DE", "AT", "CH", "EUROPA"):
        p = os.path.join(ordner, f"{land}.json")
        if not os.path.exists(p):
            continue
        d = json.load(open(p, encoding="utf-8"))
        for s in d.get("shops", []):
            shops.append({"name": s.get("name"), "url": s.get("url"), "land": s.get("land") or land,
                          "art": s.get("typ"), "schwerpunkt": s.get("fokus"),
                          "ersatzteile": ja_nein(s.get("grundfos_ersatzteile")),
                          "notiz": s.get("notiz") or s.get("ersatzteile_hinweis"), "gefunden_ueber": s.get("gefunden_ueber")})
        for r in d.get("preise", []):
            chf = r.get("preis_brutto_chf")
            eur = r.get("preis_brutto_eur")
            if chf is None and eur is None:
                continue
            preise.append({"artikelnummer": WARENKORB.get(int(r["produkt_nr"])), "typbezeichnung": r.get("typ"),
                           "artikelnummer_im_shop": r.get("artikelnummer_im_shop"), "ean_passt": ja_nein(r.get("ean_passt")),
                           "shop": r.get("shop"), "land": land, "url": r.get("url"),
                           "preis_brutto": chf if chf is not None else eur, "waehrung": "CHF" if chf is not None else "EUR",
                           "preis_eur": eur, "versand": r.get("versand_chf") if chf is not None else r.get("versand_eur"),
                           "verfuegbarkeit": r.get("verfuegbarkeit"),
                           "quelle": "Suchergebnis/Portal (unverifiziert): " + str(r.get("quelle") or ""),
                           "datum": r.get("datum") or "2026-10-27"})
    shops = [s for s in shops if s["name"]]
    j_s = json.dumps(shops, ensure_ascii=False).replace("'", "''")
    supa.sql(f"""insert into pim.wettbewerber (name, url, land, art, schwerpunkt, ersatzteile, notiz, gefunden_ueber)
                 select distinct on (name, land) name, url, land, art, schwerpunkt, ersatzteile, notiz, gefunden_ueber
                   from jsonb_to_recordset('{j_s}'::jsonb) as x(name text, url text, land text, art text, schwerpunkt text,
                        ersatzteile boolean, notiz text, gefunden_ueber text)
                 on conflict (name, land) do update set url = coalesce(excluded.url, pim.wettbewerber.url),
                        art = excluded.art, schwerpunkt = excluded.schwerpunkt, ersatzteile = excluded.ersatzteile,
                        notiz = excluded.notiz""")
    j_p = json.dumps(preise, ensure_ascii=False).replace("'", "''")
    supa.sql(f"""with x as (select * from jsonb_to_recordset('{j_p}'::jsonb) as x(artikelnummer text, typbezeichnung text,
                        artikelnummer_im_shop text, ean_passt boolean, shop text, land text, url text, preis_brutto numeric,
                        waehrung text, preis_eur numeric, versand numeric, verfuegbarkeit text, quelle text, datum date)),
                 d as (delete from pim.marktpreis m using (select distinct land, datum from x) k
                        where m.land = k.land and m.datum = k.datum and m.quelle like 'Suchergebnis/Portal%')
                 insert into pim.marktpreis (artikel_id, typbezeichnung, artikelnummer_im_shop, ean_passt, wettbewerber_id, shop,
                        land, url, preis_brutto, waehrung, preis_eur, versand, verfuegbarkeit, quelle, datum)
                 select a.id, x.typbezeichnung, x.artikelnummer_im_shop, x.ean_passt,
                        (select w.id from pim.wettbewerber w where lower(w.name) = lower(x.shop) order by (w.land = x.land) desc limit 1),
                        x.shop, x.land, x.url, x.preis_brutto, x.waehrung, x.preis_eur, x.versand, x.verfuegbarkeit, x.quelle, x.datum
                   from x left join pim.artikel a on a.hersteller_id = 1 and a.artikelnummer_norm = x.artikelnummer""")
    print(f"{len(shops)} Shops, {len(preise)} Preise geladen")


if __name__ == "__main__":
    lade(sys.argv[1])
