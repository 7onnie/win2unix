# Ziel flach: `<quelle>/…/NAME` → `<ziel>/NAME`, immer parallel (Issue #7)

Stand 2026-11-26, vom User freigegeben (Weg A plus vier Punkte aus dem Gemini-Review).

## Warum

Erster Ernstfall (Albis, zwei Windows-Kisten): Der User will immer
`F:\irgend\ein\Pfad\BRIEFE` → `/opt/data/files/BRIEFE`. Heute läuft das nur
einströmig, oder parallel mit Handarbeit: den Ordner auf Windows an die Laufwerkswurzel
verschieben, Zwischenordner gleich benennen oder per `mv` nachräumen. Der Quellpfad soll
im Ziel nie auftauchen.

Ursache: Die parallele Phase muss die Modulwurzel ansprechen. `--files-from` gegen einen
Daemon geht nur so, sonst überträgt es null Dateien bei rc 0. rsync legt deshalb den
ganzen modul-relativen Pfad unter dem Worker-Ziel an. Sweep und Verify kommen ohne
`--files-from` aus und funktionieren mit Unterpfaden schon heute.

## Ziele / Nicht-Ziele / Anti-Ziele

- **Ziel:** `pull.sh rsync://IP/m/A/B/NAME <ziel>` ergibt `<ziel>/NAME` und läuft parallel,
  egal wie tief und wie geschrieben `A/B` ist.
- **Ziel:** Nach einem Abbruch (Ctrl-C, kill -9, Strom) setzt derselbe Befehl fort, ohne
  doppelt zu übertragen.
- **Nicht-Ziel:** Quelle mit `/` am Ende („Inhalt in einen vorhandenen Ordner"). Dort gehört
  das Ziel dem User und kann fremde Dateien enthalten. Es bleibt einströmig wie heute.
- **Nicht-Ziel:** Kollisionen in Groß-/Kleinschreibung. Die gibt es heute genauso, Staging
  ändert daran nichts.
- **Anti-Ziel:** Jeder Pfad, auf dem Daten still verschwinden, doppelt liegen oder
  zusammengeführt werden. Im Zweifel abbrechen und nichts anfassen.

## Ansätze

| | Weg | Abwägung |
|---|---|---|
| **A (gewählt)** | Nur während der parallelen Phase `<ziel>/NAME` in einen Zwischenordner mit Modulpfad umbenennen, danach zurück. Sweep und Verify laufen unverändert. | Kleinster Eingriff, Prüfung unverändert. Nach einem Absturz liegen die Daten kurz im Zwischenordner, der nächste Start räumt sie zurück. |
| B | Ganzer Lauf im Zwischenordner, erst nach PASS umbenennen. | Ziel erscheint erst geprüft. Dafür müssen Verify, Bericht und Resume auf einen anderen Pfad, also mehr Code genau dort, wo Fehler Datenverlust bedeuten. |
| C | Ohne Staging: je Chunk `--include-from` gegen den Unterpfad. | Jeder Worker läuft den ganzen Baum ab. Bei Millionen Dateien unbrauchbar. |

## Entwurf

Gilt nur, wenn die Quelle einen modul-relativen Präfix hat, **keinen** Schrägstrich am
Ende, und das Ziel **nicht** schon auf `/<präfix>` endet. Endet es darauf, bleibt alles
wie heute, ohne Staging.

- **Pfade:** Der Zwischenordner `_StageDir = <ziel>/.w2u-stage-NAME` liegt neben
  `<ziel>/NAME`, also auf derselben Platte. `_StageLeaf = _StageDir/<präfix>`. Die Worker
  schreiben mit `_ParDst = _StageDir`.
- **Sperre:** Vor allem anderen `mkdir <ziel>/.w2u-stage-NAME.lock` mit PID-Datei. Lebt der
  eingetragene Prozess noch, folgt Abbruch. Ist er tot (kill -9), wird die Sperre
  übernommen. Beim Ende gibt der Lauf die Sperre frei, aber nur die eigene.
- **Aufräumen beim Start:** Gibt es `_StageLeaf`:
  - `<ziel>/NAME` fehlt oder ist ein leeres Verzeichnis → zurück umbenennen.
  - `<ziel>/NAME` hat Inhalt → Abbruch mit beiden Pfaden. Nichts wird zusammengeführt oder
    gelöscht.
  - Im `--verify-only`-Lauf wird nur gewarnt, nichts verschoben.
- **Hinein, vor der parallelen Phase** (nicht im Trockenlauf): Prüfen, ob `<ziel>/NAME`
  und `<ziel>` dasselbe Gerät haben. Bei verschiedenen Geräten (Einhängepunkt) würde `mv`
  still **kopieren**, deshalb dann laut einströmig. Sonst `mkdir -p` des Elternpfads von
  `_StageLeaf` und `mv <ziel>/NAME _StageLeaf`. Scheitert das, ebenfalls laut einströmig.
- **Messung:** `w2u_dst_kb` misst während der Phase `_StageLeaf` statt `<ziel>/NAME`.
  Variable `_WorkRoot`.
- **Heraus, nach der parallelen Phase:** `mv _StageLeaf <ziel>/NAME`. Existiert
  `<ziel>/NAME` inzwischen wieder, folgt Abbruch, die Daten bleiben im Zwischenordner.
  Danach leere Zwischenordner per `rmdir` entfernen; was nicht leer ist, bleibt mit
  Warnung liegen.
- **Abbruch während der Phase:** kein Zurückbenennen im Trap, weil noch rsync-Kinder
  schreiben könnten. Die Abbruchmeldung nennt den Zwischenordner, und der nächste Start
  räumt auf, für Ctrl-C und kill -9 gleich.
- Sweep, Verify und Bericht bleiben unverändert auf `<ziel>/NAME`.

## Dem Umsetzer überlassen

Namen der Hilfsfunktionen; die genaue Formulierung der Meldungen. Die Gerätenummer per
`stat -c %d` (GNU) mit Rückfall auf `stat -f %d` (BSD).

## Tests (zuerst rot)

- Parser: tiefer Präfix, Ziel spiegelt nicht → `parallel`, `_ParDst` = Zwischenordner.
  Schrägstrich-Form → weiterhin einströmig. Spiegelndes Ziel → unverändert, ohne Staging.
- E2E gegen echten Daemon: `Daten/SonoGDT` → `<z>/SonoGDT`, parallel, PASS, `diff -r`
  leer, kein Zwischenordner, keine Sperre übrig, keine Datei außerhalb von `<z>/SonoGDT`.
- E2E Aufräumen: Zwischenordner mit Teilbestand vorab angelegt → PASS, Daten am Ziel.
- E2E beide vorhanden → rc 1, beide Bestände unangetastet.
- Sperre mit lebender PID → rc 1. Sperre mit toter PID → läuft.
- Auch mit openrsync als Client (Linux/macOS-Ziel).
