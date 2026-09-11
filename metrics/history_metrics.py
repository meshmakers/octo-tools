#!/usr/bin/env python3
"""Monthly history of commits and lines of code per language, across all repos.

With --exact (what the workflow uses) LOC is *measured*: for every month that
had commits, the tree of that month's last commit is read straight from the git
objects via ls-tree + cat-file --batch, with no checkout; quiet months carry the
previous value forward.

Without --exact it falls back to *integrating* `git log --numstat` (running sum
of added minus deleted per language), the method GitHub's code-frequency graph
uses. That variant came out +16.9% above the real line count on this org, so it
is kept only as a cheap approximation.

Either way the result is calibrated against the actually measured LOC at HEAD
and the drift is reported, so the error is visible instead of implied.
"""
import argparse, json, os, subprocess, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collect_metrics import (LANG, CODE_LANGS, CONFIG_LANGS, DOC_LANGS,
                             is_generated, lang_of, scan_tree, git, gh_api,
                             looks_minified, git_auth_env, redact, check_token)

LFS_MAGIC = b"version https://git-lfs.github.com/spec/"

SEP = "\x1e"

def measure_at(repo, sha):
    """Exact LOC per language for the tree at `sha`, read straight from git objects."""
    try:
        tree = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "-z", sha],
                              capture_output=True, timeout=600)
        if tree.returncode != 0:
            return {}
    except Exception:
        return {}
    oids, langs = [], []
    for entry in tree.stdout.decode("utf-8", "replace").split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        bits = meta.split()
        if len(bits) < 3 or bits[1] != "blob":
            continue
        lang = lang_of(path)
        if not lang or is_generated(path):
            continue
        oids.append(bits[2])
        langs.append(lang)
    if not oids:
        return {}
    try:
        proc = subprocess.run(["git", "-C", repo, "cat-file", "--batch"],
                              input=("\n".join(oids) + "\n").encode(),
                              capture_output=True, timeout=1800)
    except Exception:
        return {}
    out, pos, i, res = proc.stdout, 0, 0, defaultdict(int)
    n = len(out)
    while pos < n and i < len(langs):
        nl = out.find(b"\n", pos)
        if nl < 0:
            break
        header = out[pos:nl].split()
        pos = nl + 1
        if len(header) < 3:           # "<oid> missing"
            i += 1
            continue
        size = int(header[2])
        blob = out[pos:pos + size]
        pos += size + 1               # trailing newline after the blob
        if b"\0" not in blob[:8192] and not blob.startswith(LFS_MAGIC):
            lines = blob.count(b"\n") + (1 if blob and not blob.endswith(b"\n") else 0)
            if not looks_minified(blob, lines):
                res[langs[i]] += lines
        i += 1
    return dict(res)

def month_end_shas(repo, months_with_commits):
    """Last commit of each month that had commits."""
    out = {}
    for m in months_with_commits:
        y, mo = int(m[:4]), int(m[5:7])
        ny, nmo = (y + 1, 1) if mo == 12 else (y, mo + 1)
        try:
            sha = git(repo, "rev-list", "-1", f"--before={ny:04d}-{nmo:02d}-01T00:00:00",
                      "HEAD").strip()
            if sha:
                out[m] = sha
        except Exception:
            pass
    return out

def month_range(first, last):
    y, m = (int(x) for x in first.split("-"))
    ly, lm = (int(x) for x in last.split("-"))
    out = []
    while (y, m) <= (ly, lm):
        out.append(f"{y:04d}-{m:02d}")
        m += 1
        if m == 13:
            y, m = y + 1, 1
    return out

