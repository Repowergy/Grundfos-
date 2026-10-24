#!/usr/bin/env python3
"""
Grundfos Datenaudit – Schritt 1 (nur lesen, nichts verändern)

Untersucht:
  1. alle DATANORM-Dateien (auch in ZIPs): Hersteller, Version, Datenstand,
     Satzarten, Kurztexte, Langtexte, EAN, Preise
  2. die Grundfos-Product-Center-Installation (GPC): Dateitypen, ZIP-Inhalte,
     Datenbanken, Regeldateien, Caches
  3. die Abdeckung gegen die Grundfos-Artikelliste (806.105 Nummern)

Schreibt kleine Berichtsdateien (CSV/JSON/Markdown/TXT) in OUTPUT_DIR.
Quelldateien werden ausschließlich gelesen.

Läuft in Google Colab (Drive gemountet) oder lokal mit Google Drive für Desktop:
  python datenaudit.py --root "/content/drive/MyDrive"
  python datenaudit.py --root "G:/Meine Ablage"
"""

import argparse
import collections
import csv
import datetime as dt
import hashlib
import io
import json
import os
import re
import sqlite3
import sys
import time
import zipfile
import zlib

# ═══════════════════════════════════════════════════════════════════
# KONFIGURATION (Pfade relativ zu --root)
# ═══════════════════════════════════════════════════════════════════
DEFAULT_CONFIG = {
    "DATANORM_DIRS": ["04 Datanorm, ENF & Herstellerdaten/Datanorm X Shopify"],
    "GPC_DIRS": ["02 Grundfos/GRUNDFOS SOFTWARE X SHOPIFY/GPC"],
    "ARTICLE_LIST": "02 Grundfos/GRUNDFOS/de_DE/checkpoints/product_list.jsonl",
    "DATANORM_CSV": "02 Grundfos/Grundfos Daten X Shopify/GRUNDFOS_DATANORM_Gesamt.csv",
    "OUTPUT_DIR": "02 Grundfos/00_Datenaudit/ergebnis",
}

# Grundfos-Produktnummer: 8 Zeichen, beginnt mit 2 Ziffern (96281376, 001A5041, 05001A04)
GF_NUM = re.compile(r"(?<![0-9A-Z])([0-9]{2}[0-9A-Z]{6})(?![0-9A-Z])")
EAN_RE = re.compile(r"^\d{8}$|^\d{12,14}$")
KNOWN_MAKERS = ["GRUNDFOS", "WILO", "BRÖTJE", "BROETJE", "VIESSMANN", "BUDERUS", "VAILLANT",
                "LOWARA", "XYLEM", "KSB", "DAB", "OVENTROP", "DANFOSS", "HONEYWELL", "RESIDEO",
                "STIEBEL", "WOLF", "WEISHAUPT", "JUNKERS", "BOSCH", "GEBERIT", "GROHE", "HANSGROHE",
                "REHAU", "UPONOR", "SYR", "JUDO", "KERMI", "PURMO", "ZEHNDER", "REFLEX", "SPIROTECH",
                "CALEFFI", "AFRISO", "WATTS", "SCHELL", "KEMPER", "VIEGA", "TECE", "DORNBRACHT"]
TEXT_EXT = {".txt", ".csv", ".xml", ".json", ".ini", ".cfg", ".config", ".log", ".htm", ".html",
            ".tsv", ".dat", ".lst", ".md"}
KEY_FILE_RE = re.compile(r"replac|accessor|rule|productrange|range|spare|service|relation|link|"
                         r"cross|successor|popular|product|catalog|katalog|sortiment|\.cache$|\.db$|"
                         r"\.sdf$|\.mdb$|\.sqlite$", re.I)
MAX_DETAIL_SIMILAR = 3          # pro (Ordner, Endung) so viele Dateien im Detail
STRINGS_SCAN_BYTES = 8 * 1024 * 1024
TEXT_HEAD_LINES = 15


# ═══════════════════════════════════════════════════════════════════
# HILFSFUNKTIONEN
# ═══════════════════════════════════════════════════════════════════
def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def human(n):
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def ean_ok(code):
    """GTIN-Prüfziffer (EAN-8/UPC-12/EAN-13/GTIN-14)."""
    if not EAN_RE.match(code) or set(code) == {"0"}:
        return False
    digits = [int(c) for c in code]
    check = digits.pop()
    total = sum(d * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(digits)))
    return (10 - total % 10) % 10 == check


def guess_encoding(raw: bytes):
    if raw.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return "utf-16"
    try:
        raw.decode("utf-8")
        return "utf-8"
    except UnicodeDecodeError:
        pass
    cp850 = sum(raw.count(bytes([b])) for b in (0x81, 0x84, 0x94, 0x8E, 0x99, 0x9A, 0xE1))
    cp1252 = sum(raw.count(bytes([b])) for b in (0xFC, 0xE4, 0xF6, 0xC4, 0xD6, 0xDC, 0xDF))
    return "cp850" if cp850 > cp1252 else "cp1252"


