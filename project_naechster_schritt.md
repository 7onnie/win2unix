# Naechster Schritt

Stand: 2026-08-25, `main` auf `f03a2b1`. Suite 585 Assertions, 0 Fehler, 0 Skips.
Zwoelf Tasks implementiert und reviewt, Gesamtreview durchlaufen, dessen Critical und die fuenf
Important behoben und nachgeprueft.

## Was als naechstes ansteht

**Der erste Ernstfall gehoert auf einen Ordner, dessen Quelle noch eine Weile stehenbleibt.**
Dann ist ein FAIL ein Nachmittag und keine Katastrophe. Erst danach auf eine Maschine, die
wirklich verschrottet wird.

Vier offene Punkte, jeder als Issue mit Abnahmekriterien:

| # | Was | Warum es zaehlt |
|---|---|---|
| [#1](https://github.com/7onnie/win2unix/issues/1) | Windows-Seite auf echter Hardware | Die `.cmd` ist nie ausgefuehrt worden — nur gelesen und auditiert. |
| [#2](https://github.com/7onnie/win2unix/issues/2) | C1-Fix auf echtem GNU/Linux | Der Fix lief nur gegen einen GNU-Nachbau, nie auf Linux. |
| [#3](https://github.com/7onnie/win2unix/issues/3) | cwRsync 3.4 gegen openrsync | Alle Messungen liefen gegen rsync 3.5.0, ausgeliefert wird 3.4.1. |
| [#4](https://github.com/7onnie/win2unix/issues/4) | DLL-Lizenztabelle | Oeffentliches Repo, Tabelle beruht auf Recherche statt Pruefung. |

Reihenfolge: **#1 vor #3** (ohne laufende Windows-Kiste ist #3 nicht messbar), #2 unabhaengig,
#4 jederzeit.

## Was schon entschieden ist — nicht neu aufrollen

- **Richtung ist PULL**, Daemon auf Windows. Admin-Rechte werden dort ohnehin gebraucht (sonst
  fehlen fremde Benutzerprofile still), damit entfaellt das einzige Argument fuer PUSH.
- **Quelle der parallelen Phase ist immer die Modulwurzel.** `--files-from` funktioniert gegen
  einen Daemon nur so; ein Unterpfad uebertraegt null Dateien und openrsync meldet dabei rc 0.
- **PASS verlangt mindestens eine bindende Beweisschicht.** Lieber ein FAIL, das nichts ueber die
  Daten sagt, als ein PASS ohne Pruefung.
- **Verankerte `--exclude-from`-Muster werden abgelehnt statt umgeschrieben** — eine falsche
  Umschreibung wuerde MEHR ausschliessen, und das ist hier Datenverlust.
- **`uid = 0` / `gid = 0` bleiben aus der `rsyncd.conf`** (toeten jeden Transfer mit
  `setgid failed`); `max connections` bleibt zwingend mit `lock file` gepaart.
- **Ein PASS beweist Groesse, Zeitstempel und Dateizahlen**, nicht Byte-Gleichheit. Dafuer
  `--checksum`, grob eine bis zwei Stunden pro Terabyte. Steht so im README.

## Was noch zu klaeren ist, bevor es gegen eine echte Kiste geht

- Auf welcher Windows-Version die erste Kiste laeuft (Zielband der Annahmen: 7 / 2008 R2+).
- Ob das Ziel ein SMB/NFS-Mount ist. Die Ergebnisdatei liegt bewusst lokal unter `$_TmpDir`,
  weil die Atomizitaets-Messung nur fuer lokale Dateisysteme gilt — das Logverzeichnis darf
  dagegen nicht unter dem Zielbaum liegen, sonst zaehlt es im Dateizahl-Vergleich mit.

## Wo das Memory liegt

Nicht im Repo — dieses Repo ist **oeffentlich**. Projekt-Memory unter
`~/.claude/projects/-Users-user-GitHubRepos-RSYNC-WIN/memory/`, neun Eintraege, darunter sechs
Messungen, die eine gaengige Annahme widerlegt haben. Wer hier weiterarbeitet, liest zuerst
`MEMORY.md` dort.
