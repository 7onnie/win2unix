#!/usr/bin/env bash
#
# win2unix / pull.sh - holt EINEN Ordner von einem Windows-rsync-Daemon.
#
# Aufruf:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/7onnie/win2unix/main/pull.sh)" -- \
#        rsync://<WIN-IP>/e/Archiv /opt/data/files/
#
# NICHT "curl | bash" verwenden: dabei ist stdin der Skript-Stream, und die
# Datei-Listen wuerden den restlichen Skriptcode lesen.

W2U_VERSION="0.1.0"

# ---------- Konfiguration (Zero-Touch: alles hier, keine Rueckfragen) ----------
_JobCnt=0              # 0 = Auto-Messung (Spec 5.4)
_PMax=8                # hoechste Parallelitaet, die die Messung probiert
_MaxRetry=3
_RetryPause=5          # Sekunden, waechst linear mit dem Versuch
_RsyncTimeout=300      # Sekunden ohne I/O, ab da bricht rsync selbst ab statt zu
                       # haengen (Review Task 6) - sonst wird aus einem Retry ein
                       # Haenger, der die Schleife nie zum naechsten Versuch kommen laesst
_ChunkMax=100          # Obergrenze Eintraege je Chunk (Spec 5.5)
_ProbeMinSecs=5        # Probe-Runden unter dieser Dauer sind KEIN Messwert (Task 7).
                       # "date +%s" hat Sekundenaufloesung: bei einer 2-s-Runde
                       # sind das bis zu 50 Prozent Fehler, die 15-Prozent-Schwelle
                       # unten waere damit nicht aufloesbar. Bei 5 s bleiben ~20
                       # Prozent - immer noch grob, deshalb gilt: lieber gar keine
                       # Aussage als eine falsche.
_ProbeMinKb=1024       # ... ebenso Runden, die weniger als so viel ans Ziel bringen.
                       # Eine Runde ueber bereits vorhandene Daten uebertraegt null
                       # Bytes; ein Durchsatz daraus waere reines Rauschen.
_ThresholdFactor=4     # SCHWELLE = _ThresholdFactor * _PMax (Spec 5.3)
_MaxItems=200000       # Notbremse gegen explodierende Ebenen
_RsyncBin=""           # leer = automatisch suchen
_LogDir=""             # leer = unter dem Zielverzeichnis anlegen
_ExcludeFrom=""
_DoVerify=1
_VerifyOnly=0
_DryRun=0
_DoChecksum=0

# ---------- Laufzeit-Zustand ----------
_SrcUrl=""
_DstDir=""
_DstRoot=""
# ---- Modulwurzel, Praefix und die Pfade der PARALLELEN Phase ----------------
# GEMESSEN (Controller-Nachmessung, Task 9): "--files-from" funktioniert gegen
# einen rsync-Daemon AUSSCHLIESSLICH, wenn die Quelle die MODULWURZEL ist. Mit
# einem Unterpfad - also dem dokumentierten Hauptfall rsync://IP/e/Archiv -
# meldet der Sender "file has vanished" und uebertraegt NICHTS; openrsync
# liefert dabei rc 0, der Ausfall waere also lautlos gewesen (rsync 3.5.0 als
# Client: rc 24). Ein Elternpfad genuegt nicht, nur die Wurzel selbst.
# Deshalb laeuft die parallele Phase ueber eigene Pfade:
#   _ParSrc = Modulwurzel, Chunk-Eintraege tragen _SrcPrefix davor,
#   _ParDst  so, dass "_ParDst/<_SrcPrefix>" wieder _DstRoot ergibt.
# Sweep und Verify benutzen weiter _SrcUrl/_DstRoot - sie kommen ohne
# --files-from aus und sind von der Falle nicht betroffen (nachgemessen).
_SrcRoot=""           # rsync://host[:port]/modul  (ohne Schraegstrich am Ende)
_SrcPrefix=""         # modul-relativer Pfad, leer wenn die Quelle die Wurzel ist
_ParSrc=""            # Quelle der Worker = _SrcRoot
_ParDst=""            # Ziel der Worker; leer, wenn nicht parallel uebertragen wird
_ParMode="parallel"   # Vorgabe bewusst "parallel": w2u_report wertet eine
                      # FEHLENDE Chunkliste nur im einstroemigen Lauf als
                      # zulaessig. Die strenge Vorgabe heisst also, dass ein
                      # Aufrufer, der w2u_parse_args nie durchlaufen hat
                      # (gesourcte Tests, kuenftige Aufrufer), eine verlorene
                      # Chunkliste weiterhin als FAIL sieht. Die umgekehrte
                      # Vorgabe wuerde jeden verlorenen Massstab entschuldigen.
                      # "parallel" oder "einstroemig". Einstroemig heisst: die
                      # Kuerzung _DstRoot minus Praefix geht nicht auf, es gibt
                      # also kein Ziel, in das die modul-relativen Eintraege
                      # passen. Dann uebertraegt der Sweep allein - korrekt und
                      # verifiziert, nur langsamer. Der Anwender MUSS das
                      # erfahren: Geschwindigkeit ist der Grund fuer dieses
                      # Werkzeug, und ein stiller Rueckfall waere derselbe
                      # Fehler wie der lautlose Ausfall oben.
_TmpDir=""
_ResultFile=""
_ChunkListFile=""     # von w2u_chunk gesetzt; der Abschlussbericht gleicht die
                      # Ergebniszeilen gegen GENAU diese Liste ab. Leer heisst
                      # "es wurde nie zerlegt" (Verify-Only) - und NICHT
                      # "null Chunks erwartet": mit Ergebniszeilen aber ohne
                      # Liste meldet w2u_report FAIL, weil dann unbekannt ist,
                      # wieviele es haetten sein muessen.
_StartTs=0
_LogDirOwned=0        # 1 = das Logverzeichnis stammt aus unserem mktemp und
                      # darf am Ende geloescht werden. Ein per --log-dir
                      # angegebenes Verzeichnis gehoert dem Anwender und wird
                      # NIE angefasst - "rm -rf" auf einen fremden Pfad waere
                      # der einzige Weg, wie dieses Werkzeug Daten zerstoert.
_VerifyState=""       # "", "sauber" oder "befunde". Von main() nach dem
                      # Vergleichslauf gesetzt, vom Abschlussbericht gelesen
                      # (CONTROLLER-RULING 2 aus Task 8): Befunde im Verify
                      # muessen im BERICHT landen, nicht nur im Exit-Code.
_AbsPath=""           # Rueckgabekanal von w2u_abs_path, siehe dort
_ArgVal=""            # Rueckgabekanal von w2u_take_arg - eine Variable statt
                      # einer Kommandosubstitution, siehe dort.

