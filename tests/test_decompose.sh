#!/usr/bin/env bash
set -uo pipefail
_Here="$(cd "$(dirname "$0")" && pwd)"
_Root="$(cd "$_Here/.." && pwd)"
. "$_Here/lib/testlib.sh"
. "$_Here/lib/daemon.sh"
W2U_LIB_ONLY=1 . "$_Root/pull.sh"

if ! d_available; then
    t_skip "kein daemon-faehiges rsync"
    t_summary
fi

_Src="$(mktemp -d)"
_TmpDir="$(mktemp -d)"
# chmod vor dem rm: der Fall-C-Test sperrt ein Verzeichnis mit "chmod 000",
# und "rm -rf" kann dessen Inhalt dann nicht loeschen - der Baum bliebe liegen.
trap 'd_stop; chmod -R u+rwx "$_Src" 2>/dev/null; rm -rf "$_Src" "$_TmpDir"' EXIT

# Fall A nachgebaut: viele Ordner auf Ebene 1, Dateien direkt darunter,
# ZUSAETZLICH zwei Dateien direkt in der Wurzel (Spec 2.4).
mkdir -p "$_Src/fallA"
_I=1
while [ "$_I" -le 40 ]; do
    mkdir -p "$_Src/fallA/ordner$_I"
    echo "inhalt$_I" > "$_Src/fallA/ordner$_I/datei.doc"
    _I=$((_I + 1))
done
echo wurzeldatei > "$_Src/fallA/direkt.txt"
mkdir -p "$_Src/fallA/leer_ordner"

# Fall B nachgebaut: EIN Ordner auf Ebene 1, viele auf Ebene 2.
mkdir -p "$_Src/fallB/Bildarchiv"
_I=1
while [ "$_I" -le 40 ]; do
    mkdir -p "$_Src/fallB/Bildarchiv/patient$_I/tag"
    echo "bild$_I" > "$_Src/fallB/Bildarchiv/patient$_I/tag/b.jpg"
    _I=$((_I + 1))
done
echo direkt > "$_Src/fallB/Bildarchiv/direkt_datei.txt"
# Ein Patientenordner bekommt Leerzeichen UND Umlaut im Namen. Er liegt auf
# Ebene 2, laeuft also durch "_Path=$_Rel/$_Name", durch $_Next -> $_Cur, durch
# den Schluss-Flush und durch den Roundtrip ueber die Arbeitsliste. Bewusst
# anzahl-neutral (Umbenennung statt Zusatzeintrag), damit der vom Brief
# vorgegebene Count-Assert von 41 unveraendert gilt.
mv "$_Src/fallB/Bildarchiv/patient7" "$_Src/fallB/Bildarchiv/patient 7 Müller"
echo befund > "$_Src/fallB/Bildarchiv/patient 7 Müller/Befund Ä.txt"

# Fall E: eine Ebene OHNE Unterordner - trifft den _AnyDir=0-Zweig.
# Ohne dieses Fixture wird der Zweig von keinem Test erreicht (Fall A bricht in
# Iteration 2 auf der Schwelle ab, Fall B in 3, Fall D in 4, Fall C stirbt,
# Schwelle-1 stirbt vor der Schleife). Fehlerbild ohne die Trunkierung dort:
# "x" bliebe in $_Cur und wuerde ZUSAETZLICH zu seinen eigenen Dateien
# Arbeitspaket - Doppeluebertragung, vom Mengenvergleich nicht erkennbar.
mkdir -p "$_Src/fallE/x"
echo e1 > "$_Src/fallE/x/datei1.txt"
echo e2 > "$_Src/fallE/x/datei2.txt"
echo e3 > "$_Src/fallE/x/datei3.txt"
echo wurzel > "$_Src/fallE/wurzel.txt"

