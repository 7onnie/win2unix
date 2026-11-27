# Transfers als Linux-Dienst mit TUI (Issue #9, #12)

Stand 2026-11-27. Weg A vom User gewählt: ein systemd-Dienst pro Transfer, der Besitzer wird
schon beim Schreiben gesetzt.

## Warum

Erster Ernstfall: drei große Ordner auf zwei Windows-Kisten, drei `pull.sh` gleichzeitig, jeder
in einem eigenen Terminal. Transfers dauern Tage, schlimmstenfalls Wochen. Heute stirbt ein
Transfer mit der SSH-Sitzung. Fortschritt sieht man nur per `du`, Neustarts muss man von Hand
mit dem exakten Befehl wiederholen. Die Dateien gehören am Ende dem falschen Benutzer
(`zollsoft` statt `tomedo`), und das Ziel ist erst nach einem `chown -R` von Hand nutzbar.

Gewünscht ist **Fire & Forget**: Transfer anlegen, dann läuft er ohne Anmeldung bis zum PASS,
übersteht Netzabbrüche und Neustarts, und am Ende stimmt der Besitzer. Eine TUI zeigt alle
Transfers und steuert sie.

## Entscheidungen des Users (2026-11-27, nach dem Builder-Check)

1. Während der parallelen Phase steht an `<ziel>/NAME` ein **Symlink** auf den
   Zwischenordner, damit die Dateien am gewohnten Ort nutzbar sind.
2. Fehlerpolitik wie vorgeschlagen: Verbindungsabbrüche endlos wiederholen,
   Einrichtungsfehler sofort stoppen, echtes FAIL-Urteil dreimal, dann „aufgegeben".
3. Transfers von derselben Windows-Kiste laufen **gleichzeitig**. Keine Warteschlange;
   pro Auftrag optional feste Parallelität.
4. Ende-zu-Ende-Test auf dem Produktivrechner `10.2.16.104` per SSH (Benutzer `zollsoft`),
   mit eigenem Testnamen und kleinem Testordner, danach vollständig entfernen.
5. Neu: **neue Dateien zuerst übertragen**. Meist werden die gebraucht, der Rest ist Archiv.

## Ziele

- Pro Transfer: Name, Quelle (IP + Pfad), Zielverzeichnis, Besitzer `U:G`, optional `--jobs`.
- Läuft als systemd-Dienst: ohne Anmeldung, über Reboots hinweg, nach Abbruch automatisch
  fortgesetzt, bis PASS.
- Neue Dateien gehören **sofort** `U:G` (nutzbar während des Transfers). Nach PASS folgt ein
  `chown -R` als Abschluss.
- TUI: alle Transfers mit Status, Phase, Fortschritt, Zahl der Neustarts und letztem Urteil.
  Aktionen: anlegen, starten, stoppen, neu starten, entfernen, Log ansehen.
- Dieselben Aktionen ohne TUI als Befehle (`w2u add/list/start/…`), damit sie skriptbar sind.
- `sudo` genau einmal, bei der Installation. Danach keine Passwortabfrage mehr.
- Dateien, die in den letzten N Tagen geändert wurden, kommen vor dem Rest.
- Laufende Terminal-Transfers lassen sich als Auftrag übernehmen.

## Nicht-Ziele

- macOS als Ziel (kein systemd). `pull.sh` bleibt dort wie heute nutzbar.
- Mehrere Linux-Rechner aus einer TUI. Die TUI verwaltet den Rechner, auf dem sie läuft.
- Steuerung der Windows-Seite.

## Anti-Ziele

- Ein PASS, nach dem Dateien fehlen oder der Besitzer nicht stimmt.
- Ein Transfer, der still steht, ohne dass die TUI es zeigt, z. B. weil er seit Tagen in
  einer FAIL-Schleife steckt.
- Eine Oberfläche, die man installieren muss (pip, npm, Pakete).

## Ansätze

| | Weg | Abwägung |
|---|---|---|
| **A (gewählt)** | systemd-Vorlage `win2unix@<job>.service`, läuft als root. `pull.sh` setzt den Besitzer per `rsync --chown`. Eine sudo-Regel erlaubt dem Bediener nur `systemctl` auf diese Dienste. | systemd liefert Neustart, Boot-Start und Log. Wenig eigener Code. Braucht systemd. |
| B | Eigener root-Hintergrundprozess, der einen Auftragsordner überwacht. | TUI braucht nie sudo, aber Prozessüberwachung, Neustart und Log müssten selbst gebaut werden, genau der Teil, der wochenlang halten muss. |
| C | Ohne root, unter dem Bediener (tmux/`systemctl --user`). | Ein `chown` auf `tomedo` ist ohne root unmöglich. Erfüllt die Anforderung nicht. |

