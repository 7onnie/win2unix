# Linux-Dienst + TUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transfers laufen als systemd-Dienste mit Besitzer `U:G` ab dem ersten Byte, neue Dateien zuerst, gesteuert über eine TUI; dazu zwei Fixes aus dem Ernstfall.

**Architecture:** `pull.sh` bekommt `--status-file`, `--chown`, `--neu-zuerst`, Exit-Code 3, einen Symlink während der Zwischenordner-Phase sowie zwei Fixes: Rechte der Windows-Quelle und negative Nanosekunden. `w2u` (Python 3, nur Standardbibliothek) ist CLI, TUI und `run`-Einstieg der Dienst-Vorlage `win2unix@.service`. `install.sh` richtet einmal mit sudo alles ein.

**Tech Stack:** bash 3.2+/GNU, rsync 3.5, Python 3.11 (curses, unittest), systemd 252, sudoers.

**Spec:** `docs/superpowers/specs/2026-11-27-linux-dienst-tui-design.md`

## Global Constraints

- `pull.sh` bleibt auf macOS mit openrsync lauffähig. Alle neuen Optionen sind optional.
- Python nur Standardbibliothek, ab 3.9.
- Variablen in bash `_PascalCase`. Keine One-Liner.
- Jede neue Logik mit Test, zuerst rot.
- Merge nach `main` erst am Blockende, ein Bump auf 0.3.0.
- Zielrechner `10.2.16.104` ist produktiv: Tests dort nur mit Präfix `w2utest`, danach alles entfernen. Die laufende MediDok-Übertragung nicht anfassen, bis die Übernahme ansteht.

## Review Focus

1. Dienst stirbt während der Zwischenordner-Phase (Symlink steht): der nächste Lauf räumt den Link weg und holt das Blatt zurück.
2. `--chown` mit Eltern-Ordnern, die `--files-from` implizit anlegt: Dateien sind trotzdem `U:G`; nach PASS ist alles `U:G`.
3. Quelle mit Rechten `0050`/`0000`: Transfer, Zählung und Verify laufen trotzdem.
4. Abbruch während `--neu-zuerst`: der Vorlauf zählt nicht als Beweis, der Bericht bleibt ehrlich.
5. FAIL-Schleife: nach 3 Urteilen „aufgegeben", Exit 3, und systemd startet nicht neu.

---

### Task 1: Ernstfall-Fixes in pull.sh
- `--chmod=Du+rwx,Fu+rw` an Worker und Sweep (nicht an den Verify-Lauf mit `-n`).
- Reparatur vorhandener Ordner, bevor übertragen oder gezählt wird:
  `find -H <ziel> -type d ! -perm -u=rwx -exec chmod u+rwx {} +` (auch auf `_WorkRoot`).
- `--protocol=30`, wenn der Client GNU rsync mit Protokoll ≥ 31 ist (gemessen gegen die
  echte Quelle, die negative nsec liefert). openrsync bleibt bei seinem Protokoll 29.
- Tests: Quelle mit `chmod 050` auf einem Ordner, danach PASS und Zählung; Argumente der
  Worker und des Sweeps enthalten `--chmod` und, bei GNU, `--protocol=30`.

### Task 2: Exit-Code 3 und `--status-file`
- Während `w2u_parse_args` beendet `w2u_die` mit Exit 3. Test: falsche URL ergibt rc 3.
- `w2u_status key=val …` schreibt atomar. Phasen laut Spec. `result`/`report`/`message`.
  Tests: echter Lauf, Phasenfolge, Endzustand PASS; Abbruch, Phase und message.

### Task 3: `--chown U:G`
- Beim Parsen: nur als root (sonst rc 3), Benutzer und Gruppe numerisch auflösen, `--chown`
  vom rsync prüfen (`rsync --help | grep -- --chown`), sonst rc 3.
- `--chown=uid:gid` an Worker und Sweep, chown von `<ziel>/NAME` nach `mkdir`, nach PASS
  `chown -R`. Scheitert der chown, ist das Ergebnis FAIL.
- Tests: ohne root rc 3; mit Attrappe `id -u`=0 wird nur die Argumentliste geprüft; echter
  chown im E2E auf Linux.

### Task 4: Symlink während der Zwischenordner-Phase
- `w2u_stage_in`: danach `ln -s .w2u-stage-NAME/<praefix> <ziel>/NAME`.
- `w2u_stage_out`: Link nur entfernen, wenn `readlink` genau so lautet, dann `mv`.
- `w2u_stage_recover`: Ist `<ziel>/NAME` ein Link genau auf das eigene Blatt, wird er
  entfernt und als „fehlt" behandelt.
- Tests in `tests/test_stage.sh`: während der Phase existiert der Link und Dateien sind
  lesbar (über eine Sonde nach der parallelen Phase); Aufräumen mit Link am Platz.

### Task 5: `--neu-zuerst TAGE`
- `w2u_newfiles <url> <tage> <out>`: `rsync -r --list-only`, Zeilen parsen (Typ, Datum,
  Name), Dateien mit Datum ≥ Stichtag, mit modul-relativem Präfix.
- Lauf über `w2u_chunk` + `w2u_run_list` mit eigener Ergebnisdatei, vor der normalen Phase.
- Tests: Parser (Kommas, Leerzeichen, Umlaute, Symlink-Zeilen `->`), Auswahl, Reihenfolge im
  echten Lauf, Bericht unverändert PASS.

### Task 6: `w2u` (Python) Kern + CLI
- Module in einer Datei `linux/w2u`: Auftrag lesen und schreiben, Windows-Pfad → URL,
  Namensprüfung, `run` (Exit-Politik laut Spec, `runs`-Datei), `add/list/start/stop/restart/
  remove/log`, Statusberechnung.
- `tests/test_w2u.py` (unittest), `systemctl`/`journalctl` per Attrappe im PATH.

### Task 7: TUI
- curses-Liste, Detailzeile, Tasten laut Spec, Formular für `n`, Log-Ansicht.
- Test: Rendering-Funktion als reine Funktion (Zeilen aus Zustand), unittest.

### Task 8: install.sh, Unit, sudoers
- `linux/install.sh` (Variablen oben, `--root DIR` für Tests), `linux/win2unix@.service`.
- Tests: `--root` erzeugt alle Dateien, `visudo -cf` (wo vorhanden) auf die Regel.

### Task 9: Doku, Version, E2E, Übernahme
- README-Abschnitt „Als Dienst auf Linux", Version 0.3.0.
- E2E per SSH auf `10.2.16.104` mit `w2utest`. Danach Review, Merge.
- Übernahme der laufenden Transfers (MediDok, SonoGDT, S3).
