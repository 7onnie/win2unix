# win2unix — Design

**Datum:** 2026-08-24
**Repo:** `7onnie/win2unix` (öffentlich)
**Status:** Design, freigegeben zur Planung

## 1 Zweck

Einmaliger Massen-Datentransfer von einem alten Windows-Server auf einen Mac oder Linux-Rechner
im selben LAN. Typisch 1–3 Ordner, mehrere hundert GB bis mehrere TB, sehr viele kleine Dateien
in tiefen Bäumen. Der Windows-Rechner wird danach verschrottet.

**Harte Anforderungen**

1. Auf Windows wird **nichts installiert** — nur ein Ordner kopiert und eine Datei angeklickt.
2. So schnell wie möglich.
3. Wiederaufnahme nach Abbruch ohne Neubeginn.
4. **Beweisbare Vollständigkeit**, bevor die Quelle verschrottet wird. Ein Transfer, der still
   Dateien auslässt, ist der einzige nicht behebbare Fehler in diesem Projekt.

**Nicht-Ziele:** laufende Synchronisation, Verschlüsselung des Transports (reines LAN, Einmal-
Vorgang), Übernahme von NTFS-ACLs, ADS oder Windows-Rechten, Transfer über das Internet.

## 2 Gemessene Grundlagen

Alle folgenden Punkte sind gemessen, nicht angenommen. Sie tragen das Design; wer sie ändert,
muss das Design prüfen.

### 2.1 Das portable rsync-Bundle existiert

`https://packages.chocolatey.org/rsync.6.4.8.nupkg` (5,7 MB) enthält kein Installer-Wrapper-
Skript, sondern ein echtes Bundle: `tools/cwrsync_6.4.8_x64_free.zip` → `bin/rsync.exe` plus
neun Cygwin-DLLs (`cygwin1.dll`, `cygcrypto-3.dll`, `cygiconv-2.dll`, `cygintl-8.dll`,
`cygz.dll`, `cygzstd-1.dll`, `cyglz4-1.dll`, `cygpopt-0.dll`, `cyggcc_s-seh-1.dll`,
`cygxxhash-0.dll`) und `etc/nsswitch.conf`. Entpackt ~13,5 MB.

Version 6.4.8 statt der ursprünglich angedachten 6.2.2, weil 6.4.8 `cygxxhash-0.dll` mitbringt
(schnelle xxHash-Prüfsummen) und das Layout `bin/` + `etc/` direkt auf Zip-Wurzel liegt.

### 2.2 Das Zielsystem hat nur openrsync

Auf den realen Ziel-Macs (macOS 26.x) ist `/usr/bin/rsync` **Apple-openrsync, Protokoll 29**,
und **Homebrew ist nicht installiert**. Das ist keine Randbedingung, sondern die Normalsituation.

Gemessen gegen einen rsync-3.5.0-Daemon — **funktioniert**: Modul-Discovery (`rsync rsync://IP/`),
`--list-only`, `--files-from`, `-W`, `--partial`, `--inplace`, `--itemize-changes`, `-n`,
`--numeric-ids`, `-d`, `--exclude-from`, `--port`, `--stats`.
**Funktioniert nicht:** `--info=progress2`, `--iconv`; `--out-format` wird im Listing-Modus
ignoriert.

⇒ `pull.sh` darf ausschließlich Optionen aus der ersten Liste verwenden.

### 2.3 Umlaute sind unproblematisch — entgegen der gängigen Empfehlung

Die verbreitete Warnung, Windows→macOS brauche `--iconv=UTF-8-MAC,UTF-8` wegen NFC/NFD, stammt
aus der HFS+-Ära. APFS ist seit High Sierra normalisierungs-*erhaltend*.

Gemessen: `Größe & Maß.DOC` (NFC, `4772c3b6c39f65…`) über den Daemon gezogen → lokale Bytes
byte-identisch, anschließender Verify-Lauf leer. Auch `--files-from` mit Umlaut **und**
Leerzeichen im Pfad funktioniert.

Einzige Restwirkung: rsync escaped Nicht-ASCII in der `--itemize-changes`-**Ausgabe** als
`\#237`. Rein kosmetisch, betrifft nur Log-Parsing, nicht die Datei.

### 2.4 Die zwei realen Datenprofile

Gemessen an zwei produktiven Ordnern, die stellvertretend für den Anwendungsfall stehen:

| | Fall A `BRIEFE` | Fall B `SonoGDT` |
|---|---|---|
| Größe | 431 GB | 36 GB |
| Einträge Ebene 1 | 306 Ordner + 2 Dateien | **1 Ordner** (`Bildarchiv`) |
| Struktur | Ordner → Dateien (`.DOC`), Tiefe 2 | Bildarchiv → 13.193 Patienten → Datum → Dateien, Tiefe 4 |
| Ordnergrößen | stark ungleich (Stichprobe 3,6 MB / 17 MB / 41 MB) | ungleich |

Fall B ist der Grund, warum eine feste Aufteilungstiefe nicht funktioniert: auf Ebene 1 gibt es
genau **einen** Eintrag. Fall A ist der Grund für Work-Stealing statt statischer Verteilung.

### 2.5 `max connections` braucht ein `lock file`

Ohne begleitendes `lock file = <pfad>` bricht **jeder** Transfer mit
`@ERROR: failed to open lock file` ab. Der Daemon startet dabei fehlerfrei und das Modul-Listing
funktioniert sogar noch — erst der eigentliche Transfer scheitert. Default ist
`/var/run/rsyncd.lock`, das im Cygwin-Root auf Windows nicht existiert.

### 2.6 Die Zerlegung ist die gefährliche Stelle — und der Verify fängt sie

Gemessen mit einer **absichtlich fehlerhaften** Zerlegung (nur Ordner der Ebene 2 als
Arbeitspakete). Der abschließende `rsync -n -i` meldete:

```
.d..t....  ./                            ← harmlos: mtime der Wurzel
<f+++++++  Bildarchiv/direkt_datei.txt   ← echte Lücke: Datei direkt im aufgeteilten Ordner
cd+++++++  leer_ordner/                  ← echte Lücke: leeres Verzeichnis
```

Nach einem Sweep-Pass war der Verify **vollständig leer**.

Zwei Nebenbefunde, die verbreiteten Warnungen widersprechen: implizit angelegte
Elternverzeichnisse erhalten die **korrekte** mtime der Quelle (getestet mit 2020-01-01), und
`--files-from` rekonstruiert unter openrsync die relativen Pfade korrekt statt flach zu schreiben.

## 3 Architektur

Drei Komponenten, klar getrennte Verantwortung:

| Komponente | Läuft auf | Aufgabe |
|---|---|---|
| `windows/` Bundle + `START-RSYNC-SERVER.cmd` | Windows-Quelle | Stellt alle Laufwerke read-only als rsync-Module bereit. Ein Doppelklick, danach nie wieder angefasst. |
| `pull.sh` | Mac/Linux-Ziel | Holt EINEN Ordner, parallelisiert, mit Wiederaufnahme, Sweep und Verifikation. |
| `tools/fetch-cwrsync.sh` | Entwickler-Mac | Baut das Windows-Bundle reproduzierbar aus dem `.nupkg` neu. Kein Teil des Transfers. |

Richtung ist **PULL**: der Daemon steht auf Windows, gezogen wird vom Ziel. Begründung: Admin-
Rechte werden auf Windows ohnehin gebraucht (ohne sie liest der Daemon fremde Benutzerprofile
nicht und lässt still Verzeichnisse aus), damit entfällt das einzige Argument für PUSH. Dafür
liegt die gesamte Steuerung — Auswahl, Wiederholung, Verifikation — auf der Unix-Seite, wo eine
brauchbare Shell existiert.

Der Einzeiler ohne jedes Skript bleibt ausdrücklich funktionsfähig und ist der dokumentierte
Fallback:

```
rsync rsync://<WIN-IP>/                       # welche Laufwerke gibt es?
rsync rsync://<WIN-IP>/e/                     # was liegt auf E:?
rsync -rltP -W rsync://<WIN-IP>/e/Archiv /opt/data/files/
```

## 4 Windows-Komponente

### 4.1 Ablauf von `START-RSYNC-SERVER.cmd`

1. **Admin-Prüfung zuerst**, per `net session >nul 2>&1`. Bei fehlenden Rechten Selbst-Neustart
   über `powershell -Command "Start-Process -Verb RunAs"`. Ein Doppelklick, eine UAC-Abfrage.
   Der Test steht *vor* jeder Aktion — ein `netsh`-Fehler, dessen Ausgabe nach `nul` umgeleitet
   wird, ist als Admin-Test unbrauchbar.
2. **Laufwerke erkennen** (alle fixed drives) und je Volume ein Modul erzeugen.
3. **`rsyncd.conf` schreiben** (Abschnitt 4.2).
4. **Firewall** TCP 873 eingehend freigeben. Regel wird bewusst nicht wieder entfernt — die
   Maschine wird verschrottet.