# Fall F: pathologische Dateinamen (Brief-Anforderung).
# Traegt zwei verschiedene Dinge:
#  - Leerzeichen und Umlaute in Datei- UND Ordnernamen
#  - fuehrendes bzw. nachgestelltes Leerzeichen: NUR daran unterscheidet sich
#    IFS="$_Tab" vom Standard-IFS. Bei zwei Variablen wuerde "read -r _Type
#    _Name" den Rest auch unter Standard-IFS komplett zuweisen, INTERNE
#    Leerzeichen pinnen die IFS-Wahl also gerade nicht.
mkdir -p "$_Src/fallF/Ebene 1 Ordner/Ünter Ordner Ä"
echo tief > "$_Src/fallF/Ebene 1 Ordner/Ünter Ordner Ä/tief ö.txt"
echo f1 > "$_Src/fallF/ fuehrend.txt"
# Echtes NACHGESTELLTES Leerzeichen (am Zeilenende), nicht bloss ein internes:
# ein interner Leerraum ueberlebt auch unter Standard-IFS und unterscheidet die
# IFS-Wahl deshalb gar nicht. Nur fuehrender bzw. nachgestellter Leerraum tut es.
echo f2 > "$_Src/fallF/nachgestellt.txt "

# Fall D: ein LEERER Ordner, der tatsaechlich EXPANDIERT wird.
# Notwendig, weil "leer_ordner" aus Fall A auf Ebene 1 liegt und dort nur
# gelistet, nie expandiert wird - die Leerordner-Behandlung in w2u_decompose
# waere durch Fall A und B gar nicht abgedeckt. Form: eine schmale Ebene 1
# erzwingt den Abstieg, auf Ebene 2 liegt der leere Ordner und wird expandiert;
# sein Listing ist leer, also MUSS er selbst Arbeitspaket werden, sonst faellt
# er lautlos aus dem Zielbaum.
mkdir -p "$_Src/fallD/a/leer"
_I=1
while [ "$_I" -le 40 ]; do
    mkdir -p "$_Src/fallD/a/b/c$_I"
    echo "x$_I" > "$_Src/fallD/a/b/c$_I/datei.txt"
    _I=$((_I + 1))
done

# Fall C: ein Verzeichnis MITTEN im Baum wird unlesbar gemacht (CONTROLLER-RULING 2).
# "vorne.txt" liegt davor in der Wurzel, damit nachweisbar ist, dass der Abbruch
# MITTEN in der Zerlegung passiert und nicht schon vor dem ersten Listing.
mkdir -p "$_Src/fallC/gesperrt/tief"
echo geheim > "$_Src/fallC/gesperrt/tief/verloren.txt"
echo vorne > "$_Src/fallC/vorne.txt"

if ! d_start "$_Src"; then
    t_skip "rsync-Daemon konnte auf keinem der versuchten Ports binden - Test wird uebersprungen statt gegen den falschen Daemon zu laufen"
    t_summary
fi
w2u_find_rsync

# --- Fall A: darf NICHT tiefer als Ebene 1 gehen ---
w2u_decompose "$D_Url/fallA" 32 "$_TmpDir/workA"
_CntA="$(grep -c . "$_TmpDir/workA")"
t_assert_eq "42" "$_CntA" "Fall A: 40 Ordner + direkte Datei + leerer Ordner"
t_assert_contains "$(cat "$_TmpDir/workA")" "direkt.txt" "Fall A: Datei direkt in der Wurzel ist Arbeitspaket"
t_assert_contains "$(cat "$_TmpDir/workA")" "leer_ordner" "Fall A: leerer Ordner ist Arbeitspaket"
t_assert_eq "0" "$(grep -c '/' "$_TmpDir/workA")" "Fall A: keine Expansion auf Ebene 2"

# --- Fall B: MUSS auf Ebene 2 absteigen ---
w2u_decompose "$D_Url/fallB" 32 "$_TmpDir/workB"
_CntB="$(grep -c . "$_TmpDir/workB")"
t_assert_eq "41" "$_CntB" "Fall B: 40 Patientenordner + direkte Datei auf Ebene 2"
t_assert_contains "$(cat "$_TmpDir/workB")" "Bildarchiv/direkt_datei.txt" "Fall B: Datei im expandierten Ordner geht nicht verloren"
t_assert_contains "$(cat "$_TmpDir/workB")" "Bildarchiv/patient1" "Fall B: Ebene-2-Ordner sind Arbeitspakete"

