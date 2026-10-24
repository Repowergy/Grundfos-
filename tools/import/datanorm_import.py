#!/usr/bin/env python3
"""
Grundfos-PIM – Import 1: DATANORM + Artikelliste + Kategoriebaum → Supabase

Ablauf je DATANORM-Datei:
  1. Prüfsumme bilden; bereits importierte Dateien werden übersprungen.
  2. Durchlauf 1: Grundfos-Artikel erkennen (Kurztext enthält GRUNDFOS oder Nummer
     steht in der Artikelliste). Dateien ohne Grundfos werden übersprungen;
     Dateien mit geringem Grundfos-Anteil (Großhandel) werden gefiltert importiert.
  3. Durchlauf 2: Zeilen unverändert nach raw.datanorm_satz, daraus pim.* aufbauen:
     Artikel, EAN, Kurz-/Lang-/Techniktext, Listenpreis, Waren- und Rabattgruppen.

Verbindung: Umgebungsvariable oder Colab-Secret SUPABASE_DB_URL (Session Pooler).
Quelldateien werden nur gelesen.
"""

import csv
import datetime as dt
import hashlib
import io
import json
import os
import re
import time

import psycopg

from datenaudit import GF_NUM, ean_ok, guess_encoding, log, looks_like_datanorm

CONFIG = {
    "DATANORM_DIRS": [
        "04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify",
        "GRUNDFOS – Zentrale Projektablage/DATANORM NEU 1",
        "05 Rohdaten Import",
    ],
    "ARTICLE_LIST": "02 Grundfos/GRUNDFOS/de_DE/checkpoints/product_list.jsonl",
    "PRODUCT_GROUPS": "02 Grundfos/Grundfos Daten X Shopify/GRUNDFOS_Product_Groups_de_DE_MASTER.csv",
    "VOLL_AB_ANTEIL": 0.5,   # ab diesem Grundfos-Anteil wird die Datei vollständig übernommen
}
HERSTELLER_ID = 1  # pim.hersteller 'Grundfos'
PREISEINHEIT = {"0": 1, "1": 10, "2": 100, "3": 1000}


# ───────────────────────────────────────────────────────────────────
# Verbindung & Hilfen
# ───────────────────────────────────────────────────────────────────
def db_url():
    url = os.environ.get("SUPABASE_DB_URL")
    if not url:
        try:
            from google.colab import userdata  # type: ignore
            url = userdata.get("SUPABASE_DB_URL")
        except Exception:  # noqa: BLE001
            url = None
    if not url:
        raise SystemExit("SUPABASE_DB_URL fehlt (Colab: Schlüssel-Symbol → Secret anlegen).")
    return url.strip()


def conn_params(url):
    """Verbindungszeile robust zerlegen – auch wenn das Passwort Sonderzeichen wie [ ] @ # / ? enthält."""
    m = re.match(r"^postgres(?:ql)?://([^:/@]+):(.*)@([^@/:]+):(\d+)/([^?]*)", url.strip())
    if not m:
        raise SystemExit("Verbindungszeile nicht erkannt. Erwartet: "
                         "postgresql://postgres.<projekt>:<passwort>@<host>.pooler.supabase.com:5432/postgres")
    user, pw, host, port, db = m.groups()
    if pw.startswith("[") and pw.endswith("]"):
        pw = pw[1:-1]          # eckige Klammern aus der Vorlage mitkopiert
    if pw == "YOUR-PASSWORD":
        raise SystemExit("Im Secret steht noch [YOUR-PASSWORD] – bitte durch das Datenbank-Passwort ersetzen.")
    if host.startswith("db."):
        raise SystemExit("Das ist die direkte Verbindung (db.…supabase.co), die Colab nicht erreicht. "
                         "Bitte Supabase → Connect → Direct → „Session pooler“ verwenden.")
    return {"host": host, "port": int(port), "user": user, "password": pw, "dbname": db or "postgres",
            "connect_timeout": 20, "sslmode": "disable" if host in ("localhost", "127.0.0.1") else "require"}


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def norm(nr):
    return (nr or "").strip().upper().replace(" ", "")


