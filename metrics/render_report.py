#!/usr/bin/env python3
"""Render a weekly development report (self-contained HTML) from a metrics snapshot."""
import argparse, html, json, os
from datetime import datetime

WD = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
# sequential blue ramp, light surface -> dark ink
HEAT_L = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]

def fmt(n):
    if n is None:
        return "–"
    return f"{n:,}".replace(",", ".")

def signed(n):
    if n is None:
        return None
    return ("+" if n > 0 else "") + fmt(n)

def esc(s):
    return html.escape(str(s), quote=True)

def delta_chip(value, good_when="up", suffix="", zero_label="±0"):
    """Arrow + number + tone. Shape (arrow) carries the sign, never colour alone."""
    if value is None:
        return '<span class="chip chip-none">neu</span>'
    if value == 0:
        return f'<span class="chip chip-flat">{zero_label}</span>'
    up = value > 0
    good = (up and good_when == "up") or (not up and good_when == "down")
    tone = "chip-good" if good else "chip-warn"
    arrow = "↑" if up else "↓"
    return f'<span class="chip {tone}">{arrow} {signed(value)}{suffix}</span>'

def bar_chart(days, counts):
    if not counts:
        return '<p class="empty">Keine Commits im Zeitraum.</p>'
    top = max(counts) or 1
    bars = []
    for d, c in zip(days, counts):
        dt = datetime.fromisoformat(d)
        h = max(round(c / top * 100), 2 if c else 0)
        label = f"{WD[dt.weekday()]} {dt.strftime('%d.%m.')}"
        bars.append(
            f'<div class="bar-slot" data-tip="{esc(label)} — {c} Commits">'
            f'<span class="bar-val">{c}</span>'
            f'<div class="bar" style="height:{h}%"></div>'
            f'<span class="bar-lbl">{WD[dt.weekday()]}<em>{dt.strftime("%d.%m.")}</em></span>'
            f"</div>")
    rows = "".join(f"<tr><td>{esc(datetime.fromisoformat(d).strftime('%a %d.%m.%Y'))}</td>"
                   f"<td class='num'>{c}</td></tr>" for d, c in zip(days, counts))
    return (f'<div class="barchart">{"".join(bars)}</div>'
            f'<details class="tableview"><summary>Datentabelle</summary>'
            f'<table class="mini"><thead><tr><th>Tag</th><th class="num">Commits</th></tr></thead>'
            f"<tbody>{rows}</tbody></table></details>")

def heatmap(matrix):
    peak = max((max(r) for r in matrix), default=0)
    if not peak:
        return '<p class="empty">Keine Commits im Zeitraum.</p>'
    cells = ['<div class="hm-corner"></div>']
    for h in range(24):
        cells.append(f'<div class="hm-hour">{h if h % 3 == 0 else ""}</div>')
    for d in range(7):
        cells.append(f'<div class="hm-day">{WD[d]}</div>')
        for h in range(24):
            v = matrix[d][h]
            if v:
                step = min(int(v / peak * len(HEAT_L)), len(HEAT_L) - 1)
                cls = f"hm-cell l{step}"
            else:
                cls = "hm-cell l-zero"
            cells.append(f'<div class="{cls}" data-tip="{WD[d]} {h:02d}:00 — {v} Commits"></div>')
    legend = "".join(f'<i class="l{i}"></i>' for i in range(len(HEAT_L)))
    rows = ""
    for d in range(7):
        tot = sum(matrix[d])
        if tot:
            busiest = max(range(24), key=lambda h: matrix[d][h])
            rows += (f"<tr><td>{WD[d]}</td><td class='num'>{tot}</td>"
                     f"<td class='num'>{busiest:02d}:00</td></tr>")
    return (f'<div class="scroll"><div class="heatmap">{"".join(cells)}</div></div>'
            f'<div class="hm-legend"><span>weniger</span>{legend}<span>mehr</span></div>'
            f'<details class="tableview"><summary>Datentabelle</summary>'
            f'<table class="mini"><thead><tr><th>Tag</th><th class="num">Commits</th>'
            f'<th class="num">Spitzenstunde</th></tr></thead><tbody>{rows}</tbody></table></details>')