# --- Vollstaendigkeits-Beweis (CONTROLLER-RULING 1) ---
# Arbeitspakete sind "Bildarchiv/patientN" - "Bildarchiv" selbst ist KEIN
# Arbeitspaket, sondern wird von rsync implizit angelegt (Spec 2.6). Die
# Vereinigung muss deshalb gegen "Arbeitspakete + deren Unterbaeume + deren
# implizite Elternverzeichnisse" gebildet werden.
#
# Derselbe Beweis wird fuer BEIDE gemessenen Baumformen gefuehrt: Fall A ist die
# Form, die den LEEREN Ordner enthaelt - genau den Fehlerfall, gegen den dieser
# Task existiert. Ihn nur per t_assert_contains zu pruefen waere zu schwach.
#
# ★ GRENZE DIESES BEWEISES - die Count-Asserts sind KEINE Redundanz.
# Der Mengenvergleich erkennt nur UNTERdeckung. "sort -u" normalisiert
# UEBERdeckung weg: ein doppeltes Arbeitspaket, oder eines fuer ein Verzeichnis,
# das ein Vorfahr ohnehin schon abdeckt, liefert exakt dieselbe Menge und laesst
# den Assert gruen - waehrend rsync die betroffenen Dateien doppelt uebertraegt.
# Duplikatfreiheit haengt deshalb allein an _CntA/_CntB/_CntD/_CntE/_CntF.
# Diese Count-Asserts NICHT als "sagt der Union-Beweis doch auch" streichen, und
# jedes neue Fixture bekommt seinen eigenen exakten Count-Assert.
t_union_proof() {
    local _TreeRoot="$1" _WorkFile="$2"
    local _P _Parent
    cd "$_TreeRoot" || return 1
    while IFS= read -r _P; do
        printf '%s\n' "$_P"
        [ -d "$_P" ] && find "$_P" -mindepth 1 | sed 's|^\./||'
        _Parent="$(dirname "$_P")"
        while [ "$_Parent" != "." ] && [ "$_Parent" != "/" ]; do
            printf '%s\n' "$_Parent"
            _Parent="$(dirname "$_Parent")"
        done
    done < "$_WorkFile" | sort -u
}

_Expected="$(cd "$_Src/fallA" && find . -mindepth 1 | sed 's|^\./||' | sort)"
_Actual="$(t_union_proof "$_Src/fallA" "$_TmpDir/workA")"
t_assert_eq "$_Expected" "$_Actual" "Fall A: Arbeitspakete plus implizite Eltern ueberdecken den Baum exakt (inkl. leerem Ordner)"

_Expected="$(cd "$_Src/fallB" && find . -mindepth 1 | sed 's|^\./||' | sort)"
_Actual="$(t_union_proof "$_Src/fallB" "$_TmpDir/workB")"
t_assert_eq "$_Expected" "$_Actual" "Fall B: Arbeitspakete plus implizite Eltern ueberdecken den Baum exakt"

# --- Fall D: ein EXPANDIERTER leerer Ordner darf nicht verschwinden ---
w2u_decompose "$D_Url/fallD" 32 "$_TmpDir/workD"
_CntD="$(grep -c . "$_TmpDir/workD")"
t_assert_eq "41" "$_CntD" "Fall D: 40 Ordner auf Ebene 3 + der expandierte leere Ordner"
t_assert_contains "$(cat "$_TmpDir/workD")" "a/leer" "Fall D: expandierter leerer Ordner bleibt Arbeitspaket"
_Expected="$(cd "$_Src/fallD" && find . -mindepth 1 | sed 's|^\./||' | sort)"
_Actual="$(t_union_proof "$_Src/fallD" "$_TmpDir/workD")"
t_assert_eq "$_Expected" "$_Actual" "Fall D: Arbeitspakete plus implizite Eltern ueberdecken den Baum exakt (expandierter Leerordner)"