5. **Energiesparen abschalten**: `powercfg /change standby-timeout-ac 0`, ebenso
   `monitor-timeout-ac`, `disk-timeout-ac`, `hibernate-timeout-ac`. Ohne das schläft der Server
   mitten im TB-Transfer ein.
6. **Alle lokalen IPv4-Adressen ausgeben**, dazu den fertigen Copy-Paste-Befehl für die Gegenseite.
7. `bin\rsync.exe --daemon --no-detach --config=rsyncd.conf` starten. Fenster schließen = Ende.

### 4.2 `rsyncd.conf` (generiert)

```ini
use chroot = false
strict modes = false
max connections = 32
lock file = <ordner>/rsyncd.lock      ; ZWINGEND, siehe 2.5
pid file   = <ordner>/rsyncd.pid
log file   = <ordner>/rsyncd.log
hosts allow = <lokales Subnetz>

[c]
    path = /cygdrive/c/
    comment = <Volume-Label> (<Größe>)
    read only = true
    list = yes
    exclude = pagefile.sys hiberfil.sys swapfile.sys DumpStack.log* "System Volume Information" "$Recycle.Bin"
```

Ein solcher Block je erkanntem Laufwerk. `read only = true` ist die einzige Sicherung dagegen,
dass ein Fehlgriff auf der Unix-Seite die Quelle beschädigt, bevor sie vollständig gesichert ist.
Die Ausschlüsse stehen **serverseitig**, damit sie unabhängig davon greifen, was ein Client
anfordert.

### 4.3 Lizenz

rsync steht unter GPLv3. Das Repo liefert Binärdateien aus, also gehören `legal/LICENSE.txt` und
`legal/VERIFICATION.txt` aus dem Chocolatey-Paket mit sowie eine `NOTICE`-Datei mit Herkunft
(itefix cwRsync free edition 6.4.8), Bezugsquelle und Verweis auf den Upstream-Quelltext.

## 5 `pull.sh`

### 5.1 Aufruf

```
pull.sh [Optionen] rsync://<WIN-IP>/<modul>/<pfad> <zielverzeichnis>
```

Optionen: `--jobs N` (überspringt die Auto-Messung), `--exclude-from <datei>`, `--dry-run`,
`--verify-only`, `--no-verify`, `--log-dir <pfad>`. Alle Defaults sind als Variablen am
Skript-Kopf gesetzt; ohne Optionen läuft es zero-touch durch, es gibt keine Rückfragen.

### 5.2 Phase 1 — Preflight

Prüft, bevor irgendetwas geschrieben wird: `rsync` vorhanden und daemon-fähig; Modul erreichbar;
Zielverzeichnis existiert und ist beschreibbar; freier Platz am Ziel gegen die Remote-Größe.
Bei openrsync als Client wird protokolliert, dass `--info=progress2` und `--iconv` fehlen — beides
ist nach 2.2/2.3 unkritisch, aber es soll im Log stehen.

### 5.3 Phase 2 — Zerlegung

Die kritische Phase. Breitensuche ab dem Quellpfad, Ziel ist eine Menge von **Arbeitspaketen**,
deren Vereinigung beweisbar der gesamte Baum ist.

```
queue      := [ quellpfad ]
arbeit     := []
solange |arbeit| + |queue| < SCHWELLE und queue enthält expandierbare Ordner:
    X := nächster Ordner aus queue
    listing := rsync --list-only -d <quelle>/X/
    für jeden Eintrag E in listing außer ".":
        wenn E eine DATEI ist        → arbeit += X/E
        wenn E ein ORDNER ist        → queue  += X/E
arbeit += alle in queue verbliebenen Ordner
```

**Vollständigkeits-Argument.** Invariante: `arbeit ∪ queue` überdeckt zu jedem Zeitpunkt exakt den
Ausgangsbaum. Wird X expandiert, so wird X aus der Menge entfernt und durch die **vollständige**
Liste seiner direkten Kinder ersetzt — Dateien *und* Ordner. Da die Kinder eines Verzeichnisses
disjunkt sind und ihre Vereinigung der Inhalt von X ist, bleibt die Überdeckung erhalten. Am Ende
wandert die Restqueue unexpandiert in die Arbeitsliste, jeder Eintrag wird rekursiv übertragen.

