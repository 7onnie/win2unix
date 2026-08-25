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
bash -c "$(curl -fsSL https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh)" -- \
     rsync://<WINDOWS-IP>/e/Archiv /opt/data/files
```

**Nicht `curl … | bash` verwenden.** Dabei ist die Standardeingabe der Skript-Stream selbst, und
die internen Dateilisten des Werkzeugs würden den restlichen Skriptcode lesen. Die Form mit
`bash -c "$(…)" --` hat diese Falle nicht.

Bricht der Transfer ab — Netzwerk, Strom, versehentlich geschlossenes Fenster, Ctrl-C —, einfach
**denselben Befehl erneut ausführen**. Es wird nur geholt, was fehlt; bereits übertragene Dateien
bleiben liegen.

Voraussetzung auf dieser Seite ist nur bash und ein rsync: **Apples `openrsync` genügt als Client**
(auf den Ziel-Macs ist das der Normalfall, Homebrew ist dort meist nicht installiert). Ein
Homebrew-rsync wird bevorzugt, wenn es liegt; `--rsync PFAD` erzwingt ein bestimmtes.

### Die Form des Zielpfads entscheidet über die Parallelität

Die parallele Phase kann technisch nur die **Modulwurzel** ansprechen (`--files-from` gegen einen
rsync-Daemon funktioniert ausschließlich so — nachgemessen). Sie hängt die modul-relativen Pfade
darunter an. Daraus folgt genau eine Regel:

> Der entstehende Zielpfad muss auf dem **gesamten** Pfad enden, der die Quelle unterhalb des
> Moduls hat.

Für den Normalfall — ein Ordner direkt unter dem Laufwerk — heißt das schlicht: **Quelle ohne
Schrägstrich am Ende**, ihr letzter Pfadteil bildet den Zielordner.

```bash
pull.sh rsync://<IP>/e/Archiv /ziel      # -> /ziel/Archiv, volle Parallelität
pull.sh rsync://<IP>/e/Archiv /ziel/     # dasselbe, Schrägstriche am ZIEL sind egal
pull.sh rsync://<IP>/e/Archiv/ /ziel     # -> /ziel, EINSTROEMIG (siehe unten)
pull.sh rsync://<IP>/e /ziel             # -> /ziel/e, ganzes Laufwerk, immer parallel
```

Liegt die Quelle **tiefer** unter dem Modul, muss das Ziel den Zwischenpfad mitbringen:

```bash
mkdir -p /ziel/Daten
pull.sh rsync://<IP>/e/Daten/Archiv /ziel/Daten     # -> /ziel/Daten/Archiv, parallel
pull.sh rsync://<IP>/e/Daten/Archiv /ziel           # -> /ziel/Archiv, EINSTROEMIG
```

Passt die Kürzung nicht auf, überträgt ein einzelner rsync-Prozess. Der Lauf ist trotzdem
vollständig und wird verifiziert, dauert aber deutlich länger — und das Werkzeug **sagt es an**,
mit dem Wort `EINSTROEMIG` und dem Zielpfad, an dem es scheitert (`… endet nicht auf
'/Daten/Archiv'`). Ein stiller Rückfall wäre dieselbe Fehlerklasse wie ein stiller Datenverlust.

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
| `--jobs N` | feste Parallelität, überspringt die Auto-Messung |
| `--exclude-from DATEI` | Ausschlussmuster. Bei einer Quelle **mit** Unterpfad müssen die Muster **ohne** führenden Schrägstrich stehen, sonst bricht der Lauf ab (ein `/x` meint in den einzelnen Phasen verschiedene Stellen) |
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

Ohne `--log-dir` legt der Lauf ein eigenes temporäres Logverzeichnis an. Nach einem PASS wird es
weggeräumt, nach einem FAIL bleibt es liegen — der Bericht nennt den Pfad.

## Wann ist es fertig?

Am Ende steht ein Bericht mit **PASS** oder **FAIL**. PASS setzt im Normallauf voraus: jeder Chunk
hat sein Ergebnis protokolliert und keiner ist fehlgeschlagen, die Dateizahlen von Quelle und Ziel
stimmen überein, und der Vergleichslauf gegen die Quelle ist leer. Erst dann darf die Quelle
verschrottet werden. Wer Prüfschichten abschaltet (`--no-verify`) oder entwertet (`--exclude-from`),
bekommt entsprechend weniger — das Werkzeug sagt in beiden Fällen, worauf das PASS dann noch beruht,
und verweigert es, wenn gar keine Schicht mehr trägt.

**Worauf man sich dabei verlässt — und worauf nicht.** Der Vergleichslauf läuft mit `-rlt -W -n -i`,
er vergleicht also **Größe und Zeitstempel**, nicht die Inhalte. Ein PASS heißt: jede Datei liegt
mit passender Größe und passender Zeit am Ziel, und die Dateizahlen stimmen. Es heißt **nicht**:
die Bytes sind nachweislich identisch. Wer das belegt haben will, nimmt `--checksum` — dieser Lauf
liest den gesamten Bestand auf beiden Seiten erneut und braucht grob ein bis zwei Stunden pro
Terabyte. Das ist die bewusste Vorgabe, kein Versehen: der Prüfsummenlauf kostet auf einem TB mehr
Zeit als der Transfer selbst.

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
- `hosts allow` auf die lokalen /24-Subnetze der Maschine,
- der Server läuft nur, solange das Fenster offen ist.

Eine Einschränkung an der zweiten Zeile, die man wissen muss: erkennt das Skript **keine**
IPv4-Adresse, setzt es `hosts allow = 0.0.0.0/0` — dann darf jeder lesen. Das Fenster sagt es
(`[!] Keine IPv4-Adresse erkannt`), und es steht auch in der erzeugten `rsyncd.conf`. Ebenso
liegt die Grenze bei /24: wer im Netz mit /16 arbeitet, korrigiert die Zeile in `rsyncd.conf`
und startet neu.

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