# --- Fall E: Ebene ohne Unterordner (_AnyDir=0-Zweig) ---
# Der Count-Assert ist hier der eigentliche Test: faellt die Trunkierung von
# $_Cur weg, steht "x" zusaetzlich zu seinen drei Dateien in der Liste (5 statt
# 4) und alle drei Dateien werden doppelt uebertragen. Der Mengenvergleich
# darunter bleibt dabei GRUEN - "x" deckt genau seine eigenen Dateien ab, und
# "sort -u" macht aus der Ueberdeckung wieder dieselbe Menge.
w2u_decompose "$D_Url/fallE" 32 "$_TmpDir/workE"
_CntE="$(grep -c . "$_TmpDir/workE")"
t_assert_eq "4" "$_CntE" "Fall E: genau 4 Arbeitspakete - der expandierte Ordner x ist KEINES davon"
t_assert_eq "0" "$(grep -c '^x$' "$_TmpDir/workE" || true)" "Fall E: kein Arbeitspaket fuer den expandierten Ordner x (sonst Doppeluebertragung)"
t_assert_contains "$(cat "$_TmpDir/workE")" "x/datei3.txt" "Fall E: die Dateien der letzten Ebene sind Arbeitspakete"
_Expected="$(cd "$_Src/fallE" && find . -mindepth 1 | sed 's|^\./||' | sort)"
_Actual="$(t_union_proof "$_Src/fallE" "$_TmpDir/workE")"
t_assert_eq "$_Expected" "$_Actual" "Fall E: Arbeitspakete plus implizite Eltern ueberdecken den Baum exakt"

# --- Fall F: Leerzeichen, Umlaute, fuehrende/nachgestellte Leerzeichen ---
# Schwelle 3 statt 32, damit "Ebene 1 Ordner" unexpandiert ueber den
# Schluss-Flush in die Arbeitsliste geht - so laeuft ein Name mit Leerzeichen
# durch BEIDE Wege: Datei -> _OutFile und Ordner -> _Next -> _Cur -> Flush.
w2u_decompose "$D_Url/fallF" 3 "$_TmpDir/workF"
_CntF="$(grep -c . "$_TmpDir/workF")"
t_assert_eq "3" "$_CntF" "Fall F: genau 3 Arbeitspakete"
t_assert_contains "$(cat "$_TmpDir/workF")" " fuehrend.txt" "Fall F: fuehrendes Leerzeichen ueberlebt (nur IFS=TAB leistet das)"
t_assert_contains "$(cat "$_TmpDir/workF")" "nachgestellt.txt " "Fall F: nachgestelltes Leerzeichen ueberlebt (nur IFS=TAB leistet das)"
t_assert_contains "$(cat "$_TmpDir/workF")" "Ebene 1 Ordner" "Fall F: Ordnername mit Leerzeichen ueberlebt den Flush"
# Zeilengenau statt per contains: beweist, dass der Name NICHT nachgespalten
# und NICHT getrimmt wurde - " fuehrend.txt" waere sonst "fuehrend.txt".
t_assert_eq "1" "$(grep -c '^ fuehrend\.txt$' "$_TmpDir/workF" || true)" "Fall F: der Name steht exakt so in der Zeile, ungetrimmt"
t_assert_eq "1" "$(grep -c '^nachgestellt\.txt $' "$_TmpDir/workF" || true)" "Fall F: nachgestelltes Leerzeichen wurde nicht abgeschnitten"
_Expected="$(cd "$_Src/fallF" && find . -mindepth 1 | sed 's|^\./||' | sort)"
_Actual="$(t_union_proof "$_Src/fallF" "$_TmpDir/workF")"
t_assert_eq "$_Expected" "$_Actual" "Fall F: Arbeitspakete plus implizite Eltern ueberdecken den Baum exakt (Umlaute, Leerzeichen)"

