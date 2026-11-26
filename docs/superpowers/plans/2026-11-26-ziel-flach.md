# Ziel flach (Issue #7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pull.sh rsync://IP/m/A/B/NAME <ziel>` ergibt `<ziel>/NAME`, parallel, mit Resume nach Abbruch.

**Architecture:** Nur für die parallele Phase wird `<ziel>/NAME` in `<ziel>/.w2u-stage-NAME/A/B/NAME` umbenannt, die Worker schreiben mit `_ParDst=<ziel>/.w2u-stage-NAME`. Danach wird zurückbenannt. Sweep, Verify und Bericht bleiben unverändert. Eine PID-Sperre verhindert parallele Läufe, und ein Aufräumschritt beim Start holt liegengebliebene Zwischenordner zurück.

**Tech Stack:** bash 3.2 (BSD und GNU userland), rsync 3.x / openrsync, Testharness `tests/lib/testlib.sh` + `tests/lib/daemon.sh`.

**Spec:** `docs/superpowers/specs/2026-11-26-ziel-flach-design.md`

## Global Constraints

- bash 3.2, BSD- und GNU-Werkzeuge. Keine GNU-only-Flags (`stat -c` nur mit Rückfall `stat -f`).
- Variablen `_PascalCase`, keine One-Liner.
- Quelle mit `/` am Ende, mit nicht spiegelndem Ziel: bleibt einströmig.
- Ziel spiegelt den Präfix schon: Verhalten unverändert, kein Staging.
- Niemals zusammenführen oder löschen, wenn Zwischenordner UND Ziel Inhalt haben. Dann Abbruch.
- `mv` nur, wenn das Gerät gleich ist. Sonst laut einströmig.

## Review Focus