Die beiden Fehler, die diese Formulierung genau vermeidet und die im Test (2.6) reproduziert
wurden: Dateien, die direkt in einem expandierten Ordner liegen, und leere Verzeichnisse — beide
sind hier reguläre Einträge und damit Arbeitspakete.

`SCHWELLE = 4 × P_max`, wobei `P_max` die **höchste** Parallelität ist, die überhaupt in Frage
kommt (Default 8, siehe 5.4, oder der Wert aus `--jobs`). Bewusst nicht „4 × Worker": die
Worker-Anzahl steht erst nach der Auto-Messung fest, die Zerlegung läuft aber davor — die Schwelle
muss also gegen die Obergrenze rechnen, nicht gegen das Ergebnis.

Angewandt auf die gemessenen Fälle: Fall A stoppt auf Ebene 1 (308 Einträge ≥ 32), Fall B steigt
automatisch auf Ebene 2 ab (1 Eintrag < 32 → 13.193 Einträge).

**Listing-Parsing.** Die Ausgabe ist immer `perms size YYYY/MM/DD HH:MM:SS name`, `--out-format`
wird ignoriert (2.2). Geparst wird per `awk`, das auf das Zeitstempel-Muster matcht und **alles
danach** als Namen nimmt — nur so überleben Leerzeichen. Zusätzlich `tr -d '\r'`. Der Typ ergibt
sich aus dem ersten Zeichen (`d` = Verzeichnis).

### 5.4 Phase 3 — Auto-Messung der Parallelität

Statt eines geratenen Defaults misst das Skript am Anfang. Probe-Runden mit steigender
Parallelität P ∈ {2, 4, 8}, je Runde `2 × P` Chunks aus der echten Warteschlange. Gemessen wird
Wanddauer und übertragene Bytes (aus `--stats`) → MB/s und Dateien/s.

- Escalation stoppt, sobald eine Stufe **weniger als 15 %** Zuwachs bringt oder der Durchsatz
  fällt. Gewählt wird dann die vorherige Stufe.
- Die Probe-Arbeit ist echte Arbeit — es wird nichts verworfen oder doppelt übertragen.
- `--jobs N` überspringt die Messung vollständig.

Begründung: der Unterschied zwischen HDD-RAID und NVMe auf der Quellseite entscheidet zwischen
P=4 und P=8, und bei drehenden Platten kostet ein zu hohes P durch Seek-Thrashing mehr, als
Parallelität bringt. Diese Information hat niemand vorab.

### 5.5 Phase 4 — Transfer

Arbeitspakete werden zu Chunks gebündelt, jeder Chunk als eigene Datei auf Platte. Die Chunkgröße
ist nicht fest, sondern

```
chunk_size = max(1, min(100, ceil(|arbeit| / (4 × P_max))))
```

Eine feste Größe von 100 wäre falsch: Fall A hat 308 Arbeitspakete und ergäbe damit nur 4 Chunks —
zu wenig für 8 Worker und mit katastrophaler Balance. Mit der Formel werden daraus 10 Einträge je
Chunk und 31 Chunks. Fall B (13.193 Pakete) läuft in die Obergrenze und ergibt 132 Chunks à 100.
Ziel ist in beiden Fällen: deutlich mehr Chunks als Worker, damit Work-Stealing überhaupt etwas zu
stehlen hat.

Verteilung per `xargs -a <chunkliste> -P <N>` — dynamisch, also Work-Stealing, was bei den
gemessenen Größenunterschieden (3,6 MB bis 41 MB+ je Ordner) nötig ist.

Je Chunk:

```
rsync -rlt -W --partial --numeric-ids --files-from=<chunkdatei> [--exclude-from=…] \
      rsync://<host>/<modul>/<pfad>/ <ziel>/
```

- `-W` (whole-file): bei einer Erstkopie ist jede Datei neu, der Delta-Algorithmus kostet nur CPU
  auf der langsamen Quelle.
- **kein `-z`**: im LAN ist die CPU das Limit, nicht die Leitung.
- **kein `-a`**: `-a` zieht `-pog` mit; die Rechte, die ein Cygwin-Daemon meldet, sind synthetisch.
- **niemals `-L`**: würde NTFS-Junctions folgen und in Endlosschleifen laufen. `-l` kopiert sie
  gefahrlos als Symlink.
- Retry je Chunk bis Exit 0, maximal 3 Versuche mit wachsender Pause.
- Jeder Chunk schreibt eigenes Log und seinen **Exit-Code** in eine Ergebnisdatei.

