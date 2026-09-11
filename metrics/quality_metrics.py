#!/usr/bin/env python3
"""Quality metrics across the meshmakers GitHub org -- deliberately not volume.

The weekly and monthly reports answer "how much code is there". This one answers
"is it holding together". Three blocks:

  Architektur  Schichtregeln gegen den .NET-Projekt- und Paketgraphen. Beim ersten
               Lauf (2026-09) waren 207 Projekte in 38 Repos verletzungsfrei -- der
               Wert liegt also nicht im Aufraeumen, sondern darin, dass Verfall
               auffaellt, bevor er sich festsetzt.
  Code         Test-Anteil, Komplexitaetsdichte, Rework-Rate.
  Produkt      (noch nicht enthalten) Bug-zu-Issue-Verhaeltnis aus Azure DevOps.

Warum keine Bug-Laufzeit: Bugs werden hier selbst eingetragen und meist am selben
Tag gefixt (AB#4931: angelegt 09:46, geschlossen 21:30). Eine Laufzeitmetrik misst
in diesem Arbeitsmodus die Tippgeschwindigkeit, nicht die Qualitaet.

Emits a single JSON snapshot; --previous rechnet Deltas gegen einen frueheren Lauf.
"""
import argparse, json, os, re, subprocess, sys, tempfile
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collect_metrics import (                                    # noqa: E402
    CODE_LANGS, is_generated, lang_of, looks_minified, decision_points,
    lfs_paths, git, git_auth_env, redact, check_token, gh_api,
)

# --------------------------------------------------------------- Schichtmodell
# Die Schicht steckt im Projektnamen -- das ist hier keine Konvention auf dem
# Papier, sondern durchgehalten: ConstructionKit.Contracts, Runtime.Engine,
# Infrastructure, *.Tests. Der Fan-in bestaetigt sie (Runtime.Contracts 38x,
# Runtime.Engine 5x): die Vertragsschicht ist die meistgenutzte, die
# Implementierung die seltenste.
TEST_SUFFIXES = (".Tests", ".SystemTests", ".IntegrationTests", ".UnitTests")
BUILD_SUFFIXES = (".SourceGeneration", ".MsBuildTasks", ".Templates")
# Testfixtures heissen nicht immer *.Tests: AssetRepositoryIntegrationTestCkModel
# ist ein CK-Modell, das nur Tests brauchen -- und wurde vom Produktionsprojekt
# AssetRepositoryServices referenziert.
TEST_MARKER = re.compile(r"(IntegrationTest|UnitTest|TestCkModel|TestAssembly|\bMocks?\b)")

def layer_of(project: str) -> str:
    if project.endswith(TEST_SUFFIXES) or TEST_MARKER.search(project):
        return "Tests"
    if project.endswith(".Contracts"):
        return "Contracts"
    if project.endswith(BUILD_SUFFIXES):
        return "Build"
    return "Impl"

# Persistenztechnologie darf nur hier auftauchen. Ueberall sonst ist sie
# durchgereicht -- genau dagegen existiert der OctoObjectId-Wrapper in
# ConstructionKit.Contracts.
PERSISTENCE_NS = ("MongoDB.", "MongoDB", "Crate.", "CrateDb.", "Npgsql")
# Dateipfade, in denen der Import erlaubt ist ...
PERSISTENCE_OK = re.compile(
    r"(persistence|repositor|store|provider|program|startup|registration|module|"
    r"extensions|migration|fixture|testcontainer)", re.I)
# ... und Projekte, deren Aufgabe die Persistenz IST. Ohne diese Ausnahme meldet
# die Regel Runtime.Engine.MongoDb an sich selbst -- 15 Fehlalarme im ersten Lauf.
PERSISTENCE_PROJECT = re.compile(
    r"\.(MongoDb|CrateDb|Postgres|Npgsql|Sql|Persistence)$", re.I)