w2u_log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
w2u_warn() { printf '[%s] WARNUNG: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
w2u_die()  { printf '[%s] ABBRUCH: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

w2u_usage() {
    cat >&2 <<'EOF'
Aufruf: pull.sh [Optionen] rsync://<WIN-IP>/<modul>/<pfad> <zielverzeichnis>

  Quelle OHNE abschliessenden Slash  -> legt <zielverzeichnis>/<ordnername> an
  Quelle MIT abschliessendem Slash   -> schreibt den Inhalt direkt ins Ziel

Optionen:
  --jobs N            feste Parallelitaet, ueberspringt die Auto-Messung
  --exclude-from DATEI Ausschlussmuster; bei Quellen mit Unterpfad OHNE
                      fuehrenden Schraegstrich (sonst Abbruch, siehe Meldung)
  --log-dir PFAD      Logverzeichnis; darf NICHT unter dem Ziel liegen
  --rsync PFAD        bestimmtes rsync benutzen statt selbst zu suchen
  --verify-only       nur pruefen, nichts uebertragen
  --no-verify         Verifikation ueberspringen (nicht empfohlen)
  --checksum          Verifikation zusaetzlich mit Pruefsummen (langsam)
  --dry-run           nur zeigen, was passieren wuerde
  --version
EOF
}

# Liest ein rsync-Listing von stdin, schreibt "TYP<TAB>NAME".
# Format ist immer: perms size YYYY/MM/DD HH:MM:SS name
# --out-format wird von openrsync im Listing-Modus ignoriert (Spec 2.2), deshalb
# wird geparst statt formatiert. Der Name ist ALLES nach dem Zeitstempel, sonst
# gehen Leerzeichen verloren. Keine Intervall-Quantoren: BSD-awk kann sie nicht.
w2u_parse_listing() {
    awk '
    {
        sub(/\r$/, "")
        if (match($0, / [0-9][0-9][0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] /) == 0) next
        _Name = substr($0, RSTART + RLENGTH)
        if (_Name == "." || _Name == "") next
        if (substr($0, 1, 1) == "d") {
            printf "d\t%s\n", _Name
        } else {
            printf "f\t%s\n", _Name
        }
    }'
}

# Sucht ein brauchbares rsync. Auf den Ziel-Macs ist das Apple-openrsync
# (Protokoll 29) - das reicht als CLIENT vollstaendig aus (Spec 2.2).
w2u_find_rsync() {
    if [ -n "$_RsyncBin" ]; then
        [ -x "$_RsyncBin" ] || w2u_die "kein ausfuehrbares rsync unter $_RsyncBin"
        return 0
    fi
    local _C
    for _C in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
        if [ -x "$_C" ]; then
            _RsyncBin="$_C"
            return 0
        fi
    done
    _RsyncBin="$(command -v rsync 2>/dev/null || true)"
    [ -n "$_RsyncBin" ] || w2u_die "kein rsync gefunden"
    return 0
}

# Listet GENAU EINE Ebene unterhalb von <basis>/<rel>.
#
# CONTROLLER-RULING: der rsync-Exit-Code darf nicht verworfen werden. Ein
# nicht lesbares Verzeichnis (rc 23, Permission denied) und ein wirklich
# leeres Verzeichnis (rc 0, Ausgabe nur der "."-Eintrag) erzeugen beide null
# geparste Zeilen - ueber die Zeilenzahl allein sind sie nicht zu
# unterscheiden. w2u_decompose (Task 4) wuerde "null Eintraege" sonst immer
# als leeres Verzeichnis behandeln und den kompletten Unterbaum stillschweigend
# aus der Arbeitsliste fallen lassen. Deshalb: rsync-Aufruf getrennt vom
# Parsen ausfuehren (Ausgabe erst in eine Variable), rc separat pruefen -
# "cmd | parser" wuerde ohnehin nur den rc des Parsers liefern, weil pipefail
# in gesourcten Test-Shells nicht aktiv ist.
#
# Fix (Review): "_Raw=$(...)" ist ein einfaches Kommando - unter set -e
# (aktiv in main()) feuert errexit GENAU an dieser Zuweisung, wenn rsync
# ungleich 0 endet, also bevor "_Rc=$?" gelesen und bevor w2u_die erreicht
# wird. Da stderr in _Raw umgeleitet ist statt aufs Terminal, geht die
# Diagnose mit der verworfenen Variable verloren, und der Aufrufer sieht nur
# ein nacktes rsync-rc ohne Meldung - besonders in Nicht-Substitutions-Form
# (Umleitung in eine Datei, Pipe), wie w2u_decompose (Task 4) sie
# voraussichtlich nutzt. "|| _Rc=$?" ist die dokumentierte errexit-Ausnahme
# und haelt den Aufruf am Leben, bis die rc-Pruefung unten laeuft.
w2u_remote_list() {
    local _Base="$1" _Rel="$2" _Url _Raw _Rc=0
    _Base="${_Base%/}"
    if [ -n "$_Rel" ]; then
        _Url="$_Base/$_Rel/"
    else
        _Url="$_Base/"
    fi
    _Raw="$("$_RsyncBin" --list-only -d "$_Url" 2>&1)" || _Rc=$?
    if [ "$_Rc" -ne 0 ]; then
        w2u_die "rsync-Listing fehlgeschlagen fuer $_Url (rc $_Rc): $_Raw"
    fi
    printf '%s\n' "$_Raw" | w2u_parse_listing
}

# Zerlegt den Quellbaum in Arbeitspakete (Spec 5.3).
#
# Aufruf: w2u_decompose <basis-url> <schwelle> <ausgabedatei>
# Ergebnis: je Arbeitspaket eine Zeile (relativer Pfad, kein fuehrender Slash).
#
# Invariante: arbeit + queue ueberdecken zu jedem Zeitpunkt exakt den Baum.
# Wird ein Ordner expandiert, ersetzt ihn die VOLLSTAENDIGE Liste seiner Kinder -
# Dateien UND Ordner. Ein LEERER Ordner hat keine Kinder und muss deshalb selbst
# Arbeitspaket bleiben, sonst verschwindet er (im Test nachgewiesen).
#
# Ein expandierter Ordner ist selbst KEIN Arbeitspaket mehr - rsync legt ihn beim
# Uebertragen seiner Kinder implizit mit korrekter mtime an (Spec 2.6).
#
# CONTROLLER-RULING 2: das Listing wird ueber eine TEMP-DATEI gelesen, nicht ueber
# eine Prozess-Substitution. In "done < <(w2u_remote_list ...)" liefe
# w2u_remote_list in einem Kindprozess - dessen w2u_die beendete nur das Kind, die
# Schleife hier laese null Zeilen, hielte das Verzeichnis fuer LEER, machte daraus
# ein Arbeitspaket und liesse den gesamten Unterbaum still aus der Arbeitsliste
# fallen. Genau der Fehler, gegen den Task 3 gehaertet wurde. Eine Umleitung
# erzeugt keine Subshell, das exit aus w2u_die beendet damit den ganzen Lauf.
w2u_decompose() {
    local _Base="$1" _Threshold="$2" _OutFile="$3"
    [ -n "$_TmpDir" ] || w2u_die "w2u_decompose ohne gesetztes _TmpDir aufgerufen"
    # Bei Schwelle < 2 braeche die Schleife vor der ersten Expansion ab. Die Wurzel
    # selbst ist als leere Zeile kein darstellbares Arbeitspaket und wuerde
    # weggefiltert - das Ergebnis waere eine LEERE Arbeitsliste, also Totalverlust.
    # Aus der Konfiguration (_ThresholdFactor * _PMax) nicht erreichbar, aber ein
    # stiller Totalverlust darf hier unter keinen Umstaenden moeglich sein.
    [ "$_Threshold" -ge 2 ] || w2u_die "Schwelle $_Threshold zu klein - die Wurzel wuerde nie expandiert"

    local _Cur="$_TmpDir/lvl.cur" _Next="$_TmpDir/lvl.next" _ListFile="$_TmpDir/lvl.listing"
    local _Tab
    _Tab="$(printf '\t')"
    : > "$_OutFile"
    printf '\n' > "$_Cur"          # eine leere Zeile = die Wurzel selbst
    local _CurCnt=1

    while : ; do
        local _WorkCnt
        _WorkCnt="$(grep -c . "$_OutFile" 2>/dev/null || true)"
        [ -n "$_WorkCnt" ] || _WorkCnt=0
        if [ $((_WorkCnt + _CurCnt)) -ge "$_Threshold" ]; then
            break
        fi

        : > "$_Next"
        local _AnyDir=0 _Rel _Type _Name _Path _EntryCnt
        while IFS= read -r _Rel; do
            # "< /dev/null": stdin dieser Schleife ist $_Cur. Ohne die Umleitung
            # erbte rsync diesen Deskriptor und koennte Verzeichniszeilen
            # wegfressen - dieselbe Klasse Fehler, vor der der Skriptkopf warnt.
            w2u_remote_list "$_Base" "$_Rel" > "$_ListFile" < /dev/null
            _EntryCnt=0
            while IFS="$_Tab" read -r _Type _Name; do
                [ -n "$_Name" ] || continue
                _EntryCnt=$((_EntryCnt + 1))
                if [ -n "$_Rel" ]; then
                    _Path="$_Rel/$_Name"
                else
                    _Path="$_Name"
                fi
                if [ "$_Type" = "d" ]; then
                    printf '%s\n' "$_Path" >> "$_Next"
                    _AnyDir=1
                else
                    printf '%s\n' "$_Path" >> "$_OutFile"
                fi
            done < "$_ListFile"

            # Leerer Ordner: haette keine Kinder, muss selbst Arbeitspaket bleiben.
            if [ "$_EntryCnt" -eq 0 ] && [ -n "$_Rel" ]; then
                printf '%s\n' "$_Rel" >> "$_OutFile"
            fi
        done < "$_Cur"

        # Keine Unterordner mehr auf dieser Ebene: alle Eintraege aus $_Cur sind
        # oben vollstaendig expandiert worden. Die Trunkierung ist PFLICHT, nicht
        # Aufraeumen - ohne sie stuenden die gerade expandierten Verzeichnisse
        # beim Schluss-Flush ZUSAETZLICH zu ihren eigenen Dateien in der
        # Arbeitsliste, und jede dieser Dateien wuerde doppelt uebertragen.
        # Gepinnt durch Fall E samt exaktem Count-Assert (der Mengenvergleich
        # allein wuerde die Ueberdeckung wegnormalisieren).
        if [ "$_AnyDir" -eq 0 ]; then
            : > "$_Cur"
            break
        fi

        local _NextCnt
        _NextCnt="$(grep -c . "$_Next" || true)"
        mv "$_Next" "$_Cur"
        _CurCnt="$_NextCnt"
        if [ "$_NextCnt" -gt "$_MaxItems" ]; then
            # Achtung fuer spaetere Tasks: _MaxItems bremst nur die WEITERE
            # Expansion, es begrenzt NICHT das Ergebnis. Diese Ebene wandert
            # gleich vollstaendig in die Arbeitsliste - die Vollstaendigkeit
            # verlangt es. Die Arbeitsliste kann also mehr als _MaxItems
            # Eintraege haben; wer damit rechnet, rechnet falsch.
            w2u_warn "Ebene mit $_NextCnt Eintraegen ueberschreitet _MaxItems=$_MaxItems - keine weitere Expansion, diese Ebene wird aber VOLLSTAENDIG als Arbeitspakete uebernommen"
            break
        fi
    done

    # Restliche, nicht expandierte Ordner sind Arbeitspakete. Das ist die Zeile,
    # die den gesamten Rest des Baums in die Arbeitsliste bringt - ein
    # verschluckter Fehler hier ergaebe eine Arbeitsliste ohne jedes verbliebene
    # Verzeichnis, und zwar mit rc 0.
    #
    # Deshalb wird grep-rc 1 ("keine Treffer", hier legitim: $_Cur kann leer sein
    # oder nur den Wurzel-Marker enthalten) NICHT mit rc >1 ("Fehler")
    # verschmolzen, und stderr wird nicht nach /dev/null geworfen. Genau diese
    # Verschmelzung ist der Fehler, gegen den Task 3 gehaertet wurde.
    # w2u_die statt nur errexit, weil errexit in gesourcten Test-Shells nicht
    # aktiv ist - ohne den expliziten Abbruch fiele der Fehler dort durch.
    #
    # Reichweite, an /usr/bin/grep (BSD) nachgemessen: fehlende Datei, unlesbare
    # Datei und Verzeichnis liefern rc 2 und werden gefangen; "kein Treffer"
    # liefert rc 1 und wird durchgelassen. NICHT unterscheidbar ist ein
    # Fehlschlag der Umleitung selbst - die Shell meldet dafuer ebenfalls rc 1.
    # Diesen Fall deckt "> $_OutFile" ganz oben ab: schlaegt es fehl, endet der
    # Lauf unter dem set -e aus main() bereits dort, lange vor dieser Zeile.
    grep -v '^$' "$_Cur" >> "$_OutFile" || [ $? -eq 1 ] || w2u_die "Schluss-Flush der Restqueue fehlgeschlagen - Arbeitsliste waere unvollstaendig"

    # Kein nachtraeglicher "Clean"-Schritt: leere Zeilen koennen in $_OutFile gar
    # nicht entstehen (jedes printf steht hinter -n-Pruefung auf _Name bzw. _Rel,
    # und der Flush oben filtert '^$' bereits weg), Duplikate ebenso wenig (ein
    # expandiertes Verzeichnis wird per mv/Trunkierung aus $_Cur entfernt).
    # Ein No-Op, der das fertige Ergebnis per mv ueberschreibt und dabei hinter
    # "|| true" Fehler verschluckt, waere reines Risiko ohne Funktionsgewinn.
}

# Buendelt Arbeitspakete zu Chunks (Spec 5.5).
# Eine feste Chunkgroesse waere falsch: 308 Pakete ergaeben nur 4 Chunks fuer
# 8 Worker. Ziel ist deutlich mehr Chunks als Worker, damit xargs etwas zu
# verteilen hat.
#
# split-Suffixlaenge und rc-Pruefung (Review nach Task 5): BSD split vergibt
# ohne "-a" nur 2 Buchstaben Suffix (aa..zz, 676 Dateien) und bricht danach mit
# "too many files" (rc 65) ab - laesst die bereits geschriebenen 676 Chunks
# aber stehen. Ohne rc-Pruefung wuerde "ls" diesen unvollstaendigen Chunk-Satz
# trotzdem einsammeln und der Rest der Arbeitsliste ginge STILL verloren -
# nachgemessen: 700 Arbeitspakete bei Chunkgroesse 1 ergaben nur 676 Dateien,
# 24 Pakete fehlten, rc 65 kam zurueck und wurde nur bisher nicht geprueft. Im
# Zielprojekt ist stiller Datenverlust der einzige nicht behebbare Fehler, weil
# die Windows-Quelle nach dem Transfer verschrottet wird. "-a 4" hebt die
# Grenze auf 456.976 Dateien an, ersetzt aber NICHT die rc-Pruefung: split kann
# auch aus anderen Gruenden scheitern (z.B. voller Zieldatentraeger), und jeder
# unbemerkte Fehlschlag hier bedeutet fehlende Dateien am Ziel. Der rc wird
# direkt an "split" gehaengt (kein Pipe, keine Command-Substitution dazwischen),
# damit er nicht verlorengeht.
w2u_chunk() {
    local _WorkFile="$1" _ChunkDir="$2" _PMaxLocal="$3" _ListOut="$4"
    local _Total _Divisor _Size _Rc
    _Total="$(grep -c . "$_WorkFile")" || [ $? -eq 1 ] || w2u_die "Arbeitsdatei $_WorkFile nicht lesbar"
    [ "$_Total" -gt 0 ] || w2u_die "keine Arbeitspakete - ist der Quellpfad richtig?"
    _Divisor=$((_ThresholdFactor * _PMaxLocal))
    _Size=$(( (_Total + _Divisor - 1) / _Divisor ))
    [ "$_Size" -gt "$_ChunkMax" ] && _Size="$_ChunkMax"
    rm -f "$_ChunkDir"/chunk.*
    _Rc=0
    split -a 4 -l "$_Size" "$_WorkFile" "$_ChunkDir/chunk." || _Rc=$?
    [ "$_Rc" -eq 0 ] || w2u_die "split fehlgeschlagen (rc $_Rc) - Chunks waeren unvollstaendig"
    ls "$_ChunkDir"/chunk.* > "$_ListOut"
    # Registrierung an der ENTSTEHUNGSSTELLE, nicht beim Aufrufer: der
    # Abschlussbericht (Task 8) gleicht die Ergebniszeilen gegen genau diese
    # Liste ab, und ein Aufrufer, der die Zuweisung vergisst, haette einen
    # Bericht ohne Vergleichsmassstab. ANNAHME: es gibt hoechstens eine gueltige
    # Chunkliste je Lauf (ein spaeterer w2u_chunk-Aufruf ueberschreibt die
    # Registrierung, so wie er die Chunks selbst neu erzeugt). WAS SIE BRICHT:
    # zwei parallele Zerlegungen in einem Prozess - gaebe es die, muesste der
    # Bericht mehrere Listen kennen. Wird diese Zeile entfernt, meldet
    # w2u_report FAIL ("Ergebniszeilen ohne bekannte Chunkliste"), nie PASS.
    _ChunkListFile="$_ListOut"
    w2u_log "$_Total Arbeitspakete, $_Size je Chunk, $(grep -c . "$_ListOut") Chunks"
}

# Uebertraegt einen Chunk (Spec 5.5), mit Retry bis Exit 0 oder _MaxRetry.
#  -W  : Erstkopie, jede Datei ist neu - Delta-Algorithmus kostet nur CPU
#  -l  : Symlinks als Symlinks. NIEMALS -L, das folgt NTFS-Junctions in Schleifen
#  kein -a: -a zieht -pog mit, und Cygwin-Rechte sind synthetisch
#  kein -z: im LAN ist die CPU das Limit, nicht die Leitung
#
# CONTROLLER-RULING 1: kein "set +e" / "set -e" um den rsync-Aufruf. Ein
# abschliessendes "set -e" schaltete errexit auch in einer Shell ein, die
# pull.sh nur gesourct hat (W2U_LIB_ONLY=1) - unabhaengig vom vorherigen
# Zustand. Genau diese Leck-Klasse wurde in Task 1 gefunden und ist der
# Grund, warum "set -euo pipefail" heute die erste Anweisung in main() ist,
# nicht im Dateikopf. Eine Funktion darf die Shell-Optionen ihres Aufrufers
# nicht veraendern. Stattdessen dasselbe Muster wie in w2u_remote_list
# (Task 3): "cmd || _Rc=$?" haelt den Aufruf unter set -e am Leben, ohne
# irgendeine Shell-Option anzufassen. _Rc wird VOR jedem Versuch neu auf 0
# gesetzt - sonst ueberlebte der rc eines fehlgeschlagenen Versuchs in die
# Log-Zeile eines spaeter doch noch erfolgreichen Versuchs, weil
# "cmd || _Rc=$?" bei Erfolg _Rc unangetastet laesst.
#
# CONTROLLER-RULING 2: ein rsync-Aufruf, nicht zwei fast identische in
# if/else - genau die Art verbatim duplizierter Logik, die stillschweigend
# auseinanderlaeuft, sobald spaeter nur ein Zweig eine Option dazubekommt.
# Die Argumentliste wird einmal als Array aufgebaut (bash 3.2 kann Arrays)
# und einmal aufgerufen. Das Array ist hier nie leer (mindestens die festen
# Basis-Optionen stehen immer drin), die "${_Args[@]}"-bei-leerem-Array-Falle
# unter set -u betrifft diese Funktion also nicht.
#
# Gibt IMMER 0 zurueck: ein einzelner fehlgeschlagener Chunk darf einen Lauf
# von mehreren hundert GB nicht abbrechen. Der Fehler ist ausschliesslich ueber
# die Ergebniszeile in $_ResultFile sichtbar (Name<TAB>rc<TAB>Versuche) - das
# macht diese Zeile zum einzigen Sicherheitsnetz. rc 23/24 ("manche Dateien
# konnten nicht uebertragen werden") sind auf der Windows-Seite die Signatur
# gesperrter/unlesbarer Dateien und werden hier unveraendert durchgereicht,
# nie verschluckt.
#
# Review-Haertung (Task 6, nach erster Abnahme):
#
# 1) "printf ... >> $_ResultFile" ist unter set -e (main()'s Konfiguration) ein
#    einfaches Kommando: schlaegt der Redirect fehl (Ergebnisverzeichnis nicht
#    beschreibbar o.ae.), reisst errexit die Shell ab, BEVOR "return 0" erreicht
#    wird - genau die Klasse Leck, gegen die Ruling 1 haertet, nur diesmal am
#    Funktionsende statt am rsync-Aufruf. "|| w2u_log ..." haelt den Schreibfehler
#    selbst am Leben (dieselbe Ausnahme-Idiom wie ueberall sonst) UND macht ihn
#    sichtbar, statt eine verlorene Ergebniszeile spurlos verschwinden zu lassen.
#
# 2) _Rc startet nicht mehr bei 0, sondern bei einem Sentinel (255), der NUR ein
#    tatsaechlich gelaufener rsync-Versuch ueberschreiben kann. Bei "_MaxRetry=0"
#    oder einer while-Bedingung, die aus irgendeinem Grund nie eintritt, macht
#    keine Zeile "Chunk 0 Versuche" mehr wie ein Erfolg aussehen. _MaxRetry und
#    _RetryPause werden zusaetzlich vorab auf nichtnegative Ganzzahlen geprueft:
#    ein nicht-numerisches _RetryPause wuerde sonst "$((_RetryPause * _Try))" zu
#    einem Arithmetikfehler machen, der den GESAMTEN Lauf abbricht statt nur
#    diesen einen Chunk als Fehler zu protokollieren - lieber hier laut und
#    kontrolliert per w2u_die scheitern (ein Konfigurationsfehler, kein
#    Transferfehler) als spaeter unkontrolliert crashen oder falsch gruen sein.
#
# 3) --timeout steht jetzt immer im argv (openrsync-erlaubt) - ohne Timeout
#    wird aus einem haengenden Daemon ein Haenger statt eines Retries, und genau
#    das hebt den Sinn der ganzen Schleife auf.
#
# 4) Jeder Versuch bekommt sein EIGENES Logfile ($_Name.$_Try.log) statt eines
#    gemeinsamen, das jeder neue Versuch ueberschreibt. rc 23/24 listen genau die
#    gesperrten/unlesbaren Dateinamen, die diese Aufgabe ueberhaupt erst
#    interessant machen - verliert Versuch 2 das Log von Versuch 1, ist diese
#    Diagnose weg, und es gibt kein zweites Hinsehen: die Windows-Quelle wird
#    nach dem Transfer verschrottet.
#
# 5) Ein Chunkname mit TAB oder Zeilenumbruch wuerde die einzige Stelle
#    zerstoeren, an der ein Fehlschlag je sichtbar wird ($_ResultFile). Aktuell
#    von "split" (chunk.aaaa) strukturell nicht erzeugbar, aber der Guard ist
#    billig gekauft gegen jeden kuenftigen Aufrufer, der das nicht mehr
#    garantiert.
w2u_run_chunk() {
    local _ChunkFile="$1"
    local _Name _Try=1 _Rc=255
    _Name="$(basename "$_ChunkFile")"

    # ACHTUNG: "$(printf '\n')" waere hier eine Falle - Kommandosubstitution
    # entfernt ALLE abschliessenden Newlines, das Ergebnis ist eine leere
    # Zeichenkette und das Pattern wuerde zu "**" (passt auf ALLES). Deshalb
    # ein echter eingebetteter Zeilenumbruch statt printf-Substitution.
    local _Tab _Nl
    _Tab="$(printf '\t')"
    _Nl="
"
    case "$_Name" in
        *"$_Tab"*|*"$_Nl"*)
            w2u_die "Chunkname enthaelt TAB oder Zeilenumbruch, wuerde \$_ResultFile zerstoeren: '$_Name'"
            ;;
    esac
    case "$_MaxRetry" in
        ''|*[!0-9]*) w2u_die "_MaxRetry ist keine nichtnegative Ganzzahl: '$_MaxRetry'" ;;
    esac
    case "$_RetryPause" in
        ''|*[!0-9]*) w2u_die "_RetryPause ist keine nichtnegative Ganzzahl: '$_RetryPause'" ;;
    esac
    # Quelle und Ziel der PARALLELEN Phase, nicht _SrcUrl/_DstRoot. Warum, steht
    # im Kopf bei _SrcRoot: mit einer Unterpfad-URL findet der Daemon die
    # Eintraege aus --files-from nicht und uebertraegt NICHTS - unter openrsync
    # sogar mit rc 0. Ein Worker ohne diese beiden Werte darf deshalb gar nicht
    # erst rsync aufrufen: er wuerde eine Ergebniszeile schreiben, die wie
    # Erfolg aussieht. Leer heisst hier "der Aufrufer hat die parallele Phase
    # nicht vorbereitet" - ein Programmierfehler, kein Transferfehler.
    [ -n "$_ParSrc" ] || w2u_die "w2u_run_chunk ohne _ParSrc aufgerufen (Modulwurzel fehlt)"
    [ -n "$_ParDst" ] || w2u_die "w2u_run_chunk ohne _ParDst aufgerufen (Ziel der parallelen Phase fehlt)"

    local _Args
    _Args=( -rlt -W --partial --numeric-ids --stats "--timeout=$_RsyncTimeout" )
    [ -n "$_ExcludeFrom" ] && _Args=( "${_Args[@]}" "--exclude-from=$_ExcludeFrom" )
    _Args=( "${_Args[@]}" "--files-from=$_ChunkFile" )

    while [ "$_Try" -le "$_MaxRetry" ]; do
        _Rc=0
        "$_RsyncBin" "${_Args[@]}" "${_ParSrc%/}/" "${_ParDst%/}/" > "$_LogDir/$_Name.$_Try.log" 2>&1 || _Rc=$?
        [ "$_Rc" -eq 0 ] && break
        [ "$_Try" -lt "$_MaxRetry" ] && sleep $((_RetryPause * _Try))
        _Try=$((_Try + 1))
    done
    [ "$_Try" -gt "$_MaxRetry" ] && _Try="$_MaxRetry"

    # CONTROLLER-RULING 2 (Task 7): dieses ">>" laeuft ab Task 7 aus bis zu
    # _PMax parallelen Prozessen gleichzeitig und ist die EINZIGE Stelle, an der
    # ein fehlgeschlagener Chunk sichtbar wird. Nachgemessen, nicht angenommen
    # (Zahlen im Task-7-Report): der parallele Append haelt.
    #
    # ANNAHME: Zeilenlaenge deutlich unter 1 KB (real 19-23 Byte, gemessene
    # Grenze 1024) und $_ResultFile auf einem LOKALEN Dateisystem.
    # WAS SIE BRICHT: ein aufgeblaehtes Zeilenformat, oder $_ResultFile auf
    # einer SMB-/NFS-Freigabe - moeglich, weil _LogDir per Vorgabe unter dem
    # Zielverzeichnis entsteht und das Ziel ein Mount sein kann. Dann gehoert je
    # Chunk eine eigene Ergebnisdatei her.
    # Oberhalb der Grenze bleiben Zeilen- UND Byteanzahl korrekt, nur der Inhalt
    # ist vermischt - eine Pruefung, die zaehlt, ist dafuer blind. Der Test
    # prueft deshalb das Format jeder Zeile.
    printf '%s\t%s\t%s\n' "$_Name" "$_Rc" "$_Try" >> "$_ResultFile" \
        || w2u_log "WARNUNG: Ergebniszeile fuer $_Name konnte nicht geschrieben werden (rc/Versuche: $_Rc/$_Try)"
    return 0
}