def magic_type(head: bytes, ext: str):
    if head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"):
        return "zip"
    if head.startswith(b"SQLite format 3\x00"):
        return "sqlite"
    if head.startswith(b"\x1f\x8b"):
        return "gzip"
    if head.startswith(b"7z\xbc\xaf\x27\x1c"):
        return "7z"
    if head.startswith(b"Rar!"):
        return "rar"
    if head.startswith(b"MZ"):
        return "pe(exe/dll)"
    if head.startswith(b"\x89PNG"):
        return "png"
    if head.startswith(b"\xff\xd8"):
        return "jpg"
    if head.startswith(b"GIF8"):
        return "gif"
    if head.startswith(b"%PDF"):
        return "pdf"
    if head[:2] in (b"\x78\x9c", b"\x78\xda", b"\x78\x01"):
        return "zlib"
    if head.startswith(b"\xff\xfe") or head.startswith(b"\xfe\xff"):
        return "text-utf16"
    if head.startswith(b"MSCF"):
        return "cab"
    if head.startswith(b"\x00\x01\x00\x00Standard Jet DB") or head[4:19] == b"Standard Jet DB":
        return "access-mdb"
    stripped = head.lstrip(b"\xef\xbb\xbf \r\n\t")
    if stripped.startswith(b"<?xml") or stripped.startswith(b"<"):
        return "xml/html"
    if stripped[:1] in (b"{", b"["):
        return "json?"
    if head:
        printable = sum(32 <= b < 127 or b in (9, 10, 13) or b >= 0xC0 for b in head)
        if printable / len(head) > 0.92:
            return "text"
    if ext == ".sdf":
        return "sqlce?"
    return "binary"


def extract_strings(data: bytes, minlen=6, limit=40):
    out = []
    for m in re.finditer(rb"[\x20-\x7e\xc0-\xff]{%d,}" % minlen, data):
        out.append(m.group().decode("latin-1")[:160])
        if len(out) >= limit:
            break
    u16 = []
    for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % minlen, data):
        u16.append(m.group().decode("utf-16le")[:160])
        if len(u16) >= limit // 2:
            break
    return out, u16


def gf_numbers_in(text, bag=None):
    found = GF_NUM.findall(text.upper())
    if bag is not None:
        bag.update(found)
    return found


# ═══════════════════════════════════════════════════════════════════
# 1) DATANORM
# ═══════════════════════════════════════════════════════════════════
def looks_like_datanorm(name, head: bytes):
    n = name.lower()
    ext = os.path.splitext(n)[1]
    if "datanorm" in n or re.match(r"^\.\d{3}$", ext) or ext in (".wrg", ".rab"):
        return True
    first = head.split(b"\n", 1)[0].strip()
    return bool(re.match(rb"^V[ ;]", first))