# Typen, an denen echte Nutzung eines Persistenz-Namespaces erkennbar ist. Den
# Namespace selbst zu suchen geht schief: Code schreibt IMongoCollection, nicht
# MongoDB.Driver.IMongoCollection. ObjectId braucht die Lookbehind-Sperre, sonst
# matcht der hauseigene OctoObjectId und jede Datei gilt als sauber.
PERSISTENCE_USE = re.compile(
    r"(?<![\w.])(Bson\w*|I?Mongo\w*|ObjectId|Npgsql\w*|Crate[A-Z]\w*)\b")

PROJECT_REF = re.compile(r'<ProjectReference\s+[^>]*Include="([^"]+)"', re.I)
PACKAGE_REF = re.compile(r'<PackageReference\s+[^>]*Include="([^"]+)"', re.I)
OWN_PACKAGE = re.compile(r"^(Meshmakers|Octo)\.", re.I)
USING_RE = re.compile(r"^\s*using\s+(?:static\s+)?([A-Za-z_][\w.]*)\s*;", re.M)

def is_test_path(path: str) -> bool:
    """Testcode nach Pfad und Dateiname. Beides noetig: .NET legt Tests in
    tests/<Projekt>.Tests/, Angular dagegen .spec.ts neben die Quelldatei."""
    low = path.lower()
    if "/tests/" in low or low.startswith("tests/") or "/test/" in low:
        return True
    base = os.path.basename(low)
    return base.endswith((".spec.ts", ".test.ts", ".spec.js", ".test.js",
                          "_test.go", "tests.cs", "test.cs", "_test.py"))