# Fall B traegt zusaetzlich den Ebene-2-Ordner mit Leerzeichen und Umlaut -
# dort laeuft der Name durch "_Path=$_Rel/$_Name".
t_assert_contains "$(cat "$_TmpDir/workB")" "Bildarchiv/patient 7 Müller" "Fall B: Leerzeichen und Umlaut ueberleben die Pfad-Verkettung _Rel/_Name"

# --- Fall C: unlesbares Verzeichnis MUSS hart fehlschlagen (CONTROLLER-RULING 2) ---
#
# Der Fehler, gegen den das schuetzt: in einer Prozess-Substitution
# ("done < <(w2u_remote_list ...)") laeuft w2u_remote_list in einem Kindprozess.
# Dessen w2u_die beendet nur das Kind, der Elternprozess liest null Zeilen und
# behandelt das Verzeichnis wie ein LEERES - macht daraus ein Arbeitspaket und
# laesst den ganzen Unterbaum still aus der Arbeitsliste fallen. Der
# aussagekraeftigste Assert ist deshalb nicht der rc, sondern das FEHLEN einer
# nackten "gesperrt"-Zeile in der Arbeitsliste.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - Rechte-Test (chmod 000) ist wirkungslos"
else
    chmod 000 "$_Src/fallC/gesperrt"

    # w2u_die beendet den Prozess -> Aufruf in eine Kommandosubstitution kapseln
    # (eigener Subshell), damit der Testlauf weiterlaeuft.
    _Rc=0
    _Err="$(w2u_decompose "$D_Url/fallC" 32 "$_TmpDir/workC" 2>&1)" || _Rc=$?
    t_assert_eq "1" "$_Rc" "Fall C: unlesbares Verzeichnis beendet die Zerlegung hart (rc 1 von w2u_die)"
    t_assert_contains "$_Err" "ABBRUCH" "Fall C: der Abbruch wird sichtbar gemeldet"
    t_assert_contains "$_Err" "Permission denied" "Fall C: die rsync-Diagnose selbst ist sichtbar - beweist echten Rechte-Fehler statt zufaelligem rc 1"
    t_assert_contains "$(cat "$_TmpDir/workC")" "vorne.txt" "Fall C: der Abbruch passiert MITTEN in der Zerlegung, nicht davor"
    t_assert_eq "0" "$(grep -c '^gesperrt$' "$_TmpDir/workC" 2>/dev/null || true)" "Fall C: das unlesbare Verzeichnis wird NICHT als (vermeintlich leeres) Arbeitspaket verbucht"

    # Produktionsbedingungen nachbauen: main() setzt "set -euo pipefail", und der
    # Aufruf steht dort nicht in einer Kommandosubstitution. Nur so faellt auf,
    # wenn errexit den Abbruch an anderer Stelle als w2u_die ausloest.
    # _TmpDir MUSS im Probe-Skript gesetzt werden: pull.sh initialisiert es leer,
    # sonst schluege das Skript schon am Schreiben nach "/lvl.cur" fehl und der
    # rc-Assert waere aus dem falschen Grund gruen.
    _ProbeErr="$(mktemp)"
    _ProbeScript="$(mktemp)"
    _ProbeWork="$_TmpDir/workC_probe"
    # Das Arbeitsverzeichnis des Probe-Skripts wird HIER angelegt, nicht per
    # "mktemp -d" im Skript selbst: das Skript stirbt planmaessig per w2u_die und
    # kaeme nie zum Aufraeumen - jeder Testlauf liesse ein Temp-Verzeichnis
    # zurueck. Unter $_TmpDir raeumt der EXIT-trap es mit ab.
    _ProbeTmp="$_TmpDir/probe_tmp"
    mkdir -p "$_ProbeTmp"
    cat > "$_ProbeScript" <<EOF