# Arbeitet eine Chunkliste mit <jobs> parallelen Prozessen ab (Spec 5.5).
# Messwerte zu allen unten genannten xargs-Eigenschaften: Task-7-Report.
#
# CONTROLLER-RULING 1: "xargs -a DATEI" gibt es auf BSD nicht. stdin wird
# deshalb EXPLIZIT aus der Liste umgeleitet - das ist auch der eigentliche Punkt
# der Constraint: xargs darf nie das GEERBTE stdin lesen, beim Bootstrap ueber
# "bash -c "$(curl ...)"" ist das der Skript-Stream selbst.
#
# CONTROLLER-RULING 3 - hier entsteht die Prozessgrenze, auf die sich das
# Fail-Fast in w2u_run_chunk stuetzt. Sie haelt, solange drei Dinge stimmen:
#   a) je Chunk EIN eigener Prozess ("-I {}" = ein Argument je Aufruf), ein
#      w2u_die im Worker ist damit "exit 1" nur DIESES Prozesses;
#   b) xargs macht nach einem Kind mit rc 1 weiter. NICHT so bei rc 255 und bei
#      Signal-Tod - da hoert xargs auf, die Liste weiterzulesen. w2u_run_chunk
#      fuehrt intern den Sentinel 255, gibt aber IMMER 0 zurueck; wer daraus je
#      "return $_Rc" macht, bricht damit den ganzen Lauf ab;
#   c) der rc von xargs wird abgefangen. Ohne "|| _Rc=$?" risse errexit aus
#      main() den GESAMTEN Transfer ab, sobald ein Worker stirbt - genau das,
#      was die Grenze verhindern soll, nur eine Ebene hoeher.
#
# Exportiert wird, was der Rumpf von w2u_run_chunk braucht - abgeleitet, nicht
# geschaetzt. Eine fehlende Funktion ist im Kind "command not found" (rc 127)
# und KEIN exit: die Ausfuehrung liefe hinter dem Guard weiter und der kaputte
# Chunk bekaeme eine Ergebniszeile, die wie erledigt aussieht.
#
# "-S 4096": BSD-xargs begrenzt die "-I"-Ersetzung per Vorgabe auf 255 Byte und
# bricht darueber die GANZE restliche Liste ab. Erreichbar ueber den Pfad des
# Arbeitsverzeichnisses (der Chunkname ist kurz), und wo $_TmpDir liegt,
# entscheidet main(). 4096 ist das Vierfache von PATH_MAX - ein einzelner
# absoluter Pfad kann die Grenze damit strukturell nicht mehr reissen.
#
# Diese Option gibt es aber NUR bei BSD/macOS. GNU-findutils-xargs kennt kein
# "-S" ueberhaupt und bricht schon am Optionen-Parsen ab ("xargs: invalid
# option -- 'S'"), also BEVOR ein einziger Worker startet - auf jedem
# GNU/Linux-Ziel, das das README zusagt, waere kein Chunk uebertragen worden.
# GNU hat die 255-Byte-Grenze der "-I"-Ersetzung nicht, braucht die Option also
# auch nicht. Deshalb wird sie GEMESSEN statt angenommen: ein Probelauf mit
# genau dieser Option entscheidet, ob sie ins argv kommt.
#
# Das Ergebnis wird NICHT zwischengespeichert. Ein Cache waere genau dann
# falsch, wenn er zaehlt (ein anderes xargs im PATH als beim ersten Aufruf),
# und die Kosten sind ein einzelner fork je PHASE - gegen einen Transfer von
# hunderten GB ist das nicht messbar. Getragen wird die Option in einem ARRAY,
# nicht in einer Variablen: eine leere Variable waere unter "set -u" ein leeres
# ARGUMENT ("xargs -P 4 '' -I {}") und damit ein Fehler statt einer
# Auslassung. Die "+"-Form der Expansion ist Pflicht - "${_Arr[@]}" auf einem
# leeren Array ist unter bash 3.2 mit set -u "unbound variable".
#
# "-I {}" bleibt in jedem Fall stehen: "-n 1" waere die naheliegende
# Alternative, zerlegt aber an Leerzeichen - und $TMPDIR (also der Pfad jedes
# Chunks) darf Leerzeichen enthalten.
#
# "${BASH:-bash}": das Umgebungsformat von "export -f" unterscheidet sich
# zwischen bash 3.2 (Apple) und 4.3+ (Homebrew). Startete ein Skript unter
# Homebrew-bash seine Worker mit /bin/bash, importierte das Kind die Funktionen
# nicht und kein einziger Chunk wuerde uebertragen. $BASH ist derselbe
# Interpreter wie der laufende und laesst die Frage nicht aufkommen.
w2u_run_list() {
    local _ListFile="$1" _Jobs="$2" _Rc=0 _Missing="" _MissCnt=0 _Done=""
    local _XargsRepl
    # "-P 0" heisst bei BSD-xargs UNBEGRENZT viele Prozesse - auf einer Quelle
    # mit drehender Platte das Gegenteil dessen, was die Messung erreichen soll.
    case "$_Jobs" in
        ''|*[!0-9]*) w2u_die "Parallelitaet ist keine Ganzzahl: '$_Jobs'" ;;
    esac
    [ "$_Jobs" -ge 1 ] || w2u_die "Parallelitaet muss mindestens 1 sein (bekam $_Jobs; '-P 0' waere bei BSD-xargs unbegrenzt)"
    # "existiert nicht" und "ist leer" duerfen hier NICHT zusammenfallen. Leer
    # ist legitim (chunks.rest nach einer Messung, die alles verbraucht hat) und
    # bleibt still. Fehlend oder unlesbar ist ein Defekt - ein stiller rc 0
    # machte einen Lauf, der NICHTS uebertragen hat, von einem vollstaendigen
    # ununterscheidbar, und danach wird die Quelle verschrottet. Dieselbe
    # Verschmelzung wie in w2u_remote_list (Task 3) und beim head weiter unten.
    [ -e "$_ListFile" ] || w2u_die "Chunkliste $_ListFile existiert nicht - ein stiller rc 0 saehe hier aus wie 'nichts mehr zu tun'"
    [ -r "$_ListFile" ] || w2u_die "Chunkliste $_ListFile ist nicht lesbar"
    [ -s "$_ListFile" ] || return 0

    # _ParSrc/_ParDst statt _SrcUrl/_DstRoot: der Worker uebertraegt von der
    # MODULWURZEL aus (siehe w2u_run_chunk). Fehlten sie in dieser Liste, waeren
    # sie im Kind leer - dort gilt kein "set -u" - und der Guard in
    # w2u_run_chunk laesse jeden Chunk ohne Ergebniszeile scheitern.
    export _RsyncBin _ParSrc _ParDst _LogDir _ResultFile _MaxRetry _RetryPause _ExcludeFrom _RsyncTimeout
    export -f w2u_run_chunk w2u_die w2u_log
    # Einmal je Phase nachsehen, ob dieses xargs "-S" kennt (siehe oben).
    # "true" statt eines echten Kommandos: der Probelauf darf nichts tun, nur
    # das Optionen-Parsen ausloesen. Ein fehlendes xargs (rc 127) landet
    # ebenfalls im GNU-Zweig - der echte Aufruf unten scheitert dann ohnehin,
    # und zwar sichtbar.
    _XargsRepl=( )
    if printf 'x\n' | xargs -S 4096 -I {} true >/dev/null 2>&1; then
        _XargsRepl=( -S 4096 )      # BSD: hebt die 255-Byte-Grenze der -I-Ersetzung
    fi                              # GNU: kennt -S nicht und hat die Grenze nicht
    xargs -P "$_Jobs" ${_XargsRepl[@]+"${_XargsRepl[@]}"} -I {} "${BASH:-bash}" -c 'w2u_run_chunk "$1"' _ {} < "$_ListFile" || _Rc=$?
    if [ "$_Rc" -ne 0 ]; then
        w2u_warn "xargs endete mit rc $_Rc - w2u_run_chunk selbst liefert immer 0, also ist mindestens ein Worker vorzeitig gestorben. Bei Signal-Tod (z.B. OOM) und bei Exit 255 liest xargs die Liste danach NICHT weiter."
        # Der Abgleich gehoert hierher und nirgendwo sonst: dies ist die einzige
        # Stelle, die beides in der Hand hat - die Eingabeliste und
        # $_ResultFile. Ohne ihn endete ein Lauf, dessen Chunkliste ab Minute
        # drei nie mehr angefasst wurde, mit rc 0 und ohne jede Spur, WELCHE
        # Chunks das waren. Ein Abschlussbericht spaeter hat den Bezug zu dieser
        # konkreten Liste nicht mehr.
        # "$_Done" statt "$_ResultFile" direkt, und Unterscheidung ueber
        # FILENAME statt ueber das uebliche "NR == FNR": beide Abkuerzungen
        # brechen genau dann, wenn die Ergebnisdatei LEER ist - und leer ist sie
        # in genau dem Fall, der hier am meisten zaehlt (xargs scheitert schon
        # am ersten Chunk). "NR == FNR" haelte dann jede Zeile der Chunkliste
        # fuer eine Ergebniszeile und meldete nichts als fehlend.
        _Done="$_ResultFile"
        [ -f "$_Done" ] || _Done="/dev/null"
        _Missing="$(awk -F'\t' -v _DoneFile="$_Done" '
            FILENAME == _DoneFile { _Seen[$1] = 1; next }
            { _N = $0; sub(/^.*\//, "", _N); if (_N != "" && !(_N in _Seen)) print _N }
        ' "$_Done" "$_ListFile")" || _Missing=""
        if [ -n "$_Missing" ]; then
            _MissCnt="$(printf '%s\n' "$_Missing" | grep -c .)" || [ "$?" -eq 1 ] || _MissCnt=0
        fi
        if [ "$_MissCnt" -gt 0 ]; then
            w2u_warn "$_MissCnt Chunk(s) aus $_ListFile haben KEINE Ergebniszeile, wurden also nicht (vollstaendig) uebertragen: $(printf '%s\n' "$_Missing" | head -n 20 | tr '\n' ' ')"
            [ "$_MissCnt" -gt 20 ] && w2u_warn "... und $((_MissCnt - 20)) weitere; die vollstaendige Liste ergibt sich aus $_ListFile abzueglich Spalte 1 von $_ResultFile"
        fi
    fi
    return 0
}

# Belegte KB am Ziel, oder eine LEERE Ausgabe, wenn sich das nicht ermitteln
# laesst. Bewusst kein "0" im Fehlerfall: 0 waere eine Zahl, mit der weiter
# gerechnet wuerde, und aus einem kaputten du wuerde ein Messwert.
# Gibt immer 0 zurueck - unter "set -euo pipefail" wuerde sonst ein
# fehlgeschlagenes du den Lauf abreissen.
w2u_dst_kb() {
    local _Kb
    _Kb="$(du -sk "$_DstRoot" 2>/dev/null | awk 'NR == 1 { print $1 }')" || _Kb=""
    case "$_Kb" in
        ''|*[!0-9]*) _Kb="" ;;
    esac
    printf '%s\n' "$_Kb"
    return 0
}

# Anzahl bereits geschriebener Ergebniszeilen. Marke, um nach einer Probe-Runde
# GENAU deren Zeilen zu betrachten. Eine noch nicht existierende Ergebnisdatei
# ist VOR der ersten Runde legitim (0 Zeilen); danach ist sie es nicht mehr -
# das prueft der Aufrufer, nicht diese Funktion.
w2u_result_lines() {
    local _Cnt=0
    [ -n "$_ResultFile" ] || w2u_die "w2u_result_lines ohne gesetztes _ResultFile - ohne Ergebnisdatei gibt es kein Sicherheitsnetz"
    if [ -f "$_ResultFile" ]; then
        _Cnt="$(grep -c . "$_ResultFile")" || [ "$?" -eq 1 ] || w2u_die "Ergebnisdatei $_ResultFile nicht lesbar - Wiederholungen in einer Probe-Runde waeren nicht erkennbar"
    fi
    printf '%s\n' "$_Cnt"
    return 0
}

