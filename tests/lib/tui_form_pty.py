# Pty-Test: Formular [n] muss auf Eingabe warten (vorher: nach 2 s Vorgabewert).
import os, pty, time, select, struct, fcntl, termios, tempfile, subprocess, sys
repo = sys.argv[1]
tmp = tempfile.mkdtemp()
os.makedirs(f"{tmp}/etc/jobs"); os.makedirs(f"{tmp}/var"); os.makedirs(f"{tmp}/bin")
open(f"{tmp}/bin/systemctl","w").write("#!/bin/sh\nexit 0\n"); os.chmod(f"{tmp}/bin/systemctl",0o755)
def drain(fd, secs):
    out=b""; end=time.time()+secs
    while time.time()<end:
        r,_,_=select.select([fd],[],[],0.2)
        if r:
            try:
                b=os.read(fd,65536)
                if not b: break
                out+=b
            except OSError: break
    return out
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(W2U_ETC=f"{tmp}/etc", W2U_VAR=f"{tmp}/var", TERM="xterm-256color", LANG="de_DE.UTF-8", PATH=f"{tmp}/bin:"+os.environ["PATH"])
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    os.execvp("python3", ["python3", f"{repo}/linux/w2u"])
drain(fd, 2)
os.write(fd, b"n")
out = drain(fd, 7).decode("utf-8", "replace")
# Ohne Eingabe darf das Formular hoechstens beim ersten Feld stehen.
reached_second = "Quell-IP" in out
os.kill(pid, 9); os.waitpid(pid, 0)
subprocess.run(["rm","-rf",tmp])
print("ZWEITES_FELD_OHNE_ENTER" if reached_second else "WARTET")
sys.exit(1 if reached_second else 0)
