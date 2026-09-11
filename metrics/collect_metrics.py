#!/usr/bin/env python3
"""Collect weekly development metrics across the meshmakers GitHub org.

Two modes:
  --clone   clone every non-archived org repo shallowly (used by the GitHub Action)
  --local   analyse existing checkouts in a directory (used for local dry-runs)

Emits a single JSON snapshot. Deltas are computed against a previous snapshot
(--previous), so LOC/complexity trends need at least two runs.
"""
import argparse, base64, json, os, re, subprocess, sys, tempfile, shutil
from collections import defaultdict, Counter
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor

# ---------------------------------------------------------------- language map
LANG = {
    ".cs": "C#", ".csx": "C#", ".razor": "C#", ".cshtml": "C#",
    ".ts": "TypeScript", ".tsx": "TypeScript",
    ".js": "JavaScript", ".jsx": "JavaScript", ".mjs": "JavaScript", ".cjs": "JavaScript",
    ".html": "HTML", ".htm": "HTML",
    ".css": "CSS", ".less": "CSS", ".scss": "SCSS",
    ".py": "Python", ".ps1": "PowerShell", ".psm1": "PowerShell", ".psd1": "PowerShell",
    ".sh": "Shell", ".bash": "Shell", ".zsh": "Shell",
    ".yml": "YAML", ".yaml": "YAML", ".json": "JSON",
    ".xml": "XML", ".csproj": "MSBuild", ".props": "MSBuild", ".targets": "MSBuild", ".sln": "MSBuild",
    ".sql": "SQL", ".graphql": "GraphQL", ".gql": "GraphQL", ".proto": "Protobuf",
    ".go": "Go", ".java": "Java", ".kt": "Kotlin", ".rs": "Rust",
    ".c": "C", ".h": "C", ".cpp": "C++", ".hpp": "C++",
    ".md": "Markdown", ".tf": "Terraform", ".tpl": "Helm", ".vue": "Vue",
    ".swift": "Swift", ".dart": "Dart",
}
# languages that count as "code" (vs. config / docs)
CODE_LANGS = {"C#", "TypeScript", "JavaScript", "HTML", "CSS", "SCSS", "Python", "PowerShell",
              "Shell", "SQL", "GraphQL", "Protobuf", "Go", "Java", "Kotlin", "Rust", "C", "C++",
              "Vue", "Swift", "Dart"}
CONFIG_LANGS = {"YAML", "JSON", "XML", "MSBuild", "Helm", "Terraform"}
DOC_LANGS = {"Markdown"}

LOCK_NAMES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "composer.lock",
              "Cargo.lock", "poetry.lock", "skills-lock.json", "globalTypes.ts",
              "possibleTypes.ts", "schema.graphql", "fragmentTypes.json"}
GEN_PATTERNS = (".designer.cs", ".g.cs", ".generated.cs", ".g.ts", ".generated.ts",
                "/generated/", "/gen/graphql", ".min.js", ".min.css",
                "/dist/", "/node_modules/", "/wwwroot/templates/", "/wwwroot/lib/")
# Published catalogs: one serialised file per released version of every CK model,
# blueprint and chart, written by CI and never edited. They grow monotonically with
# each release -- System.Communication alone carries 26 versions of ~2.900 lines --
# and made up 91% of all "JSON" before being excluded.
CATALOG_PREFIXES = ("ck-models/", "blueprints/v1/", "charts/", "apps/")
GEN_BUNDLE_RE = re.compile(r"^(chunk|main|polyfills|runtime|vendor|styles|scripts|bundle)"
                           r"[-.][A-Za-z0-9]{6,}\.(js|css)$")

def is_generated(path: str) -> bool:
    base = os.path.basename(path)
    if base in LOCK_NAMES:
        return True
    if path.startswith(CATALOG_PREFIXES):
        return True
    low = path.lower()
    if any(p in low for p in GEN_PATTERNS):
        return True
    return bool(GEN_BUNDLE_RE.match(base))

MINIFIED_BYTES_PER_LINE = 300

def looks_minified(data: bytes, loc: int) -> bool:
    """Bundler output that no path pattern catches: thousands of tokens on a
    handful of lines. Counting it wrecks both the LOC total and the complexity
    density (one webpack bundle produced 15.000 decision points on 149 lines)."""
    return loc > 0 and len(data) / loc > MINIFIED_BYTES_PER_LINE