def parse_datum(s):
    s = (s or "").strip()
    for fmt in ("%d%m%y", "%d%m%Y", "%d.%m.%Y"):
        try:
            return dt.datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    return None


def v_info(v):
    """Datum und Infotext aus V-Satz (Fest- oder Semikolonformat)."""
    if not v:
        return None, ""
    if len(v) > 1 and v[1] == ";":
        f = [x.strip() for x in v.split(";")]
        datum = next((parse_datum(x) for x in f if re.fullmatch(r"\d{6}|\d{8}", x)), None)
        return datum, " | ".join(x for x in f[1:] if x and not re.fullmatch(r"\d{6}|\d{8}|0?4|EUR", x))
    return parse_datum(v[2:8]), re.sub(r"\s+", " ", v[8:123]).strip()


def read_lines(path):
    with open(path, "rb") as fh:
        head = fh.read(256 * 1024)
    enc = guess_encoding(head)
    with open(path, encoding=enc, errors="replace", newline="") as fh:
        for i, line in enumerate(fh, 1):
            line = line.rstrip("\r\n")
            if line:
                yield i, line


def text_triples(f, start):
    """T/E-Sätze: (Zeilennummer; ; Text) wiederholt ab Feld `start`."""
    out, j = [], start
    while j < len(f):
        tok = f[j].strip()
        if tok.isdigit() and j + 2 < len(f):
            out.append((int(tok), f[j + 2].strip()))
            j += 3
        else:
            j += 1
    return out


def copy_rows(cur, table, cols, rows):
    with cur.copy(f"COPY {table} ({', '.join(cols)}) FROM STDIN") as cp:
        for r in rows:
            cp.write_row(r)


# ───────────────────────────────────────────────────────────────────
# Artikelliste + Kategoriebaum
# ───────────────────────────────────────────────────────────────────
def register_file(cur, lauf_id, path, rel, fmt, lieferant, datenstand, kopf, sprache=None):
    sha = sha256_of(path)
    cur.execute("select id from raw.quelldatei where sha256 = %s", (sha,))
    if cur.fetchone():
        return None
    cur.execute(
        """insert into raw.quelldatei (lauf_id, pfad, sha256, groesse, format, lieferant, datenstand, sprache, kopfzeile)
           values (%s,%s,%s,%s,%s,%s,%s,%s,%s) returning id""",
        (lauf_id, rel, sha, os.path.getsize(path), fmt, lieferant, datenstand, sprache, kopf))
    return cur.fetchone()[0]


def new_quelle(cur, datei_id, typ, bez, datenstand, prio):
    cur.execute("""insert into pim.quelle (datei_id, typ, bezeichnung, datenstand, prioritaet)
                   values (%s,%s,%s,%s,%s) returning id""", (datei_id, typ, bez, datenstand, prio))
    return cur.fetchone()[0]


def import_groups(con, root, lauf_id):
    path = os.path.join(root, CONFIG["PRODUCT_GROUPS"])
    if not os.path.exists(path):
        log(f"⚠ Produktgruppen fehlen: {path}")
        return
    with con.cursor() as cur:
        datei_id = register_file(cur, lauf_id, path, CONFIG["PRODUCT_GROUPS"], "csv", "Grundfos Sitemap",
                                 dt.date(2026, 8, 3), "GRUNDFOS_Product_Groups_de_DE_MASTER")
        if datei_id is None:
            log("Produktgruppen: bereits importiert")
            return
        with open(path, encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.DictReader(fh))
        copy_rows(cur, "raw.tabellen_zeile", ["datei_id", "tabelle", "zeile", "daten"],
                  ((datei_id, "product_groups", i, json.dumps(r, ensure_ascii=False)) for i, r in enumerate(rows, 1)))
        qid = new_quelle(cur, datei_id, "artikelliste", "Grundfos Produktgruppen (Sitemap 08/2026)",
                         dt.date(2026, 8, 3), 30)
        copy_rows(cur, "pim.kategorie", ["code", "ebene", "pfad", "quelle_id"],
                  ((r["group_id"], r.get("hierarchy_level"), r.get("hierarchy_path"), qid) for r in rows))
        cur.execute("""update pim.kategorie k set parent_id = p.id
                       from raw.tabellen_zeile z, pim.kategorie p
                       where z.datei_id = %s and z.daten->>'group_id' = k.code
                         and p.code = z.daten->>'parent_group'""", (datei_id,))
    con.commit()
    log(f"Produktgruppen: {len(rows)} Kategorien")