**Listen laufen ausschließlich über Dateien, nie über `-` (stdin).** Das ist keine Stilfrage: bei
der Bootstrap-Variante (Abschnitt 6) ist stdin belegt, und ein `--files-from=-` würde den
restlichen Skriptcode als Dateiliste lesen. Ebenso `xargs -a <datei>` statt `xargs < …`.

### 5.6 Phase 5 — Sweep

Ein einzelner, nicht paralleler Lauf über den gesamten Baum:

```
rsync -rlt -W --partial --numeric-ids rsync://<host>/<modul>/<pfad>/ <ziel>/
```

Da alle Daten bereits liegen, ist das ein reiner Metadaten-Durchlauf ohne nennenswertes
Datenvolumen. Er korrigiert Verzeichnis-mtimes und fängt alles ab, was die Zerlegung wider
Erwarten ausgelassen hätte. Er ist die zweite Verteidigungslinie und **nicht optional** — im Test
(2.6) hat genau dieser Pass die künstlich eingebauten Lücken geschlossen.

### 5.7 Phase 6 — Verifikation

Zwei unabhängige Prüfungen:

1. **Struktur-Verify:** `rsync -rlt -W -n -i <quelle>/ <ziel>/`. Erwartung: leere Ausgabe.
   Gefiltert wird ausschließlich die Zeile `.d..t.... ./` (mtime der Wurzel selbst, systematisch
   und harmlos). **Jede** übrige Zeile ist ein Fehler und führt zu Exit ≠ 0. Kein pauschales
   Wegfiltern von `.d`-Zeilen — nach dem Sweep gibt es sie nicht mehr, und wer sie generell
   ausblendet, blendet auch echte Befunde aus.
2. **Zählung:** reguläre Dateien remote (`rsync -r --list-only … | grep -c '^-'`) gegen lokal
   (`find … -type f | wc -l`).

Zusätzlich wertet der Abschlussbericht die gesammelten **Exit-Codes** aus. Exit 23 und 24
(partial transfer / verschwundene Quelldateien) sind **Alarm, nicht Erfolg** — das ist die Klasse,
in der gesperrte oder unlesbare Dateien still fehlen.

Optional per Flag: `--checksum` mit xxHash. Ehrlich beziffert im Bericht — liest den gesamten
Bestand auf beiden Seiten erneut, grob 1–2 Stunden pro TB.

### 5.8 Abschlussbericht

Eine Bildschirmseite: Dauer, übertragene Datenmenge, effektive MB/s, gewählte Parallelität,
Anzahl Chunks (erfolgreich / mit Retry / fehlgeschlagen), Verify-Ergebnis, Dateizahl-Abgleich, und
ein eindeutiges **PASS / FAIL**. Das FAIL-Kriterium ist explizit, weil an ihm hängt, ob die Quelle
verschrottet werden darf.

## 6 Auslieferung

Repo `7onnie/win2unix`, öffentlich. Der dokumentierte Aufruf ist:

```
bash -c "$(curl -fsSL https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh)" -- \
     rsync://<WIN-IP>/e/Archiv /opt/data/files/
```

**Nicht** `curl … | bash`. Zwei Gründe, beide real:

1. **stdin-Konflikt.** Bei einer Pipe ist stdin der Skript-Stream. `xargs` und `--files-from=-`
   würden daraus lesen und den restlichen Skriptcode als Dateiliste interpretieren.
   `bash -c "$(…)"` puffert das Skript vollständig in einer Variablen und lässt stdin frei.
2. **Teil-Download.** Bricht die Verbindung mitten im Transfer ab, führt `bash` bei der
   Pipe-Variante ein abgeschnittenes Skript aus. Die Kommandosubstitution führt gar nicht erst aus.

Zusätzliche Selbstsicherung im Skript, unabhängig vom Aufrufweg:

- Der gesamte Skriptinhalt liegt in `main() { … }`, aufgerufen in der letzten Zeile. Ein
  abgeschnittenes Skript definiert dann höchstens Funktionen und tut nichts.
- Alle Listen laufen über Dateien statt stdin (5.5).
- `set -euo pipefail`, `trap` auf EXIT/INT/TERM räumt Temp-Verzeichnis auf und beendet laufende
  Worker.

Die Windows-Seite bekommt **keinen** Download-Einzeiler: Bundle-Ordner kopieren (USB oder Share),
`START-RSYNC-SERVER.cmd` als Administrator anklicken. Damit funktioniert der Weg auch auf
Altsystemen ohne Internet — bei zu verschrottenden Servern der realistischere Fall.