def lang_of(path: str):
    return LANG.get(os.path.splitext(path)[1].lower())

# ------------------------------------------------------------ complexity probe
# Cyclomatic-complexity approximation: count decision points per file.
# Not a substitute for a real analyser -- but stable enough to trend week over week.
CFAMILY = {"C#", "TypeScript", "JavaScript", "Java", "Kotlin", "Go", "Rust", "C", "C++",
           "Swift", "Dart", "Vue", "SQL"}
DECISION_RE = {
    "cfamily": re.compile(r"\b(if|for|foreach|while|case|catch|when)\b|&&|\|\||\?\?|(?<![?:=<>!])\?(?!\?)"),
    "python":  re.compile(r"\b(if|elif|for|while|except|and|or)\b"),
    "powershell": re.compile(r"\b(if|elseif|foreach|for|while|switch|catch)\b|-and\b|-or\b"),
    "shell":   re.compile(r"\b(if|elif|for|while|case)\b|&&|\|\|"),
}
LINE_COMMENT = re.compile(r"//[^\n]*|#[^\n]*")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
STRING_LIT = re.compile(r'"(?:\\.|[^"\\])*"' r"|'(?:\\.|[^'\\])*'" r"|`(?:\\.|[^`\\])*`", re.S)

def decision_points(text: str, lang: str) -> int:
    if lang in CFAMILY:
        key, strip_hash = "cfamily", False
    elif lang == "Python":
        key, strip_hash = "python", False
    elif lang == "PowerShell":
        key, strip_hash = "powershell", False
    elif lang == "Shell":
        key, strip_hash = "shell", False
    else:
        return 0
    body = BLOCK_COMMENT.sub(" ", text)
    body = STRING_LIT.sub('""', body)
    if key == "cfamily":
        body = re.sub(r"//[^\n]*", " ", body)
    elif key in ("python", "shell", "powershell"):
        body = re.sub(r"#[^\n]*", " ", body)
    return len(DECISION_RE[key].findall(body))

# ------------------------------------------------------------------- git auth
def git_auth_env(token):
    """Environment for authenticated clones.

    The token goes in via git's GIT_CONFIG_* env vars, never into the clone URL
    and never onto the command line -- a CalledProcessError stringifies its argv,
    so a tokenised URL would end up verbatim in the Action log.
    """
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_LFS_SKIP_SMUDGE"] = "1"     # LFS content is excluded anyway
    if token:
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
        env["GIT_CONFIG_VALUE_0"] = f"Authorization: Basic {basic}"
    return env

def redact(text, token):
    """Second line of defence before anything git said reaches a log."""
    text = str(text)
    for secret in filter(None, (token, base64.b64encode(
            f"x-access-token:{token}".encode()).decode() if token else None)):
        text = text.replace(secret, "***")
    return text

# ------------------------------------------------------------------- git utils
def git(repo, *args, timeout=300):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {repo}: "
                           f"{r.stderr.decode('utf-8', 'replace')[:400]}")
    return r.stdout.decode("utf-8", "replace")

def lfs_paths(repo):
    """Files stored via Git LFS. Their working-tree content is data, not source,
    and in the object store they are 130-byte pointers -- counting them would make
    the working-tree scan and the object-store scan disagree."""
    try:
        return {f for f in git(repo, "ls-files", "-z", ":(attr:filter=lfs)").split("\0") if f}
    except Exception:
        return set()

def scan_tree(repo):
    """LOC + complexity for every tracked, non-generated file at HEAD."""
    langs = defaultdict(lambda: {"loc": 0, "files": 0, "decisions": 0})
    try:
        files = [f for f in git(repo, "ls-files", "-z").split("\0") if f]
    except Exception:
        return {}, []
    lfs = lfs_paths(repo)
    skipped = []
    for f in files:
        lang = lang_of(f)
        if not lang:
            continue
        if is_generated(f) or f in lfs:
            skipped.append(f)
            continue
        try:
            with open(os.path.join(repo, f), "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        if b"\0" in data[:8192]:      # binary
            continue
        n = data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)
        if looks_minified(data, n):
            skipped.append(f)
            continue
        e = langs[lang]
        e["loc"] += n
        e["files"] += 1
        if lang in CODE_LANGS and len(data) < 4_000_000:
            try:
                e["decisions"] += decision_points(data.decode("utf-8", "replace"), lang)
            except Exception:
                pass
    return {k: dict(v) for k, v in langs.items()}, skipped