def import_article_list(con, root, lauf_id):
    path = os.path.join(root, CONFIG["ARTICLE_LIST"])
    if not os.path.exists(path):
        log(f"⚠ Artikelliste fehlt: {path}")
        return
    with con.cursor() as cur:
        datei_id = register_file(cur, lauf_id, path, CONFIG["ARTICLE_LIST"], "jsonl", "Grundfos Sitemap",
                                 dt.date(2026, 8, 3), "product_list.jsonl")
        if datei_id is None:
            log("Artikelliste: bereits importiert")
            return
        qid = new_quelle(cur, datei_id, "artikelliste", "Grundfos Sitemap-Artikelliste 08/2026",
                         dt.date(2026, 8, 3), 30)
        # Platz sparen: die 806.000 JSON-Zeilen nicht zusätzlich als Rohdaten speichern –
        # die Quelldatei ist über Pfad + SHA-256 in raw.quelldatei eindeutig nachvollziehbar.
        cur.execute("""create temp table tmp_liste (artnr text, norm text,
                       familie text, serie text, url text, name text) on commit drop""")
        log("Artikelliste: hochladen …")
        with open(path, encoding="utf-8", errors="replace") as fh, \
                cur.copy("COPY tmp_liste FROM STDIN") as cp:
            for i, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                o = json.loads(line)
                nr = str(o.get("article_number") or "")
                cp.write_row((nr, norm(nr), o.get("family"), o.get("series"),
                              o.get("url"), o.get("product_name")))
        cur.execute("update raw.quelldatei set zeilen = (select count(*) from tmp_liste) where id = %s",
                    (datei_id,))
        cur.execute("""insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, familie, serie, hersteller_url)
                       select distinct on (norm) %s, artnr, norm, familie, serie, url from tmp_liste where norm <> ''
                       on conflict (hersteller_id, artikelnummer_norm) do update
                         set familie = coalesce(pim.artikel.familie, excluded.familie),
                             serie = coalesce(pim.artikel.serie, excluded.serie),
                             hersteller_url = coalesce(pim.artikel.hersteller_url, excluded.hersteller_url),
                             aktualisiert_am = now()""", (HERSTELLER_ID,))
        cur.execute("""insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
                       select distinct on (a.id) a.id, 'de', 'titel', t.name, %s
                       from tmp_liste t join pim.artikel a on a.hersteller_id = %s and a.artikelnummer_norm = t.norm
                       where coalesce(t.name, '') <> ''
                       on conflict do nothing""", (qid, HERSTELLER_ID))
        cur.execute("""update pim.artikel a set kategorie_id = k.id
                       from pim.kategorie k
                       where a.kategorie_id is null and k.code = a.familie || '/' || a.serie""")
        cur.execute("""update pim.artikel a set kategorie_id = k.id
                       from pim.kategorie k where a.kategorie_id is null and k.code = a.familie""")
    con.commit()
    log("Artikelliste: fertig")