# Misst den Durchsatz bei steigender Parallelitaet (Spec 5.4) und gibt die
# gewaehlte Stufe auf stdout aus. Die Probe-Arbeit ist ECHTE Arbeit: was eine
# Runde uebertraegt, verschwindet aus der Restliste ($_TmpDir/chunks.rest) und
# wird nie ein zweites Mal uebertragen. Probe-Runden und Restliste ueberdecken
# die Ausgangsliste zu jedem Zeitpunkt exakt (im Test als sortierter
# Mengenvergleich gepinnt, nicht als Zeilenzahl - eine Summe kann Verlust und
# Duplikat nicht auseinanderhalten).
#
# Gemessen wird ueber "du -sk" am Ziel, NICHT ueber "--stats": openrsync
# schreibt "Total received: 636 B", GNU rsync "Total bytes received: 636" - zwei
# Formate, ein Messfehler mehr als noetig.
#
# WAS DIESE MESSUNG NICHT KANN - die Grenzen sind der Grund fuer die
# Brauchbarkeitsschranken weiter unten:
#
# 1) Jede Runde faehrt ANDERE Chunks (Probe-Arbeit muss echte Arbeit sein, also
#    ist ein kontrolliertes Experiment ausgeschlossen). Eine Stufe kann aus
#    Gruenden schneller aussehen, die mit Parallelitaet nichts zu tun haben.
#    Einziges Gegenmittel ist die Hoehe der Schwelle: 15 Prozent verlangen ein
#    deutliches Signal, kein knappes.
# 2) Die Wanduhr hat Sekundenaufloesung - siehe _ProbeMinSecs.
# 3) Eine Runde mit einer WIEDERHOLUNG enthaelt die Retry-Pause aus
#    w2u_run_chunk (produktiv bis _RetryPause * _MaxRetry Sekunden reiner
#    Schlaf) und misst dann eine gesperrte Windows-Datei statt Parallelitaet.
#    Erkannt an der Versuchszahl, NICHT am Exit-Code: rc 23/24 ist die
#    erwartete Signatur gesperrter Dateien (Spec 5.5), ein Filter darauf wuerde
#    fast jede Runde verwerfen.
#
# Regel in allen Faellen: eine Runde ohne belastbare Aussage wird als "nicht
# verwertbar" mit Grund protokolliert und liefert KEINEN Messwert - die Arbeit
# bleibt erledigt. Ohne verwertbare Runde kommt der Vorgabewert zurueck, im Log
# ausdruecklich als Vorgabe benannt. Eine falsche Zahl mit Messwert-Anmutung
# waere schlimmer als ein zugegebener Default.
w2u_autotune() {
    local _ListFile="$1"
    [ -n "$_TmpDir" ] || w2u_die "w2u_autotune ohne gesetztes _TmpDir aufgerufen"
    local _Rest="$_TmpDir/chunks.rest"
    local _Rc=0
    # _ProbeMinSecs ist nicht nur ein Schwellwert, sondern auch die Zusicherung,
    # dass unten NIE durch 0 geteilt wird: eine Runde wird erst verwertet, wenn
    # ihre Dauer diesen Wert erreicht. Bei 0 (oder einem Text) waere aus einem
    # Konfigurationsfehler mitten im Transfer ein roher Arithmetikfehler.
    case "$_ProbeMinSecs" in
        ''|*[!0-9]*) w2u_die "_ProbeMinSecs ist keine Ganzzahl: '$_ProbeMinSecs'" ;;
    esac
    [ "$_ProbeMinSecs" -ge 1 ] || w2u_die "_ProbeMinSecs muss mindestens 1 sein (bekam $_ProbeMinSecs) - sonst waere die Durchsatzrechnung eine Division durch 0"
    case "$_ProbeMinKb" in
        ''|*[!0-9]*) w2u_die "_ProbeMinKb ist keine Ganzzahl: '$_ProbeMinKb'" ;;
    esac
    case "$_PMax" in
        ''|*[!0-9]*) w2u_die "_PMax ist keine Ganzzahl: '$_PMax'" ;;
    esac
    [ "$_PMax" -ge 1 ] || w2u_die "_PMax muss mindestens 1 sein (bekam $_PMax)"
    [ -n "$_ResultFile" ] || w2u_die "w2u_autotune ohne gesetztes _ResultFile - ohne Ergebnisdatei ist nicht feststellbar, ob eine Runde Wiederholungen enthielt"

    # Wie in w2u_chunk: Altlasten aus einem vorherigen Lauf im selben
    # Arbeitsverzeichnis wuerden den Vollstaendigkeitsbeweis (Probe-Runden plus
    # Rest gegen Ausgangsliste) mit fremden Chunks fuellen.
    rm -f "$_TmpDir"/probe.*
    # Voraussetzung: $_ListFile ist NICHT $_TmpDir/chunks.rest (cp auf sich
    # selbst schlaegt fehl). Aufrufer ist w2u_run_all mit der Chunkliste.
    cp "$_ListFile" "$_Rest" || w2u_die "Restliste $_Rest konnte nicht angelegt werden"

    # Der Vorgabewert darf _PMax nicht ueberschreiten: bei _PMax=1 wird keine
    # Runde gefahren, und eine zurueckgegebene 2 waere eine Parallelitaet, die
    # die Konfiguration ausdruecklich ausschliesst.
    local _BestP=2 _BestRate=0 _Measured=0
    [ "$_PMax" -lt 2 ] && _BestP="$_PMax"
    local _P _Take _Round _Before="" _After _T0 _T1 _Dur _Kb _Rate
    local _LinesBefore _Retried _RetryKnown _Usable _Why _Threshold
    for _P in 2 4 8; do
        [ "$_P" -gt "$_PMax" ] && break
        _Take=$((2 * _P))
        _Round="$_TmpDir/probe.$_P"
        # rc pruefen, nicht nur die Groesse: eine leere Probe-Datei heisst
        # entweder "Restliste ist abgearbeitet" (Abbruchbedingung, voellig
        # normal) oder "head kam an die Restliste nicht heran" (Defekt). Ueber
        # "[ -s ]" allein sind die beiden nicht zu unterscheiden - genau die
        # Verwechslung, gegen die schon w2u_remote_list gehaertet wurde.
        _Rc=0
        head -n "$_Take" "$_Rest" > "$_Round" || _Rc=$?
        [ "$_Rc" -eq 0 ] || w2u_die "Restliste $_Rest nicht lesbar (head rc $_Rc) - eine leere Probe-Runde waere hier nicht von 'fertig' zu unterscheiden"
        [ -s "$_Round" ] || break

        # Die Chunks dieser Runde verlassen die Restliste, BEVOR sie laufen.
        # Kein "|| true" an tail: ein verschlucktes tail plus mv ersetzte die
        # Restliste durch eine leere oder halbe Datei - der komplette Rest des
        # Transfers waere still verschwunden, mit rc 0.
        _Rc=0
        tail -n +$((_Take + 1)) "$_Rest" > "$_Rest.next" || _Rc=$?
        [ "$_Rc" -eq 0 ] || w2u_die "Restliste konnte nicht fortgeschrieben werden (tail rc $_Rc) - Chunks wuerden still verschwinden"
        mv "$_Rest.next" "$_Rest" || w2u_die "Restliste konnte nicht ersetzt werden - Chunks wuerden still verschwinden"

        # Ein du je Runde statt zwei: zwischen dem Ende einer Runde und dem
        # Beginn der naechsten schreibt niemand ans Ziel, der Endwert IST also
        # der Anfangswert der Folgerunde. Auf einem Baum mit hunderttausenden
        # Dateien ist jedes gesparte "du -sk" spuerbar. Nur wenn der Vorwert
        # fehlt (erste Runde, oder ein du, das keine Zahl lieferte), wird neu
        # gemessen.
        [ -n "$_Before" ] || _Before="$(w2u_dst_kb)"
        _LinesBefore="$(w2u_result_lines)"

        _T0="$(date +%s)"
        w2u_run_list "$_Round" "$_P"
        _T1="$(date +%s)"
        _After="$(w2u_dst_kb)"

        _Dur=$((_T1 - _T0))
        [ "$_Dur" -lt 0 ] && _Dur=0
        # Nicht als eine Pipeline: scheitert dort das tail, ist der rc von
        # "kein Treffer" (grep 1) nicht zu unterscheiden, und die Runde galte
        # als wiederholungsfrei - der Guard waere gegenueber den drei anderen
        # Datei-Operationen hier invertiert. Fehlt die Ergebnisdatei nach einer
        # Runde ganz, ist nicht FESTSTELLBAR, ob wiederholt wurde; das ist
        # nicht dasselbe wie "es wurde nicht wiederholt".
        _Retried=0
        _RetryKnown=1
        if [ -f "$_ResultFile" ]; then
            _Rc=0
            tail -n +$((_LinesBefore + 1)) "$_ResultFile" > "$_TmpDir/runde.ergebnis" || _Rc=$?
            [ "$_Rc" -eq 0 ] || w2u_die "Ergebniszeilen der Probe-Runde nicht lesbar (tail rc $_Rc)"
            _Retried="$(cut -f3 "$_TmpDir/runde.ergebnis" | grep -cv '^1$')" \
                || [ "$?" -eq 1 ] || w2u_die "Versuchszahlen der Probe-Runde nicht lesbar"
        else
            _RetryKnown=0
        fi

        _Usable=1
        _Why=""
        _Kb=0
        if [ -z "$_Before" ] || [ -z "$_After" ]; then
            _Usable=0
            _Why="du lieferte am Ziel keine Zahl"
        else
            _Kb=$((_After - _Before))
        fi
        # Kein stilles Klemmen auf 0 bei negativem Delta: "0 KB" liest sich wie
        # "war schon alles da" und waere eine falsche Begruendung. Ein
        # schrumpfendes Ziel heisst, dass jemand anderes daran schreibt - dann
        # misst diese Runde etwas anderes als den Transfer.
        if [ "$_Usable" -eq 1 ] && [ "$_Kb" -lt 0 ]; then
            _Usable=0
            _Why="das Ziel ist waehrend der Runde um $((0 - _Kb)) KB geschrumpft - schreibt noch jemand anderes dorthin?"
        fi
        if [ "$_Usable" -eq 1 ] && [ "$_Dur" -lt "$_ProbeMinSecs" ]; then
            _Usable=0
            _Why="Runde dauerte nur ${_Dur}s, Mindestdauer ${_ProbeMinSecs}s - darunter kann die Sekundenaufloesung der Uhr keine 15 Prozent aufloesen"
        fi
        if [ "$_Usable" -eq 1 ] && [ "$_Kb" -lt "$_ProbeMinKb" ]; then
            _Usable=0
            _Why="nur ${_Kb} KB am Ziel dazugekommen, Mindestmenge ${_ProbeMinKb} KB - vermutlich war das meiste schon vorhanden"
        fi
        if [ "$_Usable" -eq 1 ] && [ "$_RetryKnown" -eq 0 ]; then
            _Usable=0
            _Why="nach der Runde existiert $_ResultFile nicht - ob wiederholt wurde, ist nicht feststellbar"
        fi
        if [ "$_Usable" -eq 1 ] && [ "$_Retried" -gt 0 ]; then
            _Usable=0
            _Why="$_Retried Chunk(s) mussten wiederholt werden - die Retry-Pausen stecken in der Wanduhr dieser Runde"
        fi

        _Before="$_After"

        if [ "$_Usable" -eq 0 ]; then
            w2u_log "Messung P=$_P: nicht verwertbar ($_Why). Die Arbeit dieser Runde bleibt erledigt, sie liefert nur keinen Messwert."
            continue
        fi

        # _Dur ist hier >= _ProbeMinSecs >= 1, die Division ist sicher.
        _Rate=$((_Kb / _Dur))
        _Measured=$((_Measured + 1))
        w2u_log "Messung P=$_P: ${_Rate} KB/s (${_Kb} KB in ${_Dur}s)"
        # "* 115 / 100" und nicht "+ _BestRate / 7": ein Siebtel sind 14,3
        # Prozent. Die Spec und die Logzeile sagen 15 - eine Schwelle, die
        # anders rechnet als sie sich meldet, ist beim Nachvollziehen einer
        # Entscheidung schlimmer als eine etwas andere Zahl.
        _Threshold=$((_BestRate * 115 / 100))
        if [ "$_Rate" -gt "$_Threshold" ]; then
            _BestRate="$_Rate"
            _BestP="$_P"
        else
            w2u_log "P=$_P bringt gegenueber P=$_BestP (${_BestRate} KB/s) keine 15 Prozent (noetig waeren mehr als ${_Threshold} KB/s) - Eskalation endet hier"
            break
        fi
    done

    # Drei Faelle, drei verschiedene Aussagen - der mittlere ist der, der sich
    # sonst als Messergebnis verkleiden wuerde: bei GENAU EINER verwertbaren
    # Runde gab es nichts zu vergleichen. _BestRate startet bei 0, die erste
    # verwertbare Runde gewinnt den Vergleich also immer, egal wie sie ausfiel.
    # Die Zahl ist dann trotzdem die beste verfuegbare - aber sie ist die Rate
    # der einzigen Runde, die zustande kam, und kein Optimum.
    if [ "$_Measured" -eq 0 ]; then
        w2u_log "keine verwertbare Messung zustande gekommen - benutze den Vorgabewert P=$_BestP (KEIN Messergebnis; --jobs N setzt den Wert fest)"
    elif [ "$_Measured" -eq 1 ]; then
        w2u_log "nur EINE verwertbare Runde (P=$_BestP bei ${_BestRate} KB/s) - kein Vergleich moeglich, das ist kein gemessenes Optimum"
    else
        w2u_log "gemessenes Optimum aus $_Measured verwertbaren Runden: P=$_BestP bei ${_BestRate} KB/s"
    fi
    printf '%s\n' "$_BestP"
}

# Orchestriert Messung plus Rest (Spec 5.4/5.5).
# Nach dem Lauf traegt _JobCnt die tatsaechlich benutzte Parallelitaet, damit der
# Abschlussbericht sie nennen kann.
w2u_run_all() {
    local _ListFile="$1" _Jobs
    # Gleiche Haertung wie fuer _MaxRetry in w2u_run_chunk: ein nicht-numerisches
    # _JobCnt (etwa aus einem kuenftigen "--jobs abc") ergaebe unten einen rohen
    # Vergleichsfehler statt einer Meldung.
    case "$_JobCnt" in
        ''|*[!0-9]*) w2u_die "_JobCnt ist keine nichtnegative Ganzzahl: '$_JobCnt'" ;;
    esac
    if [ "$_JobCnt" -gt 0 ]; then
        _Jobs="$_JobCnt"
        w2u_log "feste Parallelitaet: $_Jobs (Auto-Messung uebersprungen)"
        w2u_run_list "$_ListFile" "$_Jobs"
    else
        # Kein Fallback auf einen Ersatzwert: unter dem errexit aus main() reisst
        # ein w2u_die in der Substitution den Lauf schon hier ab, und auf dem
        # rc-0-Pfad kann w2u_autotune nur eine gueltige Stufe liefern. Ein
        # Zweig, der etwas anderes behandelt, waere toter Code mit einem
        # Kommentar, der das Gegenteil des Tatsaechlichen verspricht. Kaeme doch
        # je etwas Ungueltiges durch, faengt es der Guard in w2u_run_list.
        _Jobs="$(w2u_autotune "$_ListFile")"
        w2u_log "gewaehlte Parallelitaet: $_Jobs"
        w2u_run_list "$_TmpDir/chunks.rest" "$_Jobs"
    fi
    _JobCnt="$_Jobs"
}

# ---------------------------------------------------------------------------
# Sweep, Verifikation, Abschlussbericht (Spec 5.6/5.7/9.5).
#
# Alles davor bewegt Daten, dieser Abschnitt stellt fest, OB sie angekommen
# sind. Sein Ergebnis ist ein einzelnes PASS/FAIL, und auf ein PASS folgt das
# Verschrotten der Windows-Quelle - es gibt kein zweites Hinsehen. Daraus
# folgt die Regel, der hier jede Einzelentscheidung gehorcht: was nicht
# geprueft werden KONNTE, wird als Fehler gemeldet, niemals als "in Ordnung".
# Ein falsches FAIL kostet einen Nachmittag, ein falsches PASS die Daten.
#
# Drei Schichten, jede faengt, was die anderen nicht sehen:
#   Sweep    - repariert Verzeichnis-mtimes und holt, was die Zerlegung ausliess
#   Verify   - beweist die Gleichheit von Quelle und Ziel
#   Bericht  - wertet die Exit-Codes aus, die einzige Spur der Chunks, die
#              fehlschlugen waehrend der Lauf weiterlief
# ---------------------------------------------------------------------------

# Einzelner vollstaendiger, NICHT paralleler Lauf ueber den Baum (Spec 5.6).
# Die Daten liegen schon, das ist im Wesentlichen ein Metadaten-Durchlauf.
# Gemessen an genau dem Baum, den tests/test_verify.sh aufbaut: vor dem Sweep
# meldet der Verify die zwei Luecken, die eine Zerlegung nach Verzeichnissen
# strukturell hinterlaesst - eine Datei DIREKT in einem aufgeteilten
# Verzeichnis und ein leeres Verzeichnis - plus die mtime der Wurzel; danach
# ist seine Ausgabe leer.
#
# --exclude-from MUSS mit: ohne die Ausschluesse holte ausgerechnet der Sweep
# alles wieder her, was die Chunks bewusst ausgelassen haben.
# --timeout aus demselben Grund wie in w2u_run_chunk: ohne Timeout wird aus
# einem haengenden Daemon ein Haenger statt eines Abbruchs.
# Der rc ist der des rsync; der Aufrufer entscheidet, was er damit tut (main
# warnt und laesst den Verify urteilen - der Sweep ist Reparatur, nicht Beweis).
w2u_sweep() {
    local _Args
    _Args=( -rlt -W --partial --numeric-ids "--timeout=$_RsyncTimeout" )
    [ -n "$_ExcludeFrom" ] && _Args=( "${_Args[@]}" "--exclude-from=$_ExcludeFrom" )
    "$_RsyncBin" "${_Args[@]}" "$_SrcUrl/" "$_DstRoot/"
}

# Struktur-Verify (Spec 5.7): ein Trockenlauf, dessen Erwartung LEERE Ausgabe
# ist. Jede Zeile ist ein Befund, rc 1 heisst "nicht sauber".
#
# Gefiltert wird AUSSCHLIESSLICH die mtime der Wurzel selbst ("./"): sie ist
# systematisch (das Ziel ist oft ein Mountpunkt, dessen mtime nicht gesetzt
# werden kann) und harmlos. Wer pauschal alle .d-Zeilen wegwirft, wirft jeden
# echten Verzeichnisbefund mit weg - genau diese Mutation pinnt der Test mit
# einer verstellten mtime eines UNTERverzeichnisses. Die Punktzahl im
# Itemize-String ist versionsabhaengig (nachgemessen: openrsync 9 Zeichen,
# GNU rsync 3.5 11 Zeichen), deshalb der offene Quantor.
#
# Die Ausgabe geht in eine Arbeitsdatei und wird von dort GESTREAMT, nie in
# einer Shell-Variablen gehalten (dieselbe Form wie w2u_count_remote, aus einem
# schaerferen Grund): die Ausgabe dieses Laufs ist genau dann gross, wenn etwas
# schiefging - ein gescheiterter Transfer itemisiert JEDE Datei. Eine Variable
# plus "printf | grep" hielte davon zwei Kopien im Speicher, und das Fehlerbild
# waere nicht ein falsches FAIL, sondern eine sterbende Shell OHNE gedruckten
# Bericht - das schlimmste Ergebnis ueberhaupt, weil es niemand bemerkt.
# Der rc des grep traegt zugleich das Urteil: 0 = Befunde ausgegeben, 1 = nichts
# ausser der gefilterten Wurzelzeile, alles andere = Ausgabe nicht lesbar.
#
# Der rc des rsync darf NICHT verworfen werden - das ist hier die zentrale
# Falle: stirbt der Vergleichslauf (Daemon weg, Timeout, Verbindungsabbruch),
# ist seine Ausgabe womoeglich leer, und "keine Ausgabe" saehe dann aus wie
# "alles gleich". Ein nicht durchgefuehrter Vergleich ist ein Befund, kein
# Freispruch. Preis dieser Strenge: rc 24 (Quelldateien sind waehrend des Laufs
# verschwunden) erzeugt auf einer lebenden Windows-Kiste ein FAIL, obwohl nichts
# fehlt. Das ist die gewollte Seite der Asymmetrie - ein Nachmittag Nachsehen
# statt vernichteter Daten.
w2u_verify() {
    local _Args _List _Rc=0 _GrepRc=0
    _List="$(mktemp "${TMPDIR:-/tmp}/w2u.verify.XXXXXXXX" 2>/dev/null)" || _List=""
    if [ -z "$_List" ]; then
        printf 'VERIFY NICHT MOEGLICH: keine Arbeitsdatei fuer die Ausgabe des Vergleichslaufs anlegbar\n'
        return 1
    fi
    _Args=( -rlt -W -n -i "--timeout=$_RsyncTimeout" )
    [ "$_DoChecksum" = "1" ] && _Args=( "${_Args[@]}" -c )
    [ -n "$_ExcludeFrom" ] && _Args=( "${_Args[@]}" "--exclude-from=$_ExcludeFrom" )
    "$_RsyncBin" "${_Args[@]}" "$_SrcUrl/" "$_DstRoot/" > "$_List" 2>&1 || _Rc=$?
    # Die Meldung auf STDOUT ist Verdrahtung, nicht Kosmetik: main() entscheidet
    # im Normalpfad an "[ -s verify.log ]", also an der AUSGABE, nicht am rc.
    # Wer sie zu "return 1 genuegt" aufraeumt, haengt die rc-Pruefung still ab.
    if [ "$_Rc" -ne 0 ]; then
        printf 'VERIFY NICHT MOEGLICH: der Vergleichslauf endete mit rc %s - eine leere Ausgabe ist hier KEIN Beweis fuer Gleichheit\n' "$_Rc"
    fi
    grep -Ev '^\.d\.\.t[.]* \./$' "$_List" || _GrepRc=$?
    rm -f "$_List"
    if [ "$_Rc" -ne 0 ]; then
        return 1
    fi
    case "$_GrepRc" in
        0)
            return 1
            ;;
        1)
            return 0
            ;;
        *)
            printf 'VERIFY NICHT MOEGLICH: die Ausgabe des Vergleichslaufs ist nicht lesbar (grep rc %s)\n' "$_GrepRc"
            return 1
            ;;
    esac
}

