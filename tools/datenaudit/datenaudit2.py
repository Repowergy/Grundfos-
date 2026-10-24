#!/usr/bin/env python3
"""
Grundfos Datenaudit – Teil 2 (nur lesen, nichts verändern)

  1. DATANORM: echter Grundfos-Anteil je Datei (inkl. Großhändler-Dateien 2025)
  2. GPC-Caches (QuickReplacement, VVSNo): gzip-JSON entpacken, Struktur zeigen
  3. ZIP-Listen: ProdPic, Qtp, CTF-Sprachtabellen
  4. ProductRange je Land: Zeilen, Spaltenwerte, Abgleich Artikelliste
  5. Austausch-Filterregeln und Wettbewerbs-Umwälzpumpen
  6. Datenbankdateien (*.mdb/*.accdb mit mdbtools, *.mdf/*.ldf nur Inventar)

Benötigt datenaudit.py im selben Ordner (Hilfsfunktionen).
"""

import collections
import csv
import gzip
import json
import os
import re
import shutil
import subprocess
import time
import zipfile

from datenaudit import (GF_NUM, ean_ok, guess_encoding, human, load_article_list, log,
                        looks_like_datanorm, magic_type)

DEFAULT_CONFIG = {
    "DATANORM_DIRS": [
        "04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify",
        "GRUNDFOS – Zentrale Projektablage/DATANORM NEU 1",
        "05 Rohdaten Import",
    ],
    "GPC_DIR": "02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC",
    "DB_DIRS": ["05 Rohdaten Import", "02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY"],
    "ARTICLE_LIST": "02 Grundfos/GRUNDFOS/de_DE/checkpoints/product_list.jsonl",
    "OUTPUT_DIR": "02 Grundfos/00_Datenaudit/ergebnis_teil2",
}
GF_EAN_PREFIX = ("57003", "57083", "57086", "57103", "5700", "5708", "5710")


def first_existing(root, rel_list):
    return [os.path.join(root, r) for r in rel_list if os.path.isdir(os.path.join(root, r))]


# ───────────────────────────────────────────────────────────────────
# 1) DATANORM: Grundfos-Anteil
# ───────────────────────────────────────────────────────────────────
def datanorm_grundfos_share(root, cfg, out, arts):
    rows, samples = [], {}
    seen_md5 = {}
    for base in first_existing(root, cfg["DATANORM_DIRS"]):
        for dp, _dn, fn in os.walk(base):
            for name in sorted(fn):
                path = os.path.join(dp, name)
                try:
                    with open(path, "rb") as fh:
                        head = fh.read(4096)
                except OSError:
                    continue
                if not looks_like_datanorm(name, head):
                    continue
                rel = os.path.relpath(path, root)
                import hashlib
                md5 = hashlib.md5()
                enc = guess_encoding(head)
                stats = collections.Counter()
                v_record = ""
                gf_lines = []
                gf_eans = set()
                with open(path, "rb") as fh:
                    pending = b""
                    while True:
                        buf = fh.read(4 * 1024 * 1024)
                        if not buf:
                            break
                        md5.update(buf)
                        parts = (pending + buf).split(b"\n")
                        pending = parts.pop()
                        for raw in parts:
                            line = raw.decode(enc, "replace").rstrip("\r")
                            if not line:
                                continue
                            rt = line[0].upper()
                            stats["zeilen"] += 1
                            if rt == "V" and not v_record:
                                v_record = line[:200]
                            if len(line) < 2 or line[1] != ";":
                                continue
                            f = line.split(";")
                            if rt == "A" and len(f) > 5:
                                stats["A"] += 1
                                art = f[2].strip().upper().replace(" ", "")
                                txt = (f[4] + " " + f[5]).upper()
                                is_gf_txt = "GRUNDFOS" in txt
                                in_list = art in arts
                                if is_gf_txt:
                                    stats["A_text_grundfos"] += 1
                                if in_list:
                                    stats["A_in_artikelliste"] += 1
                                if is_gf_txt or in_list:
                                    stats["A_grundfos"] += 1
                                    if len(gf_lines) < 8:
                                        gf_lines.append(line[:250])
                            elif rt == "B" and len(f) > 3:
                                for tok in f[3:]:
                                    tok = tok.strip()
                                    if ean_ok(tok):
                                        stats["B_ean"] += 1
                                        if tok.startswith(GF_EAN_PREFIX[:4]):
                                            stats["B_ean_grundfos_praefix"] += 1
                                            gf_eans.add(f[2].strip().upper())
                                        break
                            elif rt in "TDE":
                                stats[rt] += 1
                h = md5.hexdigest()
                dup = seen_md5.get(h, "")
                seen_md5.setdefault(h, rel)
                rows.append({"datei": rel, "groesse": os.path.getsize(path), "duplikat_von": dup,
                             "V_satz": v_record, **stats})
                if gf_lines and not dup:
                    samples[rel] = gf_lines
    cols = ["datei", "groesse", "duplikat_von", "V_satz", "zeilen", "A", "A_grundfos",
            "A_text_grundfos", "A_in_artikelliste", "B_ean", "B_ean_grundfos_praefix", "T", "D", "E"]
    with open(os.path.join(out, "10_datanorm_grundfos_anteil.csv"), "w", newline="",
              encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, delimiter=";", extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=lambda r: -r.get("A_grundfos", 0)):
            w.writerow(r)
    with open(os.path.join(out, "11_datanorm_grundfos_beispiele.txt"), "w", encoding="utf-8") as fh:
        for rel, lines in samples.items():
            fh.write(f"=== {rel}\n" + "\n".join(lines) + "\n\n")
    log(f"DATANORM: {len(rows)} Dateien, davon mit Grundfos-Artikeln: "
        f"{sum(1 for r in rows if r.get('A_grundfos'))}")
    return rows


