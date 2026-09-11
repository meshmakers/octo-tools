#!/usr/bin/env python3
"""Produktkennzahlen aus Azure DevOps -- absichtlich zwei Zahlen, nicht zehn.

Warum keine Bug-Laufzeit und keine Bug-Menge: Bugs werden hier selbst eingetragen
und meist am selben Tag behoben (AB#4931: angelegt 09:46, geschlossen 21:30). Eine
Laufzeit misst dann die Tippgeschwindigkeit. Eine Menge misst die Meldedisziplin --
wer sauberer dokumentiert, saehe schlechter aus.

Was stattdessen gemessen wird:

  Bug-zu-Issue-Verhaeltnis   Von allen neu angelegten Work Items der Anteil Bugs.
                             Beide Seiten unterliegen derselben Meldedisziplin,
                             der Quotient kuerzt sie heraus.
  Escape-Anteil              Anteil der Bugs, bei denen CreatedBy != ResolvedBy --
                             also jemand anderes den Fehler gefunden hat als der,
                             der ihn behoben hat. Faellt beides zusammen, hat die
                             Entwicklung ihn selbst bemerkt: das ist ein
                             Qualitaetsbeweis, kein Makel.

AreaPath wird mitgeschrieben, aber NICHT zur Unterscheidung benutzt: in einer
Stichprobe vergleichbarer Bugs stand mal "OctoMesh", mal "OctoMesh\\Product Team".
"""
import base64, json, os, sys, urllib.request, urllib.error
from collections import defaultdict
from datetime import datetime, timezone

API = "7.1"
BATCH = 200
FIELDS = ["System.Id", "System.WorkItemType", "System.CreatedDate", "System.CreatedBy",
          "System.AssignedTo", "System.State", "System.AreaPath",
          "Microsoft.VSTS.Common.ResolvedBy", "Microsoft.VSTS.Common.ClosedDate"]


def _post(url, pat, payload):
    body = json.dumps(payload).encode()
    auth = base64.b64encode(f":{pat}".encode()).decode()
    req = urllib.request.Request(url, data=body, headers={
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "meshmakers-quality-report"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read().decode())


def check_pat(org, project, pat):
    """Frueh und verstaendlich scheitern statt mit einem 203 mitten im Lauf.

    Azure DevOps antwortet auf einen ungueltigen PAT mit 203 und einer HTML-Login-
    Seite statt mit 401 -- ein blanker JSONDecodeError waere die Folge."""
    try:
        _post(f"https://dev.azure.com/{org}/{project}/_apis/wit/wiql?api-version={API}",
              pat, {"query": "SELECT [System.Id] FROM WorkItems "
                             "WHERE [System.WorkItemType] = 'Bug'"})
    except urllib.error.HTTPError as e:
        raise SystemExit(f"::error::ADO_PAT wird von {org}/{project} abgelehnt "
                         f"(HTTP {e.code}). Noetig ist Work Items (Read).")
    except json.JSONDecodeError:
        raise SystemExit(f"::error::ADO_PAT ungueltig oder abgelaufen -- "
                         f"{org}/{project} liefert eine Login-Seite statt JSON.")


def identity(value):
    """Die REST-API liefert ein Identity-Objekt, der MCP-Server einen String."""
    if isinstance(value, dict):
        return (value.get("uniqueName") or value.get("displayName") or "").lower()
    if isinstance(value, str):
        return value.split("<")[-1].strip(" >").lower() or value.lower()
    return ""


def collect(org, project, pat, since_iso):
    check_pat(org, project, pat)
    base = f"https://dev.azure.com/{org}/{project}/_apis/wit"
    since = since_iso[:10]
    wiql = (f"SELECT [System.Id] FROM WorkItems "
            f"WHERE [System.TeamProject] = '{project}' "
            f"AND [System.WorkItemType] IN ('Bug', 'Issue') "
            f"AND [System.CreatedDate] >= '{since}' "
            f"ORDER BY [System.CreatedDate]")
    ids = [w["id"] for w in
           _post(f"{base}/wiql?api-version={API}", pat, {"query": wiql})["workItems"]]

    items = []
    for i in range(0, len(ids), BATCH):
        items += _post(f"{base}/workitemsbatch?api-version={API}", pat,
                       {"ids": ids[i:i + BATCH], "fields": FIELDS})["value"]

    months = defaultdict(lambda: {"bugs": 0, "issues": 0,
                                  "bugs_resolved": 0, "escaped": 0})
    areas = defaultdict(lambda: {"bugs": 0, "issues": 0})
    for it in items:
        f = it.get("fields", {})
        created = f.get("System.CreatedDate", "")
        if not created:
            continue
        key = created[:7]
        kind = f.get("System.WorkItemType")
        area = f.get("System.AreaPath", "?")
        if kind == "Bug":
            months[key]["bugs"] += 1
            areas[area]["bugs"] += 1
            resolver = identity(f.get("Microsoft.VSTS.Common.ResolvedBy"))
            if resolver:
                months[key]["bugs_resolved"] += 1
                if resolver != identity(f.get("System.CreatedBy")):
                    months[key]["escaped"] += 1
        elif kind == "Issue":
            months[key]["issues"] += 1
            areas[area]["issues"] += 1

    series = []
    for key in sorted(months):
        m = months[key]
        total = m["bugs"] + m["issues"]
        series.append({
            "month": key,
            "bugs": m["bugs"], "issues": m["issues"],
            "bug_ratio": round(m["bugs"] / total, 4) if total else None,
            "bugs_resolved": m["bugs_resolved"], "escaped": m["escaped"],
            "escape_ratio": round(m["escaped"] / m["bugs_resolved"], 4)
                            if m["bugs_resolved"] else None,
        })
    return {
        "project": project,
        "since": since,
        "work_items": len(items),
        "months": series,
        "areas": {k: v for k, v in sorted(areas.items())},
        "caveat": "Vor der konsequenten Erfassung (ab etwa Mitte 2026) sind die "
                  "Monatswerte nicht vergleichbar -- der Anstieg misst dort die "
                  "Meldedisziplin, nicht die Fehlerzahl.",
    }


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default="meshmakers")
    ap.add_argument("--project", default="OctoMesh")
    ap.add_argument("--since", required=True, help="ISO-Datum")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    pat = os.environ.get("ADO_PAT")
    if not pat:
        sys.exit("::error::ADO_PAT nicht gesetzt.")
    data = collect(args.org, args.project, pat, args.since)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    last = data["months"][-1] if data["months"] else {}
    print(f"{data['work_items']} Work Items, {len(data['months'])} Monate. "
          f"Zuletzt: Bug-Anteil {last.get('bug_ratio')}, "
          f"Escape {last.get('escape_ratio')}.", file=sys.stderr)


if __name__ == "__main__":
    main()
