#!/usr/bin/env python3
"""Render the monthly history (commits + LOC per language) as self-contained HTML."""
import argparse, json, os, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_report import CSS, JS, fmt, signed, esc

MON = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]
SERIES = ["s1", "s2", "s3", "s4", "s5", "s6"]

EXTRA_CSS = """
:root{--s4:#eda100; --s5:#e87ba4; --s6:#008300; --other:#9aa09b}
@media (prefers-color-scheme:dark){ :root:not([data-theme="light"]){
  --s4:#c98500; --s5:#d55181; --s6:#008300; --other:#6f7571}}
:root[data-theme="dark"]{--s4:#c98500; --s5:#d55181; --s6:#008300; --other:#6f7571}
.sw.s4,.ar.s4{background:var(--s4)} .sw.s5,.ar.s5{background:var(--s5)}
.sw.s6,.ar.s6{background:var(--s6)} .sw.other,.ar.other{background:var(--other)}
.chartbox{margin-top:8px}
.chartbox svg{display:block; width:100%; height:auto}
.chartbox .frame{min-width:640px}
.gridline{stroke:var(--rule); stroke-width:1}
.axis{stroke:var(--rule); stroke-width:1}
.ticklbl{fill:var(--muted); font-size:10.5px;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.yearlbl{fill:var(--ink-2); font-size:11px; font-weight:600}
.hit{fill:transparent}
.hit:hover{fill:var(--ink); fill-opacity:.05}
.band-edge{fill:none; stroke:var(--surface); stroke-width:2}
.dlabel{font-size:11px; font-weight:600; fill:var(--ink)}
.dlabel-bg{fill:var(--surface); fill-opacity:.82}
"""

def year_ticks(months, xfn=None, min_gap=30):
    """January of each year. With xfn given, drop labels that would collide."""
    raw = [(i, m[:4]) for i, m in enumerate(months) if m.endswith("-01") or i == 0]
    if xfn is None:
        return raw
    out, last = [], None
    for i, yr in raw:
        px = xfn(i)
        if last is None or px - last >= min_gap:
            out.append((i, yr, True))
            last = px
        else:
            out.append((i, yr, False))
    return out

def nice_ticks(top, n=4):
    if top <= 0:
        return [0]
    import math
    raw = top / n
    mag = 10 ** math.floor(math.log10(raw))
    step = next(s * mag for s in (1, 2, 2.5, 5, 10) if s * mag >= raw)
    ticks, v = [], 0
    while v <= top * 1.0001:
        ticks.append(int(v)); v += step
    if ticks[-1] < top:
        ticks.append(int(ticks[-1] + step))
    return ticks

def axis_fmt(v):
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M".replace(".0M", "M")
    if v >= 1000:
        return f"{v//1000}k"
    return str(v)

def stacked_area(months, series, W=1000, H=310):
    """series: list of (label, css-class, [values per month])."""
    ml, mr, mt, mb = 52, 96, 12, 30
    pw, ph = W - ml - mr, H - mt - mb
    n = len(months)
    totals = [sum(s[2][i] for s in series) for i in range(n)]
    top = max(totals) or 1
    ticks = nice_ticks(top)
    top = ticks[-1]
    x = lambda i: ml + (i / max(n - 1, 1)) * pw
    y = lambda v: mt + ph - (v / top) * ph

    parts = []
    for v in ticks:
        parts.append(f'<line class="gridline" x1="{ml}" x2="{ml+pw}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>')
        parts.append(f'<text class="ticklbl" x="{ml-8}" y="{y(v)+3.5:.1f}" text-anchor="end">{axis_fmt(v)}</text>')

    for i, yr, _ in year_ticks(months, x):
        parts.append(f'<line class="axis" x1="{x(i):.1f}" x2="{x(i):.1f}" y1="{mt}" y2="{mt+ph}" '
                     f'stroke-dasharray="2 3" stroke-opacity=".55"/>')

    lower = [0.0] * n
    labels = []
    for label, cls, vals in series:
        upper = [lower[i] + vals[i] for i in range(n)]
        pts_up = " ".join(f"{x(i):.1f},{y(upper[i]):.1f}" for i in range(n))
        pts_dn = " ".join(f"{x(i):.1f},{y(lower[i]):.1f}" for i in range(n - 1, -1, -1))
        parts.append(f'<polygon fill="var(--{cls})" points="{pts_up} {pts_dn}"/>')
        parts.append(f'<polyline class="band-edge" points="{pts_up}"/>')
        thickness = upper[-1] - lower[-1]
        if thickness / top > 0.035:
            labels.append((label, (y(upper[-1]) + y(lower[-1])) / 2))
        lower = upper

    used = []
    for label, ly in sorted(labels, key=lambda t: t[1]):
        while any(abs(ly - u) < 14 for u in used):
            ly += 14
        used.append(ly)
        parts.append(f'<text class="dlabel" x="{ml+pw+8}" y="{ly+3.5:.1f}">{esc(label)}</text>')

    for i, yr, show in year_ticks(months, x):
        if show:
            parts.append(f'<text class="yearlbl" x="{x(i):.1f}" y="{H-9}" '
                         f'text-anchor="middle">{yr}</text>')

    step = pw / max(n - 1, 1)
    for i, m in enumerate(months):
        top3 = sorted(((s[0], s[2][i]) for s in series if s[2][i]), key=lambda t: -t[1])[:3]
        tip = (f"{MON[int(m[5:7])-1]} {m[:4]} — {fmt(totals[i])} Zeilen · "
               + ", ".join(f"{a} {fmt(b)}" for a, b in top3))
        parts.append(f'<rect class="hit" x="{x(i)-step/2:.1f}" y="{mt}" width="{step:.1f}" '
                     f'height="{ph}" data-tip="{esc(tip)}"/>')
    return (f'<div class="chartbox"><div class="scroll"><div class="frame">'
            f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Codezeilen je Sprache über die Zeit">'
            f'{"".join(parts)}</svg></div></div></div>')