def lang_chart(langs, buckets, top_n=10):
    code, config = set(buckets["code"]), set(buckets["config"])
    def slot(name):
        if name in code:
            return 1, "Code"
        if name in config:
            return 2, "Config/Build"
        return 3, "Doku"
    items = [(k, v) for k, v in langs.items() if v["loc"] > 0][:top_n]
    if not items:
        return ""
    top = max(v["loc"] for _, v in items)
    rows = []
    for name, v in items:
        s, bucket = slot(name)
        w = max(v["loc"] / top * 100, 0.6)
        churn = v.get("added", 0) + v.get("deleted", 0)
        churn_txt = (f'<span class="lang-churn">+{fmt(v.get("added",0))} / '
                     f'−{fmt(v.get("deleted",0))}</span>' if churn else
                     '<span class="lang-churn quiet">unverändert</span>')
        rows.append(
            f'<div class="lang-row" data-tip="{esc(name)} ({bucket}) — {fmt(v["loc"])} Zeilen '
            f'in {fmt(v["files"])} Dateien">'
            f'<div class="lang-name">{esc(name)}</div>'
            f'<div class="lang-track"><div class="lang-bar s{s}" style="width:{w:.2f}%"></div>'
            f'<span class="lang-loc">{fmt(v["loc"])}</span></div>'
            f"<div class='lang-meta'>{churn_txt}</div></div>")
    legend = ('<div class="legend">'
              '<span class="lg"><i class="sw s1"></i>Code</span>'
              '<span class="lg"><i class="sw s2"></i>Config/Build</span>'
              '<span class="lg"><i class="sw s3"></i>Doku</span></div>')
    return legend + '<div class="langchart">' + "".join(rows) + "</div>"

def repo_table(repos):
    rows = []
    for r in repos:
        if not r["commits"]:
            continue
        n_extra = len(r["authors"]) - 3
        more_a = f" +{n_extra}" if n_extra > 0 else ""
        d = r["delta"]
        churn = r["churn_ratio"]
        churn_cls = "warn" if churn is not None and churn > 1.0 else ""
        rows.append(
            "<tr>"
            f'<th scope="row"><code>{esc(r["name"])}</code>'
            f'{" <span class=tag>Automation</span>" if r["automation"] else ""}</th>'
            f'<td class="num strong">{r["commits"]}</td>'
            f'<td class="num">{delta_chip(d.get("commits"))}</td>'
            f'<td class="num pos">+{fmt(r["added"])}</td>'
            f'<td class="num neg">−{fmt(r["deleted"])}</td>'
            f'<td class="num {churn_cls}">{"–" if churn is None else f"{churn:.2f}"}</td>'
            f'<td class="num">{fmt(r["code_loc"])}</td>'
            f'<td class="num">{delta_chip(d.get("code_loc"))}</td>'
            f'<td class="num">{r["complexity_density"]:.1f}</td>'
            f'<td class="num">{delta_chip(d.get("complexity_density"), good_when="down")}</td>'
            f'<td class="who">{esc(", ".join(r["authors"][:3]))}{more_a}</td>'
            "</tr>")
    if not rows:
        return '<p class="empty">Keine aktiven Repos im Zeitraum.</p>'
    return (
        '<div class="scroll"><table class="grid"><thead><tr>'
        '<th scope="col">Repo</th><th scope="col" class="num">Commits</th>'
        '<th scope="col" class="num">vs. VW</th>'
        '<th scope="col" class="num">Zeilen +</th><th scope="col" class="num">Zeilen −</th>'
        '<th scope="col" class="num" title="gelöscht / hinzugefügt">Churn</th>'
        '<th scope="col" class="num">Code-LOC</th><th scope="col" class="num">Δ LOC</th>'
        '<th scope="col" class="num" title="Entscheidungspunkte je 1000 Code-Zeilen">Kompl.</th>'
        '<th scope="col" class="num">Δ Kompl.</th>'
        '<th scope="col">Wer</th>'
        f'</tr></thead><tbody>{"".join(rows)}</tbody></table></div>')