def walk(repo):
    """Full default-branch history bucketed by calendar month."""
    fmt = SEP + "%aN%x1f%aI"
    try:
        out = git(repo, "log", "--reverse", "--no-merges", "--numstat",
                  f"--format={fmt}", timeout=1800)
    except Exception as e:
        print(f"::warning:: log failed in {repo}: {str(e)[:160]}", file=sys.stderr)
        return {}
    months = defaultdict(lambda: {"commits": 0, "authors": set(),
                                  "added": defaultdict(int), "deleted": defaultdict(int)})
    for chunk in out.split(SEP):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        head, _, rest = chunk.partition("\n")
        parts = head.split("\x1f")
        if len(parts) < 2:
            continue
        author, date = parts[0], parts[1]
        key = date[:7]
        b = months[key]
        b["commits"] += 1
        b["authors"].add(author)
        for line in rest.split("\n"):
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            a, d, path = cols
            if a == "-" or d == "-" or is_generated(path):
                continue
            lang = lang_of(path)
            if not lang:
                continue
            b["added"][lang] += int(a)
            b["deleted"][lang] += int(d)
    return {k: {"commits": v["commits"], "authors": sorted(v["authors"]),
                "added": dict(v["added"]), "deleted": dict(v["deleted"])}
            for k, v in months.items()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default="meshmakers")
    ap.add_argument("--mode", choices=["clone", "local"], default="local")
    ap.add_argument("--local-root", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--exclude", default="")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--exact", action="store_true",
                    help="measure each month-end tree from git objects instead of "
                         "integrating numstat (slower, no drift)")
    args = ap.parse_args()

    automation = {r.strip() for r in args.exclude.split(",") if r.strip()}

    if args.mode == "local":
        root = args.local_root or os.getcwd()
        targets = [(d, os.path.join(root, d)) for d in sorted(os.listdir(root))
                   if os.path.isdir(os.path.join(root, d, ".git"))]
    else:
        import tempfile
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        check_token(token, args.org)
        # Archivierte Repos und Forks bleiben draussen -- Begruendung in collect_metrics.py.
        repos = [r for r in gh_api(f"orgs/{args.org}/repos?per_page=100&type=all", token)
                 if not r.get("archived") and not r.get("fork")]
        wd = tempfile.mkdtemp(prefix="devhistory-")
        genv = git_auth_env(token)
        def clone(r):
            dst = os.path.join(wd, r["name"])
            url = f"https://github.com/{args.org}/{r['name']}.git"
            try:
                subprocess.run(["git", "clone", "--quiet", "--single-branch", url, dst],
                               capture_output=True, check=True, timeout=1800, env=genv)
                return (r["name"], dst)
            except subprocess.CalledProcessError as e:
                print(f"::warning::clone {r['name']} (exit {e.returncode}): "
                      f"{redact(e.stderr.decode('utf-8', 'replace')[:160], token)}",
                      file=sys.stderr)
                return None
            except Exception as e:
                print(f"::warning::clone {r['name']}: {redact(type(e).__name__, token)}",
                      file=sys.stderr)
                return None
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            targets = [t for t in ex.map(clone, repos) if t]

    def job(item):
        name, path = item
        mm = walk(path)
        exact = {}
        if args.exact and mm:
            for m, sha in month_end_shas(path, sorted(mm)).items():
                exact[m] = measure_at(path, sha)
        return name, mm, scan_tree(path)[0], exact

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(job, targets))

    all_months = sorted({m for _, mm, _, _ in results for m in mm})
    if not all_months:
        sys.exit("keine Commits gefunden")
    months = month_range(all_months[0], all_months[-1])
    idx = {m: i for i, m in enumerate(months)}
    n = len(months)

    commits_h = [0] * n; commits_a = [0] * n
    authors_m = [set() for _ in range(n)]
    add_m = [defaultdict(int) for _ in range(n)]
    del_m = [defaultdict(int) for _ in range(n)]
    repo_first, repo_commits = {}, {}
    measured_head = defaultdict(int)

    exact_cum = [defaultdict(int) for _ in range(n)]
    for name, mm, head_langs, exact in results:
        auto = name in automation
        if mm:
            repo_first[name] = min(mm)
        rc = [0] * n
        for m, v in mm.items():
            i = idx[m]
            rc[i] = v["commits"]
            if auto:
                commits_a[i] += v["commits"]
            else:
                commits_h[i] += v["commits"]
                authors_m[i].update(v["authors"])
            for lang, x in v["added"].items():
                add_m[i][lang] += x
            for lang, x in v["deleted"].items():
                del_m[i][lang] += x
        repo_commits[name] = rc
        for lang, v in head_langs.items():
            measured_head[lang] += v["loc"]
        if args.exact:
            # carry each repo's last known measurement forward through quiet months
            last = {}
            for i, m in enumerate(months):
                if m in exact:
                    last = exact[m]
                for lang, loc in last.items():
                    exact_cum[i][lang] += loc

    langs = sorted({l for d in add_m for l in d} | {l for d in del_m for l in d} |
                   set(measured_head))
    cum = {l: [0] * n for l in langs}
    for l in langs:
        run = 0
        for i in range(n):
            run += add_m[i].get(l, 0) - del_m[i].get(l, 0)
            cum[l][i] = max(run, 0)

    def bucket(keys):
        return [sum(cum[l][i] for l in keys if l in cum) for i in range(n)]

    if args.exact:
        for l in langs:
            cum[l] = [exact_cum[i].get(l, 0) for i in range(n)]
        langs = sorted({l for d in exact_cum for l in d} | set(measured_head))
        for l in langs:
            cum.setdefault(l, [exact_cum[i].get(l, 0) for i in range(n)])

    integrated_final = sum(cum[l][-1] for l in langs)
    measured_total = sum(measured_head.values())

    snap = {
        "months": months,
        "commits": {"human": commits_h, "automation": commits_a,
                    "total": [a + b for a, b in zip(commits_h, commits_a)]},
        "authors_per_month": [len(s) for s in authors_m],
        "loc_cumulative": {l: cum[l] for l in langs if cum[l][-1] > 0 or measured_head.get(l)},
        "loc_total": [sum(cum[l][i] for l in langs) for i in range(n)],
        "buckets": {"code": bucket(CODE_LANGS), "config": bucket(CONFIG_LANGS),
                    "docs": bucket(DOC_LANGS)},
        "churn": {"added": [sum(d.values()) for d in add_m],
                  "deleted": [sum(d.values()) for d in del_m]},
        "repo_first_commit": repo_first,
        "repo_commits": repo_commits,
        "measured_head": dict(measured_head),
        "calibration": {
            "integrated_final": integrated_final,
            "measured_head": measured_total,
            "drift": integrated_final - measured_total,
            "drift_pct": round((integrated_final - measured_total) / measured_total * 100, 1)
            if measured_total else None,
            "per_lang": {l: {"integrated": cum[l][-1], "measured": measured_head.get(l, 0)}
                         for l in langs},
        },
        "method": "exact" if args.exact else "integrated",
        "automation_repos": sorted(automation),
        "repos_scanned": len(results),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    json.dump(snap, open(args.out, "w"), indent=1)
    c = snap["calibration"]
    print(f"{len(results)} Repos | {len(months)} Monate {months[0]}..{months[-1]} | "
          f"{sum(commits_h):,} Commits ({sum(commits_a):,} Automation)")
    print(f"LOC integriert {c['integrated_final']:,} vs. gemessen {c['measured_head']:,} "
          f"-> Drift {c['drift']:+,} ({c['drift_pct']:+}%)")
    print(f"-> {args.out}")

if __name__ == "__main__":
    main()