Innerhalb von A wurde „Dienst läuft direkt als `tomedo`" verworfen: `pull.sh` legt
Zwischenordner und Sperre **neben** dem Ziel an, also in einem Verzeichnis, das typischerweise
root gehört (`/opt/data/files`). Als root mit `--chown` gibt es dieses Rechteproblem nicht.

## Entwurf

### Bausteine und Ablage

| Pfad | Inhalt |
|---|---|
| `/opt/win2unix/pull.sh` | feste Kopie, nicht bei jedem Start per curl geholt (reproduzierbar). Aktualisiert per Neuinstallation. |
| `/opt/win2unix/w2u` | ein Python-3-Programm, nur Standardbibliothek: CLI + TUI (curses) + `run` |
| `/etc/systemd/system/win2unix@.service` | Dienst-Vorlage |
| `/etc/sudoers.d/win2unix` | sudo-Regel für den Bediener |
| `/etc/win2unix/jobs/<job>.conf` | ein Auftrag (key=value), gehört dem Bediener |
| `/var/lib/win2unix/<job>/` | `status` (von pull.sh), `logs/` (pull.sh-Logs), `runs` (Zähler und Verlauf) |

`install.sh` (im Repo, einmal mit `sudo` ausgeführt) legt das alles an. Der Bediener ist der
Benutzer hinter `sudo` (`SUDO_USER`), überschreibbar per Variable am Skriptanfang (Zero-Touch).
Geprüft wird: systemd vorhanden, python3 vorhanden, GNU rsync vorhanden. Fehlt etwas, folgt ein
klarer Abbruch.

### Auftrag (`/etc/win2unix/jobs/<job>.conf`)

```
SRC=rsync://192.168.2.3/e/Konvertierung_tomedo/Konverter_50770_S3/S1_S3/BRIEFE
DST=/opt/data/files
OWNER=tomedo:tomedo
JOBS=            # leer = Auto-Messung
CREATED=2026-11-27T10:00:00
```

- Jobname: nur `[a-z0-9_-]`, 1–40 Zeichen. Geprüft in `w2u add` **und** in `w2u run`, gegen
  Pfad-Tricks über den Dienstnamen.
- `w2u add` nimmt die Quelle als IP plus **Windows-Pfad**
  (`F:\Konvertierung_tomedo\…\BRIEFE`) und baut daraus die rsync-URL. Wer eine fertige
  `rsync://`-URL hat, gibt sie direkt.
- `w2u add` lehnt ab: zwei Aufträge mit demselben Ziel `DST/<NAME>`; einen Besitzer, den es
  nicht gibt (`getent`); ein `DST`, das nicht existiert.

### `pull.sh`: zwei neue Optionen

- `--status-file PFAD`: Bei jedem Phasenwechsel und mindestens alle 30 s wird
  key=value geschrieben, atomar (tmp + `mv`):
  `phase` (preflight, decompose, autotune, parallel, sweep, verify, chown, done), `pid`,
  `started`, `updated`, `chunks_total`, `chunks_done`, `chunks_failed`, `kb_dst`,
  `parallel`, `result` (leer/PASS/FAIL), `report` (Pfad zu report.txt), `message` (letzte
  Warnung oder Abbruchgrund).
- `--chown U:G`:
  - Wird beim Parsen in **numerische** `uid:gid` aufgelöst, sonst Abbruch. Grund: `pull.sh`
    benutzt `--numeric-ids`.
  - Nur als root erlaubt, sonst sofortiger Abbruch beim Parsen.
  - `--chown=uid:gid` geht an die Worker und an den Sweep, nicht an den Verify-Lauf (`-n`).
    Vorher wird geprüft, ob das rsync `--chown` kann (openrsync kann es nicht → Abbruch mit Rat).
  - Nach `mkdir -p` des Ziels wird `<ziel>/NAME` gleich auf `U:G` gesetzt.
  - Nach PASS folgt `chown -R U:G <ziel>/NAME`, Phase `chown`. Scheitert er, lautet das
    Gesamturteil FAIL, der Bestand bleibt korrekt.
  - Bekannte Lücke: Elternordner, die rsync bei `--files-from` implizit anlegt, können
    `root:root 755` sein, bis der `chown -R` am Ende läuft. Dateien sind trotzdem sofort
    lesbar und gehören `U:G`; Schreiben in diese Ordner geht erst nach dem Abschluss.
