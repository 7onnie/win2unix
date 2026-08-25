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
_TmpDir=""
_ResultFile=""
_StartTs=0

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
  --exclude-from DATEI
  --log-dir PFAD
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

    local _Args
    _Args=( -rlt -W --partial --numeric-ids --stats "--timeout=$_RsyncTimeout" )
    [ -n "$_ExcludeFrom" ] && _Args=( "${_Args[@]}" "--exclude-from=$_ExcludeFrom" )
    _Args=( "${_Args[@]}" "--files-from=$_ChunkFile" )

    while [ "$_Try" -le "$_MaxRetry" ]; do
        _Rc=0
        "$_RsyncBin" "${_Args[@]}" "$_SrcUrl/" "$_DstRoot/" > "$_LogDir/$_Name.$_Try.log" 2>&1 || _Rc=$?
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
# "${BASH:-bash}": das Umgebungsformat von "export -f" unterscheidet sich
# zwischen bash 3.2 (Apple) und 4.3+ (Homebrew). Startete ein Skript unter
# Homebrew-bash seine Worker mit /bin/bash, importierte das Kind die Funktionen
# nicht und kein einziger Chunk wuerde uebertragen. $BASH ist derselbe
# Interpreter wie der laufende und laesst die Frage nicht aufkommen.
w2u_run_list() {
    local _ListFile="$1" _Jobs="$2" _Rc=0 _Missing="" _MissCnt=0 _Done=""
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

    export _RsyncBin _SrcUrl _DstRoot _LogDir _ResultFile _MaxRetry _RetryPause _ExcludeFrom _RsyncTimeout
    export -f w2u_run_chunk w2u_die w2u_log
    xargs -P "$_Jobs" -S 4096 -I {} "${BASH:-bash}" -c 'w2u_run_chunk "$1"' _ {} < "$_ListFile" || _Rc=$?
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

main() {
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        w2u_usage
        exit 2
    fi
    w2u_die "noch nicht implementiert"
}

[ "${W2U_LIB_ONLY:-0}" = "1" ] || main "$@"