#!/usr/bin/env bash
set -euo pipefail
W2U_LIB_ONLY=1
. "$_Root/pull.sh"
_TmpDir="$_ProbeTmp"
w2u_find_rsync
w2u_decompose "$D_Url/fallC" 32 "$_ProbeWork"
EOF
    chmod +x "$_ProbeScript"
    "$_ProbeScript" >/dev/null 2>"$_ProbeErr"
    _ProbeRc=$?
    rm -f "$_ProbeScript"

    t_assert_eq "1" "$_ProbeRc" "Fall C unter set -e: rc bleibt 1 (w2u_die), nicht das nackte rsync-rc 23"
    t_assert_contains "$(cat "$_ProbeErr")" "ABBRUCH" "Fall C unter set -e: die ABBRUCH-Meldung erscheint trotzdem"
    t_assert_contains "$(cat "$_ProbeErr")" "Permission denied" "Fall C unter set -e: die rsync-Diagnose bleibt sichtbar"
    t_assert_eq "0" "$(grep -c '^gesperrt$' "$_ProbeWork" 2>/dev/null || true)" "Fall C unter set -e: kein Arbeitspaket fuer das unlesbare Verzeichnis"
    rm -f "$_ProbeErr"

    chmod 755 "$_Src/fallC/gesperrt"
fi

# --- Degenerierte Schwelle: darf keine LEERE Arbeitsliste liefern ---
# Bei Schwelle <= 1 bricht die Schleife vor der ersten Expansion ab; die Wurzel
# selbst ist als leere Zeile nicht darstellbar und wuerde weggefiltert - das
# Ergebnis waere eine leere Arbeitsliste, also Totalverlust. Aus der Konfiguration
# (4 * _PMax, _PMax >= 1) ist das nicht erreichbar, muss aber laut fehlschlagen.
_Rc=0
_Err="$(w2u_decompose "$D_Url/fallA" 1 "$_TmpDir/workSchwelle" 2>&1)" || _Rc=$?
t_assert_eq "1" "$_Rc" "Schwelle 1 schlaegt laut fehl statt still eine leere Arbeitsliste zu liefern"
t_assert_contains "$_Err" "Schwelle" "Schwelle-Fehler nennt die Ursache"

# --- Schluss-Flush darf nicht still fehlschlagen ---
# Der Flush ist die Zeile, die JEDES verbliebene Verzeichnis zum Arbeitspaket
# macht. Schluckt sie ihren Fehler, entsteht eine Arbeitsliste ohne diese
# Verzeichnisse - mit rc 0, also unbemerkt. Genau deshalb wird grep-rc 1
# ("keine Treffer", legitim) nicht mit rc 2 ("Fehler") verschmolzen.
#
# WEISSKASTEN-TEST, bewusst: er legt $_TmpDir/lvl.cur unlesbar an und koppelt
# damit an einen internen Dateinamen. Anders ist ein Flush-Fehler nicht
# herbeizufuehren. Wer lvl.cur umbenennt, muss diesen Test mitziehen.
# rc-Verhalten nachgemessen und bei BSD-grep UND ugrep identisch:
# unlesbare Datei -> rc 2, kein Treffer -> rc 1.
# Als root wirkungslos (Rechte werden ignoriert), deshalb dort skippen.
if [ "$(id -u)" -eq 0 ]; then
    t_skip "laeuft als root - unlesbare lvl.cur ist wirkungslos"
else
    rm -f "$_TmpDir/lvl.cur"
    printf 'irgendwas\n' > "$_TmpDir/lvl.cur"
    chmod 000 "$_TmpDir/lvl.cur"
    _Rc=0
    _Err="$(w2u_decompose "$D_Url/fallE" 32 "$_TmpDir/workFlush" 2>&1)" || _Rc=$?
    t_assert_eq "1" "$_Rc" "fehlgeschlagener Schluss-Flush bricht laut ab statt eine unvollstaendige Liste zu liefern"
    t_assert_contains "$_Err" "ABBRUCH" "Flush-Fehler wird als ABBRUCH gemeldet"
    chmod 644 "$_TmpDir/lvl.cur"
fi

t_summary