def author_table(authors):
    if not authors:
        return '<p class="empty">Keine Commits im Zeitraum.</p>'
    def arow(a):
        n_extra = len(a["repos"]) - 5
        more_r = f" +{n_extra}" if n_extra > 0 else ""
        return (
        "<tr>"
        f'<th scope="row">{esc(a["name"])}</th>'
        f'<td class="num strong">{a["commits"]}</td>'
        f'<td class="num pos">+{fmt(a["added"])}</td>'
        f'<td class="num neg">−{fmt(a["deleted"])}</td>'
        f'<td class="num">{a["avg_lines_per_commit"]}</td>'
        f'<td class="num">{a["avg_files_per_commit"]}</td>'
        f'<td class="num">{len(a["repos"])}</td>'
        f'<td class="who"><code>{esc(", ".join(a["repos"][:5]))}</code>{more_r}</td>'
        "</tr>")
    rows = "".join(arow(a) for a in authors)
    return ('<div class="scroll"><table class="grid"><thead><tr>'
            '<th scope="col">Autor</th><th scope="col" class="num">Commits</th>'
            '<th scope="col" class="num">Zeilen +</th><th scope="col" class="num">Zeilen −</th>'
            '<th scope="col" class="num" title="durchschnittlich geänderte Zeilen pro Commit">Ø Zeilen/Commit</th>'
            '<th scope="col" class="num">Ø Dateien/Commit</th>'
            '<th scope="col" class="num">Repos</th><th scope="col">Welche</th>'
            f'</tr></thead><tbody>{rows}</tbody></table></div>')

def focus_section(snap):
    repos = snap["repos"]
    active = [r for r in repos if r["commits"] and not r["automation"]]
    total = sum(r["commits"] for r in active) or 1
    active.sort(key=lambda r: -r["commits"])
    top = active[:8]
    share = "".join(
        f'<li><code>{esc(r["name"])}</code>'
        f'<span class="share-track"><span class="share-bar" '
        f'style="width:{r["commits"]/max(a["commits"] for a in top)*100:.1f}%"></span></span>'
        f'<span class="share-num">{r["commits"]} · {r["commits"]/total*100:.0f}%</span></li>'
        for r in top)

    dormant = [r for r in repos
               if not r["automation"] and r["code_loc"] >= 8000
               and (r["days_idle"] is None or r["days_idle"] > 60)]
    dormant.sort(key=lambda r: -r["code_loc"])
    dorm = "".join(
        f'<li><code>{esc(r["name"])}</code>'
        f'<span class="share-num">{fmt(r["code_loc"])} LOC · '
        f'{"unbekannt" if r["days_idle"] is None else str(r["days_idle"]) + " Tage still"}</span></li>'
        for r in dormant[:8]) or "<li class='empty'>Kein großes Repo länger als 60 Tage still.</li>"

    notes = []
    rework = [r for r in active if r["churn_ratio"] is not None and r["churn_ratio"] > 1.0
              and r["added"] + r["deleted"] > 400]
    if rework:
        notes.append("<li><span class='n-warn'>Umbau</span> "
                     + ", ".join(f"<code>{esc(r['name'])}</code> (Churn {r['churn_ratio']:.2f})"
                                 for r in rework[:5])
                     + " — mehr gelöscht als geschrieben: Refactoring oder Rücknahme.</li>")
    risen = [r for r in active if r["delta"].get("complexity_density") is not None
             and r["delta"]["complexity_density"] > 0.5]
    risen.sort(key=lambda r: -r["delta"]["complexity_density"])
    if risen:
        notes.append("<li><span class='n-warn'>Komplexität</span> "
                     + ", ".join(f"<code>{esc(r['name'])}</code> "
                                 f"(+{r['delta']['complexity_density']:.1f})" for r in risen[:5])
                     + " — Entscheidungsdichte gestiegen.</li>")
    solo = [r for r in active if len(r["authors"]) == 1 and r["commits"] >= 10]
    if solo:
        notes.append("<li><span class='n-info'>Bus-Faktor 1</span> "
                     + ", ".join(f"<code>{esc(r['name'])}</code>" for r in solo[:6])
                     + " — diese Woche nur von je einer Person berührt.</li>")
    if not notes:
        notes.append("<li><span class='n-good'>Unauffällig</span> Keine Churn- oder "
                     "Komplexitätsausreißer diese Woche.</li>")

    return (f'<div class="two-col">'
            f'<div><h3>Wo die Arbeit hinging</h3><ol class="share">{share}</ol></div>'
            f'<div><h3>Groß, aber still</h3><ul class="share dormant">{dorm}</ul>'
            f'<p class="hint">Repos ab 8.000 Code-Zeilen ohne Commit seit über 60 Tagen.</p></div>'
            f'</div><h3>Auffälligkeiten</h3><ul class="notes">{"".join(notes)}</ul>')