# Anzahl regulaerer Dateien in der Quelle, oder eine LEERE Ausgabe, wenn sie
# sich nicht ermitteln laesst (gleiches Muster wie w2u_dst_kb): eine 0 waere
# eine Zahl, mit der der Bericht weiterrechnete, und aus einem gescheiterten
# Listing wuerde ein Messwert - im schlimmsten Fall "remote 0 / lokal 0, passt".
#
# Das Listing geht in eine Datei statt durch eine Pipe, damit der rc des rsync
# unverfaelscht ankommt: in "rsync | zaehler" haengt der sichtbare rc von
# pipefail ab, und diese Funktion darf sich nicht darauf verlassen, in welcher
# Shell-Konfiguration ihr Aufrufer laeuft. Die Datei statt einer Variablen,
# weil das Listing eines Zielbaums leicht hunderttausende Zeilen hat.
# Die Ausschluesse gelten mit, damit die genannte Zahl zur wirklich erwarteten
# Menge passt; verglichen wird bei aktiven Ausschluessen trotzdem nicht (die
# Filtersemantik von --list-only ist kein Beweis, siehe w2u_report).
w2u_count_remote() {
    local _List _Args _Rc=0 _Cnt="" _Seen=""
    _List="$(mktemp "${TMPDIR:-/tmp}/w2u.remotelist.XXXXXXXX" 2>/dev/null)" || _List=""
    if [ -z "$_List" ]; then
        printf '%s\n' ""
        return 0
    fi
    _Args=( -r --list-only "--timeout=$_RsyncTimeout" )
    [ -n "$_ExcludeFrom" ] && _Args=( "${_Args[@]}" "--exclude-from=$_ExcludeFrom" )
    "$_RsyncBin" "${_Args[@]}" "$_SrcUrl/" > "$_List" 2>/dev/null || _Rc=$?
    # Zwei Zahlen, nicht eine: Dateien ("-") UND ueberhaupt erkannte
    # Listing-Zeilen (Rechte-Spalte). rc 0 plus null Datei-Treffer ist zweideutig
    # - es kann ein Baum ganz ohne regulaere Dateien sein ODER eine Ausgabe, die
    # dieser Zaehler nicht versteht (fremdes Format, abgeschnittenes Listing,
    # leere Ausgabe). Nur wenn ueberhaupt eine Listing-Zeile erkannt wurde, ist
    # die Null eine Messung; sonst bleibt die Ausgabe leer, also "nicht
    # ermittelbar". Sonst laese sich "remote 0 / lokal 0" als Uebereinstimmung.
    if [ "$_Rc" -eq 0 ]; then
        _Seen="$(awk '/^-/ { _F++ } /^[-dlbcps]/ { _K++ } END { printf "%d %d\n", _F + 0, _K + 0 }' "$_List")" || _Seen=""
        case "$_Seen" in
            [0-9]*' '[0-9]*)
                set -- $_Seen
                if [ "$2" -gt 0 ]; then
                    _Cnt="$1"
                fi
                ;;
        esac
    fi
    rm -f "$_List"
    printf '%s\n' "$_Cnt"
    return 0
}

# Gegenstueck am Ziel. Leer heisst auch hier "nicht ermittelbar" - ein find,
# das ueber ein unlesbares Verzeichnis stolpert, liefert rc 1 UND eine zu
# kleine Zahl; die duerfte nie als Messwert durchgehen.
#
# $_LogDir wird ausgeschlossen. Seit Task 9 liegt es per Vorgabe NICHT mehr
# unter dem Ziel (eigenes mktemp-Verzeichnis, CONTROLLER-RULING 3), und ein
# per --log-dir angegebenes unterhalb des Ziels lehnt w2u_preflight ab - der
# Ausschluss hier ist also heute ein Guertel zum Hosentraeger und kein
# tragender Teil. Er bleibt trotzdem stehen: laege das Logverzeichnis je wieder
# im verglichenen Baum, waere die lokale Zahl in JEDEM produktiven Lauf groesser
# als die entfernte - ein garantiertes falsches FAIL. Bei leerem $_LogDir passt
# "-path ''" auf nichts, der Ausdruck bleibt also auch ohne Logverzeichnis
# korrekt. Der abgeschnittene Schraegstrich ist kein Schoenheitsfehler:
# "--log-dir /pfad/" kommt vom Nutzer, und mit Schraegstrich passte "-path"
# nicht mehr - die Logs waeren wieder in der Zahl.
w2u_count_local() {
    local _List _Rc=0 _Cnt=""
    if [ ! -d "$_DstRoot" ]; then
        printf '%s\n' ""
        return 0
    fi
    _List="$(mktemp "${TMPDIR:-/tmp}/w2u.locallist.XXXXXXXX" 2>/dev/null)" || _List=""
    if [ -z "$_List" ]; then
        printf '%s\n' ""
        return 0
    fi
    find "$_DstRoot" -path "${_LogDir%/}" -prune -o -type f -print > "$_List" 2>/dev/null || _Rc=$?
    if [ "$_Rc" -eq 0 ]; then
        _Cnt="$(awk 'END { print NR + 0 }' "$_List")" || _Cnt=""
    fi
    rm -f "$_List"
    printf '%s\n' "$_Cnt"
    return 0
}

# Abschlussbericht. Das PASS/FAIL-Kriterium ist explizit, weil daran haengt, ob
# die Quelle verschrottet werden darf.
#
# CONTROLLER-RULING 1: die Ergebniszeilen werden gegen die CHUNKLISTE
# abgeglichen, nicht nur untereinander ausgewertet. w2u_run_chunk gibt bewusst
# IMMER 0 zurueck, damit ein kaputter Chunk keinen Terabyte-Transfer abbricht -
# die Ergebnisdatei ist damit die einzige Stelle, an der ein Fehlschlag je
# sichtbar wird. Wer nur die Zeilen auswertet, DIE DA SIND, kann einen Chunk
# ohne Ergebniszeile nicht von einem unterscheiden, der nie gelaufen ist:
# abgestuerzter Worker, voller Datentraeger, abgebrochener xargs-Lauf - und
# eine halb geschriebene Ergebnisdatei liest sich als "nichts fehlgeschlagen".
#
# Verglichen werden NAMEN, nicht Zeilenzahlen. Eine Summe kann Verlust und
# Duplikat nicht auseinanderhalten (dieselbe Lehre wie in w2u_autotune): zwei
# Zeilen fuer chunk.aa und keine fuer chunk.ab ergeben exakt die Zeilenzahl
# eines sauberen Laufs.
#
# CONTROLLER-RULING 2: $_TmpDir/chunks.rest wird hier NICHT gelesen - weder als
# Quelle der Chunkzahl noch sonst. Die Datei entsteht nur im Auto-Messungs-Pfad
# von w2u_run_all, im "--jobs N"-Pfad nie, und niemand entfernt eine alte aus
# einem frueheren Lauf im selben Arbeitsverzeichnis; sie waere im schlimmsten
# Fall die Chunkliste eines anderen Quellverzeichnisses. Der vollstaendige
# Massstab ist ohnehin $_ChunkListFile: Probe-Runden und Restliste ueberdecken
# diese Liste zu jedem Zeitpunkt exakt.
#
# Alle Zahlen werden ERST ermittelt und dann gedruckt, und jede Pruefung steht
# in einem vollstaendigen if-Block: unter dem "set -euo pipefail" aus main()
# risse ein Einzelkommando mit rc 1 (etwa ein "[ ... ] && ..." als Anweisung)
# den Bericht ab, bevor sein Ergebnis auf dem Bildschirm steht - und ein Lauf
# ohne gedrucktes Ergebnis ist genau der, den niemand bemerkt.
w2u_report() {
    local _Fail=0
    local _Lines=0 _Bad=0 _Retried=0 _Malformed=0 _Stats=""
    local _Chunks=0 _MissCnt=0 _DupCnt=0 _UnkCnt=0
    local _Missing="" _Dupes="" _Unknown="" _Recon=""
    local _ResultState="ok" _ListState="ok"
    local _Dur=-1 _Now _Remote="" _Local="" _Rc=0 _Detail=0 _Binding=0

    # ---- Ergebnisdatei: existiert / lesbar / auswertbar? --------------------
    # "existiert nicht" und "ist leer" duerfen nicht zusammenfallen (gleiche
    # Trennung wie in w2u_run_list): leer ist eine Aussage, fehlend ist ein
    # Defekt.
    if [ -z "$_ResultFile" ]; then
        _ResultState="ist nicht gesetzt"
    elif [ ! -e "$_ResultFile" ]; then
        _ResultState="fehlt"
    elif [ ! -r "$_ResultFile" ]; then
        _ResultState="ist nicht lesbar"
    else
        _Rc=0
        _Stats="$(awk -F'\t' '
            length($0) == 0 { next }
            { _L++ }
            (NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) { _M++; next }
            $2 != "0" { _B++ }
            $3 + 0 > 1 { _R++ }
            END { printf "%d %d %d %d\n", _L + 0, _M + 0, _B + 0, _R + 0 }
        ' "$_ResultFile")" || _Rc=$?
        if [ "$_Rc" -ne 0 ]; then
            _ResultState="ist nicht auswertbar"
        else
            case "$_Stats" in
                [0-9]*' '[0-9]*' '[0-9]*' '[0-9]*)
                    set -- $_Stats
                    _Lines="$1"; _Malformed="$2"; _Bad="$3"; _Retried="$4"
                    ;;
                *)
                    _ResultState="ist nicht auswertbar"
                    ;;
            esac
        fi
    fi
    if [ "$_ResultState" != "ok" ]; then
        _Fail=1
    fi

    # ---- Chunkliste: der Massstab fuer die Vollstaendigkeit ----------------
    if [ -z "$_ChunkListFile" ]; then
        _ListState="unbekannt"
    elif [ ! -e "$_ChunkListFile" ]; then
        _ListState="fehlt"
    elif [ ! -r "$_ChunkListFile" ]; then
        _ListState="ist nicht lesbar"
    else
        _Rc=0
        _Chunks="$(awk 'length($0) > 0 { _N++ } END { print _N + 0 }' "$_ChunkListFile")" || _Rc=$?
        case "$_Chunks" in
            ''|*[!0-9]*) _Rc=1 ;;
        esac
        if [ "$_Rc" -ne 0 ]; then
            _ListState="ist nicht auswertbar"
            _Chunks=0
        elif [ "$_Chunks" -eq 0 ]; then
            # Gesetzt, aber leer: w2u_chunk bricht bei null Arbeitspaketen ab,
            # eine leere registrierte Liste kann es also gar nicht geben. Sie
            # als "null erwartete Chunks" durchzuwinken hiesse, einen Lauf ohne
            # jede Uebertragung als vollstaendig zu melden.
            _ListState="ist leer"
        fi
    fi

    # ---- Abgleich Chunkliste <-> Ergebniszeilen (Ruling 1) -----------------
    # Ein Durchlauf ueber beide Dateien. Unterschieden wird ueber FILENAME und
    # nicht ueber das uebliche "NR == FNR": diese Abkuerzung bricht genau dann,
    # wenn die Ergebnisdatei LEER ist - also im Fall, in dem am meisten fehlt.
    if [ "$_ListState" = "ok" ] && [ "$_ResultState" = "ok" ]; then
        _Rc=0
        _Recon="$(awk -F'\t' -v _DoneFile="$_ResultFile" '
            FILENAME == _DoneFile {
                if (length($0) > 0 && $1 != "") { _Cnt[$1]++ }
                next
            }
            {
                _N = $0
                sub(/^.*\//, "", _N)
                if (_N != "") { _Want[_N] = 1 }
            }
            END {
                for (_K in _Want) {
                    if (!(_K in _Cnt)) { printf "M\t%s\n", _K }
                }
                for (_K in _Cnt) {
                    if (!(_K in _Want)) { printf "U\t%s\n", _K }
                    if (_Cnt[_K] > 1)   { printf "D\t%s (%dx)\n", _K, _Cnt[_K] }
                }
            }
        ' "$_ResultFile" "$_ChunkListFile")" || _Rc=$?
        if [ "$_Rc" -ne 0 ]; then
            _ListState="ist nicht auswertbar"
        else
            # HIER, und nur hier, hat die Chunk-Buchfuehrung tatsaechlich
            # verglichen - nicht dort, wo ein Vergleich bloss angestossen wird.
            _Binding=1
            _MissCnt="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "M" { _N++ } END { print _N + 0 }')"
            _UnkCnt="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "U" { _N++ } END { print _N + 0 }')"
            _DupCnt="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "D" { _N++ } END { print _N + 0 }')"
            # Nur die ersten 20 je Klasse, und die Begrenzung per Zaehler in awk
            # statt per "| head": head schliesst die Pipe und kann den Schreiber
            # per SIGPIPE (rc 141) toeten - unter pipefail waere das ein
            # Fehlschlag der Zuweisung und unter errexit das Ende des Berichts.
            _Missing="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "M" && _N < 20 { printf "   %s\n", $2; _N++ }')"
            _Unknown="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "U" && _N < 20 { printf "   %s\n", $2; _N++ }')"
            _Dupes="$(printf '%s\n' "$_Recon" | awk -F'\t' '$1 == "D" && _N < 20 { printf "   %s\n", $2; _N++ }')"
        fi
    fi
    if [ "$_ListState" != "ok" ] && [ "$_ListState" != "unbekannt" ]; then
        _Fail=1
    fi
    # Ohne Chunkliste gibt es keine Chunk-Buchfuehrung. Zwei Aussagen, die die
    # allgemeine Bindungs-Regel weiter unten NICHT abdeckt, weil sie nicht von
    # "es wurde nichts geprueft" handeln, sondern von "die Buchfuehrung ist
    # widerspruechlich":
    if [ "$_ListState" = "unbekannt" ]; then
        # a) Ergebniszeilen ohne Massstab: wieviele es haetten sein muessen, ist
        #    nicht feststellbar - und nicht feststellbar ist kein PASS.
        if [ "$_Lines" -gt 0 ]; then
            _Fail=1
        fi
        # b) Ein Lauf, der zerlegen sollte, dessen Massstab aber fehlt: die
        #    Registrierung in w2u_chunk ging verloren. Genau ZWEI Laeufe duerfen
        #    ohne Chunkliste dastehen, und beide sind ausdrueckliche
        #    Entscheidungen, keine Pannen: der --verify-only-Lauf (er
        #    uebertraegt nichts) und der einstroemige Lauf (er zerlegt nicht,
        #    weil die Eintraege in kein Ziel passen - angesagt beim Parsen).
        #    In beiden Faellen traegt der Dateizahl-Vergleich das Urteil allein;
        #    faellt auch der weg, greift die Bindungs-Regel weiter unten.
        if [ "$_VerifyOnly" != "1" ] && [ "$_ParMode" != "einstroemig" ]; then
            _Fail=1
        fi
    fi
    if [ "$_Malformed" -gt 0 ] || [ "$_Bad" -gt 0 ]; then
        _Fail=1
    fi
    if [ "$_MissCnt" -gt 0 ] || [ "$_DupCnt" -gt 0 ] || [ "$_UnkCnt" -gt 0 ]; then
        _Fail=1
    fi
    # Erzwungen wird die Namensmenge, GEDRUCKT wird daneben eine Zeilenzahl.
    # Diese Zeile macht beide zur selben Aussage: eine Zahl im Bericht, an der
    # nichts haengt, laedt dazu ein, ihr zu glauben. Bei exakt deckenden
    # Namensmengen ist sie strukturell nicht ausloesbar (ein Ueberschuss waere
    # ein Duplikat, ein Fehlbetrag ein fehlender Name) - sie ist der Riegel fuer
    # den Fall, dass jemand spaeter am Abgleich schraubt.
    if [ "$_ListState" = "ok" ] && [ "$_ResultState" = "ok" ] && [ "$_Lines" -ne "$_Chunks" ]; then
        _Fail=1
    fi

    # ---- Laufzeit ----------------------------------------------------------
    # Ohne gesetztes _StartTs kaeme hier die Sekunde seit 1970 heraus - eine
    # Zahl mit Messwert-Anmutung. Lieber "unbekannt".
    _Now="$(date +%s)"
    case "$_StartTs" in
        ''|*[!0-9]*)
            _Dur=-1
            ;;
        *)
            if [ "$_StartTs" -gt 0 ]; then
                _Dur=$((_Now - _StartTs))
            else
                _Dur=-1
            fi
            ;;
    esac

    printf '\n'
    printf '========================================================\n'
    printf ' win2unix %s - Abschlussbericht\n' "$W2U_VERSION"
    printf '========================================================\n'
    printf ' Quelle          : %s\n' "$_SrcUrl"
    printf ' Ziel            : %s\n' "$_DstRoot"
    if [ "$_Dur" -ge 0 ]; then
        printf ' Dauer           : %d s\n' "$_Dur"
    else
        printf ' Dauer           : unbekannt (Startzeit nicht gesetzt)\n'
    fi
    # Der Bericht ueberlebt den Scrollback - er darf nicht leise das Gegenteil
    # dessen behaupten, was der Lauf laut angesagt hat (Review-Fund). _JobCnt
    # traegt nur dann eine Messung, wenn w2u_run_all wirklich gelaufen ist; in
    # jedem anderen Modus stuende dort der ungenutzte Vorgabe- oder --jobs-Wert
    # und behauptete eine Parallelitaet, die es nie gab.
    if [ "$_VerifyOnly" = "1" ]; then
        printf ' Parallelitaet   : entfaellt (nur Verifikation, kein Transfer)\n'
    elif [ "$_ParMode" = "einstroemig" ]; then
        printf ' Parallelitaet   : keine (einstroemiger Lauf, ein rsync-Prozess)\n'
    else
        printf ' Parallelitaet   : %s\n' "$_JobCnt"
    fi

    case "$_ListState" in
        ok)
            printf ' Chunks          : %s laut Liste, %s Ergebniszeile(n), %s mit Wiederholung, %s fehlgeschlagen\n' \
                   "$_Chunks" "$_Lines" "$_Retried" "$_Bad"
            ;;
        unbekannt)
            if [ "$_Lines" -gt 0 ]; then
                printf ' Chunks          : %s Ergebniszeile(n), aber KEINE CHUNKLISTE bekannt - wieviele es haetten sein muessen, ist nicht feststellbar\n' "$_Lines"
            else
                printf ' Chunks          : keine CHUNKLISTE, keine Ergebniszeilen - es gibt keine Chunk-Buchfuehrung\n'
            fi
            # Reihenfolge: --verify-only gewinnt. Beide Bedingungen koennen
            # gleichzeitig wahr sein (ein Verify-Only-Lauf in einer Aufrufform,
            # die auch einstroemig waere) - der Text "der Sweep hat
            # uebertragen" waere dort schlicht falsch, denn dieser Modus
            # uebertraegt nichts.
            if [ "$_VerifyOnly" = "1" ]; then
                :
            elif [ "$_ParMode" = "einstroemig" ]; then
                printf '   Einstroemiger Lauf: es wurde bewusst nicht zerlegt, der Sweep hat uebertragen.\n'
                printf '   Das Urteil traegt hier allein der Dateizahl-Vergleich.\n'
            elif [ "$_VerifyOnly" != "1" ]; then
                printf '   Ohne --verify-only ist das ein Lauf, der zerlegen sollte und dessen Massstab fehlt.\n'
            fi
            ;;
        *)
            printf ' Chunks          : CHUNKLISTE %s (%s) - die Vollstaendigkeit ist damit NICHT pruefbar\n' \
                   "$_ListState" "$_ChunkListFile"
            ;;
    esac

    if [ "$_ResultState" != "ok" ]; then
        _Detail=1
        printf '\n ERGEBNISDATEI %s (%s)\n' "$_ResultState" "$_ResultFile"
        printf '   Sie ist die einzige Stelle, an der ein fehlgeschlagener Chunk sichtbar wird.\n'
    fi

    # Die Filter der Detailblöcke sind IDENTISCH mit denen der Zaehlung oben -
    # eine Liste, die mehr Zeilen zeigt als ihre eigene Zahl nennt, laesst an
    # der ganzen Buchfuehrung zweifeln. Kaputte Zeilen erscheinen deshalb nur
    # im FORMAT-Block, nicht zusaetzlich unter den Exit-Codes.
    if [ "$_Malformed" -gt 0 ]; then
        _Detail=1
        printf '\n %s Ergebniszeile(n) mit ungueltigem FORMAT (erwartet: Name<TAB>rc<TAB>Versuche):\n' "$_Malformed"
        awk -F'\t' '
            length($0) == 0 { next }
            (NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) && _N < 20 { printf "   %s\n", $0; _N++ }
        ' "$_ResultFile" || printf '   (Liste konnte nicht gelesen werden)\n'
        printf '   Nicht auswertbar heisst nicht sauber.\n'
    fi

    if [ "$_Bad" -gt 0 ]; then
        _Detail=1
        printf '\n FEHLGESCHLAGENE CHUNKS (Exit 23/24 = Dateien fehlen still!):\n'
        awk -F'\t' '
            length($0) == 0 { next }
            (NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/) { next }
            $2 != "0" { printf "   %s  Exit %s\n", $1, $2 }
        ' "$_ResultFile" || printf '   (Liste konnte nicht gelesen werden)\n'
    fi

    if [ "$_MissCnt" -gt 0 ]; then
        _Detail=1
        printf '\n %s CHUNK(S) OHNE ERGEBNISZEILE - nicht (vollstaendig) uebertragen:\n' "$_MissCnt"
        printf '%s\n' "$_Missing"
        if [ "$_MissCnt" -gt 20 ]; then
            printf '   ... und %s weitere\n' "$((_MissCnt - 20))"
        fi
    fi

    if [ "$_DupCnt" -gt 0 ]; then
        _Detail=1
        printf '\n %s CHUNK(S) DOPPELT im Ergebnisprotokoll - die Zeilenzahl allein taeuscht Vollstaendigkeit vor:\n' "$_DupCnt"
        printf '%s\n' "$_Dupes"
        if [ "$_DupCnt" -gt 20 ]; then
            printf '   ... und %s weitere\n' "$((_DupCnt - 20))"
        fi
    fi

    if [ "$_UnkCnt" -gt 0 ]; then
        _Detail=1
        printf '\n %s ERGEBNISZEILE(N) ZU UNBEKANNTEN CHUNKS - Protokoll und Chunkliste gehoeren nicht zusammen:\n' "$_UnkCnt"
        printf '%s\n' "$_Unknown"
        if [ "$_UnkCnt" -gt 20 ]; then
            printf '   ... und %s weitere\n' "$((_UnkCnt - 20))"
        fi
    fi

    if [ "$_Detail" -eq 1 ]; then
        printf '\n'
    fi
    if [ "$_DoVerify" = "1" ]; then
        _Remote="$(w2u_count_remote)"
        _Local="$(w2u_count_local)"
        printf ' Dateizahl       : remote %s / lokal %s\n' "${_Remote:-?}" "${_Local:-?}"
        if [ -n "$_ExcludeFrom" ]; then
            # Ausdruecklich NICHT bindend: bei aktiven Ausschluessen sind die
            # Zahlen wirklich nur orientierend. Die Konsequenz daraus ist nicht
            # "dann ignorieren wir sie", sondern "dann traegt dieser Vergleich
            # das Urteil nicht" - und war er der einzige, traegt es niemand.
            printf '   (Hinweis: Ausschluesse aktiv, Zahlen nur orientierend - dieser Vergleich traegt kein Urteil)\n'
        elif [ -z "$_Remote" ] || [ -z "$_Local" ]; then
            printf '   Dateizahl nicht ermittelbar - die Vollstaendigkeit ist damit NICHT bestaetigt\n'
            _Fail=1
        else
            # Erst hier wurden zwei belastbare Zahlen wirklich verglichen.
            _Binding=1
            if [ "$_Remote" != "$_Local" ]; then
                printf '   ABWEICHUNG in der Dateizahl!\n'
                _Fail=1
            fi
        fi
    else
        printf ' Dateizahl       : Vergleich uebersprungen (--no-verify)\n'
    fi

    # CONTROLLER-RULING 2 (Task 8, umgesetzt in Task 9): der Ausgang des
    # Vergleichslaufs gehoert in das BERICHTSERGEBNIS, nicht nur in den
    # Exit-Code von main(). Wer ihn dort mit "|| true" verwirft, laesst diesen
    # Bericht "PASS - Transfer vollstaendig" drucken, NACHDEM der Verify
    # Befunde ausgegeben hat - und PASS ist hier die Freigabe, die
    # Quellmaschine zu verschrotten.
    #
    # Bewusst KEIN "_Binding=1": ein Verify OHNE Befunde ist keine Schicht, die
    # dieser Bericht allein tragen kann. Er lief mit derselben Filtersemantik,
    # an der schon der Dateizahl-Vergleich sein Urteil verliert, sobald
    # Ausschluesse aktiv sind - und genau darauf beruht Ruling 5 (der Fall
    # "--verify-only + --exclude-from" hat KEINE bindende Schicht und wird
    # deshalb in der CLI abgelehnt). Diese Schicht darf also FAIL setzen, aber
    # nie allein ein PASS tragen. Wer hier "_Binding=1" ergaenzt, hebt Ruling 5
    # still auf.
    case "$_VerifyState" in
        befunde)
            printf ' Verify          : BEFUNDE - Quelle und Ziel sind NICHT gleich (%s/verify.log)\n' "${_LogDir%/}"
            _Fail=1
            ;;
        sauber)
            printf ' Verify          : Vergleichslauf ohne Befunde\n'
            ;;
        *)
            :
            ;;
    esac

    # DIE REGEL, positiv formuliert und an genau EINER Stelle (Re-Review Task 8):
    # PASS setzt mindestens eine BINDENDE Beweisschicht voraus. Bindend ist eine
    # Schicht nur, wenn ihr Ergebnis "$_Fail" setzen KANN - die Chunk-
    # Buchfuehrung also wirklich Namensmengen verglichen hat, oder zwei
    # belastbare Dateizahlen wirklich gegeneinander standen. Ein Vergleich, der
    # nur angestossen und dann als "orientierend" entwertet wurde, ist keine.
    #
    # Diese Regel ersetzt das Sammeln von Ausnahmen. Die beiden Loecher davor
    # ("--verify-only --no-verify", danach "--verify-only --exclude-from") waren
    # PRODUKTE zweier je einzeln gepruefter Formen; die naechste Kombination
    # waere wieder eine gewesen. Wer hier eine Schicht hinzufuegt, muss nur an
    # der Stelle, an der sie wirklich vergleicht, "_Binding=1" setzen.
    if [ "$_Binding" -eq 0 ]; then
        _Fail=1
        printf '\n KEINE Beweisschicht war bindend - PASS waere eine Behauptung.\n'
        printf '   Dieser Lauf hat nichts Falsches gefunden, aber auch nichts geprueft.\n'
    fi

    printf '\n'
    if [ "$_Fail" -eq 0 ]; then
        printf ' ERGEBNIS: PASS - Transfer vollstaendig.\n'
    else
        printf ' ERGEBNIS: FAIL - NICHT verschrotten, Logs pruefen: %s\n' "$_LogDir"
    fi
    printf '========================================================\n\n'
    return "$_Fail"
}

