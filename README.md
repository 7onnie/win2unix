# win2unix

Einmaliger Massen-Datentransfer von einem alten Windows-Rechner auf Mac oder Linux.
Auf Windows wird **nichts installiert** — ein Ordner wird kopiert und eine Datei angeklickt.

Gedacht für den Fall: mehrere hundert GB bis mehrere TB, sehr viele kleine Dateien in tiefen
Bäumen, danach wird die Windows-Kiste verschrottet. Genau deshalb endet jeder Lauf mit einem
ausdrücklichen **PASS** oder **FAIL** — wer die Quelle wegwirft, muss vorher etwas in der Hand
haben.

## Auf dem Windows-Rechner

1. Den Ordner `windows/` auf die Windows-Kiste kopieren (USB-Stick oder Netzwerkfreigabe) und
   dort auf eine **lokale Festplatte** legen, z. B. `C:\win2unix\`. Direkt von einer Freigabe
   gestartet findet das Skript seine eigenen Dateien nicht.
2. `START-RSYNC-SERVER.cmd` **als Administrator** ausführen (Doppelklick genügt — das Skript
   fordert die Rechte selbst an).
3. Das Fenster offen lassen. Es zeigt die IP-Adressen an, unter denen der Server erreichbar ist,
   und den fertigen Befehl für die Gegenseite. **Fenster schließen = Server aus.**

Administrator-Rechte sind nicht optional: ohne sie kann der Server fremde Benutzerprofile nicht
lesen und lässt still Dateien aus — und "still" ist in diesem Werkzeug der einzige Fehler, der
sich nicht mehr beheben lässt, wenn die Quelle erst verschrottet ist.

Angeboten wird **jedes fest eingebaute Laufwerk als eigenes Modul**, benannt nach dem
Laufwerksbuchstaben und **read only**: `C:` wird `rsync://<IP>/c/`, `E:` wird `rsync://<IP>/e/`.

### Was das Skript dauerhaft ändert

Zwei Dinge, beide im Fenster als `AENDERT DIESE MASCHINE` angesagt:

- eine Firewall-Regel `win2unix rsync` (TCP 873 eingehend),
- Standby, Ruhezustand, Platten- und Bildschirm-Timeout im aktiven Energieschema auf "nie"
  (`powercfg /change standby-timeout-ac 0` und die drei Geschwister `hibernate-`, `disk-`,
  `monitor-timeout-ac`).

