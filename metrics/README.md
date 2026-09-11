# Weekly Dev Report

Wöchentlicher Entwicklungsreport über die GitHub-Org `meshmakers`: Commits,
Commit- und Code-Komplexität, Autoren, Zeitverteilung, Codezeilen je Sprache
und die Veränderung je Repository.

## Drei Reports

| Report | Workflow | Takt | Skripte |
|---|---|---|---|
| **Wochenpuls** — was ist diese Woche passiert | `weekly-dev-report.yml` | Mo 05:00 UTC | `collect_metrics.py` → `render_report.py` |
| **Wachstum der Codebasis** — Monatshistorie seit dem ersten Commit | `monthly-history-report.yml` | 1. des Monats 04:00 UTC | `history_metrics.py --exact` → `render_history.py` |
| **Qualitätspuls** — Schichttreue, Test-Anteil, Nacharbeit | `quality-report.yml` | Mo 05:40 UTC | `quality_metrics.py` → `render_quality.py` |

## Was läuft wann

`.github/workflows/weekly-dev-report.yml` läuft **montags 05:00 UTC**
(und per `workflow_dispatch` jederzeit) und tut drei Dinge:

1. klont jedes nicht-archivierte Org-Repo ausser Forks flach (`--depth 400`, Default-Branch),
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
(fine-grained: Contents + Metadata read-only; klassisch: `repo:read`).

Das Secret existiert bereits für `sync-eslint.yml`, war beim ersten Lauf am
29.08.2026 aber **abgelaufen** (HTTP 401). Der Collector prüft den Token
deshalb vorab und bricht mit einer Klartextmeldung ab, statt später mit einem
Traceback. Reicht nur der Scope nicht, meldet er die fehlgeschlagenen Klone
als `::warning::` und rechnet ohne sie weiter — beim ersten Lauf nach einer
Rotation also in die Warnungen schauen.

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

Ausgeschlossen sind ausserdem **Forks**: sie enthalten fremden Code, der die
Sprachstatistik dort kippt, wo die Org wenig Eigenes hat. Zum Stand 2026-W37
stammten 74% allen Pythons aus `crate-operator` und 36% aller Go-Zeilen aus
`external-dns-opnsense-webhook` -- einem Fork ohne einen einzigen eigenen
Commit. Ueber alle Sprachen waren es 35.061 von 1.932.536 Zeilen (1,8%).

Ebenfalls ausgeschlossen sind die **publizierten Kataloge** (`ck-models/`,
`blueprints/v1/`, `charts/`, `apps/`): je eine serialisierte Datei pro
veröffentlichter Version jedes CK-Modells, Blueprints und Charts, von der CI
geschrieben und nie von Hand bearbeitet. Sie wachsen mit jedem Release monoton
— `System.Communication` allein trägt 26 Versionen à ~2.900 Zeilen — und
machten **91 % aller JSON-Zeilen** aus. Die handgeschriebenen Quellen
(`src/CkModels/**/ckModel.yaml`) bleiben selbstverständlich gezählt.

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

## Qualitätspuls

Volumen und Qualität sind bewusst getrennte Reports. Eine Seite, die beides zeigt,
lädt dazu ein, Wachstum als Fortschritt zu lesen — bei 4,2× LOC-Wachstum im Jahr
2026 und median 8 aktiven Autoren pro Monat ist das die falsche Lesart.

**Schichtkonformität.** Die Schicht steckt im Projektnamen und wird durchgehalten:
`*.Contracts` als Vertrag, `*.Engine` und `Infrastructure` als Implementierung,
`*.Tests` darüber. Geprüft wird gegen den `.csproj`-Graphen:

| Regel | Warum |
|---|---|
| `*.Contracts` referenziert keine Implementierung | Der Vertrag muss ohne sie übersetzbar bleiben |
| Produktionscode referenziert kein Testprojekt | Fixtures gehören nicht ins Produkt |
| keine Zyklen zwischen Projekten | Ein Zyklus macht jede Schichtaussage wertlos |
| Persistenztypen nur hinter der Repository-Grenze | `MongoDB.*`, `Npgsql`, `CrateDb.*` |

