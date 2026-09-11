#!/usr/bin/env python3
"""Render the quality snapshot as self-contained HTML.

Bewusst getrennt vom Wochen- und Historienreport: die messen Volumen, dieser misst
Verfassung. Eine Seite, die beides mischt, laedt dazu ein, Wachstum als Fortschritt
zu lesen.
"""
import argparse, json, os, sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_report import CSS, JS, fmt, signed, esc

EXTRA_CSS = """
.verdict{display:flex; align-items:baseline; gap:10px; margin:0 0 14px}
.verdict .big{font-size:26px; font-weight:700; letter-spacing:-.02em}
.rule-ok{color:var(--pos)} .rule-bad{color:var(--neg)}
td.path{white-space:normal; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  font-size:11.5px; max-width:430px; line-height:1.45}
.ratio-track{background:var(--surface-3); height:9px; border-radius:4px; overflow:hidden;
  min-width:90px}
.ratio-bar{display:block; height:100%; background:var(--accent); border-radius:4px}
.ratio-bar.warn{background:var(--neg)}
"""


def pct(x, digits=1):
    return "–" if x is None else f"{x * 100:.{digits}f}%"


def chip(n, zero_good=True):
    if n == 0:
        return '<span class="chip chip-good">0</span>'
    return f'<span class="chip chip-warn">{n}</span>'


def rules_section(arch):
    v = arch["violations"]
    rows = [
        ("Contracts referenziert Implementierung", len(v["contracts_to_impl"]),
         "Die Vertragsschicht muss ohne die Implementierung uebersetzbar bleiben."),
        ("Produktionscode referenziert Testprojekt", len(v["prod_to_test"]),
         "Testfixtures duerfen nicht ins Produkt ausgeliefert werden."),
        ("Zyklen zwischen Projekten", len(v["cycles"]),
         "Ein Zyklus macht jede Schichtaussage wertlos."),
        ("Persistenztypen ausserhalb ihrer Schicht", len(v["persistence_leak"]),
         "MongoDB- und CrateDb-Typen gehoeren hinter die Repository-Grenze."),
        ("Tote Usings auf Persistenz-Namespaces", len(arch["dead_usings"]),
         "Kein Schichtbruch, aber Aufraeumarbeit — und ein Hinweis, dass hier "
         "einmal einer war."),
    ]
    body = "".join(
        f"<tr><th scope='row'>{esc(name)}</th>"
        f"<td class='num'>{chip(n)}</td>"
        f"<td class='quiet'>{esc(why)}</td></tr>" for name, n, why in rows)
    return f"""<div class="scroll"><table class="grid">
<thead><tr><th>Regel</th><th class="num">Treffer</th><th>Warum</th></tr></thead>
<tbody>{body}</tbody></table></div>"""


def findings_table(arch):
    v = arch["violations"]
    rows = []
    for e in v["contracts_to_impl"]:
        rows.append(("Contracts → Impl", e["repo"], f"{e['from']} → {e['to']}"))
    for e in v["prod_to_test"]:
        rows.append(("Prod → Test", e["repo"], f"{e['from']} → {e['to']}"))
    for c in v["cycles"]:
        rows.append(("Zyklus", "—", " → ".join(c)))
    for e in v["persistence_leak"]:
        rows.append(("Persistenz", e["repo"],
                     f"{e['path']} ({', '.join(e['namespaces'])})"))
    if not rows:
        return '<p class="empty">Keine Verletzung. Der Graph ist sauber.</p>'
    body = "".join(
        f"<tr><td><span class='tag'>{esc(kind)}</span></td>"
        f"<td class='who'>{esc(repo)}</td><td class='path'>{esc(what)}</td></tr>"
        for kind, repo, what in rows)
    return f"""<div class="scroll"><table class="grid">
<thead><tr><th>Art</th><th>Repo</th><th>Fundstelle</th></tr></thead>
<tbody>{body}</tbody></table></div>"""


def fanin_section(arch):
    c, e = arch["fanin_contracts"], arch["fanin_engine"]
    ratio = f"{c / e:.1f}" if e else "–"
    top = "".join(
        f"<li><span class='who'>{esc(k)}</span>"
        f"<span class='share-track'><i class='share-bar' style='width:"
        f"{min(100, v / max(arch['package_fanin'].values()) * 100):.0f}%'></i></span>"
        f"<span class='share-num'>{v}×</span></li>"
        for k, v in list(arch["package_fanin"].items())[:12])
    return f"""<p class="lede">Wie oft ein eigenes Paket von anderen Projekten
    referenziert wird. Die Vertragspakete sollen oben stehen — steht die
    Implementierung oben, ist die Schichtung am Ausfransen.</p>
<div class="verdict"><span class="big">{ratio}&thinsp;:&thinsp;1</span>
  <span class="quiet">Contracts zu Engine ({c} zu {e} Referenzen)</span></div>
<ol class="share">{top}</ol>"""