def commits_table(commits):
    if not commits:
        return ""
    rows = "".join(
        "<tr>"
        f'<td><code>{esc(c["repo"])}</code></td>'
        f'<td class="who">{esc(c["author"])}</td>'
        f'<td class="subj">{esc(c["subject"])}</td>'
        f'<td class="num">{c["files"]}</td>'
        f'<td class="num pos">+{fmt(c["added"])}</td>'
        f'<td class="num neg">−{fmt(c["deleted"])}</td>'
        f'<td class="num quiet">{esc(datetime.fromisoformat(c["date"]).strftime("%a %d.%m. %H:%M"))}</td>'
        "</tr>" for c in commits[:10])
    return ('<div class="scroll"><table class="grid"><thead><tr>'
            '<th scope="col">Repo</th><th scope="col">Autor</th><th scope="col">Betreff</th>'
            '<th scope="col" class="num">Dateien</th><th scope="col" class="num">+</th>'
            '<th scope="col" class="num">−</th><th scope="col">Wann</th>'
            f'</tr></thead><tbody>{rows}</tbody></table></div>')

CSS = """
:root{
  color-scheme:light;
  --plane:#f7f8f7; --surface:#fcfdfc; --surface-2:#f0f2f0; --surface-3:#e8ebe9;
  --ink:#0b0d0c; --ink-2:#4e534f; --muted:#858a86;
  --rule:#dfe3e0; --ring:rgba(11,13,12,.10);
  --accent:#2a78d6;
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a;
  --pos:#006300; --neg:#b03636;
  --good-bg:rgba(12,163,12,.12); --good-fg:#006300;
  --warn-bg:rgba(208,59,59,.12); --warn-fg:#a52f2f;
  --flat-bg:rgba(11,13,12,.06); --flat-fg:#6b706c;
  --h0:#cde2fb; --h1:#9ec5f4; --h2:#6da7ec; --h3:#3987e5;
  --h4:#256abf; --h5:#184f95; --h6:#0d366b;
  --shadow:0 1px 2px rgba(11,13,12,.05), 0 8px 24px -16px rgba(11,13,12,.28);
}
@media (prefers-color-scheme:dark){ :root:not([data-theme="light"]){
  color-scheme:dark;
  --plane:#0d0f0e; --surface:#1a1c1b; --surface-2:#232624; --surface-3:#2c2f2d;
  --ink:#ffffff; --ink-2:#c0c5c1; --muted:#8b908c;
  --rule:#2e312f; --ring:rgba(255,255,255,.10);
  --accent:#3987e5;
  --s1:#3987e5; --s2:#d95926; --s3:#199e70;
  --pos:#0ca30c; --neg:#e66767;
  --good-bg:rgba(12,163,12,.18); --good-fg:#3ec93e;
  --warn-bg:rgba(230,103,103,.18); --warn-fg:#f08a8a;
  --flat-bg:rgba(255,255,255,.07); --flat-fg:#9aa09b;
  --h0:#13314f; --h1:#184f95; --h2:#256abf; --h3:#3987e5;
  --h4:#6da7ec; --h5:#9ec5f4; --h6:#cde2fb;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.8);
}}
:root[data-theme="dark"]{
  color-scheme:dark;
  --plane:#0d0f0e; --surface:#1a1c1b; --surface-2:#232624; --surface-3:#2c2f2d;
  --ink:#ffffff; --ink-2:#c0c5c1; --muted:#8b908c;
  --rule:#2e312f; --ring:rgba(255,255,255,.10);
  --accent:#3987e5;
  --s1:#3987e5; --s2:#d95926; --s3:#199e70;
  --pos:#0ca30c; --neg:#e66767;
  --good-bg:rgba(12,163,12,.18); --good-fg:#3ec93e;
  --warn-bg:rgba(230,103,103,.18); --warn-fg:#f08a8a;
  --flat-bg:rgba(255,255,255,.07); --flat-fg:#9aa09b;
  --h0:#13314f; --h1:#184f95; --h2:#256abf; --h3:#3987e5;
  --h4:#6da7ec; --h5:#9ec5f4; --h6:#cde2fb;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 8px 24px -16px rgba(0,0,0,.8);
}
*{box-sizing:border-box}
body{
  margin:0; background:var(--plane); color:var(--ink);
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
  font-size:15px; line-height:1.5; -webkit-font-smoothing:antialiased;
}
code,.num,.mono{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace}
.wrap{max-width:1140px; margin:0 auto; padding:40px 24px 88px; display:flex; flex-direction:column; gap:36px}
.eyebrow{font-size:11px; letter-spacing:.14em; text-transform:uppercase; color:var(--muted); font-weight:600}

/* masthead */
.masthead{display:flex; flex-wrap:wrap; align-items:flex-end; justify-content:space-between; gap:16px;
  padding-bottom:22px; border-bottom:2px solid var(--ink)}
.masthead h1{margin:6px 0 0; font-size:clamp(28px,4.4vw,42px); font-weight:700; letter-spacing:-.025em;
  text-wrap:balance; line-height:1.05}
.masthead .range{color:var(--ink-2); font-size:14px; margin-top:8px}
.masthead .stamp{text-align:right; color:var(--muted); font-size:12px; line-height:1.6}

/* stat tiles */
.tiles{display:grid; grid-template-columns:repeat(auto-fit,minmax(158px,1fr)); gap:1px;
  background:var(--rule); border:1px solid var(--rule); border-radius:10px; overflow:hidden}
.tile{background:var(--surface); padding:16px 18px 18px; display:flex; flex-direction:column; gap:2px}
.tile .k{font-size:11px; letter-spacing:.1em; text-transform:uppercase; color:var(--muted); font-weight:600}
.tile .v{font-size:30px; font-weight:700; letter-spacing:-.02em; line-height:1.15}
.tile .s{font-size:12px; color:var(--ink-2)}

section{background:var(--surface); border:1px solid var(--ring); border-radius:12px;
  padding:24px 26px 26px; box-shadow:var(--shadow)}
section > h2{margin:4px 0 2px; font-size:19px; font-weight:650; letter-spacing:-.015em}
section > .lede{margin:0 0 20px; color:var(--ink-2); font-size:13.5px; max-width:62ch}
section h3{margin:22px 0 10px; font-size:13px; letter-spacing:.06em; text-transform:uppercase; color:var(--ink-2)}
section h3:first-child{margin-top:0}

/* bar chart */
.barchart{display:flex; align-items:flex-end; gap:8px; height:190px; margin-top:6px}
.bar-slot{flex:1; display:flex; flex-direction:column; justify-content:flex-end; align-items:center;
  gap:6px; height:100%; border-radius:6px; padding:4px 0; cursor:default}
.bar-slot:hover{background:var(--surface-2)}
.bar-val{font-size:12px; font-weight:650; font-variant-numeric:tabular-nums; color:var(--ink-2)}
.bar{width:100%; max-width:54px; background:var(--accent); border-radius:4px 4px 0 0; min-height:2px}
.bar-lbl{font-size:11px; color:var(--muted); text-align:center; line-height:1.3}
.bar-lbl em{display:block; font-style:normal; font-size:10px}

/* heatmap */
.heatmap{display:grid; grid-template-columns:30px repeat(24,1fr); gap:2px; margin-top:4px;
  min-width:352px}
.hm-corner{}
.hm-hour{font-size:9.5px; color:var(--muted); text-align:center; font-variant-numeric:tabular-nums}
.hm-day{font-size:11px; color:var(--muted); display:flex; align-items:center}
.hm-cell{aspect-ratio:1; border-radius:2px; background:var(--surface-2); min-height:11px}
.hm-cell.l-zero{background:var(--surface-2)}
.hm-cell.l0{background:var(--h0)} .hm-cell.l1{background:var(--h1)} .hm-cell.l2{background:var(--h2)}
.hm-cell.l3{background:var(--h3)} .hm-cell.l4{background:var(--h4)} .hm-cell.l5{background:var(--h5)}
.hm-cell.l6{background:var(--h6)}
.hm-legend{display:flex; align-items:center; gap:4px; margin-top:12px; font-size:11px; color:var(--muted)}
.hm-legend i{width:14px; height:14px; border-radius:2px; display:inline-block}
.hm-legend i.l0{background:var(--h0)} .hm-legend i.l1{background:var(--h1)}
.hm-legend i.l2{background:var(--h2)} .hm-legend i.l3{background:var(--h3)}
.hm-legend i.l4{background:var(--h4)} .hm-legend i.l5{background:var(--h5)}
.hm-legend i.l6{background:var(--h6)}
.hm-legend span:first-child{margin-right:4px} .hm-legend span:last-child{margin-left:4px}

/* language chart */
.legend{display:flex; gap:18px; flex-wrap:wrap; margin:0 0 14px; font-size:12px; color:var(--ink-2)}
.lg{display:inline-flex; align-items:center; gap:7px}
.sw{width:11px; height:11px; border-radius:3px; display:inline-block}
.sw.s1,.lang-bar.s1{background:var(--s1)} .sw.s2,.lang-bar.s2{background:var(--s2)}
.sw.s3,.lang-bar.s3{background:var(--s3)}
.langchart{display:flex; flex-direction:column; gap:7px}
.lang-row{display:grid; grid-template-columns:112px 1fr 190px; gap:14px; align-items:center;
  padding:3px 0; border-radius:6px}
.lang-row:hover{background:var(--surface-2)}
.lang-name{font-size:13px; font-weight:550}
.lang-track{display:flex; align-items:center; gap:10px; min-width:0}
.lang-bar{height:15px; border-radius:4px; min-width:3px}
.lang-loc{font-size:12px; font-variant-numeric:tabular-nums; color:var(--ink-2); white-space:nowrap;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.lang-meta{font-size:12px; color:var(--ink-2); text-align:right; font-variant-numeric:tabular-nums}
.lang-churn.quiet{color:var(--muted)}

/* tables */
.scroll{overflow-x:auto; margin:0 -4px}
table.grid{width:max-content; min-width:100%; border-collapse:collapse; font-size:13px}
table.grid th, table.grid td{padding:9px 11px; text-align:left; border-bottom:1px solid var(--rule);
  vertical-align:baseline; white-space:nowrap}
table.grid thead th{font-size:11px; letter-spacing:.05em; text-transform:uppercase; color:var(--muted);
  font-weight:600; border-bottom:1px solid var(--ink-2)}
table.grid tbody tr:hover{background:var(--surface-2)}
table.grid tbody th{font-weight:500}
table.grid td.num,table.grid th.num{text-align:right; font-variant-numeric:tabular-nums;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
td.strong{font-weight:700}
td.pos{color:var(--pos)} td.neg{color:var(--neg)} td.warn{color:var(--warn-fg); font-weight:650}
table.grid td.who,.share .who{color:var(--ink-2); font-size:12px; white-space:nowrap;
  min-width:150px; max-width:none}
table.grid td.subj{white-space:normal; min-width:230px; max-width:355px; line-height:1.4}
.quiet{color:var(--muted)}
code{font-size:12.5px; background:var(--surface-2); padding:1px 5px; border-radius:4px}
.tag{font-size:10px; letter-spacing:.06em; text-transform:uppercase; color:var(--muted);
  border:1px solid var(--rule); border-radius:3px; padding:0 4px}

/* chips */
.chip{display:inline-block; font-size:11.5px; font-weight:600; padding:1.5px 7px; border-radius:20px;
  font-variant-numeric:tabular-nums; white-space:nowrap}
.chip-good{background:var(--good-bg); color:var(--good-fg)}
.chip-warn{background:var(--warn-bg); color:var(--warn-fg)}
.chip-flat,.chip-none{background:var(--flat-bg); color:var(--flat-fg)}

/* focus */
.two-col{display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); gap:32px}
ol.share,ul.share{list-style:none; margin:0; padding:0; display:flex; flex-direction:column; gap:8px}
.share li{display:grid; grid-template-columns:minmax(120px,auto) 1fr auto; gap:12px; align-items:center;
  font-size:13px}
.share.dormant li{grid-template-columns:1fr auto}
.share-track{background:var(--surface-3); height:9px; border-radius:4px; overflow:hidden}
.share-bar{display:block; height:100%; background:var(--accent); border-radius:4px}
.share-num{font-size:12px; color:var(--ink-2); font-variant-numeric:tabular-nums; white-space:nowrap;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.hint{font-size:12px; color:var(--muted); margin:12px 0 0}
ul.notes{list-style:none; margin:0; padding:0; display:flex; flex-direction:column; gap:10px; font-size:13.5px}
ul.notes li{padding-left:0; color:var(--ink-2)}
.n-warn,.n-info,.n-good{display:inline-block; font-size:10.5px; font-weight:700; letter-spacing:.06em;
  text-transform:uppercase; padding:2px 7px; border-radius:4px; margin-right:8px; vertical-align:1px}
.n-warn{background:var(--warn-bg); color:var(--warn-fg)}
.n-info{background:var(--flat-bg); color:var(--flat-fg)}
.n-good{background:var(--good-bg); color:var(--good-fg)}

details.tableview{margin-top:16px; font-size:12px}
details.tableview summary{cursor:pointer; color:var(--muted); font-size:11.5px;
  letter-spacing:.05em; text-transform:uppercase; font-weight:600}
details.tableview summary:hover{color:var(--ink-2)}
table.mini{border-collapse:collapse; margin-top:10px; font-size:12px}
table.mini th,table.mini td{padding:4px 14px 4px 0; text-align:left; color:var(--ink-2)}
table.mini td.num,table.mini th.num{text-align:right; font-variant-numeric:tabular-nums}
.empty{color:var(--muted); font-size:13px; margin:8px 0}

/* tooltip */
#tip{position:fixed; z-index:50; pointer-events:none; opacity:0; transition:opacity .1s;
  background:var(--ink); color:var(--surface); font-size:12px; padding:5px 9px; border-radius:6px;
  white-space:nowrap; box-shadow:0 4px 14px rgba(0,0,0,.25)}
#tip.on{opacity:1}
:focus-visible{outline:2px solid var(--accent); outline-offset:2px}
@media (prefers-reduced-motion:reduce){*{transition:none!important; animation:none!important}}
footer{color:var(--muted); font-size:12px; line-height:1.7; border-top:1px solid var(--rule); padding-top:20px}
footer code{background:none; padding:0}
@media (max-width:720px){
  .wrap{padding:28px 16px 64px; gap:26px}
  section{padding:20px 16px 22px}
  .lang-row{grid-template-columns:92px 1fr; }
  .lang-meta{grid-column:1/-1; text-align:left}
  .heatmap{grid-template-columns:26px repeat(24,1fr); gap:1.5px}
  .hm-hour{font-size:8px}
}
"""