# ---------------------------------------------------------------------------
# CLI, Preflight, Ablaufsteuerung (Spec 5.1/5.2).
# ---------------------------------------------------------------------------

# Holt den Wert einer Option und faengt die zwei Faelle ab, an denen ein
# naiver "$2"-Zugriff scheitert. Sie muessen BEIDE einzeln stehen - jede fuer
# sich sieht wie ein Sonderfall aus, ihr Produkt ist der Fehler:
#   a) die Option steht am ENDE der Befehlszeile: "$2" ist unter "set -u" ein
#      "unbound variable" mitten im Parser (Abbruch ohne verwertbare Meldung),
#      und ohne set -u ein leerer Wert, mit dem der Lauf weiterliefe;
#   b) der Option folgt die NAECHSTE OPTION: "--jobs --dry-run" wuerde
#      "--dry-run" als Wert verschlucken - die Option waere weg, der Wert
#      Unsinn, und beides faellt erst Stunden spaeter auf.
# Der Wert kommt ueber eine Variable zurueck, NICHT ueber eine
# Kommandosubstitution: w2u_die beendete darin nur die Subshell, der Aufrufer
# liefe mit leerem Wert weiter (dieselbe Falle wie in w2u_decompose).
w2u_take_arg() {
    local _Opt="$1" _Val="${2-}"
    if [ -z "$_Val" ]; then
        w2u_die "Option $_Opt braucht ein Argument, hat aber keines bekommen"
    fi
    case "$_Val" in
        -*)
            w2u_die "Option $_Opt braucht ein Argument, bekam aber die Option '$_Val' - fehlt der Wert?"
            ;;
    esac
    _ArgVal="$_Val"
}

# Schaltet den Transfer auf EINEN Strom um - die einzige Stelle, die das tut.
# <grund> nennt, warum die parallele Phase nicht laufen kann.
#
# Drei Dinge gehoeren zusammen und deshalb in EINE Funktion (aufgerufen aus dem
# Parser UND aus dem Preflight - zwei Stellen, an denen die Umschaltung noetig
# werden kann, und getrennte Kopien liefen garantiert auseinander):
#
# 1) Der Rueckfall wird ANGESAGT. Wer dieses Werkzeug benutzt, tut es wegen der
#    Parallelitaet; still auf einen Strom zurueckzufallen waere dieselbe
#    Fehlerklasse wie der lautlose Ausfall, gegen den der Modulwurzel-Fix steht.
# 2) Ohne Zerlegung gibt es KEINE Chunk-Buchfuehrung. Das Urteil haengt dann
#    allein am Dateizahl-Vergleich - und faellt der auch weg (--no-verify, oder
#    --exclude-from, das ihn zu einer blossen Orientierung macht), bleibt keine
#    bindende Beweisschicht und der Lauf koennte nur FAIL melden. Dieselbe Lage
#    wie bei Ruling 5, nur aus anderen Faktoren: also gleich ablehnen statt nach
#    Stunden FAIL zu melden.
# 3) --verify-only ist ausgenommen: dieser Modus uebertraegt ohnehin nichts, die
#    Aufrufform spielt dort keine Rolle.
w2u_einstroemig() {
    local _Grund="$1" _Weg="$2"
    _ParMode="einstroemig"
    _ParDst=""
    if [ "$_VerifyOnly" -eq 1 ]; then
        return 0
    fi
    if [ "$_DryRun" -eq 0 ]; then
        if [ "$_DoVerify" -eq 0 ]; then
            w2u_die "Diese Aufrufform uebertraegt einstroemig ($_Grund), es gibt also keine Chunk-Buchfuehrung. Zusammen mit --no-verify bliebe KEINE bindende Beweisschicht - der Bericht koennte nur FAIL melden. Entweder --no-verify weglassen, oder parallel uebertragen: $_Weg"
        fi
        if [ -n "$_ExcludeFrom" ]; then
            w2u_die "Diese Aufrufform uebertraegt einstroemig ($_Grund), es gibt also keine Chunk-Buchfuehrung; mit --exclude-from ist zugleich der Dateizahl-Vergleich nur orientierend. Es bliebe keine bindende Beweisschicht, der Lauf endete zwangslaeufig mit FAIL. Parallel uebertragen, dann traegt die Chunk-Buchfuehrung das Urteil auch mit Ausschluessen: $_Weg"
        fi
    fi
    w2u_warn "Diese Aufrufform uebertraegt EINSTROEMIG, nicht parallel: $_Grund. Der Transfer laeuft vollstaendig und wird verifiziert, dauert aber laenger. Weil es ohne Zerlegung keine Chunk-Buchfuehrung gibt, haengt das Urteil allein am Dateizahl-Vergleich - laesst der sich nicht ermitteln, meldet der Bericht FAIL. $_Weg"
}