class DatanormStats:
    def __init__(self, label):
        self.label = label
        self.md5 = hashlib.md5()
        self.size = 0
        self.lines = 0
        self.rec = collections.Counter()
        self.samples = collections.defaultdict(list)
        self.v_record = ""
        self.encoding = ""
        self.fmt = ""           # "semikolon" | "fest(128)" | "gemischt"
        self.sep_lines = 0
        self.fixed_lines = 0
        self.articles = set()
        self.with_ean = set()
        self.with_price = set()
        self.with_longkey = set()
        self.textkz = collections.Counter()
        self.longtext_keys = set()
        self.t_records_by_key = collections.Counter()
        self.maker_hits = collections.Counter()
        self.example_articles = {}      # artnr -> dict
        self.t_texts = {}               # key -> list of text pieces (nur für Beispiele)
        self.wg = collections.Counter()

    def feed_line(self, line: str):
        self.lines += 1
        if not line.strip():
            return
        rt = line[0].upper()
        is_sep = len(line) > 1 and line[1] == ";"
        if is_sep:
            self.sep_lines += 1
        else:
            self.fixed_lines += 1
        self.rec[rt] += 1
        if len(self.samples[rt]) < 4:
            self.samples[rt].append(line[:300])
        up = line.upper()
        if self.lines <= 3000:
            for m in KNOWN_MAKERS:
                if m in up:
                    self.maker_hits[m] += 1
        if rt == "V" and not self.v_record:
            self.v_record = line[:300]
            return
        if not is_sep:
            # Festformat (128 Zeichen): Satzart(1) + Verarbeitungskz.(1) + Artikelnummer(15) …
            # Vollständige Feldzerlegung erst im Import; hier nur Nummern/EAN-Indizien
            art = up[2:17].strip().replace(" ", "")
            if rt == "A" and art:
                self.articles.add(art)
            if rt == "B" and art:
                for tok in re.findall(r"\d{13}", line):
                    if ean_ok(tok):
                        self.with_ean.add(art)
                        break
            return
        f = [x.strip() for x in line.rstrip("\r\n").split(";")]
        if rt == "A" and len(f) > 3:
            art = f[2].upper().replace(" ", "")
            self.articles.add(art)
            if len(f) > 3:
                self.textkz[f[3]] += 1
            if len(f) > 9 and re.match(r"^\d+([.,]\d+)?$", f[9] or "") and f[9].strip("0"):
                self.with_price.add(art)
            if len(f) > 11 and f[11]:
                self.wg[f[11]] += 1
            if len(f) > 12 and f[12]:
                self.with_longkey.add(art)
                self.longtext_keys.add(f[12])
            if len(self.example_articles) < 400:
                self.example_articles.setdefault(art, {
                    "artikelnummer": art,
                    "kurztext1": f[4] if len(f) > 4 else "",
                    "kurztext2": f[5] if len(f) > 5 else "",
                    "preis_roh": f[9] if len(f) > 9 else "",
                    "mengeneinheit": f[8] if len(f) > 8 else "",
                    "rabattgruppe": f[10] if len(f) > 10 else "",
                    "warengruppe": f[11] if len(f) > 11 else "",
                    "langtext_schluessel": f[12] if len(f) > 12 else "",
                    "textkennzeichen": f[3],
                    "ean": "",
                })
        elif rt == "B" and len(f) > 2:
            art = f[2].upper().replace(" ", "")
            for tok in f[3:]:
                if ean_ok(tok):
                    self.with_ean.add(art)
                    if art in self.example_articles:
                        self.example_articles[art]["ean"] = tok
                    break
        elif rt == "T" and len(f) > 3:
            key = f[2]
            self.t_records_by_key[key] += 1
            if len(self.t_texts) < 3000 or key in self.t_texts:
                txt = " ".join(x for x in f[3:] if x and not x.isdigit())
                self.t_texts.setdefault(key, []).append(txt)
        elif rt == "P" and len(f) > 3:
            # P-Sätze können mehrere Artikel je Zeile enthalten
            for i in range(2, len(f) - 2):
                if f[i] and GF_NUM.fullmatch(f[i].upper()):
                    if i + 2 < len(f) and re.match(r"^\d+$", f[i + 2] or ""):
                        self.with_price.add(f[i].upper())

    def finish(self):
        if self.sep_lines and self.fixed_lines:
            self.fmt = "gemischt" if min(self.sep_lines, self.fixed_lines) > 5 else (
                "semikolon" if self.sep_lines > self.fixed_lines else "fest")
        else:
            self.fmt = "semikolon" if self.sep_lines else "fest"
        for art, ex in self.example_articles.items():
            key = ex.get("langtext_schluessel")
            if key and key in self.t_texts:
                ex["langtext_heuristisch"] = " ".join(self.t_texts[key])[:800]
            else:
                ex["langtext_heuristisch"] = ""

    def v_fields(self):
        v = self.v_record
        res = {"datum": "", "version": "", "waehrung": "", "info": ""}
        if not v:
            return res
        if len(v) > 1 and v[1] == ";":
            f = [x.strip() for x in v.split(";")]
            res["info"] = " | ".join(x for x in f[1:] if x)[:200]
            for x in f:
                if re.fullmatch(r"\d{6}|\d{8}", x) and not res["datum"]:
                    res["datum"] = x
                if re.fullmatch(r"0?[345]\d?", x) and not res["version"]:
                    res["version"] = x
                if x in ("EUR", "DEM", "CHF") and not res["waehrung"]:
                    res["waehrung"] = x
        else:
            res["datum"] = v[2:8].strip()
            res["info"] = re.sub(r"\s+", " ", v[8:123]).strip()
            res["version"] = v[123:125].strip()
            res["waehrung"] = v[125:128].strip()
        return res

    def maker(self):
        info = self.v_fields()["info"].upper()
        for m in KNOWN_MAKERS:
            if m in info:
                return m
        if self.maker_hits:
            return self.maker_hits.most_common(1)[0][0] + " (aus Texten)"
        return "unbekannt"

    def is_grundfos(self):
        return "GRUNDFOS" in self.v_record.upper() or self.maker_hits.get("GRUNDFOS", 0) >= 5


def analyse_datanorm_stream(label, fobj, size):
    st = DatanormStats(label)
    st.size = size
    head = fobj.read(256 * 1024)
    st.encoding = guess_encoding(head)
    enc = st.encoding
    if enc == "utf-16":
        # UTF-16 lässt sich nicht byteweise an \n trennen → komplett dekodieren
        data = head + fobj.read()
        st.md5.update(data)
        for ln in data.decode("utf-16", errors="replace").splitlines():
            st.feed_line(ln)
        st.finish()
        return st
    buf = head
    pending = b""
    while True:
        st.md5.update(buf)
        data = pending + buf
        lines = data.split(b"\n")
        pending = lines.pop()
        for raw in lines:
            st.feed_line(raw.decode(enc, errors="replace"))
        buf = fobj.read(4 * 1024 * 1024)
        if not buf:
            break
    if pending:
        st.feed_line(pending.decode(enc, errors="replace"))
    st.finish()
    return st


