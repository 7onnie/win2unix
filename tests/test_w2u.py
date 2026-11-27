#!/usr/bin/env python3
"""Unit-Tests fuer linux/w2u (Issue #9).

systemctl, journalctl und sudo sind Attrappen im PATH, die ihre Aufrufe
protokollieren. pull.sh ist eine Attrappe (W2U_PULL), die Statusdatei und
Exit-Code vorgibt. Laeuft auf macOS und Linux ohne root.
"""
import importlib.machinery
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
W2U_PATH = ROOT / "linux" / "w2u"


def load_w2u():
    loader = importlib.machinery.SourceFileLoader("w2u", str(W2U_PATH))
    spec = importlib.util.spec_from_loader("w2u", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def write_exec(path: Path, body: str):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.etc = self.tmp / "etc"
        self.var = self.tmp / "var"
        self.bin = self.tmp / "bin"
        self.dst = self.tmp / "dst"
        for d in (self.etc / "jobs", self.var, self.bin, self.dst):
            d.mkdir(parents=True)
        self.calls = self.tmp / "calls"
        self.calls.write_text("")
        # Attrappen: protokollieren argv, systemctl show liefert Werte aus Datei
        write_exec(self.bin / "sudo", '#!/bin/sh\n[ "$1" = "-n" ] && shift\nexec "$@"\n')
        write_exec(self.bin / "systemctl", f'''#!/bin/sh
echo "systemctl $*" >> "{self.calls}"
if [ "$1" = "show" ]; then
    _U=""
    for _A in "$@"; do case "$_A" in win2unix@*) _U="$_A" ;; esac; done
    _F="{self.tmp}/show.$_U"
    if [ -f "$_F" ]; then cat "$_F"; else printf 'ActiveState=inactive\\nSubState=dead\\nNRestarts=0\\nUnitFileState=disabled\\nExecMainStatus=0\\n'; fi
fi
exit 0
''')
        write_exec(self.bin / "journalctl", f'#!/bin/sh\necho "journalctl $*" >> "{self.calls}"\necho "log-zeile"\n')
        self.env_backup = dict(os.environ)
        os.environ["PATH"] = f"{self.bin}:{os.environ['PATH']}"
        os.environ["W2U_ETC"] = str(self.etc)
        os.environ["W2U_VAR"] = str(self.var)
        self.w2u = load_w2u()
        self.me = f"{os.getuid()}:{os.getgid()}"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def show(self, name, **kv):
        (self.tmp / f"show.win2unix@{name}.service").write_text(
            "".join(f"{k}={v}\n" for k, v in kv.items()))


class TestHelpers(Base):
    def test_windows_path_to_url(self):
        f = self.w2u.source_url
        self.assertEqual(f("192.168.2.3", r"E:\Konvertierung_tomedo\S1_S3\BRIEFE"),
                         "rsync://192.168.2.3/e/Konvertierung_tomedo/S1_S3/BRIEFE")
        self.assertEqual(f("10.0.0.1", "f:/SonoGDT/Bildarchiv/"),
                         "rsync://10.0.0.1/f/SonoGDT/Bildarchiv")
        self.assertEqual(f("10.0.0.1", r"F:\Ordner mit Leerzeichen\Größe"),
                         "rsync://10.0.0.1/f/Ordner mit Leerzeichen/Größe")
        self.assertEqual(f("", "rsync://h/e/x"), "rsync://h/e/x")
        with self.assertRaises(ValueError):
            f("10.0.0.1", "F:\\")          # ganzes Laufwerk: Name fehlt
        with self.assertRaises(ValueError):
            f("", r"F:\x")                # IP fehlt

    def test_job_names(self):
        ok = self.w2u.valid_name
        self.assertTrue(ok("s3-briefe_2"))
        for bad in ("", "../x", "a/b", "Gross", "x" * 41, "a b", "-", "a.b"):
            self.assertFalse(ok(bad), bad)


class TestAdd(Base):
    def test_add_writes_conf(self):
        self.w2u.add("albis", "rsync://h/f/A/BRIEFE", str(self.dst), self.me, jobs=4, newdays=365)
        conf = self.w2u.read_job("albis")
        self.assertEqual(conf["SRC"], "rsync://h/f/A/BRIEFE")
        self.assertEqual(conf["DST"], str(self.dst))
        self.assertEqual(conf["OWNER"], self.me)
        self.assertEqual(conf["JOBS"], "4")
        self.assertEqual(conf["NEWDAYS"], "365")

    def test_add_rejects(self):
        add = self.w2u.add
        with self.assertRaises(ValueError):
            add("../x", "rsync://h/f/A", str(self.dst), self.me)
        with self.assertRaises(ValueError):
            add("a", "rsync://h/f/A", str(self.dst / "fehlt"), self.me)
        with self.assertRaises(ValueError):
            add("a", "rsync://h/f/A", str(self.dst), "gibtsnicht-w2u:gibtsnicht-w2u")
        with self.assertRaises(ValueError):
            add("a", "rsync://h/f/A/", str(self.dst), self.me)   # Schraegstrich-Form
        add("a", "rsync://h/f/X/BRIEFE", str(self.dst), self.me)
        with self.assertRaises(ValueError):                      # gleiches Ziel
            add("b", "rsync://k/e/Y/BRIEFE", str(self.dst), self.me)
        with self.assertRaises(ValueError):                      # gleicher Name
            add("a", "rsync://h/f/Z/ANDERS", str(self.dst), self.me)


class TestControl(Base):
    def test_start_stop_use_sudo_systemctl(self):
        self.w2u.add("j1", "rsync://h/f/A/N", str(self.dst), self.me)
        self.w2u.cmd_start("j1")
        self.w2u.cmd_stop("j1")
        self.w2u.cmd_restart("j1")
        calls = self.calls.read_text()
        self.assertIn("systemctl enable --now win2unix@j1.service", calls)
        self.assertIn("systemctl disable --now win2unix@j1.service", calls)
        self.assertIn("systemctl restart win2unix@j1.service", calls)

    def test_start_resets_fail_streak(self):
        self.w2u.add("j1", "rsync://h/f/A/N", str(self.dst), self.me)
        jd = self.var / "j1"
        jd.mkdir()
        (jd / "runs").write_text("attempts=5\nfail_streak=3\ngiven_up=1\n")
        self.w2u.cmd_start("j1")
        runs = self.w2u.read_kv(jd / "runs")
        self.assertEqual(runs["fail_streak"], "0")
        self.assertEqual(runs["given_up"], "0")

    def test_remove_refuses_running(self):
        self.w2u.add("j1", "rsync://h/f/A/N", str(self.dst), self.me)
        self.show("j1", ActiveState="active", SubState="running", NRestarts=0,
                  UnitFileState="enabled", ExecMainStatus=0)
        with self.assertRaises(ValueError):
            self.w2u.cmd_remove("j1")
        self.show("j1", ActiveState="inactive", SubState="dead", NRestarts=0,
                  UnitFileState="disabled", ExecMainStatus=0)
        self.w2u.cmd_remove("j1")
        self.assertFalse((self.etc / "jobs" / "j1.conf").exists())


class TestRun(Base):
    """w2u run: Exit-Politik laut Spec."""

    def fake_pull(self, rc, result=""):
        script = self.tmp / "fake-pull.sh"
        write_exec(script, f'''#!/bin/sh
echo "$@" > "{self.tmp}/pull-args"
_St=""
while [ $# -gt 0 ]; do
    [ "$1" = "--status-file" ] && _St="$2"
    shift
done
printf 'phase=done\\nresult={result}\\n' > "$_St"
exit {rc}
''')
        os.environ["W2U_PULL"] = str(script)

    def run_job(self):
        return self.w2u.cmd_run("j1")

    def setUp(self):
        super().setUp()
        self.w2u.add("j1", "rsync://h/f/A/N", str(self.dst), self.me, jobs=3, newdays=30)

    def runs(self):
        return self.w2u.read_kv(self.var / "j1" / "runs")

    def test_pass(self):
        self.fake_pull(0, "PASS")
        self.assertEqual(self.run_job(), 0)
        args = (self.tmp / "pull-args").read_text()
        for part in ("--status-file", "--log-dir", f"--chown {self.me}", "--jobs 3",
                     "--neu-zuerst 30", "rsync://h/f/A/N", str(self.dst)):
            self.assertIn(part, args)
        self.assertEqual(self.runs()["fail_streak"], "0")
        self.assertIn("systemctl disable win2unix@j1.service", self.calls.read_text())

    def test_setup_error_is_3(self):
        self.fake_pull(3)
        self.assertEqual(self.run_job(), 3)

    def test_transient_abort_retries_forever(self):
        self.fake_pull(1, "")
        for _ in range(5):
            self.assertEqual(self.run_job(), 1)
        self.assertEqual(self.runs()["fail_streak"], "0")

    def test_three_fail_verdicts_give_up(self):
        self.fake_pull(1, "FAIL")
        self.assertEqual(self.run_job(), 1)
        self.assertEqual(self.run_job(), 1)
        self.assertEqual(self.run_job(), 3)
        self.assertEqual(self.runs()["fail_streak"], "3")
        self.assertEqual(self.runs()["given_up"], "1")

    def test_pass_resets_streak(self):
        self.fake_pull(1, "FAIL")
        self.run_job()
        self.fake_pull(0, "PASS")
        self.run_job()
        self.assertEqual(self.runs()["fail_streak"], "0")

    def test_stop_signal_ends_cleanly(self):
        # systemctl stop schickt SIGTERM: w2u run reicht es weiter und endet
        # mit 0 - ein bewusster Stopp ist kein Fehler (sonst "failed").
        script = self.tmp / "slow-pull.sh"
        write_exec(script, "#!/bin/sh\ntrap 'exit 130' TERM\nsleep 30 & wait\n")
        os.environ["W2U_PULL"] = str(script)
        import threading
        def term():
            time.sleep(1.0)
            os.kill(os.getpid(), signal.SIGTERM)
        import signal, time
        t = threading.Thread(target=term)
        t.start()
        rc = self.run_job()
        t.join()
        self.assertEqual(rc, 0)

    def test_bad_name_rejected_in_run(self):
        self.assertEqual(self.w2u.cmd_run("../etc/passwd"), 3)


class TestState(Base):
    def setUp(self):
        super().setUp()
        self.w2u.add("j1", "rsync://h/f/A/N", str(self.dst), self.me)
        self.jd = self.var / "j1"
        self.jd.mkdir()

    def st(self, **kv):
        (self.jd / "status").write_text("".join(f"{k}={v}\n" for k, v in kv.items()))

    def label(self):
        return self.w2u.job_state("j1")["label"]

    def test_labels(self):
        import time
        now = int(time.time())
        self.assertEqual(self.label(), "neu")
        self.show("j1", ActiveState="active", SubState="running", NRestarts=0,
                  UnitFileState="enabled", ExecMainStatus=0)
        self.st(phase="parallel", updated=now, chunks_total=10, chunks_done=4)
        self.assertEqual(self.label(), "läuft")
        self.st(phase="parallel", updated=now - 900)
        self.assertEqual(self.label(), "keine Rückmeldung")
        self.show("j1", ActiveState="activating", SubState="auto-restart", NRestarts=2,
                  UnitFileState="enabled", ExecMainStatus=1)
        self.assertEqual(self.label(), "wartet auf Neustart")
        self.show("j1", ActiveState="inactive", SubState="dead", NRestarts=0,
                  UnitFileState="disabled", ExecMainStatus=0)
        self.st(phase="done", result="PASS", updated=now)
        self.assertEqual(self.label(), "erledigt")
        self.st(phase="preflight", result="", updated=now)
        self.assertEqual(self.label(), "gestoppt")
        self.show("j1", ActiveState="failed", SubState="failed", NRestarts=0,
                  UnitFileState="disabled", ExecMainStatus=1)
        self.assertEqual(self.label(), "abgebrochen")      # nicht "Einrichtungsfehler"
        self.show("j1", ActiveState="failed", SubState="failed", NRestarts=0,
                  UnitFileState="enabled", ExecMainStatus=3)
        self.assertEqual(self.label(), "Einrichtungsfehler")
        (self.jd / "runs").write_text("fail_streak=3\ngiven_up=1\n")
        self.assertEqual(self.label(), "aufgegeben")

    def test_progress_fields(self):
        self.st(phase="parallel", chunks_total=10, chunks_done=4, kb_dst=2097152,
                updated=1, message="x")
        s = self.w2u.job_state("j1")
        self.assertEqual(s["phase"], "parallel")
        self.assertEqual(s["progress"], "4/10")
        self.assertEqual(s["gb"], "2.0 GB")


class TestRender(Base):
    def test_rows(self):
        states = [{"name": "albis-brf", "src": "rsync://10.3.208.159/f/Konv/Albis/AlbisWin/BRIEFE",
                   "label": "läuft", "phase": "parallel", "progress": "412/980", "gb": "183.0 GB",
                   "restarts": "0"},
                  {"name": "s3", "src": "rsync://192.168.2.3/e/X/BRIEFE", "label": "erledigt",
                   "phase": "done", "progress": "", "gb": "", "restarts": "2"}]
        rows = self.w2u.render_rows(states, {"albis-brf": "42 MB/s"})
        self.assertEqual(len(rows), 2)
        self.assertIn("albis-brf", rows[0])
        self.assertIn("10.3.208.159 f:/…/BRIEFE", rows[0])
        self.assertIn("412/980 183.0 GB 42 MB/s", rows[0])
        self.assertIn("erledigt ✓", rows[1])
        self.assertEqual(len(rows[0]), len(rows[1]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