# Setzt _SrcUrl, _DstDir, _DstRoot und die Optionen.
#
# Zielpfad-Semantik wie bei rsync: der Slash am ENDE DER QUELLE entscheidet,
# nicht der am Ziel.
#
# Die Kombinationspruefungen am Ende sind der eigentliche Inhalt dieser
# Funktion. Die Lehre aus den beiden PASS-Loechern in w2u_report: die Fehler
# entstehen nicht an einzelnen Flaggen, sondern an ihren PRODUKTEN. Deshalb
# steht hier eine ausdrueckliche Regel, wann eine Kombination abgelehnt wird:
#
#   ABGELEHNT wird sie, wenn sie kein tragfaehiges Urteil erzeugen KANN, oder
#   wenn ihre Wirkung dem widerspricht, was der Anwender ausdruecklich verlangt
#   hat (er bekaeme weniger Pruefung, als er angefordert hat, und merkt es nicht).
#   GEWARNT wird, wenn eine Option wirkungslos bleibt, der Lauf aber ehrlich
#   ist - also kein Urteil faellt, das jemanden zum Verschrotten der Quelle
#   verleiten koennte.
#
# Abgelehnt wird beim PARSEN, nicht nach Stunden Arbeit: ein Lauf, der
# strukturell nur FAIL melden kann, darf nicht erst den ganzen Bestand lesen.
w2u_parse_args() {
    local _Pos=0 _Base _Rest _SrcHost _SrcModule _Weg
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --jobs)         w2u_take_arg "$1" "${2-}"; _JobCnt="$_ArgVal"; shift 2 ;;
            --exclude-from) w2u_take_arg "$1" "${2-}"; _ExcludeFrom="$_ArgVal"; shift 2 ;;
            --log-dir)      w2u_take_arg "$1" "${2-}"; _LogDir="$_ArgVal"; shift 2 ;;
            --rsync)        w2u_take_arg "$1" "${2-}"; _RsyncBin="$_ArgVal"; shift 2 ;;
            --verify-only)  _VerifyOnly=1; shift ;;
            --no-verify)    _DoVerify=0; shift ;;
            --checksum)     _DoChecksum=1; shift ;;
            --dry-run)      _DryRun=1; shift ;;
            --version)      printf 'win2unix pull.sh %s\n' "$W2U_VERSION"; exit 0 ;;
            -h|--help)      w2u_usage; exit 0 ;;
            -*)             w2u_die "unbekannte Option: $1" ;;
            *)
                if [ "$_Pos" -eq 0 ]; then
                    _SrcUrl="$1"
                elif [ "$_Pos" -eq 1 ]; then
                    _DstDir="$1"
                else
                    w2u_die "zu viele Argumente: $1"
                fi
                _Pos=$((_Pos + 1))
                shift
                ;;
        esac
    done

    [ -n "$_SrcUrl" ] || { w2u_usage; exit 2; }
    [ -n "$_DstDir" ] || { w2u_usage; exit 2; }
    # Zuerst numerisch pruefen: die Kombinationspruefungen unten rechnen mit
    # _JobCnt, und ein "-eq" auf "abc" waere ein roher Shell-Fehler statt einer
    # Meldung.
    case "$_JobCnt" in
        ''|*[!0-9]*) w2u_die "--jobs braucht eine Zahl, bekam: $_JobCnt" ;;
    esac
    case "$_SrcUrl" in
        rsync://*) : ;;
        *) w2u_die "Quelle muss mit rsync:// beginnen, bekam: $_SrcUrl" ;;
    esac

    # ---- Zielpfad-Semantik wie bei rsync ---------------------------------
    # Doppelte Schraegstriche im PFADTEIL der URL zusammenziehen (das "//" des
    # Schemas bleibt unangetastet). Ohne das wuerde "rsync://h/e//Archiv" den
    # modul-relativen Praefix zu "/Archiv" machen, und die Kuerzung des Ziels
    # ginge nie auf - der Lauf fiele stillschweigend auf einstroemig zurueck.
    # "tr -s" statt einer Muster-Ersetzung: in bash 3.2 landen die
    # Maskierungszeichen aus "${v//\/\//\/}" im Ergebnis (nachgemessen:
    # "rsync://10.0.0.1\/e\"), und eine Falle in der Pfadberechnung ist genau
    # das, was hier NICHT passieren darf.
    _Rest="$(printf '%s' "${_SrcUrl#rsync://}" | tr -s '/')" \
        || w2u_die "Quell-URL nicht normalisierbar: $_SrcUrl"
    _SrcUrl="rsync://$_Rest"
    # Erst die Schraegstriche am ZIEL abschneiden (mehrere sind erlaubt, "/"
    # bleibt "/"), dann anhand der QUELLE entscheiden.
    while [ "$_DstDir" != "/" ] && [ "${_DstDir%/}" != "$_DstDir" ]; do
        _DstDir="${_DstDir%/}"
    done
    case "$_SrcUrl" in
        */)
            # Inhalt direkt ins Ziel. Auch hier koennen mehrere Schraegstriche
            # stehen ("…/Archiv//"), sonst bliebe einer im Pfad stehen und
            # jeder daraus gebaute URL haette einen doppelten.
            while [ "${_SrcUrl%/}" != "$_SrcUrl" ]; do
                _SrcUrl="${_SrcUrl%/}"
            done
            _DstRoot="$_DstDir"
            ;;
        *)
            _Base="$(basename "$_SrcUrl")"
            if [ "$_DstDir" = "/" ]; then
                _DstRoot="/$_Base"
            else
                _DstRoot="$_DstDir/$_Base"
            fi
            ;;
    esac
    # Erst NACH dem Abschneiden pruefbar: "rsync://10.0.0.1/" ist ohne den
    # Schraegstrich nur noch ein Host ohne Modul, und ein Transfer der
    # Daemon-Wurzel gibt es nicht. Ohne diese Pruefung waere _DstRoot
    # "<ziel>/10.0.0.1" und der Lauf liefe erst beim Listing auf.
    case "${_SrcUrl#rsync://}" in
        */*) : ;;
        *)   w2u_die "Quelle braucht Host UND Modul: rsync://<host>/<modul>[/<pfad>], bekam: $_SrcUrl" ;;
    esac

    # ---- Modulwurzel, Praefix, Pfade der parallelen Phase -----------------
    # Siehe die Herleitung im Kopf bei _SrcRoot: die Worker MUESSEN die
    # Modulwurzel als Quelle bekommen, sonst uebertragen sie nichts.
    _Rest="${_SrcUrl#rsync://}"
    _SrcHost="${_Rest%%/*}"
    _Rest="${_Rest#*/}"
    _SrcModule="${_Rest%%/*}"
    case "$_Rest" in
        */*) _SrcPrefix="${_Rest#*/}" ;;
        *)   _SrcPrefix="" ;;
    esac
    _SrcRoot="rsync://$_SrcHost/$_SrcModule"
    _ParSrc="$_SrcRoot"
    # _ParDst ist definiert durch "_ParDst/<praefix> == _DstRoot". Praktisch:
    # _DstRoot von hinten um den Praefix kuerzen. Geht das nicht exakt auf,
    # gibt es KEIN Ziel, in das die modul-relativen Eintraege passen - dann
    # laeuft der Transfer einstroemig ueber den Sweep. Das Anfuehrungszeichen
    # im Muster ist Pflicht: ein Praefix mit *, ? oder [ waere sonst ein Glob.
    if [ -z "$_SrcPrefix" ]; then
        _ParDst="$_DstRoot"
        _ParMode="parallel"
    elif [ "${_DstRoot%"/$_SrcPrefix"}" != "$_DstRoot" ]; then
        _ParDst="${_DstRoot%"/$_SrcPrefix"}"
        [ -n "$_ParDst" ] || _ParDst="/"
        _ParMode="parallel"
    else
        # Der Ratschlag MUSS zur Tiefe des Praefixes passen (Fund in Task 12,
        # gegen einen echten Daemon nachgemessen). Die Regel ist: das Ziel muss
        # auf dem GANZEN modul-relativen Pfad enden, nicht bloss auf dessen
        # letztem Teil. Bei einem Praefix aus EINEM Segment ist beides dasselbe,
        # da stimmt '<ziel>' - nachgemessen. Bei jedem tieferen Praefix ist
        # '<ziel>' aber exakt der Aufruf, der gerade abgelehnt wurde: der
        # Anwender folgte dem Vorschlag und landete wieder einstroemig.
        #
        # Zerlegt per Muster-Ersetzung statt per dirname: pull.sh braucht
        # dirname sonst nirgends, und dirname lieferte fuer ein einsegmentiges
        # Praefix "." - also '<ziel>/.', eine Verschlechterung genau des Falls,
        # der heute korrekt ist.
        case "$_SrcPrefix" in
            */*)
                _Weg="Volle Parallelitaet gibt es, wenn das Ziel auf dem GANZEN modul-relativen Pfad '$_SrcPrefix' endet - der Zwischenpfad gehoert also mit ins Zielverzeichnis: 'pull.sh $_SrcRoot/$_SrcPrefix <ziel>/${_SrcPrefix%/*}'. Dieses Zielverzeichnis muss vorher existieren (mkdir -p)."
                ;;
            *)
                _Weg="Volle Parallelitaet gibt es mit einer Quelle OHNE abschliessenden Schraegstrich, deren letzter Pfadteil das Ziel bildet - z.B. 'pull.sh $_SrcRoot/$_SrcPrefix <ziel>'."
                ;;
        esac
        w2u_einstroemig \
            "das Ziel '$_DstRoot' endet nicht auf '/$_SrcPrefix', die modul-relativen Eintraege passen also in kein Verzeichnis" \
            "$_Weg"
    fi

    # ---- Flag-Kombinationen: ABGELEHNT ------------------------------------
    if [ "$_VerifyOnly" -eq 1 ] && [ "$_DoVerify" -eq 0 ]; then
        # CONTROLLER-RULING 4.1: nachgewiesenes Loch. Der eine Lauf soll NUR
        # pruefen, der andere gar nicht - zusammen bleibt weder
        # Chunk-Buchfuehrung noch Dateizahl-Vergleich, also keine bindende
        # Beweisschicht. w2u_report riegelt das seit Task 8 zusaetzlich ab;
        # hier soll die sinnlose Kombination gar nicht erst starten.
        w2u_die "--verify-only und --no-verify widersprechen sich: der eine Lauf soll NUR pruefen, der andere gar nicht. Uebrig bliebe ein Lauf ohne jede bindende Beweisschicht - der Bericht koennte nur FAIL melden. Eines von beiden weglassen."
    fi
    if [ "$_VerifyOnly" -eq 1 ] && [ -n "$_ExcludeFrom" ]; then
        # CONTROLLER-RULING 5: bei aktiven Ausschluessen ist der
        # Dateizahl-Vergleich nur orientierend und damit nicht bindend; ohne
        # Uebertragung gibt es zugleich keine Chunk-Buchfuehrung. Der Lauf
        # koennte nach der ganzen Pruefzeit nur FAIL melden - und dieses FAIL
        # saegte nichts ueber die Daten aus.
        w2u_die "--verify-only zusammen mit --exclude-from kann kein bindendes Urteil faellen: bei aktiven Ausschluessen sind die Dateizahlen nur orientierend, und ohne Uebertragung gibt es keine Chunk-Buchfuehrung. Der Lauf endete nach der gesamten Pruefzeit zwangslaeufig mit FAIL, ohne etwas ueber die Daten zu sagen. Entweder ohne --exclude-from pruefen, oder einen vollen Lauf fahren - dessen Chunk-Buchfuehrung traegt das Urteil auch mit Ausschluessen."
    fi
    if [ "$_VerifyOnly" -eq 1 ] && [ "$_DryRun" -eq 1 ]; then
        w2u_die "--verify-only und --dry-run sind zwei verschiedene Betriebsarten; eine von beiden wuerde stillschweigend ignoriert. Eines von beiden weglassen."
    fi
    if [ "$_DoVerify" -eq 0 ] && [ "$_DoChecksum" -eq 1 ]; then
        # Nicht bloss nutzlos, sondern irrefuehrend: wer --checksum tippt, will
        # die STAERKSTE Pruefung und bekaeme gar keine.
        w2u_die "--checksum verstaerkt genau die Verifikation, die --no-verify abschaltet - zusammen bewirkt --checksum NICHTS. Wer Byte-Gleichheit belegt haben will, laesst --no-verify weg."
    fi

    # ---- Flag-Kombinationen: nur GEWARNT ----------------------------------
    # Der Unterschied zur Ablehnung oben: ein Trockenlauf faellt kein Urteil
    # und uebertraegt nichts. Niemand kann sich durch ihn zum Verschrotten der
    # Quelle verleiten lassen - deshalb reicht hier der Hinweis.
    if [ "$_DryRun" -eq 1 ]; then
        if [ "$_DoChecksum" -eq 1 ]; then
            w2u_warn "--checksum bleibt im Trockenlauf wirkungslos"
        fi
        if [ "$_DoVerify" -eq 0 ]; then
            w2u_warn "--no-verify bleibt im Trockenlauf wirkungslos"
        fi
        if [ "$_JobCnt" -gt 0 ]; then
            w2u_warn "--jobs bleibt im Trockenlauf wirkungslos - es wird nichts uebertragen"
        fi
    fi
    if [ "$_VerifyOnly" -eq 1 ] && [ "$_JobCnt" -gt 0 ]; then
        w2u_warn "--jobs bleibt im Verify-Only-Lauf wirkungslos - es wird nichts uebertragen"
    fi
    if [ "$_VerifyOnly" -eq 0 ] && [ "$_DryRun" -eq 0 ] && [ "$_DoVerify" -eq 0 ]; then
        w2u_warn "--no-verify: der Vergleich mit der Quelle entfaellt. Ein PASS heisst dann nur noch 'jeder Chunk hat rc 0 gemeldet' - nicht 'Quelle und Ziel sind gleich'."
    fi
}

# Loest einen Pfad zu einem absoluten Pfad OHNE "." und ".." auf, und ohne ihn
# anzulegen. Ergebnis in $_AbsPath, leer wenn nicht aufloesbar.
#
# Warum nicht einfach "cd $_LogDir && pwd -P": das setzt voraus, dass das
# Verzeichnis schon da ist - und genau das Anlegen ist es, was hier erst NACH
# der Pruefung passieren darf (sonst legt ein abgelehntes --log-dir im
# Trockenlauf noch Verzeichnisse an). Rueckgabe ueber eine Variable, aus
# demselben Grund wie bei w2u_take_arg.
#
# REVIEW-FUND, in beide Richtungen reproduziert: den noch nicht existierenden
# Rest einfach LEXIKALISCH anzuhaengen, geht falsch, sobald darin ".." steht.
# "<ziel>/foo/../Archiv/logs" saehe fuer den Vergleich nach "ausserhalb" aus,
# waehrend "mkdir -p" es anschliessend INNERHALB des verglichenen Baums anlegt -
# der Lauf uebertraegt Stunden und faellt am Ende am Dateizahl-Vergleich auf
# FAIL (Ruling 3). Umgekehrt wuerde "<ziel>/Archiv/x/../../aussen" grundlos
# abgelehnt, obwohl es kanonisch draussen liegt. Und ".." ist kein Sonderfall
# fuer Bastler: "--log-dir ../logs" ist der normale Aufruf aus einem
# Arbeitsverzeichnis heraus.
#
# Deshalb wird Segment fuer Segment gelaufen: "." faellt weg, ".." nimmt ein
# Segment zurueck (bis hoechstens zur Wurzel), alles andere wird angehaengt -
# und SOBALD der Zwischenstand wirklich existiert, uebernimmt "cd/pwd -P" die
# Aufloesung. Damit loest das Betriebssystem alles, was es aufloesen kann
# (Symlinks eingeschlossen, genau wie beim spaeteren mkdir), und nur der
# wirklich noch nicht existierende Rest wird rein rechnerisch behandelt.
# Zerlegt wird per Parameter-Expansion statt per IFS-Wortzerlegung: die
# braeuchte "set -f" gegen Glob-Zeichen im Pfad, und eine Funktion darf die
# Shell-Optionen ihres Aufrufers nicht anfassen (Ruling aus Task 6).
w2u_abs_path() {
    local _P="$1" _Rest _Seg _Cur
    _AbsPath=""
    [ -n "$_P" ] || return 0
    case "$_P" in
        /*) : ;;
        *)  _P="$PWD/$_P" ;;
    esac
    _Cur="/"
    _Rest="${_P#/}"
    while [ -n "$_Rest" ]; do
        _Seg="${_Rest%%/*}"
        case "$_Rest" in
            */*) _Rest="${_Rest#*/}" ;;
            *)   _Rest="" ;;
        esac
        case "$_Seg" in
            ''|.)
                continue
                ;;
            ..)
                _Cur="${_Cur%/*}"
                [ -n "$_Cur" ] || _Cur="/"
                ;;
            *)
                if [ "$_Cur" = "/" ]; then
                    _Cur="/$_Seg"
                else
                    _Cur="$_Cur/$_Seg"
                fi
                ;;
        esac
        if [ -d "$_Cur" ]; then
            _Cur="$(cd "$_Cur" 2>/dev/null && pwd -P)" || _Cur=""
            if [ -z "$_Cur" ]; then
                return 0
            fi
        fi
    done
    _AbsPath="$_Cur"
    return 0
}