# ───────────────────────────────────────────────────────────────────
# DATANORM
# ───────────────────────────────────────────────────────────────────
def scan_datanorm(path, known):
    """Durchlauf 1: Kopf, Grundfos-Artikel und benötigte Text-Schlüssel."""
    v, n_a, gf = "", 0, set()
    keys = set()
    for _i, line in read_lines(path):
        rt = line[0].upper()
        if rt == "V" and not v:
            v = line[:300]
        if len(line) < 2 or line[1] != ";":
            continue
        f = line.split(";")
        if rt == "A" and len(f) > 5:
            n_a += 1
            nr = norm(f[2])
            if "GRUNDFOS" in (f[4] + f[5]).upper() or nr in known:
                gf.add(nr)
                if len(f) > 12 and f[12].strip():
                    keys.add(f[12].strip())
        elif rt == "D" and len(f) > 5 and norm(f[2]) in gf:
            for j in range(3, len(f) - 3, 4):
                if f[j + 2].strip():
                    keys.add(f[j + 2].strip())
    return v, n_a, gf, keys


def import_datanorm_file(con, root, lauf_id, path, known):
    rel = os.path.relpath(path, root)
    v, n_a, gf, keys = scan_datanorm(path, known)
    datum, info = v_info(v)
    is_aux = os.path.splitext(path)[1].lower() in (".wrg", ".rab")
    hersteller_kopf = "GRUNDFOS" in v.upper()
    gf_code = bool(re.search(r"(^|[;\s])GF alle Preisangaben", v))   # Grundfos-Daten über Großhandel/Datendienst
    gf_kopf = hersteller_kopf or gf_code
    if not gf and not (is_aux and gf_kopf) and not (gf_kopf and n_a == 0):
        log(f"  überspringe (kein Grundfos): {rel}")
        return
    anteil = len(gf) / n_a if n_a else 1.0
    voll = anteil >= CONFIG["VOLL_AB_ANTEIL"] or gf_kopf
    with con.cursor() as cur:
        datei_id = register_file(cur, lauf_id, path, rel, "datanorm4", info[:200], datum, v[:300], "de")
        if datei_id is None:
            log(f"  bereits importiert: {rel}")
            return
        if not voll:
            cur.execute("update raw.quelldatei set kopfzeile = kopfzeile || %s where id = %s",
                        (f"  [gefiltert: nur {len(gf)} Grundfos-Artikel von {n_a}]", datei_id))
        typ = "hersteller_datanorm" if hersteller_kopf else "grosshandel_datanorm"
        prio = 80 if hersteller_kopf else (70 if gf_code else 60)
        qid = new_quelle(cur, datei_id, typ, info[:200] or rel, datum, prio)

        raw_rows, art, ean, texte, preise, bausteine = [], {}, {}, [], [], []
        d_vals = {}          # (artnr) -> list of (zeile, ekey, werte)
        wg, rg = [], []
        n = 0
        for i, line in read_lines(path):
            rt = line[0].upper()
            f = line.split(";") if len(line) > 1 and line[1] == ";" else [line]
            nr = norm(f[2]) if len(f) > 2 else ""
            keep = voll or rt in "VSR" or (rt in "ABDP" and nr in gf) or \
                (rt in "TE" and len(f) > 2 and f[2].strip() in keys)
            if not keep:
                continue
            raw_rows.append((datei_id, i, rt, f))
            n += 1
            if len(raw_rows) >= 20000:
                copy_rows(cur, "raw.datanorm_satz", ["datei_id", "zeile", "satzart", "felder"], raw_rows)
                raw_rows = []
            if len(f) < 3:
                continue
            if rt == "A" and nr in gf and len(f) > 9:
                art[nr] = f[2].strip()
                for a, idx in (("kurz1", 4), ("kurz2", 5)):
                    if f[idx].strip():
                        texte.append((nr, a, f[idx].strip()))
                preis = re.sub(r"\D", "", f[9])
                if preis and int(preis) > 0:
                    preise.append((nr, "listenpreis" if f[6].strip() in ("1", "") else "ek",
                                   int(preis) / 100, PREISEINHEIT.get(f[7].strip(), 1), f[8].strip() or None,
                                   f[10].strip() if len(f) > 10 else None, datum))
                if len(f) > 12 and f[12].strip():
                    texte.append((nr, "_langkey", f[12].strip()))
                if len(f) > 11 and f[11].strip():
                    texte.append((nr, "_hwg", f[11].strip()))
            elif rt == "B" and nr in gf:
                e = next((x.strip() for x in f[3:] if ean_ok(x.strip())), None)
                if e:
                    ean[nr] = e
            elif rt in "TE":
                for z, t in text_triples(f, 3):
                    bausteine.append((qid, f[2].strip(), "de", z if rt == "T" else 100000 + z, t))
            elif rt == "D" and nr in gf:
                for j in range(3, len(f) - 3, 4):
                    if f[j].strip().isdigit():
                        d_vals.setdefault(nr, []).append((int(f[j]), f[j + 2].strip(), f[j + 3]))
            elif rt == "S" and len(f) > 5:
                wg.append((f[2].strip() + (("/" + f[4].strip()) if f[4].strip() else ""), f[2].strip(), f[5].strip()))
            elif rt == "R" and len(f) > 5:
                rg.append((f[2].strip(), f[5].strip()))
        if raw_rows:
            copy_rows(cur, "raw.datanorm_satz", ["datei_id", "zeile", "satzart", "felder"], raw_rows)
        cur.execute("update raw.quelldatei set zeilen = %s where id = %s", (n, datei_id))

        # Artikel anlegen / EAN ergänzen
        cur.execute("create temp table tmp_a (nr text, norm text, ean text) on commit drop")
        copy_rows(cur, "tmp_a", ["nr", "norm", "ean"], ((v_, k, ean.get(k)) for k, v_ in art.items()))
        cur.execute("""insert into pim.artikel (hersteller_id, artikelnummer, artikelnummer_norm, ean)
                       select %s, nr, norm, ean from tmp_a
                       on conflict (hersteller_id, artikelnummer_norm) do update
                         set ean = coalesce(pim.artikel.ean, excluded.ean), aktualisiert_am = now()""",
                    (HERSTELLER_ID,))
        cur.execute("create temp table tmp_map on commit drop as select a.id, a.artikelnummer_norm as norm "
                    "from pim.artikel a join tmp_a t on t.norm = a.artikelnummer_norm where a.hersteller_id = %s",
                    (HERSTELLER_ID,))
        cur.execute("create index on tmp_map (norm)")

        # Textbausteine
        if bausteine:
            cur.execute("create temp table tmp_b (quelle_id bigint, schluessel text, sprache text, zeile int, text text) on commit drop")
            copy_rows(cur, "tmp_b", ["quelle_id", "schluessel", "sprache", "zeile", "text"], bausteine)
            cur.execute("""insert into pim.textbaustein select distinct on (quelle_id, schluessel, sprache, zeile) *
                           from tmp_b on conflict do nothing""")

        # Langtext (T-Bausteine) und Techniktext (E-Vorlagen + D-Werte) je Artikel
        bs = {}
        for _q, k, _s, z, t in bausteine:
            bs.setdefault(k, {})[z] = t
        lang_rows = []
        langkey = {nr: t for nr, a, t in texte if a == "_langkey"}
        for nr, key in langkey.items():
            lines = bs.get(key, {})
            txt = " ".join(t for z, t in sorted(lines.items()) if z < 100000 and t)
            if txt:
                lang_rows.append((nr, "lang", fix_hyphen(txt)))
        for nr, vals in d_vals.items():
            parts = []
            for z, ekey, werte in sorted(vals):
                vorlage = bs.get(ekey, {}).get(100000 + z, "")
                parts.append(fill_template(vorlage, werte))
            # E-Zeilen ohne D-Werte (feste Technikzeilen) ergänzen
            ekeys = {e for _z, e, _w in vals}
            used = {z for z, _e, _w in vals}
            for ekey in sorted(ekeys):
                for z, t in sorted(bs.get(ekey, {}).items()):
                    if z >= 100000 and (z - 100000) not in used and "$" not in t:
                        parts.append(t)
            txt = "\n".join(p for p in parts if p.strip())
            if txt:
                lang_rows.append((nr, "technik", txt))
        kurz = [(nr, a, t) for nr, a, t in texte if not a.startswith("_")]
        cur.execute("create temp table tmp_t (norm text, art text, text text) on commit drop")
        copy_rows(cur, "tmp_t", ["norm", "art", "text"], kurz + lang_rows)
        cur.execute("""insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
                       select distinct on (m.id, t.art) m.id, 'de', t.art, t.text, %s
                       from tmp_t t join tmp_map m using (norm) on conflict do nothing""", (qid,))

        # Preise
        cur.execute("""create temp table tmp_p (norm text, preisart text, betrag numeric, preiseinheit int,
                       mengeneinheit text, rabattgruppe text, gueltig_ab date) on commit drop""")
        copy_rows(cur, "tmp_p", ["norm", "preisart", "betrag", "preiseinheit", "mengeneinheit",
                                 "rabattgruppe", "gueltig_ab"], preise)
        cur.execute("""insert into pim.artikel_preis (artikel_id, markt, preisart, betrag, waehrung, preiseinheit,
                         mengeneinheit, rabattgruppe, gueltig_ab, quelle_id)
                       select m.id, 'DE', p.preisart, p.betrag, 'EUR', p.preiseinheit, p.mengeneinheit,
                              p.rabattgruppe, p.gueltig_ab, %s
                       from tmp_p p join tmp_map m using (norm)""", (qid,))

        # Waren- und Rabattgruppen (nur aus Grundfos-Dateien)
        if hersteller_kopf:
            for code, haupt, bez in wg:
                cur.execute("""insert into pim.warengruppe (hersteller_id, code, hauptgruppe, bezeichnung, quelle_id)
                               values (%s,%s,%s,%s,%s) on conflict (hersteller_id, code) do update
                               set bezeichnung = excluded.bezeichnung, quelle_id = excluded.quelle_id""",
                            (HERSTELLER_ID, code, haupt, bez, qid))
            for code, bez in rg:
                cur.execute("""insert into pim.rabattgruppe (hersteller_id, code, bezeichnung, quelle_id)
                               values (%s,%s,%s,%s) on conflict (hersteller_id, code) do update
                               set bezeichnung = excluded.bezeichnung, quelle_id = excluded.quelle_id""",
                            (HERSTELLER_ID, code, bez, qid))
    con.commit()
    log(f"  ✔ {rel}: {n} Zeilen roh, {len(art)} Grundfos-Artikel, {len(ean)} EAN, {len(preise)} Preise, "
        f"{len(lang_rows)} Lang-/Techniktexte ({'voll' if voll else f'gefiltert {anteil:.0%}'})")


