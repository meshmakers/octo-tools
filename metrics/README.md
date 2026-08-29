# Weekly Dev Report

Wöchentlicher Entwicklungsreport über die GitHub-Org `meshmakers`: Commits,
Commit- und Code-Komplexität, Autoren, Zeitverteilung, Codezeilen je Sprache
und die Veränderung je Repository.

## Zwei Reports

| Report | Workflow | Takt | Skripte |
|---|---|---|---|
| **Wochenpuls** — was ist diese Woche passiert | `weekly-dev-report.yml` | Mo 05:00 UTC | `collect_metrics.py` → `render_report.py` |
| **Wachstum der Codebasis** — Monatshistorie seit dem ersten Commit | `monthly-history-report.yml` | 1. des Monats 04:00 UTC | `history_metrics.py --exact` → `render_history.py` |

## Was läuft wann

`.github/workflows/weekly-dev-report.yml` läuft **montags 05:00 UTC**
(und per `workflow_dispatch` jederzeit) und tut drei Dinge:

1. klont jedes nicht-archivierte Org-Repo flach (`--depth 400`, Default-Branch),
2. schreibt einen Snapshot nach `metrics/data/<ISO-Woche>.json` (plus `latest.json`),
3. rendert `metrics/reports/<ISO-Woche>.html` und committet beides zurück.

Der Report liegt zusätzlich als Workflow-Artifact (90 Tage) und als
Job-Summary im Actions-Run.

`monthly-history-report.yml` läuft **am 1. jedes Monats** und braucht
**vollständige** Klone (keine `--depth`-Begrenzung), weil `--exact` für jeden
Monat mit Commits den Baum des letzten Commits dieses Monats direkt aus den
Git-Objekten vermisst — `git ls-tree` plus `git cat-file --batch`, ohne Checkout.
Monate ohne Commits übernehmen den Vorwert. Das Ergebnis wird gegen den heute
gemessenen Bestand gegengeprüft und die Abweichung ausgewiesen (zuletzt −31
Zeilen auf 2,3 Mio, also −0,0 %).

Die naheliegende Alternative — den Verlauf aus `git log --numstat`
aufzuintegrieren, wie es GitHubs Code-Frequency-Graph tut — lag am Ende
**+16,9 %** über dem echten Bestand und ist deshalb verworfen worden.

## Voraussetzung

Repo-Secret **`REPO_ACCESS_TOKEN`** mit Leserechten auf alle Org-Repos
(`contents: read`, `metadata: read`). Das Secret existiert bereits für
`sync-eslint.yml`; reicht sein Scope nicht, meldet der Collector die
fehlgeschlagenen Klone als `::warning::` und rechnet ohne sie weiter.

## Was gemessen wird

| Kennzahl | Bedeutung |
|---|---|
| Commits | Default-Branch, ohne Merge-Commits |
| Ø Zeilen/Commit, Ø Dateien/Commit | Commit-Komplexität je Autor |
| Churn | gelöschte ÷ hinzugefügte Zeilen; > 1,00 = Rückbau/Refactoring |
| Code-LOC | Bestand ohne Config, Doku, generierten Code, Lockfiles |
| Kompl. | Entscheidungspunkte (`if/for/while/case/catch`, `&&`, `\|\|`, `?:`) je 1.000 Code-Zeilen. Orientierung: Gesamtwert ~59, Median je Repo ~55, Spanne 19–148 |
| Δ | Vergleich mit dem Snapshot der Vorwoche |

Ausgeschlossen: generierter Code (`globalTypes.ts`, `possibleTypes.ts`,
`schema.graphql`, `/dist/`, `*.designer.cs`, Minified), Lockfiles, Binärdateien
und **Git-LFS-Dateien**. LFS ist nicht kosmetisch: im Arbeitsbaum steht der
gesmudgete Inhalt (in `octo-plug-zenon` 67.000 Zeilen Zenon-Testdaten), im
Objektspeicher nur ein 130-Byte-Pointer — würde man LFS nicht ausschließen,
widersprächen sich Wochen- und Historienreport genau um diesen Betrag.

Zusätzlich greift eine **Inhaltsheuristik**: Dateien mit mehr als 300 Byte je
Zeile gelten als Bundler-Output, egal wie sie heißen. Ohne sie schlug ein
einzelnes ungetarntes webpack-Bundle unter `wwwroot/` mit 15.000
Entscheidungspunkten auf 149 Zeilen durch und trieb die Komplexität von
`octo-asset-repo-services` auf 359 statt 54 — und die Gesamtkennzahl von
59 auf 71.
Repos aus `config.json → automation_repos` werden gescannt, aber aus Commit-,
Autoren- und Rhythmuszahlen herausgerechnet — sonst dominieren CI-Bots die Statistik.

Die Komplexität ist eine **Näherung**, kein statischer Analysator. Ihr Wert
liegt im Wochenvergleich, nicht im Absolutwert.

## Bekannte Lücken

- **Azure DevOps ist nicht abgedeckt.** 16 Repos (u.a. alle `*-deployment`,
  `ponton-xp-messenger`, `LkvLogistik`) liegen auf `dev.azure.com` und fehlen im Report.
- Nur der Default-Branch. Nie gemergte Feature-Branches sind unsichtbar.
- Die erste Ausführung hat keine Vorwoche und zeigt daher überall `neu` statt Δ.

## Lokal ausführen

```bash
# gegen vorhandene Checkouts, ohne GitHub-Zugriff
python3 metrics/collect_metrics.py --mode local \
  --local-root ~/RiderProjects/meshmakers/main --days 7 \
  --exclude "$(python3 -c "import json;print(','.join(json.load(open('metrics/config.json'))['automation_repos']))")" \
  --out /tmp/week.json
python3 metrics/render_report.py --snapshot /tmp/week.json --out /tmp/week.html
```

Im `--mode local` stammt der LOC-Stand immer aus dem aktuellen Arbeitsbaum —
Δ-Werte sind dort nur zwischen zwei echten Läufen zu verschiedenen Zeitpunkten aussagekräftig.