def test_table(repos, limit=18):
    rows = [r for r in repos.items() if r[1]["prod_loc"] > 2000]
    rows.sort(key=lambda r: (r[1]["test_ratio"] is None, r[1]["test_ratio"] or 0))
    body = ""
    for name, r in rows[:limit]:
        tr = r["test_ratio"]
        w = min(100, (tr or 0) * 200)          # 50% Testanteil fuellt den Balken
        cls = "warn" if (tr or 0) < 0.10 else ""
        body += (f"<tr><th scope='row'>{esc(name)}</th>"
                 f"<td class='num'>{fmt(r['prod_loc'])}</td>"
                 f"<td class='num'>{fmt(r['test_loc'])}</td>"
                 f"<td><span class='ratio-track'><i class='ratio-bar {cls}' "
                 f"style='width:{w:.0f}%'></i></span></td>"
                 f"<td class='num strong'>{pct(tr)}</td>"
                 f"<td class='num'>{r['complexity_density'] or '–'}</td>"
                 f"<td class='num'>{pct(r['rework_ratio'])}</td></tr>")
    return f"""<div class="scroll"><table class="grid">
<thead><tr><th>Repo</th><th class="num">Produktion</th><th class="num">Test</th>
<th></th><th class="num">Anteil</th><th class="num">Kompl.</th>
<th class="num">Rework</th></tr></thead>
<tbody>{body}</tbody></table></div>"""


def render(snap):
    code, arch = snap["code"], snap["architecture"]
    gen = datetime.fromisoformat(snap["generated_at"])
    d = snap.get("delta", {})
    total_v = sum(len(x) for x in arch["violations"].values())

    def dchip(key, suffix="", good="down"):
        val = d.get(key)
        if val is None:
            return ""
        cls = "chip-good" if ((val < 0) == (good == "down")) and val else "chip-warn"
        if not val:
            cls = "chip-flat"
        return f' <span class="chip {cls}">{signed(val)}{suffix}</span>'

    tiles = [
        ("Schichtverletzungen", str(total_v),
         f"{arch['projects']} Projekte, {arch['project_refs']} Verweise"),
        ("Test-Anteil", pct(code["test_ratio"]),
         f"{fmt(code['test_loc'])} zu {fmt(code['prod_loc'])} Zeilen"),
        ("Rework-Rate", pct(code["rework_ratio"]),
         f"{fmt(code['rework']['rework'])} von {fmt(code['rework']['changed'])} "
         f"Zeilen, {snap['window']['days']} Tage"),
        ("Komplexität", f"{code['complexity_density'] or '–'}",
         "Entscheidungspunkte / 1.000 Zeilen"),
        ("Tote Usings", str(len(arch["dead_usings"])), "Persistenz-Namespaces"),
    ]
    tiles_html = "".join(
        f'<div class="tile"><span class="k">{esc(k)}</span><span class="v">{v}</span>'
        f'<span class="s">{esc(s)}</span></div>' for k, v, s in tiles)

    return f"""<title>OctoMesh Qualitätspuls</title>
<style>{CSS}{EXTRA_CSS}</style>
<div class="wrap">

<header class="masthead">
  <div>
    <span class="eyebrow">Stand {gen.strftime('%d.%m.%Y')} ·
      {snap['repos_scanned']} Repositories</span>
    <h1>Qualitätspuls</h1>
    <p class="range">Schichttreue, Testabdeckung und Nacharbeit — bewusst getrennt
      vom Wochenpuls, der das Volumen misst.</p>
  </div>
  <div class="stamp">erzeugt {gen.strftime('%d.%m.%Y %H:%M')} UTC<br>
    <code>octo-tools/metrics</code></div>
</header>

<div class="tiles">{tiles_html}</div>

<section>
  <h2>Schichtkonformität{dchip('violations')}</h2>
  <p class="lede">Die Schicht steckt im Projektnamen — <code>*.Contracts</code>
     als Vertrag, <code>*.Engine</code> und <code>Infrastructure</code> als
     Implementierung. Diese Regeln halten den Zustand, sie stellen ihn nicht her.</p>
  {rules_section(arch)}
  <h3>Fundstellen</h3>
  {findings_table(arch)}
</section>

<section>
  <h2>Paket-Fan-in</h2>
  {fanin_section(arch)}
</section>

<section>
  <h2>Test, Komplexität, Nacharbeit{dchip('test_ratio', good='up')}</h2>
  <p class="lede">Aufsteigend nach Test-Anteil, nur Repos über 2.000 Produktionszeilen.
     Rot markiert unter 10 %. Die Rework-Rate ist der Anteil der Änderungen an
     Dateien, die vor weniger als 30 Tagen zuletzt angefasst wurden — sie erfasst
     sofort behobene Fehler auch dann, wenn dafür kein Work Item entsteht.</p>
  {test_table(snap['repos'])}
</section>

<footer>
  <p>Gemessen am HEAD-Baum jedes Default-Branch, dieselben Ausschlüsse wie im
  Wochenpuls: generierter Code, Lockfiles, LFS, Minified, publizierte Kataloge,
  Forks und archivierte Repos.</p>
  <p>Die Komplexitätszahl ist eine Regex-Näherung über Entscheidungspunkte, kein
  Ersatz für einen echten Analyser — sie taugt für den Trend, nicht für ein Urteil
  über eine einzelne Datei. Der Test-Anteil misst Zeilen, nicht Abdeckung: viel
  Testcode ist kein Beweis für gute Tests, wenig Testcode aber ein belastbarer
  Hinweis auf fehlende.</p>
  <p>Bug-Kennzahlen aus Azure DevOps fehlen bewusst. Bugs werden hier meist selbst
  gefunden und am selben Tag behoben; eine Laufzeit- oder Mengenmetrik würde in
  diesem Arbeitsmodus die Meldedisziplin messen, nicht die Qualität.</p>
</footer>

</div>
<div id="tip"></div>
<script>{JS}</script>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    with open(args.snapshot, encoding="utf-8") as fh:
        snap = json.load(fh)
    html = render(snap)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print(f"{args.out} ({len(html) // 1024} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