# ───────────────────────────────────────────────────────────────────
# 2) GPC-Caches (gzip-JSON)
# ───────────────────────────────────────────────────────────────────
def describe_json(obj, depth=0, maxdepth=4):
    pad = "  " * depth
    if depth > maxdepth:
        return [pad + "…"]
    out = []
    if isinstance(obj, dict):
        out.append(f"{pad}dict mit {len(obj)} Schlüsseln: {list(obj)[:15]}")
        for k in list(obj)[:3]:
            out.append(f"{pad}[{k!r}]")
            out += describe_json(obj[k], depth + 1, maxdepth)
    elif isinstance(obj, list):
        out.append(f"{pad}Liste mit {len(obj)} Einträgen")
        for item in obj[:2]:
            out += describe_json(item, depth + 1, maxdepth)
    else:
        out.append(f"{pad}{type(obj).__name__}: {str(obj)[:120]}")
    return out


def walk_labels(obj, counter, pairs):
    if isinstance(obj, dict):
        lab = obj.get("Label") or obj.get("label")
        if isinstance(lab, str):
            counter[lab] += 1
            val = obj.get("Value") or obj.get("value") or obj.get("Values")
            if re.search(r"REPL|SUCC|REPLAC|NEW|OLD|ALTERN", lab, re.I) and len(pairs) < 60:
                pairs.append(f"{lab} = {str(val)[:160]}")
        for v in obj.values():
            walk_labels(v, counter, pairs)
    elif isinstance(obj, list):
        for v in obj:
            walk_labels(v, counter, pairs)