Erster Lauf (2026-09, 71 Repos, 201 Projekte): Contracts→Impl 0, Zyklen 0,
Prod→Test 1, Persistenz 2. Der Wert liegt also nicht im Aufräumen — die Architektur
ist in Ordnung — sondern darin, dass Verfall auffällt, bevor er sich festsetzt.

Zwei Fallstricke, die beim Bau dieser Regeln aufgetreten sind und die das Skript
deshalb gesondert behandelt:

- **Tote Usings sind kein Schichtbruch.** Fünf Identity-Controller importierten
  `MongoDB.Bson`, benutzten daraus aber nichts — alle 33 `ObjectId`-Treffer waren
  der hauseigene `OctoObjectId` aus `ConstructionKit.Contracts`. Sie werden
  getrennt gezählt; würden sie als Verletzung erscheinen, wäre die Zahl unbrauchbar.
- **Die Persistenzschicht darf Persistenz.** `Runtime.Engine.MongoDb` an sich selbst
  zu melden ergab im ersten Entwurf 15 Fehlalarme. Projekte, deren Name auf
  `.MongoDb`, `.CrateDb`, `.Postgres`, `.Npgsql`, `.Sql` oder `.Persistence` endet,
  sind ausgenommen, Testcode ebenfalls.

**Test-Anteil** ist Test-LOC ÷ Produktions-LOC, erkannt an Pfad und Dateiname
(`tests/`, `*.spec.ts`, `*Tests.cs`, `*_test.go`). Das misst Zeilen, nicht
Abdeckung: viel Testcode beweist keine guten Tests, wenig Testcode ist aber ein
belastbarer Hinweis auf fehlende.

**Rework-Rate** ist der Anteil geänderter Zeilen in Dateien, die vor weniger als
30 Tagen zuletzt angefasst wurden — ein Durchlauf durch die Historie, der je Datei
den letzten Anfasszeitpunkt mitführt. Sie ersetzt die Bug-Statistik: wer einen
Fehler bemerkt und sofort behebt, legt dafür kein Work Item an, aber der Fix ist
ein Commit auf frischem Code.

**Produktblock aus Azure DevOps** (`ado_metrics.py`, optional). Zwei Zahlen je
Monat, keine dritte:

| Kennzahl | Definition |
|---|---|
| Bug-Anteil | Bugs ÷ (Bugs + Issues) neu angelegter Work Items |
| Escape | Anteil der behobenen Bugs mit `CreatedBy` ≠ `ResolvedBy` |

Bewusst *keine* Bug-Laufzeit und *keine* absolute Bug-Menge: Bugs werden hier
selbst eingetragen und meist am selben Tag behoben (AB#4931: angelegt 09:46,
geschlossen 21:30). Die Laufzeit misst dann die Tippgeschwindigkeit, die Menge die
Meldedisziplin — wer sauberer dokumentiert, sähe schlechter aus. Der Bug-Anteil
unterwirft beide Seiten derselben Disziplin und kürzt sie heraus; der Escape
trennt „selbst bemerkt" von „jemand anderes hat es gefunden", und Ersteres ist ein
Qualitätsbeweis, kein Makel.

`AreaPath` wird mitgeschrieben, aber nicht zur Unterscheidung benutzt: in einer
Stichprobe vergleichbarer Bugs stand mal `OctoMesh`, mal `OctoMesh\Product Team`.

Der Block braucht das Repo-Secret `ADO_PAT` mit **Work Items (Read)**. Fehlt es,
wird er übersprungen und der Report läuft weiter — er ist die Zugabe, der Code-
und Architekturteil die Hauptaussage. Vor der konsequenten Erfassung (etwa ab
Mitte 2026) sind die Monatswerte nicht vergleichbar; der Report weist das aus.

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

# Qualitätspuls, ebenfalls ohne GitHub-Zugriff
python3 metrics/quality_metrics.py --mode local \
  --local-root ~/RiderProjects/meshmakers/main --days 30 \
  --exclude "$(python3 -c "import json;print(','.join(json.load(open('metrics/config.json'))['automation_repos']))")" \
  --out /tmp/quality.json
python3 metrics/render_quality.py --snapshot /tmp/quality.json --out /tmp/quality.html
```

Im `--mode local` stammt der LOC-Stand immer aus dem aktuellen Arbeitsbaum —
Δ-Werte sind dort nur zwischen zwei echten Läufen zu verschiedenen Zeitpunkten aussagekräftig.
