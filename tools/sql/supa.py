#!/usr/bin/env python3
"""SQL gegen Grundfos-PIM über die Supabase-Management-API ausführen.

Der Zugangsschlüssel wird von der Umgebung automatisch an api.supabase.com angehängt
(Secret in den Umgebungseinstellungen) – er steht nie im Code oder im Repository.

  python3 tools/sql/supa.py "select 1"
  python3 tools/sql/supa.py -f supabase/migrations/2026….sql
"""
import json
import sys
import urllib.request

PROJEKT = "xgpkjxjwcxelskygojvl"
URL = f"https://api.supabase.com/v1/projects/{PROJEKT}/database/query"


def sql(query, timeout=900):
    req = urllib.request.Request(URL, data=json.dumps({"query": query}).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code}: {e.read().decode(errors='replace')[:2000]}")


if __name__ == "__main__":
    args = sys.argv[1:]
    q = open(args[1], encoding="utf-8").read() if args[:1] == ["-f"] else " ".join(args)
    res = sql(q)
    if isinstance(res, list):
        for row in res:
            print(json.dumps(row, ensure_ascii=False, default=str))
    else:
        print(json.dumps(res, ensure_ascii=False))