SEP = "\x1e"
def scan_history(repo, since_iso, until_iso):
    """Per-commit metadata + numstat within the window, default branch only."""
    fmt = SEP + "%H%x1f%aN%x1f%aE%x1f%aI%x1f%s"
    try:
        out = git(repo, "log", f"--since={since_iso}", f"--until={until_iso}",
                  "--no-merges", "--numstat", f"--format={fmt}")
    except Exception:
        return []
    commits = []
    for chunk in out.split(SEP):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        head, _, rest = chunk.partition("\n")
        parts = head.split("\x1f")
        if len(parts) < 5:
            continue
        sha, name, email, date, subject = parts[0], parts[1], parts[2], parts[3], parts[4]
        added = deleted = files = 0
        per_lang = defaultdict(lambda: [0, 0])
        for line in rest.split("\n"):
            if not line.strip():
                continue
            cols = line.split("\t")
            if len(cols) != 3:
                continue
            a, d, path = cols
            if a == "-" or d == "-":        # binary
                continue
            if is_generated(path):
                continue
            a, d = int(a), int(d)
            added += a; deleted += d; files += 1
            lang = lang_of(path)
            if lang:
                per_lang[lang][0] += a
                per_lang[lang][1] += d
        commits.append({"sha": sha[:10], "author": name, "email": email.lower(),
                        "date": date, "subject": subject[:160],
                        "files": files, "added": added, "deleted": deleted,
                        "langs": {k: v for k, v in per_lang.items()}})
    return commits

# ---------------------------------------------------------------------- github
def check_token(token, org):
    """Fail loudly and usefully instead of a bare 401/403 traceback deep in the run.

    Deliberately does not call GET /user: that endpoint requires a user-bound
    PAT and always 401s for a GitHub App installation token, which has no
    associated user. Listing the org's repos works for both token kinds and
    is the permission we actually need.
    """
    if not token:
        sys.exit("::error::No token. Set GH_TOKEN (workflow: an app-token step's output, "
                 "or secrets.REPO_ACCESS_TOKEN).")
    try:
        gh_api(f"orgs/{org}/repos?per_page=1&type=all", token, paginate=False)
    except Exception as e:
        code = getattr(e, "code", None)
        sys.exit(f"::error::GH_TOKEN cannot list repositories of org '{org}' (HTTP {code}). "
                 f"For a GitHub App token: the app needs Contents + Metadata read access and "
                 f"must be installed on {org}'s repositories. For a classic PAT: rotate it and "
                 f"grant org read access (repo:read).")
    print(f"Token ok (can list {org} repositories)")

def gh_api(path, token, paginate=True):
    import urllib.request, urllib.error
    results, url = [], f"https://api.github.com/{path}"
    while url:
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "meshmakers-weekly-report"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode())
            results.extend(body if isinstance(body, list) else [body])
            link = resp.headers.get("Link", "")
            url = None
            if paginate:
                for part in link.split(","):
                    if 'rel="next"' in part:
                        url = part.split(";")[0].strip().strip("<>")
    return results