def stacked_bars(months, human, auto, W=1000, H=250):
    ml, mr, mt, mb = 52, 20, 12, 30
    pw, ph = W - ml - mr, H - mt - mb
    n = len(months)
    tot = [human[i] + auto[i] for i in range(n)]
    ticks = nice_ticks(max(tot) or 1)
    top = ticks[-1]
    slot = pw / n
    bw = max(slot - 2, 1.5)
    y = lambda v: mt + ph - (v / top) * ph
    parts = []
    for v in ticks:
        parts.append(f'<line class="gridline" x1="{ml}" x2="{ml+pw}" y1="{y(v):.1f}" y2="{y(v):.1f}"/>')
        parts.append(f'<text class="ticklbl" x="{ml-8}" y="{y(v)+3.5:.1f}" text-anchor="end">{axis_fmt(v)}</text>')
    for i, m in enumerate(months):
        bx = ml + i * slot + (slot - bw) / 2
        hh = (human[i] / top) * ph
        ah = (auto[i] / top) * ph
        if ah > 0:
            parts.append(f'<rect x="{bx:.1f}" y="{y(tot[i]):.1f}" width="{bw:.1f}" '
                         f'height="{max(ah,1):.1f}" fill="var(--other)" rx="1.5"/>')
        if hh > 0:
            parts.append(f'<rect x="{bx:.1f}" y="{y(human[i]):.1f}" width="{bw:.1f}" '
                         f'height="{max(hh,1):.1f}" fill="var(--s1)" rx="1.5"/>')
        tip = (f"{MON[int(m[5:7])-1]} {m[:4]} — {human[i]} Commits"
               + (f", {auto[i]} Automation" if auto[i] else ""))
        parts.append(f'<rect class="hit" x="{ml+i*slot:.1f}" y="{mt}" width="{slot:.1f}" '
                     f'height="{ph}" data-tip="{esc(tip)}"/>')
    for i, yr, show in year_ticks(months, lambda k: ml + k * slot + slot / 2):
        if show:
            parts.append(f'<text class="yearlbl" x="{ml+i*slot+slot/2:.1f}" y="{H-9}" '
                         f'text-anchor="middle">{yr}</text>')
    parts.append(f'<line class="axis" x1="{ml}" x2="{ml+pw}" y1="{mt+ph}" y2="{mt+ph}"/>')
    return (f'<div class="chartbox"><div class="scroll"><div class="frame">'
            f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Commits pro Monat">'
            f'{"".join(parts)}</svg></div></div></div>')

