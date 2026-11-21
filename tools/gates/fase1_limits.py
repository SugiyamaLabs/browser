import json, os, socket, time
path = os.environ["AGENS_SOCK"]
def ask(req):
    s = socket.socket(socket.AF_UNIX); s.connect(path); s.sendall((json.dumps(req) + "\n").encode())
    r = json.loads(s.makefile().readline()); s.close(); return r
print("257-char name:", ask({"id": 1, "op": "atos.create", "name": "x" * 257}).get("error"), "(expect bad_request)")
print("256-char name ok:", ask({"id": 1, "op": "atos.create", "name": "y" * 256}).get("ok"), "(expect True)")
print("1025-char tag:", ask({"id": 1, "op": "atos.create", "name": "z", "tag": "t" * 1025}).get("error"), "(expect bad_request)")
print("no color/tag:", ask({"id": 1, "op": "atos.create", "name": "Sem cor"}), "(expect ok)")
socks = []
for _ in range(18):
    s = socket.socket(socket.AF_UNIX); s.connect(path); socks.append(s)
time.sleep(0.5)
alive = 0
for s in socks:
    s.settimeout(1)
    try:
        s.sendall(b'{"id":1,"op":"hello"}\n'); alive += bool(s.recv(200))
    except OSError:
        pass
print("connections answered out of 18:", alive, "(expect 16)")
for s in socks: s.close()
time.sleep(0.5)
print("after closing them, hello:", ask({"id": 2, "op": "hello"}).get("ok"), "(expect True)")