# ------------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default="meshmakers")
    ap.add_argument("--mode", choices=["clone", "local"], default="clone")
    ap.add_argument("--local-root", default=None, help="directory of existing checkouts (--mode local)")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--until", default=None, help="ISO date, exclusive upper bound (default: now)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--previous", default=None, help="previous snapshot JSON for deltas")
    ap.add_argument("--exclude", default="", help="comma separated repo names to treat as automation")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--only", default="", help="comma separated repo names (debugging)")
    ap.add_argument("--at", default=None,
                    help="ISO date: measure the tree as of the last commit before this date. "
                         "Clone mode only -- never touches an existing working tree.")
    args = ap.parse_args()

    if args.until:
        parsed = datetime.fromisoformat(args.until)
        # An explicit offset is honoured; only a naive timestamp defaults to UTC.
        until = (parsed.astimezone(timezone.utc) if parsed.tzinfo
                 else parsed.replace(tzinfo=timezone.utc))
    else:
        until = datetime.now(timezone.utc)
    since = until - timedelta(days=args.days)
    since_iso, until_iso = since.isoformat(), until.isoformat()

    if args.at and args.mode == "local":
        sys.exit("--at ist nur im clone-Modus erlaubt (es wuerde den Arbeitsbaum veraendern)")
    automation = {r.strip() for r in args.exclude.split(",") if r.strip()}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    # ---- build the repo work list
    workdir = None
    if args.mode == "local":
        root = args.local_root or os.getcwd()
        targets = [(d, os.path.join(root, d)) for d in sorted(os.listdir(root))
                   if os.path.isdir(os.path.join(root, d, ".git"))]
    else:
        check_token(token, args.org)
        repos = gh_api(f"orgs/{args.org}/repos?per_page=100&type=all", token)
        # Forks sind fremder Code. Der Fork von crutonjohn/external-dns-opnsense-webhook
        # hat seit dem Fork keinen eigenen Commit, stellte aber 36% aller Go-Zeilen;
        # crate-operator stellte 74% allen Pythons. Bei Sprachen, in denen die Org wenig
        # eigenen Code hat, entscheidet sonst der Fork ueber die Statistik.
        repos = [r for r in repos if not r.get("archived") and not r.get("fork")]
        only = {x.strip() for x in args.only.split(",") if x.strip()}
        if only:
            repos = [r for r in repos if r["name"] in only]
        workdir = tempfile.mkdtemp(prefix="devmetrics-")
        genv = git_auth_env(token)
        targets = []
        def clone(r):
            dst = os.path.join(workdir, r["name"])
            url = f"https://github.com/{args.org}/{r['name']}.git"
            try:
                subprocess.run(["git", "clone", "--quiet", "--single-branch",
                                "--depth", "400", url, dst],
                               capture_output=True, check=True, timeout=900, env=genv)
                return (r["name"], dst)
            except subprocess.CalledProcessError as e:
                detail = redact(e.stderr.decode("utf-8", "replace")[:200], token)
                print(f"::warning::clone failed {r['name']} (exit {e.returncode}): {detail}",
                      file=sys.stderr)
                return None
            except Exception as e:
                print(f"::warning::clone failed {r['name']}: "
                      f"{redact(type(e).__name__, token)}", file=sys.stderr)
                return None
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            targets = [t for t in ex.map(clone, repos) if t]
        if args.at:
            for name, path in targets:
                try:
                    sha = git(path, "rev-list", "-1", f"--before={args.at}", "HEAD").strip()
                    if sha:
                        git(path, "checkout", "--quiet", "--detach", sha)
                    else:
                        print(f"::warning::{name}: kein Commit vor {args.at} in der "
                              f"geklonten Historie", file=sys.stderr)
                except Exception as e:
                    print(f"::warning::{name}: checkout --at fehlgeschlagen: {str(e)[:160]}",
                          file=sys.stderr)

    # ---- analyse
    def analyse(item):
        name, path = item
        langs, _ = scan_tree(path)
        commits = scan_history(path, since_iso, until_iso)
        try:
            last = git(path, "log", "-1", "--format=%aI").strip()
        except Exception:
            last = None
        return name, langs, commits, last

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        analysed = list(ex.map(analyse, targets))

    prev = {}
    if args.previous and os.path.exists(args.previous):
        try:
            prev = {r["name"]: r for r in json.load(open(args.previous)).get("repos", [])}
        except Exception:
            prev = {}

    repos_out, lang_tot = [], defaultdict(lambda: {"loc": 0, "files": 0, "decisions": 0,
                                                   "added": 0, "deleted": 0})
    author_tot = defaultdict(lambda: {"commits": 0, "added": 0, "deleted": 0,
                                      "files": 0, "repos": set(), "email": ""})
    by_day, by_hour, by_weekday = Counter(), Counter(), Counter()
    by_wd_hour = [[0] * 24 for _ in range(7)]
    all_commits = []

    for name, langs, commits, last in analysed:
        is_auto = name in automation
        loc = sum(v["loc"] for v in langs.values())
        code_loc = sum(v["loc"] for k, v in langs.items() if k in CODE_LANGS)
        decisions = sum(v["decisions"] for v in langs.values())
        added = sum(c["added"] for c in commits)
        deleted = sum(c["deleted"] for c in commits)
        authors = sorted({c["author"] for c in commits})

        for lang, v in langs.items():
            t = lang_tot[lang]
            t["loc"] += v["loc"]; t["files"] += v["files"]; t["decisions"] += v["decisions"]

        if not is_auto:
            for c in commits:
                a = author_tot[c["author"]]
                a["commits"] += 1; a["added"] += c["added"]; a["deleted"] += c["deleted"]
                a["files"] += c["files"]; a["repos"].add(name); a["email"] = c["email"]
                dt = datetime.fromisoformat(c["date"])
                by_day[dt.date().isoformat()] += 1
                by_hour[dt.hour] += 1
                by_weekday[dt.weekday()] += 1
                by_wd_hour[dt.weekday()][dt.hour] += 1
                for lang, (la, ld) in c["langs"].items():
                    lang_tot[lang]["added"] += la
                    lang_tot[lang]["deleted"] += ld
                all_commits.append({**c, "repo": name})

        p = prev.get(name, {})
        density = round(decisions / code_loc * 1000, 2) if code_loc else 0.0
        days_idle = None
        if last:
            days_idle = (until - datetime.fromisoformat(last)).days

        repos_out.append({
            "name": name, "automation": is_auto,
            "commits": len(commits), "authors": authors,
            "added": added, "deleted": deleted,
            "net": added - deleted,
            "files_touched": sum(c["files"] for c in commits),
            "churn_ratio": round(deleted / added, 2) if added else None,
            "loc": loc, "code_loc": code_loc,
            "decisions": decisions, "complexity_density": density,
            "langs": langs,
            "last_commit": last, "days_idle": days_idle,
            "delta": {
                "loc": loc - p["loc"] if "loc" in p else None,
                "code_loc": code_loc - p["code_loc"] if "code_loc" in p else None,
                "decisions": decisions - p["decisions"] if "decisions" in p else None,
                "complexity_density": (round(density - p["complexity_density"], 2)
                                       if "complexity_density" in p else None),
                "commits": len(commits) - p["commits"] if "commits" in p else None,
            },
        })

    all_commits.sort(key=lambda c: c["added"] + c["deleted"], reverse=True)
    active = [r for r in repos_out if r["commits"] and not r["automation"]]

    snapshot = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "org": args.org,
        "window": {"since": since_iso, "until": until_iso, "days": args.days,
                   "iso_week": until.strftime("%G-W%V")},
        "totals": {
            "repos_scanned": len(repos_out),
            "repos_active": len(active),
            "commits": sum(r["commits"] for r in repos_out if not r["automation"]),
            "commits_automation": sum(r["commits"] for r in repos_out if r["automation"]),
            "authors": len(author_tot),
            "added": sum(r["added"] for r in repos_out if not r["automation"]),
            "deleted": sum(r["deleted"] for r in repos_out if not r["automation"]),
            "loc": sum(r["loc"] for r in repos_out),
            "code_loc": sum(r["code_loc"] for r in repos_out),
            "decisions": sum(r["decisions"] for r in repos_out),
        },
        "authors": sorted(
            [{"name": k, "email": v["email"], "commits": v["commits"], "added": v["added"],
              "deleted": v["deleted"], "files": v["files"],
              "avg_files_per_commit": round(v["files"] / v["commits"], 1) if v["commits"] else 0,
              "avg_lines_per_commit": round((v["added"] + v["deleted"]) / v["commits"]) if v["commits"] else 0,
              "repos": sorted(v["repos"])}
             for k, v in author_tot.items()],
            key=lambda a: -a["commits"]),
        "timeline": {
            "by_day": dict(sorted(by_day.items())),
            "by_hour": [by_hour.get(h, 0) for h in range(24)],
            "by_weekday": [by_weekday.get(d, 0) for d in range(7)],
            "by_weekday_hour": by_wd_hour,
        },
        "largest_commits": all_commits[:15],
        "languages": {k: dict(v) for k, v in sorted(lang_tot.items(), key=lambda x: -x[1]["loc"])},
        "repos": sorted(repos_out, key=lambda r: (-r["commits"], -r["loc"])),
        "lang_buckets": {"code": sorted(CODE_LANGS), "config": sorted(CONFIG_LANGS),
                         "docs": sorted(DOC_LANGS)},
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(snapshot, fh, indent=1)
    if workdir:
        shutil.rmtree(workdir, ignore_errors=True)

    t = snapshot["totals"]
    print(f"{t['repos_scanned']} repos | {t['commits']} commits "
          f"({t['commits_automation']} automation) | {t['authors']} authors | "
          f"+{t['added']}/-{t['deleted']} | {t['loc']:,} LOC | {t['decisions']:,} decision points")
    print(f"-> {args.out}")

if __name__ == "__main__":
    main()