def audit_datanorm(root, cfg, out):
    log("DATANORM: suche Dateien …")
    results = []
    other_files = []
    for rel in cfg["DATANORM_DIRS"]:
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            log(f"  ⚠ Ordner nicht gefunden: {base}")
            continue
        for dp, _dn, fn in os.walk(base):
            for name in sorted(fn):
                path = os.path.join(dp, name)
                relp = os.path.relpath(path, root)
                try:
                    size = os.path.getsize(path)
                    with open(path, "rb") as fh:
                        head = fh.read(4096)
                except OSError as e:
                    other_files.append((relp, 0, f"Fehler: {e}"))
                    continue
                kind = magic_type(head, os.path.splitext(name)[1].lower())
                if kind == "zip":
                    try:
                        with zipfile.ZipFile(path) as zf:
                            for zi in zf.infolist():
                                if zi.is_dir():
                                    continue
                                with zf.open(zi) as zfh:
                                    zhead = zfh.read(4096)
                                if looks_like_datanorm(zi.filename, zhead):
                                    with zf.open(zi) as zfh:
                                        log(f"  ZIP {relp} :: {zi.filename} ({human(zi.file_size)})")
                                        results.append(analyse_datanorm_stream(
                                            f"{relp}::{zi.filename}", zfh, zi.file_size))
                                else:
                                    other_files.append((f"{relp}::{zi.filename}", zi.file_size,
                                                        magic_type(zhead, os.path.splitext(zi.filename)[1].lower())))
                    except zipfile.BadZipFile:
                        other_files.append((relp, size, "zip (defekt)"))
                elif looks_like_datanorm(name, head):
                    log(f"  {relp} ({human(size)})")
                    with open(path, "rb") as fh:
                        results.append(analyse_datanorm_stream(relp, fh, size))
                else:
                    other_files.append((relp, size, kind))

    # Duplikate per MD5
    first_by_md5 = {}
    for st in results:
        h = st.md5.hexdigest()
        st.dup_of = first_by_md5.get(h, "")
        first_by_md5.setdefault(h, st.label)

    # 01 Dateiliste
    rec_types = sorted({rt for st in results for rt in st.rec})
    with open(os.path.join(out, "01_datanorm_dateien.csv"), "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["datei", "groesse", "md5", "duplikat_von", "hersteller", "grundfos", "datum_V",
                    "version_V", "waehrung", "info_V", "format", "encoding", "zeilen",
                    "artikel", "mit_ean", "mit_preis", "mit_langtext_schluessel", "langtext_schluessel_unique",
                    "T_saetze_schluessel"] + [f"satz_{r}" for r in rec_types])
        for st in results:
            v = st.v_fields()
            w.writerow([st.label, st.size, st.md5.hexdigest(), st.dup_of, st.maker(),
                        "ja" if st.is_grundfos() else "", v["datum"], v["version"], v["waehrung"],
                        v["info"], st.fmt, st.encoding, st.lines, len(st.articles), len(st.with_ean),
                        len(st.with_price), len(st.with_longkey), len(st.longtext_keys),
                        len(st.t_records_by_key)] + [st.rec.get(r, 0) for r in rec_types])
        for relp, size, kind in other_files:
            w.writerow([relp, size, "", "", "", "", "", "", "", f"kein DATANORM ({kind})"])

    # 02 Beispiele je eindeutiger Datei
    with open(os.path.join(out, "02_datanorm_beispiele.txt"), "w", encoding="utf-8") as fh:
        for st in results:
            if st.dup_of:
                continue
            v = st.v_fields()
            fh.write("=" * 100 + "\n")
            fh.write(f"DATEI: {st.label}\nHersteller: {st.maker()} | Grundfos: {st.is_grundfos()} | "
                     f"Datum: {v['datum']} | Version: {v['version']} | Format: {st.fmt} | "
                     f"Encoding: {st.encoding} | Zeilen: {st.lines}\n")
            fh.write(f"V-Satz: {st.v_record}\n")
            fh.write(f"Satzarten: {dict(st.rec)}\n")
            if st.textkz:
                fh.write(f"Textkennzeichen (A-Satz Feld 4): {dict(st.textkz.most_common(10))}\n")
            if st.wg:
                fh.write(f"Top-Warengruppen: {dict(st.wg.most_common(15))}\n")
            for rt, lines in sorted(st.samples.items()):
                fh.write(f"--- Beispiele Satzart {rt} ---\n")
                for ln in lines:
                    fh.write(ln.rstrip("\r\n") + "\n")
            exs = [e for e in st.example_articles.values() if e.get("langtext_heuristisch")][:3]
            if exs:
                fh.write("--- zusammengesetzte Beispielartikel (A + B + T, heuristisch) ---\n")
                for e in exs:
                    fh.write(json.dumps(e, ensure_ascii=False) + "\n")
            fh.write("\n")

    # 06 Stichprobe Grundfos-Artikel
    with open(os.path.join(out, "06_datanorm_grundfos_stichprobe.csv"), "w", newline="",
              encoding="utf-8-sig") as fh:
        cols = ["quelle", "datum_V", "artikelnummer", "kurztext1", "kurztext2", "ean", "preis_roh",
                "mengeneinheit", "rabattgruppe", "warengruppe", "textkennzeichen",
                "langtext_schluessel", "langtext_heuristisch"]
        w = csv.DictWriter(fh, fieldnames=cols, delimiter=";", extrasaction="ignore")
        w.writeheader()
        n = 0
        for st in results:
            if st.dup_of or not st.is_grundfos():
                continue
            for e in list(st.example_articles.values())[:60]:
                w.writerow({**e, "quelle": st.label, "datum_V": st.v_fields()["datum"]})
                n += 1
                if n >= 600:
                    break
    log(f"DATANORM: {len(results)} Dateien analysiert, {len(other_files)} sonstige Dateien")
    return results


