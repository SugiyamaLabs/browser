#!/usr/bin/env python3
"""The part of the manual test that needs a client on the socket: asks for control, acts on a page,
and waits for the person to press "Parar". Started by manual.sh; talks to the person in Portuguese."""
import json, os, socket, sys

SOCK, SITE = os.environ["AGENS_SOCK"], "http://127.0.0.1:8765"


class Conn:  # one connection: control belongs to it
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(SOCK)
        self.f = self.s.makefile("r")
        self.n = 0

    def read(self):  # the next message, reply or event; waits as long as the person takes
        line = self.f.readline()
        if not line:
            sys.exit("A conexão com o navegador caiu.")
        return json.loads(line)

    def ask(self, op, **params):
        self.n += 1
        self.s.sendall((json.dumps({"id": self.n, "op": op, **params}) + "\n").encode())
        while True:
            msg = self.read()
            if msg.get("id") == self.n:
                return msg

    def event(self):
        while True:
            msg = self.read()
            if "event" in msg:
                return msg


def passo(titulo, *linhas):
    print(f"\n=== {titulo}")
    for linha in linhas:
        print(f"  {linha}")


def pausa(texto="Enter para continuar"):
    input(f"  [{texto}] ")


def resultado(ok, texto):
    print(f"  {'OK   ' if ok else 'FALHA'} {texto}")


def atos(c):
    return {a["name"]: a for a in c.ask("atos.list")["atos"]}


def comecar_controle(ato, motivo):
    c = Conn()
    r = c.ask("control.start", ato=ato, reason=motivo)
    if not r.get("ok"):
        resultado(False, f"control.start respondeu {r.get('error')}: você tocou em Não permitir?")
        return None, None
    tab = c.ask("tab.open", ato=ato, url=f"{SITE}/form")["tab"]
    return c, tab


c0 = Conn()
passo("1. O interruptor de cookies",
      "No navegador que abriu: ⌘, (Configurações) e a seção Atos.",
      "Cada ato tem \"Compartilhar cookies\", desligado, com o detalhe",
      "  \"Os logins valem nos outros atos que também ligaram.\"",
      "Ligue no Time B. A folha deve dizer:",
      "  \"Compartilhar os cookies de Time B?\"",
      "  \"Por enquanto nada é compartilhado: os logins de Time B só passam a valer em outro ato",
      "   quando ele também ligar esta opção.\" e depois o trecho sobre mesmo site, apagar cookies",
      "   e \"Só cookies: senhas, histórico e dados dos sites continuam separados.\"",
      "Toque em Compartilhar. Depois ligue no Time C. Agora a folha deve dizer:",
      "  \"Os logins de Time C passam a valer também em Time B, e os deles em Time C.\"",
      "Toque em Compartilhar.")
pausa("Enter quando os dois estiverem ligados")
lista = atos(c0)
resultado(lista["Time B"]["shared"] and lista["Time C"]["shared"], "Time B e Time C aparecem como compartilhados no socket")
resultado(not lista["Pessoal"]["shared"], "Pessoal continua isolado")

passo("2. A folha do controle e a faixa",
      "Vou pedir controle do Time B. Deve aparecer a folha:",
      "  \"O Python quer usar abas do ato Time B\"",
      "  o motivo \"Teste manual do controle\" e, num parágrafo separado,",
      "  \"Time B compartilha cookies com Time C: os logins deles também ficam ao alcance.\"",
      "Botões: Permitir e Não permitir (sem \"Permitir sempre\", porque o cliente não é assinado).",
      "O botão do Enter deve ser Não permitir. Toque em Permitir com o mouse.")
pausa("Enter para eu pedir o controle")
c, tab = comecar_controle(lista["Time B"]["id"], "Teste manual do controle")
if c:
    nos = c.ask("page.snapshot", tab=tab)["nodes"]
    campo = next((n for n in nos if n["role"] == "textField" and n["name"] == "Text"), None)
    r = c.ask("page.type", tab=tab, ref=campo["ref"], text="digitado pelo agente") if campo else {}
    resultado(bool(r.get("ok")), "o agente digitou \"digitado pelo agente\" no campo Text")
    passo("3. Parar",
          "Na janela do Time B: a aba Form tem uma marca na lista, a página tem borda, e acima dela",
          "a faixa \"Controlado pelo Python  ·  Parar\".",
          "Toque em Parar.")
    ev = c.event()
    resultado(ev.get("event") == "control.stopped" and ev.get("reason") == "user", f"evento recebido: {json.dumps(ev)}")
    r = c.ask("page.snapshot", tab=tab)
    resultado(r.get("error") == "unauthorized", f"depois do Parar o agente não age mais ({r.get('error')})")
    print("  Confira: a faixa e a borda sumiram, e a aba continua aberta.")
    c.s.close()

    passo("4. O grupo de cookies muda no meio do controle",
          "Vou pedir controle de novo. Toque em Permitir.")
    pausa("Enter para eu pedir o controle")
    c, tab = comecar_controle(lista["Time B"]["id"], "Segundo teste")
    if c:
        print("  Agora, em Configurações › Atos, desligue \"Compartilhar cookies\" do Time C.")
        ev = c.event()
        resultado(ev.get("event") == "control.stopped" and ev.get("reason") == "sharing_changed", f"evento recebido: {json.dumps(ev)}")
        c.s.close()

passo("5. Os cookies, à mão (opcional)",
      "Ligue de novo o interruptor do Time C.",
      f"No Time B abra {SITE}/login?auto=1 (cai em \"logged in\").",
      f"No Time C abra {SITE}/app/ : deve mostrar \"logged in\" sem pedir login.",
      f"No Pessoal abra {SITE}/app/ : deve voltar para a tela de login.",
      f"No Time C abra {SITE}/logout e recarregue /app/ no Time B: deve pedir login.")
pausa("Enter para fechar o navegador de teste")