def fix_hyphen(txt):
    """Silbentrennung über Zeilengrenzen zusammenziehen: 'Wellen- abdichtung' → 'Wellenabdichtung'."""
    return re.sub(r"(\w)- (?=[a-zäöüß])", r"\1", txt)


def fill_template(vorlage, werte):
    vals = [w for w in werte.split("$")]
    if vals and vals[-1] == "":
        vals.pop()
    if "$" not in vorlage:
        return (vorlage + " " + " ".join(vals)).strip()
    out, k = [], 0
    for ch in vorlage:
        if ch == "$":
            out.append(vals[k] if k < len(vals) else "")
            k += 1
        else:
            out.append(ch)
    return "".join(out)


def import_datanorm(con, root, lauf_id):
    with con.cursor() as cur:
        cur.execute("select artikelnummer_norm from pim.artikel where hersteller_id = %s", (HERSTELLER_ID,))
        known = {r[0] for r in cur.fetchall()}
    log(f"DATANORM: {len(known)} bekannte Grundfos-Nummern zum Abgleich")
    files = []
    for rel in CONFIG["DATANORM_DIRS"]:
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            log(f"  (Ordner fehlt, übersprungen: {rel})")
            continue
        for dp, _dn, fn in os.walk(base):
            for name in sorted(fn):
                p = os.path.join(dp, name)
                with open(p, "rb") as fh:
                    head = fh.read(4096)
                if looks_like_datanorm(name, head):
                    files.append(p)
    log(f"DATANORM: {len(files)} Dateien gefunden")
    for p in files:
        try:
            import_datanorm_file(con, root, lauf_id, p, known)
        except Exception as e:  # noqa: BLE001 – eine kaputte Datei soll den Lauf nicht stoppen
            con.rollback()
            log(f"  ⚠ Fehler bei {os.path.relpath(p, root)}: {e!r}")