# ═══════════════════════════════════════════════════════════════════
# 2) GPC (Grundfos Product Center Desktop)
# ═══════════════════════════════════════════════════════════════════
def audit_gpc(root, cfg, out, gf_numbers_from_gpc):
    log("GPC: durchsuche Installation …")
    rows = []
    groups = collections.defaultdict(list)
    for rel in cfg["GPC_DIRS"]:
        base = os.path.join(root, rel)
        if not os.path.isdir(base):
            log(f"  ⚠ Ordner nicht gefunden: {base}")
            continue
        for dp, _dn, fn in os.walk(base):
            for name in sorted(fn):
                path = os.path.join(dp, name)
                relp = os.path.relpath(path, base)
                ext = os.path.splitext(name)[1].lower()
                try:
                    size = os.path.getsize(path)
                    with open(path, "rb") as fh:
                        head = fh.read(64)
                except OSError as e:
                    rows.append([relp, 0, ext, "", f"Fehler: {e}", ""])
                    continue
                kind = magic_type(head, ext)
                rows.append([relp, size, ext, head[:16].hex(" "), kind, ""])
                groups[(os.path.dirname(relp), ext, kind)].append((path, relp, size))

    detail = []
    detail.append("# GPC – Detailanalyse\n")
    # Übersicht nach Ordner/Endung
    detail.append("## Übersicht (Ordner, Endung, Typ)\n")
    detail.append("| Ordner | Endung | Typ | Dateien | Größe gesamt |\n|---|---|---|---|---|")
    for (d, ext, kind), items in sorted(groups.items(), key=lambda kv: -sum(i[2] for i in kv[1])):
        detail.append(f"| {d or '.'} | {ext or '-'} | {kind} | {len(items)} | {human(sum(i[2] for i in items))} |")
    detail.append("")

    skip_kinds = {"pe(exe/dll)", "png", "jpg", "gif"}
    key_files = []
    for (d, ext, kind), items in sorted(groups.items()):
        # Produktnummern aus Dateinamen aller Dateien sammeln (z. B. Bilder je Artikel)
        for _p, rp, _s in items:
            gf_numbers_in(os.path.basename(rp), gf_numbers_from_gpc["dateinamen"])
            if KEY_FILE_RE.search(os.path.basename(rp)) and kind not in skip_kinds:
                key_files.append((_p, rp, _s, kind))
        if kind in skip_kinds:
            continue
        src_key = os.path.basename(items[0][1]) if len(items) == 1 else f"{d or '.'}/*{ext}"
        for path, relp, size in items[:MAX_DETAIL_SIMILAR]:
            detail.append(f"## {relp}  ({human(size)}, Typ {kind})\n")
            try:
                detail.extend(describe_file(path, size, kind, ext, gf_numbers_from_gpc, src_key))
            except Exception as e:  # noqa: BLE001 – Audit soll weiterlaufen
                detail.append(f"Fehler bei Analyse: {e!r}")
            detail.append("")
        if len(items) > MAX_DETAIL_SIMILAR:
            detail.append(f"_… weitere {len(items) - MAX_DETAIL_SIMILAR} Dateien gleicher Art in "
                          f"`{d or '.'}` ({ext}), zusammen {human(sum(i[2] for i in items))}_\n")
            # restliche Dateien der Gruppe nur nach Grundfos-Nummern durchsuchen (ohne Detailausgabe)
            if kind not in ("zip", "sqlite") and sum(i[2] for i in items) <= 300 * 1024 * 1024:
                for path, _relp, size in items[MAX_DETAIL_SIMILAR:]:
                    try:
                        with open(path, "rb") as bf:
                            data = bf.read(min(size, STRINGS_SCAN_BYTES))
                        if data[:2] in (b"\x78\x9c", b"\x78\xda"):
                            data = zlib.decompressobj().decompress(data, STRINGS_SCAN_BYTES)
                        prefix = "text:" if kind.startswith("text") or kind in ("xml/html", "json?") else "bin:"
                        gf_numbers_in(data.decode("latin-1"), gf_numbers_from_gpc[prefix + src_key])
                    except (OSError, zlib.error):
                        pass

    # Schlüsseldateien (Austausch, Zubehör, Sortiment, Service …) ausführlicher
    with open(os.path.join(out, "07_gpc_schluesseldateien.txt"), "w", encoding="utf-8") as fh:
        for path, relp, size, kind in key_files[:80]:
            fh.write("=" * 100 + f"\n{relp}  ({human(size)}, Typ {kind})\n")
            try:
                with open(path, "rb") as bf:
                    data = bf.read(min(size, STRINGS_SCAN_BYTES))
                if kind == "zip":
                    fh.write("\n".join(describe_file(path, size, kind, "", collections.defaultdict(
                        collections.Counter))) + "\n")
                    continue
                if data[:2] in (b"\x78\x9c", b"\x78\xda"):
                    try:
                        data = zlib.decompressobj().decompress(data, STRINGS_SCAN_BYTES)
                        fh.write(f"(zlib entpackt: {human(len(data))})\n")
                    except zlib.error:
                        pass
                fh.write("HEX (erste 512 Bytes):\n")
                for off in range(0, min(512, len(data)), 32):
                    chunk = data[off:off + 32]
                    fh.write(f"{off:04x}  {chunk.hex(' '):<96}  "
                             f"{''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)}\n")
                s8, s16 = extract_strings(data, minlen=4, limit=200)
                fh.write("STRINGS:\n" + "\n".join(s8[:200]) + "\n")
                if s16:
                    fh.write("STRINGS UTF-16:\n" + "\n".join(s16[:100]) + "\n")
            except Exception as e:  # noqa: BLE001
                fh.write(f"Fehler: {e!r}\n")

    with open(os.path.join(out, "03_gpc_dateien.csv"), "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["datei", "groesse", "endung", "magic_hex", "typ", "hinweis"])
        w.writerows(rows)
    with open(os.path.join(out, "04_gpc_details.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(detail))
    log(f"GPC: {len(rows)} Dateien erfasst")
    return rows


def describe_file(path, size, kind, ext, gf_bag, src_key=None):
    """Beschreibt eine Datei; Grundfos-Nummern landen in gf_bag[src_key]."""
    lines = []
    key = src_key or os.path.basename(path)
    if kind == "zip":
        with zipfile.ZipFile(path) as zf:
            infos = [i for i in zf.infolist() if not i.is_dir()]
            exts = collections.Counter(os.path.splitext(i.filename)[1].lower() for i in infos)
            tops = collections.Counter(i.filename.split("/")[0] for i in infos)
            nums = collections.Counter()
            for i in infos:
                gf_numbers_in(os.path.basename(i.filename), nums)
            gf_bag["zip:" + key].update(nums)
            lines.append(f"- Einträge: {len(infos)}, entpackt: {human(sum(i.file_size for i in infos))}")
            lines.append(f"- Endungen: {dict(exts.most_common(12))}")
            lines.append(f"- Top-Ordner: {dict(tops.most_common(12))}")
            lines.append(f"- Dateinamen mit Grundfos-Nummer: {sum(nums.values())} "
                         f"({len(nums)} verschiedene Nummern)")
            lines.append("- Beispiele: " + ", ".join(f"`{i.filename}`" for i in infos[:20]))
            # kleine Text-/XML-/DB-Einträge kurz anreißen
            shown = 0
            for i in infos:
                e = os.path.splitext(i.filename)[1].lower()
                if shown < 3 and (e in TEXT_EXT or e in (".db", ".sqlite")) and i.file_size < 20_000_000:
                    with zf.open(i) as zfh:
                        raw = zfh.read(4096)
                    enc = guess_encoding(raw)
                    lines.append(f"- Kopf von `{i.filename}`:\n```\n"
                                 + "\n".join(raw.decode(enc, "replace").splitlines()[:10]) + "\n```")
                    shown += 1
    elif kind == "sqlite":
        uri = "file:" + path.replace("\\", "/") + "?mode=ro&immutable=1"
        con = sqlite3.connect(uri, uri=True)
        try:
            tabs = [r[0] for r in con.execute("select name from sqlite_master where type='table'")]
            lines.append(f"- Tabellen: {len(tabs)}")
            for t in tabs[:60]:
                cols = [r[1] for r in con.execute(f'pragma table_info("{t}")')]
                cnt = con.execute(f'select count(*) from "{t}"').fetchone()[0]
                lines.append(f"  - **{t}** ({cnt} Zeilen): {', '.join(cols)[:400]}")
                for row in con.execute(f'select * from "{t}" limit 3'):
                    lines.append("    - " + " | ".join(str(v)[:60] for v in row)[:400])
        finally:
            con.close()
    elif kind in ("text", "xml/html", "json?", "text-utf16") or ext in TEXT_EXT:
        with open(path, "rb") as fh:
            raw = fh.read(min(size, 2 * 1024 * 1024))
        enc = guess_encoding(raw)
        text = raw.decode(enc, "replace")
        nums = collections.Counter()
        gf_numbers_in(text, nums)
        gf_bag["text:" + key].update(nums)
        lines.append(f"- Encoding: {enc}, Zeilen (erste 2 MB): {text.count(chr(10))}, "
                     f"Grundfos-Nummern darin: {sum(nums.values())} ({len(nums)} verschiedene)")
        lines.append("```\n" + "\n".join(l[:300] for l in text.splitlines()[:TEXT_HEAD_LINES]) + "\n```")
    else:
        with open(path, "rb") as fh:
            data = fh.read(min(size, STRINGS_SCAN_BYTES))
        if kind == "zlib" or data[:2] in (b"\x78\x9c", b"\x78\xda"):
            try:
                data = zlib.decompress(data) if size <= STRINGS_SCAN_BYTES else \
                    zlib.decompressobj().decompress(data, STRINGS_SCAN_BYTES)
                lines.append(f"- zlib entpackt: {human(len(data))}")
            except zlib.error as e:
                lines.append(f"- zlib-Versuch fehlgeschlagen: {e}")
        elif kind == "gzip":
            import gzip
            try:
                data = gzip.decompress(data)
                lines.append(f"- gzip entpackt: {human(len(data))}")
            except Exception as e:  # noqa: BLE001
                lines.append(f"- gzip-Versuch fehlgeschlagen: {e}")
        s8, s16 = extract_strings(data)
        nums = collections.Counter()
        gf_numbers_in(data.decode("latin-1"), nums)
        gf_bag["bin:" + key].update(nums)
        lines.append(f"- Kopf (hex): `{data[:32].hex(' ')}`")
        lines.append(f"- Grundfos-Nummern im gelesenen Bereich: {sum(nums.values())} ({len(nums)} verschiedene); "
                     f"Beispiele: {', '.join(list(nums)[:10])}")
        if s8:
            lines.append("- Strings (ASCII/Latin-1): " + " ‖ ".join(s8[:30]))
        if s16:
            lines.append("- Strings (UTF-16): " + " ‖ ".join(s16[:20]))
    return lines


# ═══════════════════════════════════════════════════════════════════
# 3) ARTIKELLISTE + ABDECKUNG
# ═══════════════════════════════════════════════════════════════════
def load_article_list(path):
    arts = {}
    keys_seen = None
    if not os.path.exists(path):
        log(f"  ⚠ Artikelliste nicht gefunden: {path}")
        return arts, None
    log(f"Artikelliste laden: {path}")
    cand = ["article_number", "articleNumber", "product_number", "productNumber", "productnumber",
            "material_number", "sku", "article", "number"]
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if keys_seen is None:
                keys_seen = list(obj.keys()) if isinstance(obj, dict) else type(obj).__name__
            num = ""
            if isinstance(obj, dict):
                for k in cand:
                    if obj.get(k):
                        num = str(obj[k])
                        break
                if not num:
                    m = GF_NUM.search(json.dumps(obj).upper())
                    num = m.group(1) if m else ""
                fam = obj.get("family") or obj.get("family_slug") or ""
            else:
                fam = ""
            if num:
                arts[num.upper().replace(" ", "")] = fam
            if i % 200000 == 0 and i:
                log(f"  … {i} Zeilen")
    log(f"  {len(arts)} Artikel, Felder: {keys_seen}")
    return arts, keys_seen


def audit_datanorm_csv(path):
    res = {}
    if not os.path.exists(path):
        return res
    with open(path, encoding="utf-8-sig", errors="replace", newline="") as fh:
        r = csv.DictReader(fh, delimiter=";")
        rows = list(r)
    res["zeilen"] = len(rows)
    res["spalten"] = r.fieldnames
    res["artikel_unique"] = len({x.get("Artikelnummer", "") for x in rows})
    res["mit_langtextschluessel"] = sum(1 for x in rows if (x.get("Langtextschluessel") or "").strip())
    res["mit_ean"] = sum(1 for x in rows if ean_ok((x.get("EAN_GTIN") or "").strip()))
    res["sortimente"] = dict(collections.Counter(x.get("Sortiment", "") for x in rows).most_common(20))
    res["datenstaende"] = dict(collections.Counter(x.get("Datenstand", "") for x in rows).most_common(20))
    res["quelldateien"] = dict(collections.Counter(x.get("Quelldatei", "") for x in rows).most_common(20))
    res["_artikel"] = {x.get("Artikelnummer", "").upper().replace(" ", "") for x in rows}
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="/content/drive/MyDrive")
    ap.add_argument("--config", default="", help="optional: JSON-Datei mit abweichenden Pfaden")
    ap.add_argument("--skip-gpc", action="store_true")
    ap.add_argument("--skip-articles", action="store_true")
    args, _ = ap.parse_known_args()
    run(args.root, args.config, args.skip_gpc, args.skip_articles)


def run(root, config_path="", skip_gpc=False, skip_articles=False, overrides=None):
    t0 = time.time()
    cfg = dict(DEFAULT_CONFIG)
    if config_path:
        with open(config_path, encoding="utf-8") as fh:
            cfg.update(json.load(fh))
    if overrides:
        cfg.update(overrides)
    out = os.path.join(root, cfg["OUTPUT_DIR"])
    os.makedirs(out, exist_ok=True)
    log(f"Ausgabe: {out}")

    dn = audit_datanorm(root, cfg, out)

    gpc_nums = collections.defaultdict(collections.Counter)
    gpc_rows = [] if skip_gpc else audit_gpc(root, cfg, out, gpc_nums)

    arts, keys = ({}, None) if skip_articles else load_article_list(os.path.join(root, cfg["ARTICLE_LIST"]))
    dncsv = audit_datanorm_csv(os.path.join(root, cfg["DATANORM_CSV"]))

    # Abdeckung
    art_set = set(arts)
    gf_dn = [st for st in dn if st.is_grundfos() and not st.dup_of]
    dn_arts = set().union(*[st.articles for st in gf_dn]) if gf_dn else set()
    dn_ean = set().union(*[st.with_ean for st in gf_dn]) if gf_dn else set()
    dn_price = set().union(*[st.with_price for st in gf_dn]) if gf_dn else set()
    dn_long = set().union(*[st.with_longkey for st in gf_dn]) if gf_dn else set()
    cover = {
        "erstellt": dt.datetime.now().isoformat(timespec="seconds"),
        "laufzeit_min": round((time.time() - t0) / 60, 1),
        "artikelliste": {"anzahl": len(art_set), "felder": keys},
        "datanorm_grundfos_dateien": [
            {"datei": st.label, "datum": st.v_fields()["datum"], "info": st.v_fields()["info"],
             "artikel": len(st.articles), "ean": len(st.with_ean), "preis": len(st.with_price),
             "langtext": len(st.with_longkey)} for st in gf_dn],
        "datanorm_grundfos_gesamt": {
            "artikel_unique": len(dn_arts),
            "davon_in_artikelliste": len(dn_arts & art_set),
            "mit_ean": len(dn_ean),
            "mit_preis": len(dn_price),
            "mit_langtext_schluessel": len(dn_long),
            "nicht_in_artikelliste_beispiele": sorted(dn_arts - art_set)[:25],
        },
        "datanorm_gesamt_csv": {k: v for k, v in dncsv.items() if not k.startswith("_")},
        "gpc_nummern_nach_quelle": {
            src: {"verschiedene": len(c), "davon_in_artikelliste": len(set(c) & art_set),
                  "beispiele": list(c)[:8]}
            for src, c in sorted(gpc_nums.items(), key=lambda kv: -len(kv[1]))[:40]},
    }
    if dncsv.get("_artikel"):
        cover["datanorm_gesamt_csv"]["davon_in_artikelliste"] = len(dncsv["_artikel"] & art_set)
    if arts:
        fam_total = collections.Counter(arts.values())
        fam_dn = collections.Counter(arts[a] for a in dn_arts & art_set)
        cover["abdeckung_nach_familie_top30"] = {
            f: {"artikel": n, "in_datanorm": fam_dn.get(f, 0)} for f, n in fam_total.most_common(30)}
    with open(os.path.join(out, "05_abdeckung.json"), "w", encoding="utf-8") as fh:
        json.dump(cover, fh, ensure_ascii=False, indent=2)

    # Zusammenfassung
    md = ["# Datenaudit – Zusammenfassung", "",
          f"Erstellt: {cover['erstellt']} · Laufzeit: {cover['laufzeit_min']} min", "",
          "## DATANORM", "",
          f"- Dateien analysiert: {len(dn)} (davon Duplikate: {sum(1 for s in dn if s.dup_of)})",
          f"- Grundfos-Dateien (eindeutig): {len(gf_dn)}", ""]
    md.append("| Datei | Hersteller | Datum | Version | Format | Artikel | EAN | Preis | Langtext | Satzarten |")
    md.append("|---|---|---|---|---|---|---|---|---|---|")
    for st in dn:
        if st.dup_of:
            continue
        v = st.v_fields()
        md.append(f"| {st.label} | {st.maker()} | {v['datum']} | {v['version']} | {st.fmt} | "
                  f"{len(st.articles)} | {len(st.with_ean)} | {len(st.with_price)} | {len(st.with_longkey)} | "
                  f"{dict(st.rec)} |")
    g = cover["datanorm_grundfos_gesamt"]
    md += ["", "## Abdeckung Grundfos", "",
           f"- Artikelliste: {len(art_set)} Nummern",
           f"- Grundfos-Artikel in DATANORM: {g['artikel_unique']} (davon in Artikelliste: {g['davon_in_artikelliste']})",
           f"- mit EAN: {g['mit_ean']} · mit Preis: {g['mit_preis']} · mit Langtext-Schlüssel: {g['mit_langtext_schluessel']}",
           "", "## GPC", "", f"- Dateien: {len(gpc_rows)} · Details: `04_gpc_details.md`", ""]
    md.append("| Quelle | verschiedene Grundfos-Nummern | davon in Artikelliste |")
    md.append("|---|---|---|")
    for src, v in cover["gpc_nummern_nach_quelle"].items():
        md.append(f"| {src} | {v['verschiedene']} | {v['davon_in_artikelliste']} |")
    with open(os.path.join(out, "00_zusammenfassung.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")
    log(f"FERTIG in {cover['laufzeit_min']} min → {out}")


if __name__ == "__main__":
    main()
