#!/usr/bin/env python3
"""
Grundfos-PIM – Import 6: Bilder und Dokumente aus Drive → Supabase Storage (Bucket 'medien', öffentlich lesbar)

Arbeitsliste: pim.medium_datei (status 'offen'), gefüllt von pim.medien_dateien_zuordnen().
Reihenfolge: Produktbilder → Maß-/Schaltbilder → Explosionszeichnungen → Datenblätter/Anleitungen/Service.
  - TIF wird in PNG umgewandelt (Pillow)
  - .np2 (Grundfos-Format): ist der Inhalt eigentlich PNG/GIF/JPEG/PDF, wird er so hochgeladen;
    sonst status 'format_unbekannt' (die ersten Bytes stehen zur Prüfung in medium_datei.fehler)
Nach dem Hochladen: medium_datei.status = 'hochgeladen', pim.medium.storage_pfad / extern_url / sha256 gesetzt.
Ein erneuter Lauf macht dort weiter, wo er aufgehört hat.

Secrets (Colab, Schlüssel-Symbol): SUPABASE_DB_URL und SUPABASE_SERVICE_KEY (Supabase → Project Settings → API Keys:
neuer „Secret key“ sb_secret_… oder alter „service_role“-Schlüssel). Der Schlüssel wird nur für den Upload benutzt und nirgends gespeichert oder ausgegeben.
"""

import hashlib
import io
import os
import time
import urllib.error
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

import psycopg

from datanorm_import import conn_params, db_url
from datenaudit import log

SUPABASE_URL = "https://xgpkjxjwcxelskygojvl.supabase.co"
BUCKET = "medien"
PAKET = 300
THREADS = 8
MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
        ".pdf": "application/pdf", ".tif": "image/tiff"}
REIHENFOLGE = """case m.typ when 'bild' then 1 when 'massbild' then 2 when 'schaltbild' then 3
                 when 'explosionszeichnung' then 4 when 'datenblatt' then 5 when 'anleitung' then 6 else 7 end"""


def erkenne(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:3] == b"GIF":
        return ".gif"
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:4] == b"%PDF":
        return ".pdf"
    if data[:4] in (b"II*\x00", b"MM\x00*"):
        return ".tif"
    return None


def aufbereiten(data, ext, ziel):
    """→ (bytes, ziel_pfad, content_type) oder (None, fehlertext)"""
    art = erkenne(data) or (ext if ext in MIME else None)
    if art in (".tif",):
        from PIL import Image
        img = Image.open(io.BytesIO(data))
        if img.mode not in ("RGB", "RGBA", "L", "LA", "P"):
            img = img.convert("RGB")
        out = io.BytesIO()
        img.save(out, "PNG", optimize=True)
        return out.getvalue(), os.path.splitext(ziel)[0] + ".png", "image/png"
    if art is None:
        return None, "unbekanntes Format, Anfang: " + data[:16].hex()
    if not ziel.lower().endswith(art):
        ziel = os.path.splitext(ziel)[0] + art
    return data, ziel, MIME[art]


def hochladen(key, ziel, data, ctype):
    kopf = {"apikey": key, "x-upsert": "true", "Content-Type": ctype, "Cache-Control": "max-age=31536000"}
    if not key.startswith("sb_secret_"):   # alter service_role-Schlüssel (JWT) zusätzlich als Bearer; neue nicht
        kopf["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(f"{SUPABASE_URL}/storage/v1/object/{BUCKET}/{ziel}", data=data, method="POST",
                                 headers=kopf)
    err = ""
    for versuch in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                r.read()
            return None
        except urllib.error.HTTPError as e:
            if e.code < 500:
                return f"HTTP {e.code}: {e.read()[:200]!r}"
            err = f"HTTP {e.code}"
        except Exception as e:  # noqa: BLE001 – Netzfehler: erneut versuchen
            err = repr(e)
        time.sleep(2 ** versuch)
    return f"Upload fehlgeschlagen: {err}"


def run(root="/content/drive/MyDrive", nur_typen=None):
    key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not key:
        raise SystemExit("Secret SUPABASE_SERVICE_KEY fehlt")
    t0, ok, fehl, unbek = time.time(), 0, 0, 0
    zips = {}
    with psycopg.connect(**conn_params(db_url()), autocommit=True) as con, con.cursor() as cur:
        while True:
            cur.execute(f"""select d.medium_id, d.basis, d.container, d.pfad, d.ext, d.ziel_pfad
                              from pim.medium_datei d join pim.medium m on m.id = d.medium_id
                             where d.status = 'offen' {"and m.typ = any(%s)" if nur_typen else ""}
                             order by {REIHENFOLGE}, d.basis, d.container, d.pfad limit {PAKET}""",
                        (nur_typen,) if nur_typen else None)
            rows = cur.fetchall()
            if not rows:
                break
            jobs, gesehen = [], set()
            for mid, basis, container, pfad, ext, ziel in rows:
                if ziel in gesehen:
                    continue
                gesehen.add(ziel)
                try:
                    if container:
                        zp = os.path.join(root, basis, container)
                        if zp not in zips:
                            zips[zp] = zipfile.ZipFile(zp)
                        data = zips[zp].read(pfad)
                    else:
                        with open(os.path.join(root, basis, pfad), "rb") as fh:
                            data = fh.read()
                    res = aufbereiten(data, ext, ziel)
                except Exception as e:  # noqa: BLE001
                    res = (None, f"Lesefehler: {e!r}"[:500])
                jobs.append((mid, ziel, res))

            def lade(job):
                mid, alt, res = job
                if res[0] is None:
                    return mid, alt, None, None, res[1]
                data, ziel, ctype = res
                return mid, alt, ziel, hashlib.sha256(data).hexdigest(), hochladen(key, ziel, data, ctype)

            with ThreadPoolExecutor(THREADS) as ex:
                for mid, alt, ziel, sha, err in ex.map(lade, jobs):
                    # dieselbe Datei hängt oft an mehreren Medien (z. B. Literatur je Sprache/Markt):
                    # einmal hochladen, alle Medien mit demselben Ziel auf einmal setzen
                    if err is None:
                        cur.execute("update pim.medium set storage_pfad = %s, extern_url = pim.medien_url(%s), sha256 = %s"
                                    " where id in (select medium_id from pim.medium_datei"
                                    "               where ziel_pfad = %s and status = 'offen')",
                                    (f"{BUCKET}/{ziel}", ziel, sha, alt))
                        cur.execute("update pim.medium_datei set status = 'hochgeladen', ziel_pfad = %s, fehler = null,"
                                    " geaendert_am = now() where ziel_pfad = %s and status = 'offen'", (ziel, alt))
                        ok += 1
                    else:
                        st = "format_unbekannt" if err.startswith("unbekanntes Format") else "fehler"
                        unbek += st == "format_unbekannt"
                        fehl += st == "fehler"
                        cur.execute("update pim.medium_datei set status = %s, fehler = %s, geaendert_am = now()"
                                    " where ziel_pfad = %s and status = 'offen'", (st, err[:500], alt))
            log(f"  hochgeladen {ok:,} · Fehler {fehl:,} · Format unbekannt {unbek:,} · {(time.time() - t0) / 60:.1f} min")
    log(f"FERTIG: {ok:,} Dateien hochgeladen, {fehl:,} Fehler, {unbek:,} unbekanntes Format")


if __name__ == "__main__":
    run()