1. Abbruch nach dem Hinein-Umbenennen, dann derselbe Befehl → Daten zurück, Fortsetzen, PASS. (Task 2: Test „Aufräumen")
2. Liegengebliebene Sperre nach kill -9 → der nächste Lauf übernimmt sie. (Task 2: Test „tote PID")
3. `<ziel>/NAME` ist ein leeres Verzeichnis neben dem Zwischenordner (z. B. von `mkdir -p`) → zählt als „fehlt". (Task 2)
4. Trockenlauf verschiebt nichts und legt keinen Zwischenordner an. (Task 3)
5. Nach PASS bleibt nichts übrig: kein `.w2u-stage-*`, kein `.lock`. Die Dateizahl unter `<ziel>` ist gleich der Dateizahl unter `<ziel>/NAME`. (Task 3)

---

### Task 1: Parser erkennt den Staging-Fall

**Files:**
- Modify: `pull.sh` (globale Variablen um Zeile 106-120, `w2u_parse_args` um Zeile 2053-2090)
- Test: `tests/test_cli.sh:546-575`

**Interfaces:**
- Produces: globale Variablen `_Stage` (0/1), `_StageDir` (`<_DstDir>/.w2u-stage-<_Base>`), `_StageLeaf` (`_StageDir/_SrcPrefix`), `_StageLock` (`_StageDir.lock`). Bei `_Stage=1` gilt `_ParDst=_StageDir`, `_ParMode=parallel`.

- [ ] **Step 1: Tests anpassen/schreiben**
  - `Daten/Archiv` → `$_Tmp/ziel`: `_ParMode=parallel`, `_Stage=1`, `_ParDst=$_Tmp/ziel/.w2u-stage-Archiv`, `_StageLeaf=$_Tmp/ziel/.w2u-stage-Archiv/Daten/Archiv`, keine Meldung `EINSTROEMIG`.
  - `Archiv/` → `$_Tmp/ziel`: weiterhin `einstroemig`, `_Stage=0`. Die Meldung bleibt.
  - `Archiv/` → `$_Tmp/ziel/Archiv`: parallel, `_Stage=0`.
  - `Archiv` → `$_Tmp/ziel`: parallel, `_Stage=0`, `_ParDst=$_Tmp/ziel` (unverändert).
  - Die Asserts zum Rat `<ziel>/Daten` entfallen (der Fall ist nicht mehr einströmig).
- [ ] **Step 2:** `bash tests/test_cli.sh` → die neuen Asserts sind rot.
- [ ] **Step 3:** Im else-Zweig: Quelle ohne `/` am Ende → Staging-Variablen setzen. Sonst `w2u_einstroemig` wie bisher, mit einsegmentigem Rat. Zusätzlich die Variable `_SrcSlash` (0/1), die vor dem Abschneiden gesetzt wird.
- [ ] **Step 4:** `bash tests/test_cli.sh` grün.
- [ ] **Step 5:** Commit.

### Task 2: Sperre und Aufräumen im Preflight

**Files:**
- Modify: `pull.sh` (neue Funktionen `w2u_stage_lock`, `w2u_stage_recover` vor `w2u_preflight`; Aufruf im Preflight VOR `mkdir -p "$_DstRoot"`; Freigabe in `w2u_cleanup`)
- Test: `tests/test_e2e.sh` (neue Läufe)

**Interfaces:**
- `w2u_stage_lock()`: nur bei `_Stage=1`, nicht im Trockenlauf und nicht bei `--verify-only`. Legt `mkdir "$_StageLock"` an und schreibt `$$` nach `$_StageLock/pid`. Lebt die eingetragene PID (`kill -0`), folgt `w2u_die` mit der PID; sonst wird die Sperre übernommen (mit Warnung). Setzt `_StageLockOwned=1`.
- `w2u_stage_recover()`: existiert `_StageLeaf`, gilt: `_DstRoot` fehlt oder ist leer → `rmdir` und `mv` zurück, mit Log-Zeile. `_DstRoot` hat Inhalt → `w2u_die` mit beiden Pfaden. Bei `--verify-only` nur `w2u_warn`.
- In `w2u_cleanup`: Ist `_StageLockOwned=1`, folgt `rm -rf "$_StageLock"`. Ein leerer `_StageDir` bleibt nicht liegen (`rmdir` ohne Fehler).

- [ ] **Step 1: E2E-Tests schreiben** (Quelle `Daten/SonoGDT`, wie Lauf 6)
  - „Aufräumen": `<z>/.w2u-stage-SonoGDT/Daten/SonoGDT` mit 3 echten Quelldateien vorab angelegt, `<z>/SonoGDT` fehlt → rc 0, PASS, `diff -r` leer, kein `.w2u-stage-SonoGDT`.
  - „Beide da": Zwischenordner mit Datei und `<z>/SonoGDT/x` → rc 1, Ausgabe enthält `.w2u-stage-SonoGDT`, beide Dateien existieren danach noch.
  - „leeres Ziel": Zwischenordner mit Teilbestand plus leeres `<z>/SonoGDT` → rc 0, PASS.
  - „lebende Sperre": `mkdir <z>/.w2u-stage-SonoGDT.lock; echo $$ > …/pid` → rc 1, Ausgabe nennt die Sperre.
  - „tote Sperre": PID eines beendeten Prozesses (`sh -c 'exit 0' & wait; echo $!`) → rc 0, PASS, Sperre danach weg.
- [ ] **Step 2:** `bash tests/test_e2e.sh` → rot.
- [ ] **Step 3:** Funktionen implementieren und im Preflight aufrufen.
- [ ] **Step 4:** (wird mit Task 3 grün; erst „beide da" und die Sperren-Tests grün.)
- [ ] **Step 5:** Commit.

### Task 3: Hinein/Heraus um die parallele Phase

**Files:**
- Modify: `pull.sh` (`w2u_dst_kb` Zeile 729: misst `${_WorkRoot:-$_DstRoot}`; neue Funktionen `w2u_stage_in`, `w2u_stage_out`; `main` um Zeile 2550-2585; `w2u_on_signal` Meldung)
- Test: `tests/test_e2e.sh` Lauf 6 (negative Richtung wird positiv), `tests/test_cli.sh` PARPROBE-Block

**Interfaces:**
- `w2u_dev_of <pfad>` → Gerätenummer auf stdout, leer bei Fehler (`stat -c %d`, sonst `stat -f %d`).
- `w2u_stage_in()` → rc 0 und `_WorkRoot=_StageLeaf`, oder rc 1 nach einer Warnung (verschiedene Geräte, gescheitertes `mkdir`/`mv`). Aufrufer schaltet dann per `w2u_einstroemig` um. Aufgerufen in `main` VOR dem Parallel-Block, nur bei `_Stage=1` und ohne Trockenlauf.
- `w2u_stage_out()`: `_DstRoot` existiert → `w2u_die` (Daten bleiben im Zwischenordner). Sonst `mv` zurück, `_WorkRoot=""`, und `rmdir` der leeren Kette von `dirname(_StageLeaf)` bis einschließlich `_StageDir`. Aufgerufen direkt nach `_ParKbAfter`.
- `w2u_on_signal`: Ist `_WorkRoot` gesetzt, zusätzlich die Warnung „Daten liegen in $_StageLeaf - derselbe Aufruf holt sie zurueck".

- [ ] **Step 1: Tests**
  - E2E Lauf 6, negativ → echter Lauf `Daten/SonoGDT` → `$_Dst2`: rc 0, PASS, `parallele Phase:`, kein `EINSTROEMIG`, `diff -r` leer, 31 Dateien in `$_Dst2/SonoGDT` und 31 unter `$_Dst2` insgesamt, kein `.w2u-stage-*`, keine `.lock`.
  - E2E Trockenlauf `Daten/SonoGDT` → `$_Dst2b`: kein `.w2u-stage-*` angelegt.
  - test_cli PARPROBE: `Daten/BRIEFE` → `dst-flach` mit openrsync UND mit Daemon-rsync: `PAR_FILES` = 3 im Zielbaum (Sweep ersetzt, die Dateien stammen also aus der parallelen Phase).
- [ ] **Step 2:** rot.
- [ ] **Step 3:** implementieren.
- [ ] **Step 4:** `bash tests/run_all.sh` → `ALLE TESTS GRUEN`.
- [ ] **Step 5:** Commit.

### Task 4: Doku und Abschluss

**Files:** `README.md` (Abschnitt „Die Form des Zielpfads entscheidet über die Parallelität"), `pull.sh` `w2u_usage`, Kopfkommentar `_ParMode`, Version bumpen (`W2U_VERSION`).

- [ ] README-Abschnitt ersetzen: Ziel ist immer `<ziel>/NAME`, parallel. Einzige Ausnahme Quelle mit `/` am Ende. Zwischenordner `.w2u-stage-NAME` erklären, inkl. dessen, was nach Ctrl-C zu tun ist (denselben Befehl wiederholen).
- [ ] Suite grün, Commit, Merge nach main (ein Release für #7 + #8), Issue #7 schließen.