def link_cross_file_langtexts(con):
    """Langtexte, deren T-Sätze in einer anderen Datei gleichen Datenstands liegen (z. B. .001 + .002)."""
    with con.cursor() as cur:
        cur.execute(r"""
            insert into pim.artikel_text (artikel_id, sprache, art, text, quelle_id)
            select a.id, 'de', 'lang',
                   regexp_replace(string_agg(tb.text, ' ' order by tb.zeile), '(\w)- ([a-zäöüß])', '\1\2', 'g'),
                   q.id
            from raw.datanorm_satz s
            join pim.quelle q on q.datei_id = s.datei_id
            join pim.artikel a on a.hersteller_id = %s
                              and a.artikelnummer_norm = upper(replace(trim(s.felder[3]), ' ', ''))
            join pim.quelle q2 on q2.datenstand = q.datenstand and q2.id <> q.id
            join pim.textbaustein tb on tb.quelle_id = q2.id and tb.schluessel = trim(s.felder[13])
                                    and tb.zeile < 100000
            where s.satzart = 'A' and coalesce(trim(s.felder[13]), '') <> ''
              and not exists (select 1 from pim.artikel_text x
                              where x.artikel_id = a.id and x.art = 'lang' and x.quelle_id = q.id)
            group by a.id, q.id
            on conflict do nothing""", (HERSTELLER_ID,))
        n = cur.rowcount
    con.commit()
    log(f"Langtexte aus Nachbardateien verknüpft: {n}")