JS = """
(function(){
  var tip=document.getElementById('tip');
  document.addEventListener('mouseover',function(e){
    var el=e.target.closest('[data-tip]'); if(!el)return;
    tip.textContent=el.getAttribute('data-tip'); tip.classList.add('on');
  });
  document.addEventListener('mousemove',function(e){
    if(!tip.classList.contains('on'))return;
    var x=e.clientX+14,y=e.clientY-34;
    if(x+tip.offsetWidth>window.innerWidth-8)x=e.clientX-tip.offsetWidth-14;
    if(y<8)y=e.clientY+20;
    tip.style.left=x+'px'; tip.style.top=y+'px';
  });
  document.addEventListener('mouseout',function(e){
    if(e.target.closest('[data-tip]'))tip.classList.remove('on');
  });
})();
"""

def render(snap):
    t = snap["totals"]
    w = snap["window"]
    since = datetime.fromisoformat(w["since"]); until = datetime.fromisoformat(w["until"])
    gen = datetime.fromisoformat(snap["generated_at"])
    days = list(snap["timeline"]["by_day"].keys())
    counts = list(snap["timeline"]["by_day"].values())
    net = t["added"] - t["deleted"]
    density = (t["decisions"] / t["code_loc"] * 1000) if t["code_loc"] else 0
    per_day = t["commits"] / max(w["days"], 1)

    tiles = [
        ("Commits", fmt(t["commits"]), f"{per_day:.1f} pro Tag · {fmt(t['commits_automation'])} von Bots"),
        ("Autoren", fmt(t["authors"]), f"in {t['repos_active']} von {t['repos_scanned']} Repos"),
        ("Zeilen netto", signed(net), f"+{fmt(t['added'])} / −{fmt(t['deleted'])}"),
        ("Code-LOC", fmt(t["code_loc"]), f"{fmt(t['loc'])} inkl. Config & Doku"),
        ("Komplexität", f"{density:.1f}", "Entscheidungspunkte / 1.000 Zeilen"),
    ]
    tiles_html = "".join(
        f'<div class="tile"><span class="k">{esc(k)}</span><span class="v">{v}</span>'
        f'<span class="s">{esc(s)}</span></div>' for k, v, s in tiles)

    return f"""<title>OctoMesh Wochenpuls</title>
<style>{CSS}</style>
<div class="wrap">

<header class="masthead">
  <div>
    <span class="eyebrow">Kalenderwoche {esc(w['iso_week'])} · GitHub-Org {esc(snap['org'])}</span>
    <h1>Wochenpuls der Entwicklung</h1>
    <p class="range">{since.strftime('%d.%m.%Y')} bis {until.strftime('%d.%m.%Y')} ·
      {w['days']} Tage · {t['repos_scanned']} Repositories, Default-Branch</p>
  </div>
  <div class="stamp">erzeugt {gen.strftime('%d.%m.%Y %H:%M')} UTC<br>
    <code>octo-tools/metrics</code></div>
</header>

<div class="tiles">{tiles_html}</div>

<section>
  <h2>Fokus-Check</h2>
  <p class="lede">Wohin die Woche wirklich geflossen ist — und welche großen Repos
     dabei unberührt geblieben sind.</p>
  {focus_section(snap)}
</section>

<section>
  <h2>Rhythmus</h2>
  <p class="lede">Commits pro Tag und die Verteilung über Wochentag und Stunde, in der
     Zeitzone des jeweiligen Autors. Bot-Repos sind ausgenommen.</p>
  {bar_chart(days, counts)}
  <h3>Wochentag × Stunde</h3>
  {heatmap(snap['timeline']['by_weekday_hour'])}
</section>

<section>
  <h2>Wer</h2>
  <p class="lede">Commit-Komplexität pro Person: Ø geänderte Zeilen und Dateien je Commit
     zeigen, ob in kleinen Schritten oder in großen Blöcken gearbeitet wurde.</p>
  {author_table(snap['authors'])}
</section>

<section>
  <h2>Repositories</h2>
  <p class="lede">Nur Repos mit Aktivität im Zeitraum. <em>Churn</em> ist gelöschte durch
     hinzugefügte Zeilen — über 1,00 heißt: es wurde mehr abgetragen als aufgebaut.
     <em>Kompl.</em> ist die Entscheidungsdichte je 1.000 Code-Zeilen, eine Näherung der
     zyklomatischen Komplexität. Δ vergleicht mit dem Snapshot der Vorwoche.</p>
  {repo_table([r for r in snap['repos'] if r['commits']])}
</section>

<section>
  <h2>Sprachen</h2>
  <p class="lede">Bestand am Ende der Woche, generierter Code und Lockfiles ausgenommen.
     Rechts die Veränderung im Zeitraum.</p>
  {lang_chart(snap['languages'], snap['lang_buckets'])}
</section>

<section>
  <h2>Größte Commits</h2>
  <p class="lede">Nach geänderten Zeilen. Sehr große Einzelcommits sind meist Umbauten,
     Imports oder Merges von Hand — und ein Hinweis, wo Review teuer wird.</p>
  {commits_table(snap['largest_commits'])}
</section>

<footer>
  Erhoben aus dem Default-Branch jedes Repos; Merge-Commits, generierter Code
  (<code>globalTypes.ts</code>, <code>schema.graphql</code>, <code>/dist/</code>, Lockfiles)
  und Binärdateien sind ausgeschlossen. Die Komplexität ist eine Näherung über
  Entscheidungspunkte (if/for/while/case/catch, &amp;&amp;, ||, ?:) und ersetzt keinen
  statischen Analysator — ihr Wert liegt im Wochenvergleich, nicht im Absolutwert.
  Feature-Branches, die nie gemergt wurden, sind nicht enthalten.
</footer>

</div>
<div id="tip"></div>
<script>{JS}</script>
"""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    snap = json.load(open(a.snapshot))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as fh:
        fh.write(render(snap))
    print(f"-> {a.out}")

if __name__ == "__main__":
    main()