- `--neu-zuerst TAGE` (0 = aus):
  - Vor der parallelen Phase, nach dem Hinein-Umbenennen, wird die Quelle **einmal
    rekursiv gelistet** (`rsync -r --list-only`, ein Strom).
  - Alle Dateien mit mtime ab heute minus TAGE kommen als eigene Chunkliste mit
    modul-relativem Präfix und laufen über dieselbe Worker-Maschinerie (`w2u_run_list`).
  - Eigene Ergebnisdatei: Der Vorlauf ist eine **Vorab-Lieferung ohne Beweiskraft**.
    Vollständigkeit belegen weiter die normale Phase, der Sweep und der Verify, die bereits
    vorhandene Dateien überspringen.
  - Phase `neu-zuerst` in der Statusdatei, mit eigenem Zähler.
  - Kosten: ein vollständiges Listing pro Lauf, auch nach jedem Neustart. Bei Millionen
    Dateien grob Minuten bis eine halbe Stunde. Deshalb abschaltbar.
  - Vorgabe in `w2u add`: 365 Tage (meine Wahl, im Formular änderbar).
- Symlink während der parallelen Phase (nur im Zwischenordner-Fall, #7):
  - Nach dem Hinein-Umbenennen legt `pull.sh` `<ziel>/NAME -> .w2u-stage-NAME/<praefix>`
    an (relativer Link, damit er auch über Mounts hinweg stimmt).
  - Vor dem Zurück-Umbenennen wird er entfernt, und zwar nur, wenn er noch genau dorthin zeigt.
  - Aufräumen beim Start: Ist `<ziel>/NAME` ein Symlink auf das eigene Blatt im
    Zwischenordner, zählt er als „fehlt" und wird entfernt. Jeder andere Symlink an dieser
    Stelle bleibt die Ausnahme aus #7 (einströmig durch den Link).
  - Workers und Sweep schreiben nie durch den Link: Die Worker schreiben in den
    Zwischenordner, der Sweep läuft erst nach dem Zurück-Umbenennen.
- Exit-Codes von `pull.sh`: 0 = PASS, 1 = FAIL oder Abbruch (vorübergehend, neu versuchen),
  **3 = Einrichtungsfehler** (jeder Abbruch während `w2u_parse_args`, z. B. falsche URL,
  unbekannter Besitzer, openrsync mit `--chown`, Optionskombination). 2 bleibt „Aufruf
  ohne Argumente".

### systemd-Vorlage (`win2unix@.service`)

```
[Unit]
Description=win2unix Transfer %i
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/opt/win2unix/w2u run %i
Restart=on-failure
RestartSec=2min
KillMode=control-group
TimeoutStopSec=60
TasksMax=infinity
Nice=0
RestartPreventExitStatus=3

[Install]
WantedBy=multi-user.target
```

- `w2u run <job>` prüft den Namen, liest den Auftrag, ruft `pull.sh` mit `--status-file`,
  `--log-dir /var/lib/win2unix/<job>/logs`, `--chown`, `--neu-zuerst` und ggf. `--jobs`
  auf, zählt den Versuch in `runs` und entscheidet:
  - pull.sh 0 (PASS): `runs` setzt den FAIL-Zähler zurück, `disable`, Exit 0 → „erledigt".
  - pull.sh 3 (Einrichtung): Exit 3 → kein Neustart (`RestartPreventExitStatus=3`),
    TUI „gestoppt: Einrichtungsfehler" in Rot mit `message`.
  - pull.sh 1 **mit** `result=FAIL` in der Statusdatei (vollständiger Lauf, echtes Urteil):
    FAIL-Zähler +1. Ab 3 hintereinander folgt Exit 3, „aufgegeben", rot. Darunter Exit 1 → Neustart.
  - pull.sh 1 ohne Urteil (Abbruch, Quelle weg, Netz): Exit 1 → Neustart nach 2 min,
    endlos. Der FAIL-Zähler bleibt unverändert.
  - `w2u start` setzt den FAIL-Zähler zurück (bewusster Neuversuch).
- `w2u start` = `enable --now` (übersteht Reboot), `w2u stop` = `disable --now`. Ein
  gestoppter Auftrag startet also auch nach einem Reboot nicht wieder. Nach PASS:
  `disable`, damit ein Reboot keinen erledigten Transfer neu prüft.
- Ein bewusstes `stop` löst keinen Neustart aus (systemd unterscheidet das).

### sudo-Regel (`/etc/sudoers.d/win2unix`)

```
<bediener> ALL=(root) NOPASSWD: /usr/bin/systemctl start win2unix@*, \
  /usr/bin/systemctl stop win2unix@*, /usr/bin/systemctl restart win2unix@*, \
  /usr/bin/systemctl enable --now win2unix@*, /usr/bin/systemctl disable --now win2unix@*, \
  /usr/bin/systemctl reset-failed win2unix@*
```

Der Pfad von `systemctl` wird bei der Installation ermittelt (`command -v`). Geprüft wird mit
`visudo -cf` vor dem Aktivieren; eine kaputte Datei würde sudo sperren.

Info (bewusst so, nicht anfassen): Wer `/etc/win2unix/jobs` schreiben darf, bestimmt, was root
holt und wem es gehört. Das ist hier gewollt, der Bediener ist ohnehin Administrator.

### Status in der TUI

| Anzeige | Quelle |
|---|---|
| läuft / wartet auf Neustart / gestoppt / erledigt (PASS) | `systemctl show -p ActiveState,SubState,NRestarts,UnitFileState` + `result` im Status |
| Phase, Chunks x/y, GB am Ziel, Rate | Statusdatei (Rate = Differenz zwischen zwei Lesungen) |
| Neustarts | `NRestarts`; ab 3 aufeinanderfolgenden FAIL **rot** samt letzter `message` |
| veraltet | `updated` älter als 5 min, während der Dienst läuft → gelb „keine Rückmeldung" |

```
 win2unix – 3 Transfers                                    Do 27.11. 10:42
 ───────────────────────────────────────────────────────────────────────────
  NAME        QUELLE                         STATUS        PHASE     FORTSCHRITT        NEUSTARTS
> albis-brf   10.3.208.159 f:/…/BRIEFE       läuft         parallel  412/980  183 GB  42 MB/s   0
  albis-sono  10.3.208.159 f:/…/Bildarchiv   wartet        –         –                          1
  s3-brf      192.168.2.3  e:/…/BRIEFE       PASS ✓        done      980/980  611 GB            0
 ───────────────────────────────────────────────────────────────────────────
  Ziel: /opt/data/files/Albis/BRIEFE   Besitzer: tomedo:tomedo   seit 2 T 4 h
  Letzte Meldung: –
 ───────────────────────────────────────────────────────────────────────────
  [n]eu  [s]tart  [x] stop  [r]estart  [l]og  [d] entfernen  [q]uit
```

- `l` zeigt die letzten 200 Zeilen aus `journalctl -u win2unix@<job>` (blätterbar).
- `d` geht nur bei gestopptem oder erledigtem Auftrag und entfernt Auftrag und Status,
  **nie** Zieldaten.
- `n` öffnet ein Formular: Name, Quell-IP, Quellpfad (Windows-Schreibweise), Zielverzeichnis,
  Besitzer, Parallelität. Vor dem Anlegen wird die Quelle per `rsync rsync://IP/` geprüft.
- Aktualisierung alle 2 s. Die TUI hält keinen Zustand: Beenden der TUI ändert nichts an den
  Transfers.

### Übernahme laufender Terminal-Transfers

1. Den alten `pull.sh` im Terminal mit Ctrl-C beenden (er hinterlässt ggf. Zwischenordner und
   Sperre mit toter PID).
2. `w2u add` mit derselben Quelle und demselben Ziel. Den Zielordner gibt es schon, das ist
   erlaubt.
3. `w2u start`: Der Dienst läuft als root. Er übernimmt die verwaiste Sperre (Waisen-Prüfung
   aus #7), holt einen Zwischenordner zurück und setzt fort. Bereits vorhandene Dateien
   gehören noch `zollsoft`, das korrigiert der `chown -R` nach dem PASS.

## Dem Umsetzer überlassen

Interne Struktur von `w2u`, Farben, Spaltenbreiten, Kürzung langer Pfade, Wortlaut der Meldungen,
Aufbau der `runs`-Datei.

## Tests

- `pull.sh --status-file`: Phasen in Reihenfolge, `result=PASS` am Ende, atomar, auch bei FAIL
  und Abbruch (Phase und `message` stimmen).
- `pull.sh --chown`: ohne root Abbruch beim Parsen; unbekannter Benutzer Abbruch; openrsync
  Abbruch mit Rat. Als root (CI/Linux): Dateien während und nach dem Lauf `U:G`.
- `w2u`: Python-Unit-Tests (Windows-Pfad → URL, Jobname-Prüfung, Auftrag lesen/schreiben,
  Statusberechnung aus `systemctl show` + Statusdatei, doppeltes Ziel abgelehnt), `systemctl`
  per Attrappe.
- `install.sh`: Trockenlauf-Modus (`--root DIR`) schreibt alles unter ein Testverzeichnis;
  `visudo -cf` auf die erzeugte Regel.
- `--neu-zuerst`: Parser für `rsync -r --list-only`-Zeilen (Größe mit Kommas, Namen mit
  Leerzeichen und Umlauten), Auswahl nach Datum, Reihenfolge im echten Lauf (neue Dateien
  sind am Ziel, bevor die normale Phase beginnt), Bericht unverändert.
- Symlink: während der Phase existiert `<ziel>/NAME` als Link mit lesbaren Dateien; nach PASS
  ein echter Ordner; Aufräumen nach kill -9 mit Link am Platz.
- Ende-zu-Ende auf `10.2.16.104` per SSH: Installation, Testauftrag mit kleinem Ordner,
  Stop/Start/Neustart, Reboot-Fest (`is-enabled`), PASS, Besitzer, Entfernen. Danach alles
  Testbezogene wieder weg. Keine GitHub Action.