def run(root="/content/drive/MyDrive", overrides=None):
    if overrides:
        CONFIG.update(overrides)
    t0 = time.time()
    with psycopg.connect(**conn_params(db_url()), autocommit=False) as con:
        with con.cursor() as cur:
            cur.execute("insert into raw.import_lauf (werkzeug, notiz) values (%s, %s) returning id",
                        ("datanorm_import v1", "DATANORM + Artikelliste + Produktgruppen"))
            lauf_id = cur.fetchone()[0]
        con.commit()
        import_groups(con, root, lauf_id)
        import_article_list(con, root, lauf_id)
        import_datanorm(con, root, lauf_id)
        link_cross_file_langtexts(con)
        with con.cursor() as cur:   # Großhändler-Nummern → Grundfos-Nummern, Fremdhersteller entfernen
            cur.execute("select to_regprocedure('pim.grosshandel_zuordnen()') is not null")
            if cur.fetchone()[0]:
                cur.execute("select * from pim.grosshandel_zuordnen()")
                for schritt, anzahl in cur.fetchall():
                    log(f"Zuordnung: {schritt}: {anzahl}")
        con.commit()
        with con.cursor() as cur:
            cur.execute("update raw.import_lauf set beendet_am = now() where id = %s", (lauf_id,))
            cur.execute("""select (select count(*) from pim.artikel),
                                  (select count(*) from pim.artikel where ean is not null),
                                  (select count(distinct artikel_id) from pim.artikel_preis),
                                  (select count(distinct artikel_id) from pim.artikel_text where art = 'lang'),
                                  (select count(distinct artikel_id) from pim.artikel_text where art = 'technik')""")
            a, e, p, l, t = cur.fetchone()
        con.commit()
    log(f"FERTIG in {(time.time() - t0) / 60:.1f} min · Artikel {a} · mit EAN {e} · mit Preis {p} · "
        f"mit Langtext {l} · mit Techniktext {t}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="/content/drive/MyDrive")
    run(ap.parse_args().root)