Beides bleibt bewusst stehen: die Maschine wird verschrottet, und ein Rechner, der mitten im
TB-Transfer einschläft, ist das größere Problem. Überlebt die Kiste doch — siehe
[Aufräumen](#aufräumen-falls-die-maschine-doch-weiterlebt).

## Auf dem Mac oder Linux-Rechner

Erst schauen, was es gibt:

```bash
rsync rsync://<WINDOWS-IP>/          # welche Laufwerke?
rsync rsync://<WINDOWS-IP>/e/        # was liegt auf E:?
```

Dann holen:

```bash
curl -fsSL -o /tmp/pull.sh https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh
bash /tmp/pull.sh rsync://<WINDOWS-IP>/e/Archiv /opt/data/files
```

**Nicht `curl … | bash` verwenden.** Dabei ist die Standardeingabe der Skript-Stream selbst, und
die internen Dateilisten des Werkzeugs würden den restlichen Skriptcode lesen. Ebenfalls **nicht**
die Form `bash -c "$(curl …)"`: `pull.sh` ist größer als die 128 KB, die Linux einem einzelnen
Argument erlaubt, und scheitert dort mit „Argumentliste ist zu lang".

Bricht der Transfer ab — Netzwerk, Strom, versehentlich geschlossenes Fenster, Ctrl-C —, einfach
**denselben Befehl erneut ausführen**. Es wird nur geholt, was fehlt; bereits übertragene Dateien
bleiben liegen.

Voraussetzung auf dieser Seite ist bash und ein rsync: **Apples `openrsync` genügt als Client**
(auf den Ziel-Macs ist das der Normalfall, Homebrew ist dort meist nicht installiert). Ein
Homebrew-rsync wird bevorzugt, wenn es liegt; `--rsync PFAD` erzwingt ein bestimmtes. Dazu die
üblichen POSIX-Werkzeuge, die `pull.sh` aufruft — `awk`, `find`, `du`, `split`, `xargs`, `grep`,
`cut`, `head`, `tail`, `tr`, `basename`, `mktemp`, optional `pkill`. Auf macOS und jedem
Linux-System ist das vorhanden; die BSD-Varianten reichen (`awk` ohne Intervall-Quantoren, bash 3.2).

### Wohin der Ordner kommt

Das Ziel ist immer `<ziel>/<ordnername>`, egal wie tief der Ordner auf Windows liegt. Der
Pfad davor taucht im Ziel nicht auf:

```bash
bash /tmp/pull.sh rsync://<IP>/f/Konvertierung/Albis/AlbisWin/BRIEFE /opt/data/files
# -> /opt/data/files/BRIEFE, parallel
```

Das angegebene Zielverzeichnis (`/opt/data/files`) muss existieren, sonst bricht der Lauf mit
`Zielverzeichnis existiert nicht` ab. `<ordnername>` legt `pull.sh` selbst an.

**Einzige Ausnahme: Quelle mit Schrägstrich am Ende.** `…/BRIEFE/` schreibt den *Inhalt*
direkt ins Ziel. Das läuft mit einem einzelnen rsync-Prozess, angesagt mit dem Wort
`EINSTROEMIG`: vollständig und verifiziert, aber langsamer. Für viele kleine Dateien die Form
ohne Schrägstrich nehmen.

#### Der Zwischenordner `.w2u-stage-<ordnername>`

Technischer Hintergrund: Die parallele Phase kann nur die **Modulwurzel** ansprechen
(`--files-from` gegen einen rsync-Daemon funktioniert ausschließlich so, nachgemessen). rsync
legt deshalb den ganzen Pfad ab Laufwerkswurzel an. `pull.sh` benennt `<ziel>/BRIEFE` dafür
nur für die Dauer der parallelen Phase nach
`<ziel>/.w2u-stage-BRIEFE/Konvertierung/Albis/AlbisWin/BRIEFE` um und danach zurück. Das ist
ein Umbenennen auf derselben Platte und dauert keine Sekunde. Prüfung und Bericht laufen auf
`<ziel>/BRIEFE`.

- **Nach Ctrl-C oder Absturz** liegt der Bestand eventuell im Zwischenordner. Die Meldung
  sagt das. **Denselben Befehl erneut ausführen**: Er holt den Bestand zurück und setzt fort.
- **Zwei Läufe auf dasselbe Ziel** verhindert eine Sperre `<ziel>/.w2u-stage-BRIEFE.lock`.
  Stammt sie von einem Prozess, der nicht mehr läuft, übernimmt der nächste Lauf sie. Nach
  einem `kill -9` laufen allerdings oft noch dessen `xargs`/`rsync` weiter und schreiben in den
  Zwischenordner. Dann bricht der Lauf ab, nennt deren PIDs und fasst nichts an. Warten, bis sie
  fertig sind, oder sie mit `kill` beenden, und denselben Befehl wiederholen.
- **Ist `<ziel>/BRIEFE` ein Symlink**, wird er nicht umbenannt. Der Transfer läuft
  einströmig durch den Link, angesagt.
- **Liegt Inhalt im Zwischenordner UND in `<ziel>/BRIEFE`**, bricht der Lauf ab und fasst
  nichts an. Das passiert nur nach Handarbeit zwischen zwei Läufen. Beide Bestände ansehen,
  von Hand zusammenführen, den Zwischenordner löschen, neu starten.
- **Ist `<ziel>/BRIEFE` ein eigener Einhängepunkt** (andere Platte als `<ziel>`), ginge das
  Umbenennen nur als Kopie. Dann läuft der Transfer einströmig, angesagt.

### Ohne Skript

Der Weg funktioniert auch mit blankem rsync, das Skript ist nur schneller:

```bash
rsync -rltP -W rsync://<WINDOWS-IP>/e/Archiv /opt/data/files/
```

Der Unterschied: `pull.sh` zerlegt den Ordner und überträgt parallel. Erwartet wird bei tiefen
Bäumen voller kleiner Dateien Faktor 4–6, nicht Faktor N — ab einem Punkt limitiert die
Quell-Platte oder deren CPU (ein einzelner rsync-Prozess auf Windows ist in der Cygwin-Schicht
CPU-gebunden). Deshalb *misst* das Skript die Parallelität statt sie zu raten. Dazu kommt die
Verifikation, die es beim blanken rsync nicht gibt.

### Optionen

| Option | Wirkung |
|---|---|
| `--jobs N` | feste Parallelität, überspringt die Auto-Messung. Höchstens 64 — mehr wären keine Einstellung mehr, sondern ein Tippfehler mit 10000 rsync-Prozessen. Ein N über 8 hebt zugleich die Zerlegung an, damit es mehr Chunks als Worker gibt (sonst läuft mindestens einer leer) |
| `--exclude-from DATEI` | Ausschlussmuster. Muster **ohne** führenden Schrägstrich gelten überall gleich und sind immer erlaubt. **Verankerte** Muster (mit führendem `/`) lehnt der Lauf ab, sobald die Quelle einen Unterpfad hat und parallel übertragen wird — dort meint ein `/x` je Phase eine andere Stelle. Gegen die Modulwurzel und im `--verify-only`-Lauf sind sie eindeutig und bleiben erlaubt; im Trockenlauf gibt es nur eine Warnung |
| `--log-dir PFAD` | Logverzeichnis. Darf **nicht** unter dem Ziel liegen, sonst zählen die Logdateien als lokale Dateien mit |
| `--rsync PFAD` | ein bestimmtes rsync benutzen statt selbst zu suchen |
| `--verify-only` | nur prüfen, nichts übertragen |
| `--no-verify` | Verifikation überspringen (nicht empfohlen — ein PASS heißt dann nur noch "jeder Chunk hat rc 0 gemeldet") |
| `--checksum` | Verifikation zusätzlich mit Prüfsummen (`-c`); liest den gesamten Bestand auf **beiden** Seiten erneut, grob 1–2 h pro TB |
| `--dry-run` | zeigt die Arbeitspakete, überträgt nichts |
| `--version`, `-h` | Version bzw. Hilfe |

Ohne `--jobs` misst das Werkzeug die günstigste Parallelität an echter Arbeit: es fährt die Stufen
2, 4 und 8 und bleibt stehen, sobald eine Stufe keine 15 Prozent mehr bringt. Gemessen wird an
Arbeit, die ohnehin anfällt — nichts wird zweimal übertragen. Kommt keine verwertbare Messung
zustande — zu kurze Runden, zu wenig neue Daten, Wiederholungen in der Runde —, sagt das Log das
ausdrücklich und es bleibt beim Vorgabewert 2; eine erfundene Zahl mit Messwert-Anmutung gibt es
nicht.

Vier Kombinationen werden **abgelehnt**, und zwar sofort beim Parsen statt nach Stunden Arbeit,
weil sie strukturell kein tragfähiges Urteil erzeugen können: `--verify-only` mit `--no-verify`,
`--verify-only` mit `--exclude-from`, `--verify-only` mit `--dry-run`, und `--no-verify` mit
`--checksum`.

Ohne `--log-dir` legt der Lauf ein eigenes temporäres Logverzeichnis an. Es **bleibt liegen** —
nach einem FAIL, weil es die einzige Spur ist, und nach einem PASS, weil PASS die Freigabe zum
Verschrotten der Quelle ist und der Nachweis dieser Freigabe danach das Einzige ist, was von der
Maschine übrig bleibt. Darin: `verify.log`, `sweep.log`, ein Log je Chunk-Versuch und
`report.txt` — der vollständige Abschlussbericht, wortgleich mit dem auf dem Bildschirm.
Weggeräumt wird das Verzeichnis nur, wenn es leer geblieben ist (ein Abbruch vor der ersten
Übertragung). Ein per `--log-dir` angegebenes Verzeichnis fasst der Lauf ohnehin nie an.

## Wann ist es fertig?

Am Ende steht ein Bericht mit **PASS** oder **FAIL**. PASS setzt im Normallauf voraus: jeder Chunk
hat sein Ergebnis protokolliert und keiner ist fehlgeschlagen, die Dateizahlen von Quelle und Ziel
stimmen überein, und der Vergleichslauf gegen die Quelle ist leer. Erst dann darf die Quelle
verschrottet werden. Wer Prüfschichten abschaltet (`--no-verify`) oder entwertet (`--exclude-from`),
bekommt entsprechend weniger — das Werkzeug sagt in beiden Fällen, worauf das PASS dann noch beruht,
und verweigert es, wenn gar keine Schicht mehr trägt.

**Worauf man sich dabei verlässt — und worauf nicht.** Der Vergleichslauf läuft mit `-rlt -W -n -i`,
er vergleicht also **Größe und Zeitstempel**, nicht die Inhalte. Der Bericht sagt in seiner
Verify-Zeile ausdrücklich, welche der beiden Vergleiche gelaufen ist. Ein PASS heißt: jede Datei liegt
mit passender Größe und passender Zeit am Ziel, und die Dateizahlen stimmen. Es heißt **nicht**:
die Bytes sind nachweislich identisch. Wer das belegt haben will, nimmt `--checksum` — dieser Lauf
liest den gesamten Bestand auf beiden Seiten erneut und braucht grob ein bis zwei Stunden pro
Terabyte. Das ist die bewusste Vorgabe, kein Versehen: der Prüfsummenlauf kostet auf einem TB mehr
Zeit als der Transfer selbst.

**Wenn die Dateizahlen auseinandergehen**, nennt der Bericht nicht bloß zwei Zahlen, sondern die
**Namen**: welche Datei am Ziel fehlt, und welche dort ohne Gegenstück in der Quelle liegt. Eine
Ausnahme wird dabei entschuldigt, und nur diese eine: eine liegengebliebene rsync-Temp-Datei
(`.name.XXXXXX`, deren Originaldatei in der Quelle existiert) — das ist der Rückstand eines hart
abgebrochenen Laufs, sie wird namentlich genannt und zählt nicht gegen die Vollständigkeit. Ohne
diese Ausnahme wäre jeder Lauf nach einem harten Abbruch dauerhaft ein FAIL. Eine Datei in
derselben Form, deren Original es in der Quelle **nicht** gibt, bleibt ein Befund.

Und ein Widerspruch bleibt ein FAIL: melden alle Chunks rc 0, während am Ziel keine einzige Datei
liegt und nichts dazugekommen ist, endet der Lauf mit FAIL — auch unter `--no-verify`. Ein rc 0 ohne
übertragene Daten ist in diesem Projekt gemessen worden. Eine Wiederaufnahme über einen bereits
vollständigen Zielbaum überträgt dagegen legitim null Bytes und bleibt PASS.

FAIL nennt die fehlgeschlagenen Chunks und den Pfad zu den Logs. Exit-Code 23 oder 24 bedeutet,
dass Dateien nicht gelesen werden konnten — meist gesperrt durch ein laufendes Programm, oder
fehlende Administrator-Rechte auf der Windows-Seite. Programme schließen, Lauf wiederholen.

## Aufräumen, falls die Maschine doch weiterlebt

`START-RSYNC-SERVER.cmd` lässt seine zwei dauerhaften Änderungen bewusst stehen — "wird
verschrottet" ist aber eine Annahme, keine Garantie. Wird der Transfer abgebrochen, die
Entscheidung geändert oder die falsche Maschine erwischt, bleibt sie mit offenem Port 873 und
abgeschaltetem Energiesparen zurück. In einem Administrator-`cmd`:

```bat
netsh advfirewall firewall delete rule name="win2unix rsync"
powercfg /restoredefaultschemes
```

Zwei Dinge dazu:

- Jeder Start legt eine **weitere** gleichnamige Regel an (wirkungsgleich, deshalb im Skript
  akzeptiert). `delete rule` entfernt alle Regeln dieses Namens auf einmal — die Zeile also
  nur einmal ausführen und danach mit
  `netsh advfirewall firewall show rule name="win2unix rsync"` nachsehen.
- Das Skript **notiert die vorherigen Energiespar-Werte nicht**. `powercfg /restoredefaultschemes`
  ist deshalb der einzige ehrliche Weg zurück — es setzt allerdings **alle** Energieschemata auf
  die Windows-Vorgaben, auch selbst angepasste. Wer eigene Werte hatte, setzt sie stattdessen
  gezielt wieder, z. B. `powercfg /change standby-timeout-ac 30`.

Der Bundle-Ordner selbst darf einfach gelöscht werden. Darin liegen nach einem Lauf noch
`rsyncd.conf` (mit den lokalen Subnetzen dieser Maschine), `rsyncd.log`, `rsyncd.lock` und
`rsyncd.pid`.

## Sicherheit

Der Transfer ist **unverschlüsselt und nicht authentifiziert**. Solange der Server läuft, kann
jeder im selben Netz die freigegebenen Laufwerke lesen — und freigegeben sind alle. Das ist bewusst
so: reines LAN, einmaliger Vorgang, und Verschlüsselung würde die CPU der alten Quelle zum
Flaschenhals machen, also genau das kaputtmachen, wofür dieses Werkzeug existiert.

Abgesichert ist es durch drei Dinge:

- `read only` in jedem Modul — es lässt sich nichts auf die Quelle schreiben,
- der Server läuft nur, solange das Fenster offen ist.

`hosts allow` steht bewusst auf `0.0.0.0/0`: jeder, der Port 873 erreicht, darf lesen. Früher
waren es die lokalen /24-Netze der Maschine — das hat im ersten Ernstfall den Client ausgesperrt,
der die Daten holen sollte. Wer es enger will, ändert die Zeile in der erzeugten `rsyncd.conf`.
Der Daemon liest die Datei bei jeder Verbindung neu, ein **Neustart ist nicht nötig — und
schädlich**: das Skript erzeugt die Datei beim Start neu.

Sind die Daten schutzbedürftig, gehört der Transfer in ein eigenes Netzsegment oder direkt an ein
Crossover-Kabel zwischen die beiden Rechner. Das ist eine Betriebs-, keine Skript-Entscheidung.

## Für Entwickler

```bash
bash tests/run_all.sh          # alles
bash tests/test_e2e.sh         # nur der Ende-zu-Ende-Lauf gegen einen echten Daemon
```

**"Suite grün" auf einer Zielmaschine ist kein Beleg, dass das Werkzeug dort funktioniert.** Die
aussagekräftigsten Tests brauchen ein **daemon-fähiges rsync** auf der Testmaschine — Apples
`openrsync` kann kein `--daemon`. Auf einem Mac ohne Homebrew-rsync, also auf dem typischen
*Zielsystem*, überspringt der gesamte Integrationsblock samt Ende-zu-Ende-Test; übrig bleiben
Zeichenketten-Prüfungen, die ein "null Dateien angekommen" nicht bemerken würden.

Dabei ist `run_all.sh` gutgläubig: es meldet `ALLE TESTS GRUEN`, sobald keine Testdatei mit
Fehler endet — und eine Datei, in der **alles** übersprungen wurde, endet mit 0. Die Zahl, auf die
es ankommt, steht in der Zusammenfassungszeile jeder Datei:

```
test_e2e.sh: 32 Tests, 0 Fehler, 0 uebersprungen
```

Viele `uebersprungen` heißt **"nicht getestet"**, nicht "bestanden". Für den vollen Nachweis
`brew install rsync` (GNU rsync 3.x) und erneut laufen lassen.

Das Bundle unter `windows/` lässt sich mit `tools/fetch-cwrsync.sh` reproduzierbar neu bauen.

### Was noch nicht gemessen ist

Die Windows-Seite ist gegen einen **echten Windows-Rechner ungetestet** — es stand keiner zur
Verfügung. Gemessen ist alles gegen einen rsync-3.5.0-Daemon auf einem Mac; der riskanteste Teil
der Windows-Seite, die erzeugte `rsyncd.conf`, wird von `tests/test_rsyncd_conf.sh` aus genau den
ausgelieferten Templates gebaut und gegen einen echten Daemon geprüft. Offen bleibt damit die
Kombination cwRsync-Daemon (rsync 3.4) gegen openrsync-Client: dieselbe Protokollfamilie, kleines
Restrisiko — der erste Lauf gegen echte Hardware räumt es aus.

## Lizenz

Die mitgelieferten Windows-Binärdateien stammen aus cwRsync free edition und stehen unter der
GPLv3 — siehe `windows/NOTICE.md`, `windows/COPYING` und `windows/LICENSE.txt`.