def scan_projects(repo_name, repo_path):
    """.csproj-Graph eines Repos: Projektverweise, eigene Paketverweise, Schicht."""
    projects = {}
    try:
        out = git(repo_path, "ls-files", "-z", "*.csproj")
    except Exception:
        return projects
    for rel in (f for f in out.split("\0") if f):
        name = os.path.basename(rel)[:-7]
        try:
            with open(os.path.join(repo_path, rel), encoding="utf-8-sig",
                      errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        projects[name] = {
            "repo": repo_name,
            "path": rel,
            "layer": layer_of(name),
            "project_refs": sorted({os.path.basename(i.replace("\\", "/"))[:-7]
                                    for i in PROJECT_REF.findall(text)}),
            "package_refs": sorted({p for p in PACKAGE_REF.findall(text)
                                    if OWN_PACKAGE.match(p)}),
        }
    return projects


def scan_persistence_leaks(repo_name, repo_path, projects):
    """C#-Dateien, die Persistenz-Namespaces importieren, wo sie nichts zu suchen
    haben -- und solche, die den Import tragen, ohne einen Typ daraus zu nutzen.

    Die Unterscheidung ist der ganze Witz: fuenf Identity-Controller importierten
    MongoDB.Bson, benutzten daraus aber nichts (alle 33 ObjectId-Treffer waren der
    eigene OctoObjectId). Tote Usings sind Aufraeumarbeit, kein Schichtbruch -- sie
    getrennt zu zaehlen verhindert einen Fehlalarm, der die Metrik unglaubwuerdig
    macht.

    Testcode zaehlt nicht: Integrationstests der Persistenzschicht MUESSEN die
    Treiber-Typen anfassen, sonst testen sie nichts.
    """
    leaks, dead = [], []
    # Verzeichnis -> Projektname, laengster Treffer gewinnt: so weiss eine Datei,
    # zu welchem Projekt sie gehoert, und Runtime.Engine.MongoDb darf MongoDB.
    owners = sorted(((os.path.dirname(p["path"]), name)
                     for name, p in projects.items()), key=lambda x: -len(x[0]))
    try:
        files = [f for f in git(repo_path, "ls-files", "-z", "*.cs").split("\0") if f]
    except Exception:
        return leaks, dead
    for rel in files:
        if is_generated(rel) or is_test_path(rel):
            continue
        try:
            with open(os.path.join(repo_path, rel), encoding="utf-8",
                      errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        hits = [ns for ns in USING_RE.findall(text)
                if ns.startswith(PERSISTENCE_NS)]
        if not hits:
            continue
        owner = next((n for d, n in owners if d and rel.startswith(d + "/")), None)
        entry = {"repo": repo_name, "path": rel, "project": owner,
                 "namespaces": sorted(set(hits))}
        if not PERSISTENCE_USE.search(USING_RE.sub("", text)):
            dead.append(entry)
        elif not (PERSISTENCE_OK.search(rel)
                  or (owner and PERSISTENCE_PROJECT.search(owner))):
            leaks.append(entry)
    return leaks, dead


def scan_loc(repo_name, repo_path):
    """LOC, Komplexitaet und Test-Anteil am HEAD-Baum.

    Bewusst dieselben Filter wie collect_metrics (generierter Code, Lockfiles, LFS,
    Minified) -- sonst widersprechen sich Volumen- und Qualitaetsreport."""
    acc = {"prod_loc": 0, "test_loc": 0, "prod_files": 0, "test_files": 0,
           "code_loc": 0, "decisions": 0, "langs": defaultdict(
               lambda: {"prod": 0, "test": 0})}
    try:
        files = [f for f in git(repo_path, "ls-files", "-z").split("\0") if f]
    except Exception:
        return acc
    lfs = lfs_paths(repo_path)
    for rel in files:
        lang = lang_of(rel)
        if not lang or is_generated(rel) or rel in lfs:
            continue
        try:
            with open(os.path.join(repo_path, rel), "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        loc = data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)
        if looks_minified(data, loc):
            continue
        test = is_test_path(rel)
        acc["test_loc" if test else "prod_loc"] += loc
        acc["test_files" if test else "prod_files"] += 1
        acc["langs"][lang]["test" if test else "prod"] += loc
        if lang in CODE_LANGS and not test:
            acc["code_loc"] += loc
            if len(data) < 4_000_000:
                try:
                    acc["decisions"] += decision_points(
                        data.decode("utf-8", "replace"), lang)
                except Exception:
                    pass
    acc["langs"] = {k: dict(v) for k, v in acc["langs"].items()}
    return acc


REWORK_WINDOW_DAYS = 30

def scan_rework(repo_path, since_iso, window_days=REWORK_WINDOW_DAYS):
    """Anteil der Aenderungen an Code, der juenger als `window_days` ist.

    Ein Durchlauf durch die Historie in chronologischer Reihenfolge, der je Datei
    den letzten Anfasszeitpunkt mitfuehrt. Faellt eine Aenderung im Auswertefenster
    auf eine Datei, die vor weniger als 30 Tagen zuletzt geaendert wurde, zaehlen
    ihre Zeilen als Rework.

    Diese Zahl ist der Ersatz fuer die Bug-Statistik: wer einen Fehler bemerkt und
    sofort behebt, legt dafuer kein Work Item an -- aber der Fix ist ein Commit auf
    frischem Code und taucht hier auf.
    """
    try:
        out = git(repo_path, "log", "--reverse", "--no-merges", "--numstat",
                  "--format=\x1e%H\x1f%aI")
    except Exception:
        return {"changed": 0, "rework": 0}
    since = datetime.fromisoformat(since_iso)
    last_touch, changed, rework = {}, 0, 0
    for chunk in out.split("\x1e"):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        head, _, rest = chunk.partition("\n")
        parts = head.split("\x1f")
        if len(parts) < 2:
            continue
        try:
            when = datetime.fromisoformat(parts[1])
        except ValueError:
            continue
        in_window = when >= since
        for line in rest.split("\n"):
            cols = line.split("\t")
            if len(cols) != 3 or cols[0] == "-":
                continue
            a, d, path = cols
            if is_generated(path) or is_test_path(path) or not lang_of(path):
                continue
            lines = int(a) + int(d)
            prev = last_touch.get(path)
            if in_window and lines:
                changed += lines
                if prev is not None and (when - prev).days < window_days:
                    rework += lines
            last_touch[path] = when
    return {"changed": changed, "rework": rework}


def check_rules(projects):
    """Die Schichtregeln gegen den Projektgraphen. Reihenfolge = Schwere."""
    findings = defaultdict(list)

    for name, p in sorted(projects.items()):
        if p["layer"] == "Contracts":
            for dep in p["project_refs"]:
                if projects.get(dep, {}).get("layer") == "Impl":
                    findings["contracts_to_impl"].append(
                        {"repo": p["repo"], "from": name, "to": dep})
        if p["layer"] != "Tests":
            for dep in p["project_refs"]:
                if dep in projects and projects[dep]["layer"] == "Tests":
                    findings["prod_to_test"].append(
                        {"repo": p["repo"], "from": name, "to": dep})

    # Zyklen: iteratives DFS, damit tiefe Graphen nicht den Stack sprengen.
    WHITE, GREY, BLACK = 0, 1, 2
    colour = defaultdict(int)
    for root in sorted(projects):
        if colour[root] != WHITE:
            continue
        stack = [(root, iter(projects[root]["project_refs"]))]
        path = [root]
        colour[root] = GREY
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                colour[node] = BLACK
                stack.pop(); path.pop()
                continue
            if nxt not in projects:
                continue
            if colour[nxt] == GREY:
                findings["cycles"].append(path[path.index(nxt):] + [nxt])
            elif colour[nxt] == WHITE:
                colour[nxt] = GREY
                path.append(nxt)
                stack.append((nxt, iter(projects[nxt]["project_refs"])))
    return {k: v for k, v in findings.items()}


def package_fanin(projects):
    fan = Counter()
    for p in projects.values():
        for pkg in p["package_refs"]:
            fan[pkg] += 1
    contracts = sum(v for k, v in fan.items() if k.endswith(".Contracts"))
    engine = sum(v for k, v in fan.items()
                 if ".Engine" in k and not k.endswith(".Contracts"))
    return fan, contracts, engine


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default="meshmakers")
    ap.add_argument("--mode", choices=["clone", "local"], default="clone")
    ap.add_argument("--local-root", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--previous", default=None)
    ap.add_argument("--exclude", default="", help="comma separated automation repos")
    ap.add_argument("--days", type=int, default=30, help="Fenster fuer die Rework-Rate")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    until = datetime.now(timezone.utc)
    since_iso = (until - timedelta(days=args.days)).isoformat()
    automation = {r.strip() for r in args.exclude.split(",") if r.strip()}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    workdir = None
    if args.mode == "local":
        root = args.local_root or os.getcwd()
        targets = [(d, os.path.join(root, d)) for d in sorted(os.listdir(root))
                   if os.path.isdir(os.path.join(root, d, ".git"))]
    else:
        check_token(token, args.org)
        repos = [r for r in gh_api(f"orgs/{args.org}/repos?per_page=100&type=all", token)
                 if not r.get("archived") and not r.get("fork")]
        only = {x.strip() for x in args.only.split(",") if x.strip()}
        if only:
            repos = [r for r in repos if r["name"] in only]
        workdir = tempfile.mkdtemp(prefix="quality-")
        genv = git_auth_env(token)

        def clone(r):
            dst = os.path.join(workdir, r["name"])
            url = f"https://github.com/{args.org}/{r['name']}.git"
            try:
                subprocess.run(["git", "clone", "--quiet", "--single-branch",
                                "--depth", "400", url, dst],
                               capture_output=True, check=True, timeout=900, env=genv)
                return (r["name"], dst)
            except Exception as e:
                print(f"::warning::clone failed {r['name']}: "
                      f"{redact(str(e)[:200], token)}", file=sys.stderr)
                return None
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            targets = [t for t in ex.map(clone, repos) if t]

    targets = [(n, p) for n, p in targets if n not in automation]

    projects, leaks, dead_usings = {}, [], []
    loc = {"prod_loc": 0, "test_loc": 0, "prod_files": 0, "test_files": 0,
           "code_loc": 0, "decisions": 0}
    langs = defaultdict(lambda: {"prod": 0, "test": 0})
    rework = {"changed": 0, "rework": 0}
    per_repo = {}

    def analyse(target):
        name, path = target
        p = scan_projects(name, path)
        lk, dd = scan_persistence_leaks(name, path, p)
        return name, p, lk, dd, scan_loc(name, path), scan_rework(path, since_iso, args.days)

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, p, lk, dd, lc, rw in ex.map(analyse, targets):
            projects.update(p)
            leaks += lk
            dead_usings += dd
            for k in loc:
                loc[k] += lc[k]
            for lang, v in lc["langs"].items():
                langs[lang]["prod"] += v["prod"]
                langs[lang]["test"] += v["test"]
            rework["changed"] += rw["changed"]
            rework["rework"] += rw["rework"]
            per_repo[name] = {
                "projects": len(p),
                "prod_loc": lc["prod_loc"], "test_loc": lc["test_loc"],
                "test_ratio": round(lc["test_loc"] / lc["prod_loc"], 4) if lc["prod_loc"] else None,
                "complexity_density": round(lc["decisions"] / lc["code_loc"] * 1000, 1)
                                      if lc["code_loc"] else None,
                "rework_ratio": round(rw["rework"] / rw["changed"], 4) if rw["changed"] else None,
            }

    findings = check_rules(projects)
    fan, fan_contracts, fan_engine = package_fanin(projects)

    snapshot = {
        "generated_at": until.isoformat(),
        "org": args.org,
        "window": {"days": args.days, "since": since_iso, "until": until.isoformat()},
        "repos_scanned": len(targets),
        "architecture": {
            "projects": len(projects),
            "project_refs": sum(len(p["project_refs"]) for p in projects.values()),
            "layers": dict(Counter(p["layer"] for p in projects.values())),
            "violations": {
                "contracts_to_impl": findings.get("contracts_to_impl", []),
                "prod_to_test": findings.get("prod_to_test", []),
                "cycles": findings.get("cycles", []),
                "persistence_leak": leaks,
            },
            "dead_usings": dead_usings,
            "package_fanin": dict(fan.most_common(25)),
            "fanin_contracts": fan_contracts,
            "fanin_engine": fan_engine,
        },
        "code": {
            "prod_loc": loc["prod_loc"], "test_loc": loc["test_loc"],
            "prod_files": loc["prod_files"], "test_files": loc["test_files"],
            "test_ratio": round(loc["test_loc"] / loc["prod_loc"], 4) if loc["prod_loc"] else None,
            "code_loc": loc["code_loc"], "decisions": loc["decisions"],
            "complexity_density": round(loc["decisions"] / loc["code_loc"] * 1000, 1)
                                  if loc["code_loc"] else None,
            "rework": rework,
            "rework_ratio": round(rework["rework"] / rework["changed"], 4)
                            if rework["changed"] else None,
            "langs": {k: dict(v) for k, v in sorted(langs.items())},
        },
        "repos": dict(sorted(per_repo.items())),
    }

    if args.previous and os.path.exists(args.previous):
        try:
            with open(args.previous, encoding="utf-8") as fh:
                prev = json.load(fh)
            snapshot["delta"] = {
                "test_ratio": _delta(snapshot["code"]["test_ratio"],
                                     prev.get("code", {}).get("test_ratio")),
                "complexity_density": _delta(snapshot["code"]["complexity_density"],
                                             prev.get("code", {}).get("complexity_density")),
                "rework_ratio": _delta(snapshot["code"]["rework_ratio"],
                                       prev.get("code", {}).get("rework_ratio")),
                "violations": _delta(
                    sum(len(v) for v in snapshot["architecture"]["violations"].values()),
                    sum(len(v) for v in prev.get("architecture", {})
                        .get("violations", {}).values())),
                "previous_generated_at": prev.get("generated_at"),
            }
        except Exception as e:
            print(f"::warning::previous snapshot unreadable: {str(e)[:160]}", file=sys.stderr)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh, ensure_ascii=False, indent=1)

    v = snapshot["architecture"]["violations"]
    print(f"{len(targets)} Repos, {len(projects)} Projekte. "
          f"Verletzungen: contracts->impl {len(v['contracts_to_impl'])}, "
          f"prod->test {len(v['prod_to_test'])}, Zyklen {len(v['cycles'])}, "
          f"Persistenz {len(v['persistence_leak'])}, tote Usings {len(dead_usings)}. "
          f"Test-Anteil {snapshot['code']['test_ratio']}, "
          f"Rework {snapshot['code']['rework_ratio']}.", file=sys.stderr)


def _delta(now, before):
    if now is None or before is None:
        return None
    return round(now - before, 4)


if __name__ == "__main__":
    main()
