# Herkunft der Binärdateien

`bin/rsync.exe` und die `cyg*.dll` stammen unverändert aus **cwRsync free edition 6.4.8**
von itefix (https://itefix.net/cwrsync), bezogen über das Chocolatey-Paket
`https://packages.chocolatey.org/rsync.6.4.8.nupkg`.

rsync selbst steht unter der **GNU General Public License v3**. Der vollständige
Lizenztext liegt hier als `COPYING` (unverändert von https://www.gnu.org/licenses/gpl-3.0.txt,
da das cwRsync-Bundle selbst keine COPYING-Datei mitliefert, obwohl `README.rsync.txt`
im Bundle genau darauf verweist). Der Quelltext ist bei https://rsync.samba.org/ und
https://itefix.net/cwrsync erhältlich.

`LICENSE.txt` ist **nicht** die GPLv3, sondern itefix' eigene Simplified-BSD-Lizenz für
das cwRsync-Bundle als Ganzes (siehe `VERIFICATION.txt`, die das explizit so benennt und
auf https://itefix.net/simplified-bsd-license verweist). Beide Dateien liegen unverändert
aus dem Chocolatey-Paket bei, zur Provenienz.

Die Prüfsummen des Ursprungspakets stehen in `VERIFICATION.txt`.

Neu bauen: `bash tools/fetch-cwrsync.sh` im Repo-Wurzelverzeichnis. `COPYING` wird davon
NICHT berührt oder erzeugt - es ist ein statischer, unveränderlicher Lizenztext und liegt
deshalb fest im Repo statt im generierten Teil.