def gpc_caches(gpc, out):
    lines = []
    for dp, _dn, fn in os.walk(gpc):
        for name in fn:
            if not name.lower().endswith(".cache"):
                continue
            path = os.path.join(dp, name)
            lines.append(f"# {os.path.relpath(path, gpc)} ({human(os.path.getsize(path))})")
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
                data = gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw
                lines.append(f"- entpackt: {human(len(data))}")
                text = data.decode("utf-8-sig", "replace")
                try:
                    obj = json.loads(text)
                except json.JSONDecodeError:
                    # manche Caches: Kopf-JSON + Daten-JSON hintereinander
                    dec = json.JSONDecoder()
                    objs, i = [], 0
                    while i < len(text) and len(objs) < 5:
                        while i < len(text) and text[i] in " \r\n\t,":
                            i += 1
                        if i >= len(text):
                            break
                        o, i = dec.raw_decode(text, i)
                        objs.append(o)
                    obj = objs
                lines += describe_json(obj)
                labels, pairs = collections.Counter(), []
                walk_labels(obj, labels, pairs)
                lines.append(f"- verschiedene Labels: {len(labels)}")
                lines.append("- häufigste Labels: " + ", ".join(f"{k}({v})" for k, v in labels.most_common(60)))
                if pairs:
                    lines.append("- Labels mit REPL/SUCC/OLD/NEW:")
                    lines += ["  - " + p for p in pairs]
                lines.append("- Anfang (2.000 Zeichen):\n```\n" + text[:2000] + "\n```")
            except Exception as e:  # noqa: BLE001
                lines.append(f"- Fehler: {e!r}")
            lines.append("")
    with open(os.path.join(out, "12_gpc_caches.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    log("GPC-Caches ausgewertet")


# ───────────────────────────────────────────────────────────────────
# 3) ZIP-Listen
# ───────────────────────────────────────────────────────────────────
def zip_lists(gpc, out, arts):
    lines = []
    targets = []
    for dp, _dn, fn in os.walk(gpc):
        for name in fn:
            low = name.lower()
            if low.endswith(".zip") and (low in ("prodpic.zip", "qtp.zip") or "ctf" in dp.lower()):
                targets.append(os.path.join(dp, name))
    for path in sorted(targets):
        rel = os.path.relpath(path, gpc)
        try:
            with zipfile.ZipFile(path) as zf:
                infos = [i for i in zf.infolist() if not i.is_dir()]
                exts = collections.Counter(os.path.splitext(i.filename)[1].lower() for i in infos)
                nums = collections.Counter()
                stems = collections.Counter()
                for i in infos:
                    base = os.path.basename(i.filename)
                    nums.update(GF_NUM.findall(base.upper()))
                    stems[re.sub(r"\d", "9", os.path.splitext(base)[0])[:20]] += 1
                lines.append(f"## {rel}")
                lines.append(f"- Einträge: {len(infos)}, entpackt: {human(sum(i.file_size for i in infos))}")
                lines.append(f"- Endungen: {dict(exts.most_common(10))}")
                lines.append(f"- Namensmuster (Ziffern→9): {dict(stems.most_common(12))}")
                lines.append(f"- Grundfos-Nummern in Namen: {len(nums)} verschieden, "
                             f"davon in Artikelliste: {len(set(nums) & arts)}")
                lines.append("- Beispiele: " + ", ".join(f"`{i.filename}`" for i in infos[:40]))
                if "ctf" in rel.lower() and rel.lower().endswith(("deu.zip", "enu.zip")):
                    for i in infos[:6]:
                        with zf.open(i) as zfh:
                            raw = zfh.read(3000)
                        enc = guess_encoding(raw)
                        lines.append(f"- Kopf `{i.filename}` ({enc}):\n```\n"
                                     + "\n".join(raw.decode(enc, "replace").splitlines()[:8]) + "\n```")
                lines.append("")
        except Exception as e:  # noqa: BLE001
            lines.append(f"## {rel}\n- Fehler: {e!r}\n")
    with open(os.path.join(out, "13_gpc_zip_listen.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    log(f"ZIP-Listen: {len(targets)} Archive")


# ───────────────────────────────────────────────────────────────────
# 4) ProductRange je Land + 5) Filterregeln
# ───────────────────────────────────────────────────────────────────
def product_ranges(gpc, out, arts):
    rows = []
    extra = []
    for dp, _dn, fn in os.walk(gpc):
        for name in sorted(fn):
            path = os.path.join(dp, name)
            low = name.lower()
            if "productrange" in dp.lower() and low.endswith(".txt"):
                nums, col4, col2 = set(), collections.Counter(), 0
                with open(path, encoding="latin-1", errors="replace") as fh:
                    n = 0
                    for line in fh:
                        f = line.rstrip("\r\n").split(";")
                        if not f or not f[0]:
                            continue
                        n += 1
                        nums.add(f[0].strip().upper())
                        if len(f) > 3:
                            col4[f[3]] += 1
                        if len(f) > 1 and f[1].strip():
                            col2 += 1
                rows.append({"datei": name, "zeilen": n, "nummern": len(nums),
                             "in_artikelliste": len(nums & arts), "spalte2_gefuellt": col2,
                             "spalte4_werte": dict(col4.most_common(6))})
            elif ("replacement" in dp.lower() or low in ("customerprofile.xml", "hybrisexport.xml",
                                                          "circ_p1avg_update.csv", "productrange.ini",
                                                          "acclink2.csv")):
                try:
                    with open(path, "rb") as fh:
                        raw = fh.read(6000)
                    enc = guess_encoding(raw)
                    extra.append(f"## {os.path.relpath(path, gpc)} ({human(os.path.getsize(path))})\n```\n"
                                 + "\n".join(raw.decode(enc, "replace").splitlines()[:40]) + "\n```\n")
                except OSError:
                    pass
    with open(os.path.join(out, "14_gpc_productrange.csv"), "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["datei", "zeilen", "nummern", "in_artikelliste",
                                           "spalte2_gefuellt", "spalte4_werte"], delimiter=";")
        w.writeheader()
        for r in sorted(rows, key=lambda r: -r["zeilen"]):
            w.writerow(r)
    with open(os.path.join(out, "15_gpc_regeln_und_profile.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(extra))
    log(f"ProductRange: {len(rows)} Dateien; Regeln/Profile: {len(extra)} Dateien")


# ───────────────────────────────────────────────────────────────────
# 6) Datenbankdateien
# ───────────────────────────────────────────────────────────────────
def have_mdbtools():
    if shutil.which("mdb-tables"):
        return True
    try:
        subprocess.run(["apt-get", "install", "-y", "-qq", "mdbtools"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    except Exception:  # noqa: BLE001
        return False
    return bool(shutil.which("mdb-tables"))


def _head_lines(cmd, n=4, timeout=600):
    """Nur die ersten n Zeilen einer (evtl. riesigen) Ausgabe lesen."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            encoding="utf-8", errors="replace")
    lines = []
    try:
        for line in proc.stdout:
            lines.append(line.rstrip("\n"))
            if len(lines) >= n:
                break
    finally:
        proc.kill()
    return lines


def databases(root, cfg, out, name="16_datenbanken.md", cache_dir=None):
    lines = ["# Datenbankdateien", ""]
    found = []
    for base in first_existing(root, cfg["DB_DIRS"]):
        for dp, _dn, fn in os.walk(base):
            for fname in fn:
                if fname.lower().endswith((".mdb", ".accdb", ".mdf", ".ldf", ".bak", ".sdf")):
                    found.append(os.path.join(dp, fname))
    if not found:
        lines.append("Keine *.mdb/*.accdb/*.mdf gefunden in: " + ", ".join(cfg["DB_DIRS"]))
    mdb_ok = None
    seen = {}
    import hashlib
    for path in sorted(found, key=lambda p: (len(p), p)):
        rel = os.path.relpath(path, root)
        size = os.path.getsize(path)
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            head = fh.read(64)
            fh.seek(0)
            for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
                h.update(chunk)
        digest = h.hexdigest()
        lines.append(f"## {rel} ({human(size)})")
        if digest in seen:
            lines.append(f"- Duplikat von `{seen[digest]}` – übersprungen\n")
            continue
        seen[digest] = rel
        lines.append(f"- SHA-256: `{digest[:16]}…` · Kopf: `{head[:20].hex(' ')}`")
        if path.lower().endswith((".mdb", ".accdb")):
            if cache_dir:  # lokale Kopie: mdbtools liest wahlfrei, über Drive sehr langsam
                import shutil
                os.makedirs(cache_dir, exist_ok=True)
                local = os.path.join(cache_dir, digest[:12] + "_" + os.path.basename(path))
                if not os.path.exists(local):
                    log(f"kopiere {rel} …")
                    shutil.copyfile(path, local)
                path = local
            if mdb_ok is None:
                mdb_ok = have_mdbtools()
            if not mdb_ok:
                lines.append("- mdbtools nicht verfügbar")
                continue
            try:
                ver = subprocess.run(["mdb-ver", path], capture_output=True, text=True, timeout=60).stdout.strip()
                tabs = subprocess.run(["mdb-tables", "-1", path], capture_output=True, text=True,
                                      timeout=600).stdout.split("\n")
                tabs = [t for t in tabs if t.strip()]
                lines.append(f"- Access-Version: {ver} · Tabellen: {len(tabs)}")
                schema = subprocess.run(["mdb-schema", path, "postgres"], capture_output=True, text=True,
                                        timeout=600).stdout
                sname = re.sub(r"[^A-Za-z0-9_.-]+", "_", os.path.basename(rel)) + ".schema.sql"
                with open(os.path.join(out, sname), "w", encoding="utf-8") as fh:
                    fh.write(schema)
                lines.append(f"- Schema inkl. Beziehungen: `{sname}`")
                for t in tabs:
                    cnt = subprocess.run(["mdb-count", path, t], capture_output=True, text=True,
                                         timeout=900).stdout.strip()
                    rows = _head_lines(["mdb-export", "-Q", "-d", "\t", path, t], n=4)
                    lines.append(f"  - **{t}** ({cnt} Zeilen)")
                    if rows:
                        lines.append(f"    - Spalten: `{rows[0][:600]}`")
                        for r in rows[1:]:
                            lines.append(f"    - `{r[:400]}`")
            except Exception as e:  # noqa: BLE001
                lines.append(f"- Fehler: {e!r}")
        elif path.lower().endswith(".mdf"):
            lines.append("- SQL-Server-Datei: wird im nächsten Schritt mit SQL Server ausgelesen")
        lines.append("")
    with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    log(f"Datenbanken: {len(found)} Dateien, {len(seen)} eindeutig")


def run_datenbanken(root, db_dirs, output_dir="02 Grundfos/00_Datenaudit/ergebnis_gpi",
                    cache_dir="/content/mdb_cache"):
    out = os.path.join(root, output_dir)
    os.makedirs(out, exist_ok=True)
    databases(root, {"DB_DIRS": db_dirs}, out, name="20_access_datenbanken.md", cache_dir=cache_dir)
    log(f"FERTIG → {out}")


def run(root, overrides=None):
    t0 = time.time()
    cfg = dict(DEFAULT_CONFIG)
    if overrides:
        cfg.update(overrides)
    out = os.path.join(root, cfg["OUTPUT_DIR"])
    os.makedirs(out, exist_ok=True)
    log(f"Ausgabe: {out}")
    arts_map, _ = load_article_list(os.path.join(root, cfg["ARTICLE_LIST"]))
    arts = set(arts_map)
    gpc = os.path.join(root, cfg["GPC_DIR"])
    steps = [
        ("DATANORM", lambda: datanorm_grundfos_share(root, cfg, out, arts)),
        ("Caches", lambda: gpc_caches(gpc, out)),
        ("ZIPs", lambda: zip_lists(gpc, out, arts)),
        ("ProductRange", lambda: product_ranges(gpc, out, arts)),
        ("Datenbanken", lambda: databases(root, cfg, out)),
    ]
    errors = []
    for name, fn in steps:
        try:
            fn()
        except Exception as e:  # noqa: BLE001 – jeder Teil soll unabhängig laufen
            errors.append(f"{name}: {e!r}")
            log(f"⚠ {name} fehlgeschlagen: {e!r}")
    with open(os.path.join(out, "00_status.txt"), "w", encoding="utf-8") as fh:
        fh.write(f"Laufzeit: {round((time.time() - t0) / 60, 1)} min\nFehler: {errors or 'keine'}\n")
    log(f"FERTIG in {round((time.time() - t0) / 60, 1)} min → {out}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="/content/drive/MyDrive")
    run(ap.parse_args().root)