# Preflight (Spec 5.2). Alles, was den Lauf strukturell unmoeglich macht, wird
# HIER laut - nicht nach der ersten Stunde Uebertragung.
w2u_preflight() {
    local _Version _VersionAll _Nl _LogAbs _DstAbs _Rc=0
    w2u_find_rsync
    # KEIN "| head -1" (nachgemessen, sonst stirbt hier JEDER Lauf): head
    # schliesst die Pipe nach der ersten Zeile, GNU rsync 3.5 schreibt aber
    # noch viele weitere und bekommt dafuer SIGPIPE. Unter dem "pipefail" aus
    # main() ist damit die ganze Zuweisung rc 141, unter errexit endet der Lauf
    # - vor der ersten Ausgabezeile, also voellig stumm. Dieselbe Falle ist in
    # tests/lib/daemon.sh dokumentiert; die Loesung ist dieselbe: einmal
    # vollstaendig einlesen, danach ohne Pipe schneiden.
    _Nl="
"
    _VersionAll="$("$_RsyncBin" --version 2>&1)" || _VersionAll=""
    _Version="${_VersionAll%%"$_Nl"*}"
    w2u_log "rsync: $_RsyncBin ($_Version)"
    case "$_Version" in
        *openrsync*) w2u_log "openrsync erkannt - kein --info=progress2, kein --iconv (beides unkritisch)" ;;
    esac

    [ -d "$_DstDir" ] || w2u_die "Zielverzeichnis existiert nicht: $_DstDir"
    # Schreibrecht nur verlangen, wo auch geschrieben wird: ein --verify-only
    # gegen ein schreibgeschuetzt gemountetes Archiv ist ein voellig
    # legitimer Anwendungsfall und darf nicht an dieser Pruefung sterben.
    if [ "$_VerifyOnly" -eq 0 ]; then
        [ -w "$_DstDir" ] || w2u_die "Zielverzeichnis nicht beschreibbar: $_DstDir"
    fi
    [ -z "$_ExcludeFrom" ] || [ -r "$_ExcludeFrom" ] || w2u_die "Ausschlussdatei nicht lesbar: $_ExcludeFrom"

    "$_RsyncBin" --list-only -d "$_SrcUrl/" >/dev/null 2>&1 \
        || w2u_die "Quelle nicht erreichbar: $_SrcUrl (laeuft START-RSYNC-SERVER.cmd? Port 873 offen?)"

    # CONTROLLER-RULING: verankerte Ausschlussmuster werden ABGELEHNT, nicht
    # umgeschrieben.
    #
    # Ausschluesse gelten relativ zur WURZEL DES TRANSFERS. Die ist seit dem
    # Modulwurzel-Fix in der parallelen Phase $_ParSrc, in Sweep und Verify
    # dagegen $_SrcUrl - ein "/Bild" meint also zwei verschiedene Stellen,
    # sobald ein modul-relativer Praefix im Spiel ist. Nur der FUEHRENDE
    # Schraegstrich ist davon betroffen: er verankert an der Transferwurzel.
    # Muster ohne ihn ("*.tmp", "Bild/x") vergleicht rsync gegen das Ende des
    # Pfades und sind damit von der Wurzel unabhaengig.
    #
    # Warum ablehnen statt umschreiben: eine Umschreibung ("/X" -> "/praefix/X")
    # muesste die ganze Filtersyntax treffen (+/- Regeln, Negationen,
    # Verzeichnis-Schraegstriche). Trifft sie daneben, schliesst der Lauf MEHR
    # aus als gewollt - und das ist Datenverlust in einem Werkzeug, dessen
    # Quelle danach verschrottet wird, mit dem Fehlerbild "eine Datei fehlt".
    # Ein abgelehnter Lauf kostet eine Minute.
    #
    # Ohne Praefix (Quelle IST die Modulwurzel) sind verankerte Muster
    # eindeutig - beide Wurzeln sind dieselbe - und bleiben erlaubt. Ebenso im
    # Verify-Only-Lauf: dort laeuft keine parallele Phase, es gibt also nur
    # eine Wurzel.
    if [ -n "$_ExcludeFrom" ] && [ -n "$_SrcPrefix" ] \
       && [ "$_ParMode" = "parallel" ] && [ "$_VerifyOnly" -eq 0 ]; then
        _Rc=0
        # Kommentare (# oder ;), Leerzeilen und CRLF-Enden sind KEINE Muster -
        # eine Ausschlussdatei mit "# /Bild" darf keinen Lauf kosten. Die
        # beiden Kommentar-Zeilen unten koennen bei DIESER Pruefung nicht
        # zuschlagen (was mit "#" beginnt, beginnt nicht mit "/") - sie stehen
        # als Riegel fuer jeden, der die Erkennung spaeter lockert; eine
        # naivere Form ("steht irgendwo ein Schraegstrich?") laege sofort
        # falsch, und der zugehoerige Test faengt genau das ab.
        # Keine Intervall-Quantoren: BSD-awk kann sie nicht.
        awk '
            {
                sub(/\r$/, "")
                _L = $0
                sub(/^[ \t]+/, "", _L)
                if (_L == "") { next }
                if (_L ~ /^[#;]/) { next }
                sub(/^[-+][ \t]*/, "", _L)
                if (_L ~ /^\//) { _N++ }
            }
            END { exit (_N > 0 ? 0 : 1) }
        ' "$_ExcludeFrom" || _Rc=$?
        if [ "$_Rc" -eq 0 ] && [ "$_DryRun" -eq 1 ]; then
            # Eigene Regel, gleiche Begruendung wie bei den Flag-Kombinationen:
            # ein Trockenlauf uebertraegt nichts und faellt kein Urteil, also
            # warnt er, statt abzulehnen.
            w2u_warn "In $_ExcludeFrom stehen VERANKERTE Muster (mit fuehrendem Schraegstrich); ein echter Lauf mit dieser Quelle wuerde deshalb abgelehnt."
        elif [ "$_Rc" -eq 0 ]; then
            w2u_die "In $_ExcludeFrom stehen VERANKERTE Muster (mit fuehrendem Schraegstrich), und die Quelle hat den modul-relativen Praefix '$_SrcPrefix'. Ein '/xyz' meint in der parallelen Phase (Wurzel $_ParSrc) etwas anderes als in Sweep und Verify (Wurzel $_SrcUrl) - ausgeschlossen wuerde je nach Phase Verschiedenes. Zwei Auswege: die Muster OHNE fuehrenden Schraegstrich schreiben (dann gelten sie ueberall gleich), oder gegen die Modulwurzel laufen ('pull.sh $_SrcRoot <ziel>'), wo der Anker eindeutig ist. Umgeschrieben wird hier bewusst nichts: ein daneben getroffenes Muster schliesst zu viel aus, und das faellt erst auf, wenn die Quelle schon verschrottet ist."
        elif [ "$_Rc" -ne 1 ]; then
            w2u_die "Ausschlussdatei $_ExcludeFrom nicht auswertbar (awk rc $_Rc)"
        fi
    fi

    if [ "$_VerifyOnly" -eq 1 ]; then
        # Ohne Zielbaum gibt es nichts zu vergleichen. Der Lauf wuerde sonst
        # die volle Pruefzeit brauchen und am Ende "remote N / lokal 0" melden -
        # richtig, aber teuer erkauft.
        [ -d "$_DstRoot" ] || w2u_die "--verify-only, aber am Ziel gibt es nichts zu pruefen: $_DstRoot existiert nicht"
    fi
    # ---- Logverzeichnis ---------------------------------------------------
    # CONTROLLER-RULING 3: $_LogDir darf NICHT unterhalb von $_DstRoot liegen.
    # Der Bericht vergleicht die Zahl regulaerer Dateien remote gegen lokal;
    # Logdateien im verglichenen Baum sind lokale Dateien ohne Gegenstueck auf
    # der Quelle, und JEDER vollstaendige Lauf fiele falsch auf FAIL. Die
    # Vorgabe ist deshalb ein eigenes Verzeichnis ausserhalb des verglichenen
    # Baums - und ausserhalb von $_TmpDir, damit die Logs den Lauf ueberleben
    # und die FAIL-Zeile des Berichts auf ein existierendes Verzeichnis zeigt.
    #
    # Reihenfolge (Review-Fund): GEPRUEFT WIRD, BEVOR ANGELEGT WIRD. Ein
    # "mkdir -p" auf ein abgelehntes --log-dir im Zielbaum legte als
    # Nebenwirkung auch $_DstRoot an - ausgerechnet im Trockenlauf, der nichts
    # anlegen darf, und beide Verzeichnisse blieben liegen (ein fremdes
    # Logverzeichnis raeumt w2u_cleanup zu Recht nie weg).
    if [ -z "$_LogDir" ]; then
        _LogDir="$(mktemp -d "${TMPDIR:-/tmp}/win2unix-logs.XXXXXXXX")" \
            || w2u_die "Logverzeichnis nicht anlegbar"
        _LogDirOwned=1
    fi
    # Auch ein selbst angegebenes Logverzeichnis muss draussen bleiben. Der
    # Ausschluss in w2u_count_local schuetzt nur den LAUFENDEN Lauf: ein
    # spaeterer Lauf mit anderem Logverzeichnis zaehlt diese Dateien mit und
    # faellt falsch auf FAIL. Verglichen werden AUFGELOESTE Pfade (sonst
    # entkaeme jede relative Schreibweise der Pruefung) - und aufgeloest wird
    # ohne anzulegen, siehe w2u_abs_path.
    w2u_abs_path "$_LogDir"; _LogAbs="$_AbsPath"
    w2u_abs_path "$_DstRoot"; _DstAbs="$_AbsPath"
    if [ -n "$_LogAbs" ] && [ -n "$_DstAbs" ]; then
        case "$_LogAbs/" in
            "$_DstAbs"/*)
                w2u_die "--log-dir liegt im Zielbaum ($_LogAbs unter $_DstAbs): die Logdateien wuerden als lokale Dateien mitgezaehlt, und ein spaeterer Lauf faellt dadurch falsch auf FAIL. Logverzeichnis ausserhalb des Ziels waehlen."
                ;;
        esac
    fi
    if [ "$_LogDirOwned" -eq 0 ]; then
        mkdir -p "$_LogDir" || w2u_die "Logverzeichnis nicht anlegbar: $_LogDir"
    fi
    # "mkdir -p" liefert 0 fuer ein bereits existierendes Verzeichnis, auch fuer
    # ein schreibgeschuetztes. Ohne diese Zeile stuerbe der Lauf erst spaeter an
    # einer fehlgeschlagenen Umleitung, und die Diagnose zeigte auf rsync statt
    # auf das Logverzeichnis.
    [ -w "$_LogDir" ] || w2u_die "Logverzeichnis nicht beschreibbar: $_LogDir"
    w2u_log "Logs: $_LogDir"

    # Angelegt wird nur, wenn wirklich uebertragen wird: ein Trockenlauf, der
    # Verzeichnisse anlegt, ist kein Trockenlauf.
    if [ "$_VerifyOnly" -eq 0 ] && [ "$_DryRun" -eq 0 ]; then
        mkdir -p "$_DstRoot"
        # _ParDst ist per Konstruktion ein VORFAHRE von _DstRoot - bei der
        # Schraegstrich-Form kann das ein Verzeichnis sein, das der Anwender nie
        # genannt hat und das die Pruefung oben nie gesehen hat. Dorthin
        # schreiben die Worker. Was nicht beschreibbar ist, wird nicht
        # stillschweigend versucht: dann laeuft der Transfer einstroemig, und
        # der Anwender erfaehrt es.
        if [ "$_ParMode" = "parallel" ]; then
            if [ ! -d "$_ParDst" ] || [ ! -w "$_ParDst" ]; then
                w2u_einstroemig \
                    "das Ziel der parallelen Phase '$_ParDst' (der Teil von '$_DstRoot' oberhalb von '$_SrcPrefix') ist nicht beschreibbar" \
                    "Der Zielpfad selbst stimmt bereits - es fehlen die Rechte: entweder '$_ParDst' beschreibbar machen, oder ein Ziel waehlen, dessen entsprechender Vorfahre beschreibbar ist."
            fi
        fi
    fi

}

# Fuehrt den Vergleichslauf aus und haelt sein Ergebnis fuer den Bericht fest.
#
# CONTROLLER-RULING 2: der Ausgang darf NICHT mit "|| true" verworfen werden,
# sonst druckt w2u_report ein PASS, nachdem der Verify Befunde ausgegeben hat.
# Geprueft werden BEIDE Formen - der rc UND die Ausgabe. w2u_verify meldet
# Befunde ueber beides; wer nur eine Form prueft, verliert die andere, sobald
# jemand an w2u_verify schraubt. Genau dieses Produkt zweier je einzeln
# gepruefter Formen war die Fehlerklasse der Tasks 7 und 8.
w2u_verify_step() {
    local _Rc=0
    w2u_log "Verifikation (Vergleichslauf gegen die Quelle)"
    w2u_verify > "$_LogDir/verify.log" 2>&1 || _Rc=$?
    if [ "$_Rc" -ne 0 ] || [ -s "$_LogDir/verify.log" ]; then
        _VerifyState="befunde"
        w2u_warn "Verify meldet Abweichungen (rc $_Rc), erste Zeilen:"
        head -50 "$_LogDir/verify.log" >&2
    else
        _VerifyState="sauber"
    fi
}

# Aufraeumen am Ende JEDES Weges aus main() heraus - auch aus w2u_die, auch
# nach einem Signal.
#
# Das Arbeitsverzeichnis geht immer, es enthaelt nur Zwischenstaende. Das
# Logverzeichnis nur dann, wenn WIR es angelegt haben UND der Lauf sauber war:
# nach einem FAIL sind die Logs die einzige Spur, warum, und der Bericht nennt
# genau diesen Pfad. Ein per --log-dir angegebenes Verzeichnis wird nie
# geloescht - es koennte auf alles Moegliche zeigen.
w2u_cleanup() {
    local _Rc=$? _LogEmpty=0
    if [ -n "$_TmpDir" ] && [ -d "$_TmpDir" ]; then
        rm -rf "$_TmpDir"
    fi
    if [ -n "$_LogDir" ] && [ -d "$_LogDir" ]; then
        if [ -z "$(ls -A "$_LogDir" 2>/dev/null)" ]; then
            _LogEmpty=1
        fi
        # Ein LEERES eigenes Logverzeichnis geht auch nach einem Fehlschlag:
        # scheitert der Lauf vor der ersten Uebertragung (Listing der Quelle
        # bricht ab), bliebe sonst bei jedem Versuch ein leeres Verzeichnis
        # zurueck, und die Meldung verspraeche Logs, die es nicht gibt.
        if [ "$_LogDirOwned" -eq 1 ] && { [ "$_Rc" -eq 0 ] || [ "$_LogEmpty" -eq 1 ]; }; then
            rm -rf "$_LogDir"
        else
            printf '[%s] Logs bleiben liegen: %s\n' "$(date '+%H:%M:%S')" "$_LogDir" >&2
        fi
    fi
    return "$_Rc"
}

# Abbruch von aussen. Der Lauf ist an jeder Stelle wiederaufnehmbar - rsync
# holt beim naechsten Mal nur, was fehlt -, deshalb ist hier nichts zu retten,
# sondern nur aufzuraeumen und das klar zu sagen.
#
# Die Kinder gehoeren zur Prozessgruppe dieses Skripts: ein Ctrl-C am Terminal
# erreicht sie damit ohnehin selbst. Wird dagegen gezielt nur diesem Prozess ein
# TERM geschickt, laeuft der Rest weiter - "pkill -P $$" beendet dann die
# DIREKTEN Kinder, also den laufenden xargs; dessen eigene rsync-Kinder erreicht
# es nicht, die beendet xargs beim Sterben oder sie laufen ihren Chunk zu Ende.
# ANNAHME: pkill existiert (BSD und Linux haben es); fehlt es, bleibt es beim
# Aufraeumen. WAS SIE BRICHT: ein Vordergrund-Kind laeuft noch, waehrend das
# Signal kommt - bash fuehrt den Trap erst danach aus, dann ist das Kind
# bereits fertig.
w2u_on_signal() {
    w2u_warn "abgebrochen - derselbe Aufruf setzt fort, bereits uebertragene Dateien bleiben liegen"
    if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P $$ >/dev/null 2>&1 || true
    fi
    exit 130
}

main() {
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        w2u_usage
        exit 2
    fi
    local _Rc=0 _Cnt=0
    _StartTs="$(date +%s)"
    w2u_parse_args "$@"

    # CONTROLLER-RULING (Task 7): $_TmpDir kommt aus mktemp -d und liegt damit
    # auf einem LOKALEN Dateisystem. Das ist keine Bequemlichkeit: $_ResultFile
    # wird gleich von bis zu _PMax Prozessen gleichzeitig per ">>" beschrieben,
    # und die Messung dazu (32 Schreiber, 116.000 Zeilen, kein Verlust) gilt
    # nur lokal. Das ZIEL dieses Werkzeugs ist oft ein SMB-/NFS-Mount, auf dem
    # sie nicht gilt - eine zerrissene Zeile dort waere ein fehlgeschlagener
    # Chunk, den niemand mehr sieht. Die Ergebnisdatei gehoert deshalb NIE
    # unter $_DstRoot, auch nicht "zu den Logs".
    _TmpDir="$(mktemp -d "${TMPDIR:-/tmp}/win2unix.XXXXXXXX")"
    trap 'w2u_cleanup' EXIT
    trap 'w2u_on_signal' INT TERM

    w2u_preflight

    _ResultFile="$_TmpDir/results"
    # CONTROLLER-RULING 4.2/4.3: in JEDEM Modus, auch in --verify-only.
    # w2u_report stuft eine FEHLENDE Ergebnisdatei als Defekt ein (richtig so -
    # sie ist die einzige Spur eines fehlgeschlagenen Chunks); ohne diese Zeile
    # fiele jeder Verify-Only-Lauf falsch auf FAIL. Das ">" leert sie zugleich:
    # Reste aus einem frueheren Lauf waeren fremde Namen im Abgleich.
    : > "$_ResultFile"

    if [ "$_VerifyOnly" -eq 1 ]; then
        w2u_log "nur Verifikation - es wird nichts uebertragen"
        w2u_verify_step
        _Rc=0
        w2u_report || _Rc=$?
        exit "$_Rc"
    fi

    if [ "$_ParMode" = "parallel" ]; then
        w2u_log "zerlege $_SrcUrl"
        w2u_decompose "$_SrcUrl" $((_ThresholdFactor * _PMax)) "$_TmpDir/work"

        if [ "$_DryRun" -eq 1 ]; then
            # grep -c liefert rc 1 bei null Treffern - unter errexit waere das
            # das Ende des Laufs, obwohl "keine Arbeitspakete" hier eine Aussage
            # ist und kein Fehler. rc>1 (Datei unlesbar) bleibt ein Fehler.
            _Cnt="$(grep -c . "$_TmpDir/work")" || [ $? -eq 1 ] || w2u_die "Arbeitsdatei nicht lesbar: $_TmpDir/work"
            w2u_log "dry-run: $_Cnt Arbeitspakete, nichts uebertragen"
            head -20 "$_TmpDir/work"
            exit 0
        fi

        # Die Arbeitspakete stehen relativ zu $_SrcUrl - die Worker uebertragen
        # aber von der MODULWURZEL aus, weil --files-from gegen einen Daemon nur
        # so funktioniert (Herleitung im Kopf bei _SrcRoot). Deshalb bekommt
        # jede Zeile hier den modul-relativen Praefix davor. Bewusst an DIESER
        # Stelle und nicht in w2u_decompose: die Zerlegung bleibt damit das, was
        # sie ist (eine Liste relativ zur angeforderten Quelle), und ihre
        # Vollstaendigkeits-Tests messen weiter dasselbe.
        if [ -n "$_SrcPrefix" ]; then
            awk -v _P="$_SrcPrefix/" 'length($0) > 0 { print _P $0 }' "$_TmpDir/work" > "$_TmpDir/work.par" \
                || w2u_die "Arbeitsliste konnte nicht auf modul-relative Pfade umgestellt werden"
        else
            cp "$_TmpDir/work" "$_TmpDir/work.par" \
                || w2u_die "Arbeitsliste konnte nicht kopiert werden"
        fi

        mkdir -p "$_TmpDir/chunks"
        w2u_chunk "$_TmpDir/work.par" "$_TmpDir/chunks" "$_PMax" "$_TmpDir/chunks.list"
        w2u_log "parallele Phase: $_ParSrc/ -> $_ParDst/ (Praefix '${_SrcPrefix:-<keiner>}')"
        w2u_run_all "$_TmpDir/chunks.list"
    else
        # Einstroemig: kein Zerlegen, keine Chunks, keine Buchfuehrung - der
        # Sweep unten macht die ganze Arbeit. Beim Parsen ist das bereits
        # angesagt worden; hier steht es noch einmal an der Stelle, an der es
        # tatsaechlich passiert.
        if [ "$_DryRun" -eq 1 ]; then
            w2u_log "dry-run: einstroemige Aufrufform - es wuerde in EINEM rsync-Lauf uebertragen ($_SrcUrl/ -> $_DstRoot/), ohne Zerlegung"
            exit 0
        fi
        w2u_log "einstroemige Uebertragung (keine Zerlegung, keine Chunk-Buchfuehrung) - der Vergleichslauf urteilt"
    fi

    w2u_log "Sweep-Pass"
    _Rc=0
    w2u_sweep >> "$_LogDir/sweep.log" 2>&1 || _Rc=$?
    if [ "$_Rc" -ne 0 ]; then
        # Der Sweep ist Reparatur, kein Beweis - sein rc darf den Lauf nicht
        # abbrechen. Urteilen tun Verify und Bericht.
        w2u_warn "Sweep meldete rc $_Rc, siehe $_LogDir/sweep.log"
    fi

    if [ "$_DoVerify" -eq 1 ]; then
        w2u_verify_step
    fi

    _Rc=0
    w2u_report || _Rc=$?
    exit "$_Rc"
}

[ "${W2U_LIB_ONLY:-0}" = "1" ] || main "$@"