def render(d):
    M, C, A = d["months"], d["commits"]["human"], d["commits"]["automation"]
    T, L = d["loc_total"], d["loc_cumulative"]
    n = len(M)
    ranked = sorted(L.items(), key=lambda kv: -kv[1][-1])
    top6 = ranked[:6]
    rest = ranked[6:]
    other = [sum(v[i] for _, v in rest) for i in range(n)]
    series = [(k, SERIES[j], v) for j, (k, v) in enumerate(top6)]
    if any(other):
        series.append(("Übrige", "other", other))

    legend = "".join(f'<span class="lg"><i class="sw {cls}"></i>{esc(lbl)}</span>'
                     for lbl, cls, _ in series)

    # Jahrestabelle
    years = sorted({m[:4] for m in M})
    yrows = []
    for yv in years:
        idx = [i for i, m in enumerate(M) if m.startswith(yv)]
        c = sum(C[i] for i in idx)
        a = sum(A[i] for i in idx)
        end = T[idx[-1]]
        start = T[idx[0] - 1] if idx[0] > 0 else 0
        peak = max(d["authors_per_month"][i] for i in idx)
        new_repos = sum(1 for v in d["repo_first_commit"].values() if v.startswith(yv))
        yrows.append(
            f"<tr><th scope='row'>{yv}</th>"
            f"<td class='num strong'>{fmt(c)}</td><td class='num quiet'>{fmt(a)}</td>"
            f"<td class='num'>{peak}</td><td class='num'>{new_repos}</td>"
            f"<td class='num'>{fmt(end)}</td>"
            f"<td class='num pos'>{signed(end-start)}</td></tr>")

    # Sprachtabelle: heute / vor 12M / vor 24M
    i12 = max(n - 13, 0); i24 = max(n - 25, 0)
    lrows = []
    for k, v in ranked:
        if v[-1] == 0:
            continue
        d12 = v[-1] - v[i12]
        share = v[-1] / T[-1] * 100 if T[-1] else 0
        growth = (f"{v[-1]/v[i12]:.1f}×" if v[i12] else "neu")
        lrows.append(
            f"<tr><th scope='row'>{esc(k)}</th>"
            f"<td class='num strong'>{fmt(v[-1])}</td>"
            f"<td class='num'>{share:.1f}%</td>"
            f"<td class='num'>{fmt(v[i12])}</td>"
            f"<td class='num'>{fmt(v[i24])}</td>"
            f"<td class='num pos'>{signed(d12)}</td>"
            f"<td class='num'>{growth}</td></tr>")

    # Repos nach Commits
    rc = d["repo_commits"]
    auto = set(d["automation_repos"])
    rrows = []
    for name, vals in sorted(rc.items(), key=lambda kv: -sum(kv[1]))[:15]:
        tot = sum(vals)
        if not tot:
            continue
        last12 = sum(vals[i12:])
        first = d["repo_first_commit"].get(name, "–")
        rrows.append(
            f"<tr><th scope='row'><code>{esc(name)}</code>"
            f"{' <span class=tag>Automation</span>' if name in auto else ''}</th>"
            f"<td class='num strong'>{fmt(tot)}</td><td class='num'>{fmt(last12)}</td>"
            f"<td class='num quiet'>{esc(first)}</td></tr>")

    cal = d["calibration"]
    span = f"{MON[int(M[0][5:7])-1]} {M[0][:4]} bis {MON[int(M[-1][5:7])-1]} {M[-1][:4]}"
    peak_month = max(range(n), key=lambda i: C[i])

    return f"""<title>Wachstum der Codebasis</title>
<style>{CSS}{EXTRA_CSS}</style>
<div class="wrap">

<header class="masthead">
  <div>
    <span class="eyebrow">{esc(span)} · {d['repos_scanned']} Repositories</span>
    <h1>Wachstum der Codebasis</h1>
    <p class="range">Commits und Codezeilen je Sprache, Monat für Monat —
      gemessen am Baum zum jeweiligen Monatsende, nicht hochgerechnet.</p>
  </div>
  <div class="stamp">{len(M)} Monate<br><code>octo-tools/metrics</code></div>
</header>

<div class="tiles">
  <div class="tile"><span class="k">Commits</span><span class="v">{fmt(sum(C))}</span>
    <span class="s">+ {fmt(sum(A))} von Bots</span></div>
  <div class="tile"><span class="k">Zeilen heute</span><span class="v">{fmt(T[-1])}</span>
    <span class="s">aus {fmt(T[i12])} vor 12 Monaten</span></div>
  <div class="tile"><span class="k">Wachstum 12 M</span>
    <span class="v">{T[-1]/T[i12]:.1f}×</span>
    <span class="s">{signed(T[-1]-T[i12])} Zeilen</span></div>
  <div class="tile"><span class="k">Aktivster Monat</span>
    <span class="v">{C[peak_month]}</span>
    <span class="s">{MON[int(M[peak_month][5:7])-1]} {M[peak_month][:4]}</span></div>
  <div class="tile"><span class="k">Repositories</span>
    <span class="v">{len([1 for v in rc.values() if sum(v)])}</span>
    <span class="s">mit Commits im Zeitraum</span></div>
</div>

<section>
  <h2>Commits pro Monat</h2>
  <p class="lede">Default-Branch, ohne Merge-Commits. Grau sind die Katalog- und
     Build-Repos, die von CI-Bots beschrieben werden — sie sind echte Commits,
     aber keine Entwicklungsarbeit.</p>
  <div class="legend"><span class="lg"><i class="sw s1"></i>Menschen</span>
    <span class="lg"><i class="sw other"></i>Automation</span></div>
  {stacked_bars(M, C, A)}
</section>

<section>
  <h2>Codezeilen je Sprache</h2>
  <p class="lede">Bestand am jeweiligen Monatsende, gestapelt. Generierter Code,
     Lockfiles und LFS-Daten sind ausgenommen; die sechs größten Sprachen sind
     einzeln ausgewiesen, der Rest als <em>Übrige</em>.</p>
  <div class="legend">{legend}</div>
  {stacked_area(M, series)}
</section>

<section>
  <h2>Jahre im Vergleich</h2>
  <p class="lede">Höchste Zahl gleichzeitig aktiver Autoren in einem Monat des Jahres,
     neu hinzugekommene Repositories und der Zeilenbestand am Jahresende.</p>
  <div class="scroll"><table class="grid"><thead><tr>
    <th scope="col">Jahr</th><th scope="col" class="num">Commits</th>
    <th scope="col" class="num">davon Bots</th><th scope="col" class="num">Autoren max.</th>
    <th scope="col" class="num">Neue Repos</th><th scope="col" class="num">Zeilen Jahresende</th>
    <th scope="col" class="num">Δ Jahr</th>
  </tr></thead><tbody>{''.join(yrows)}</tbody></table></div>
</section>

<section>
  <h2>Sprachen im Detail</h2>
  <p class="lede">Bestand heute, Anteil an der Gesamtcodebasis und der Vergleich mit
     dem Stand vor 12 und 24 Monaten.</p>
  <div class="scroll"><table class="grid"><thead><tr>
    <th scope="col">Sprache</th><th scope="col" class="num">Heute</th>
    <th scope="col" class="num">Anteil</th><th scope="col" class="num">vor 12 M</th>
    <th scope="col" class="num">vor 24 M</th><th scope="col" class="num">Δ 12 M</th>
    <th scope="col" class="num">Faktor</th>
  </tr></thead><tbody>{''.join(lrows)}</tbody></table></div>
</section>

<section>
  <h2>Repositories nach Commits</h2>
  <p class="lede">Die 15 aktivsten über die gesamte Historie, mit ihrem Anteil aus den
     letzten zwölf Monaten und dem Monat des ersten Commits.</p>
  <div class="scroll"><table class="grid"><thead><tr>
    <th scope="col">Repo</th><th scope="col" class="num">Commits gesamt</th>
    <th scope="col" class="num">letzte 12 M</th><th scope="col" class="num">erster Commit</th>
  </tr></thead><tbody>{''.join(rrows)}</tbody></table></div>
</section>

<footer>
  Für jeden Monat mit Commits wird der Baum des letzten Commits dieses Monats
  direkt aus den Git-Objekten vermessen; Monate ohne Commits übernehmen den
  Vorwert. Gegenprobe gegen den heute gemessenen Bestand:
  {fmt(cal['integrated_final'])} zu {fmt(cal['measured_head'])} Zeilen,
  Abweichung {signed(cal['drift'])} ({cal['drift_pct']:+}%).
  Erfasst ist nur der Default-Branch jedes Repos — nie gemergte Feature-Branches
  fehlen, und Repositories, die vor der Messung gelöscht wurden, ebenso.
  Historien-Umschreibungen (Squash, Rebase, Filter) datieren Code auf den
  Zeitpunkt des Rewrites um.
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
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "w").write(render(json.load(open(a.snapshot))))
    print(f"-> {a.out}")

if __name__ == "__main__":
    main()