## 7 Fehlerklassen und Gegenmaßnahmen

| Fehlerklasse | Wirkung ohne Maßnahme | Maßnahme |
|---|---|---|
| Datei direkt im aufgeteilten Ordner | fehlt still | Zerlegung 5.3 nimmt Dateien als Arbeitspakete; Sweep 5.6; Verify 5.7 |
| Leeres Verzeichnis | fehlt still | dito |
| Gesperrte / unlesbare Datei | rsync überspringt, Exit 23 | Exit-Codes je Chunk gesammelt, 23/24 = FAIL |
| Fehlende Admin-Rechte | ganze Profile fehlen still | Admin-Prüfung vor allem anderen, Abbruch mit Klartext |
| `max connections` ohne `lock file` | jeder Transfer bricht ab | `lock file` fest in generierter Config (2.5) |
| NTFS-Junctions | Endlosschleife | `-l`, niemals `-L` |
| Pfade > 260 Zeichen | einzelne Dateien fehlen still | Verify 5.7 zeigt sie als fehlend; Cygwin selbst kann lange Pfade |
| `\r` in Chunk-Dateien | Pfad wird nicht gefunden | `tr -d '\r'` beim Parsen |
| Standby des Servers | Transfer stoppt nachts | `powercfg` in der `.cmd` |
| Chunk-Liste zu groß für Argumentliste | Abbruch | Übergabe ausschließlich per Datei |
| stdin-Kollision beim Bootstrap | Skript bricht verstümmelt ab | `bash -c "$(…)"` + Datei-Listen (6) |

## 8 Sicherheit

Der Transport ist **unverschlüsselt und unauthentifiziert**. Für die Dauer des Transfers kann jeder
im selben LAN die freigegebenen Laufwerke lesen. Das ist eine bewusste Abwägung: reines LAN,
einmaliger Vorgang, Maschine wird verschrottet, und Verschlüsselung würde die CPU der alten Quelle
zum Flaschenhals machen.

Abgesichert wird durch: `read only = true` auf allen Modulen, `hosts allow` auf das lokale Subnetz,
und den Umstand, dass der Daemon nur läuft, solange das Konsolenfenster offen ist. Wenn die Daten
schutzbedürftig sind, gehört der Transfer in ein isoliertes Netzsegment oder direkt an ein
Crossover-Kabel — das ist eine Betriebs-, keine Skript-Entscheidung, und gehört so ins README.

## 9 Testplan

1. **Unit-nah:** Listing-Parser gegen Fixtures mit Leerzeichen, Umlauten, `\r`, sehr langen Namen.
2. **Zerlegung:** synthetische Bäume, die Fall A und Fall B nachbilden, inklusive Dateien direkt
   im aufgeteilten Ordner und leerer Verzeichnisse. Prüfkriterium ist die Vereinigung der
   Arbeitspakete gegen den vollständigen Baum.
3. **Ende-zu-Ende gegen lokalen Daemon** (rsync 3.5 auf dem Entwickler-Mac, openrsync als Client) —
   der Aufbau, mit dem 2.2/2.3/2.6 gemessen wurden.
4. **Abbruch-Test:** Transfer hart killen, erneut starten, Verify muss sauber sein.
5. **Negativ-Test:** absichtlich unvollständige Zerlegung ⇒ Verify **muss** FAIL melden. Ein
   Verify, der nicht nachweislich fehlschlagen kann, beweist nichts.
6. **Windows real:** gegen eine echte Windows-Kiste, sobald verfügbar.

## 10 Offene Risiken

- **cwRsync 3.4-Daemon gegen openrsync-Client ist nicht direkt getestet.** Gemessen wurde gegen
  rsync 3.5.0. Die Protokollaushandlung ist dieselbe Familie, das Restrisiko ist klein, aber es
  ist ein Restrisiko — der erste Lauf gegen echte Windows-Hardware muss es ausräumen.
- **Durchsatz-Erwartung.** Realistisch Faktor 4–6 gegenüber einem einzelnen Stream, nicht Faktor N.
  Ab einem Punkt limitiert die Quell-Platte oder deren CPU; genau deshalb misst 5.4 statt zu raten.
- **Windows-Seite ist noch ungetestet**, weil keine Windows-Maschine zur Verfügung steht. Alles
  daran ist aus Dokumentation und Cygwin-Verhalten abgeleitet, nicht gemessen.
