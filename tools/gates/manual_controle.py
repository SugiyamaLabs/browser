#!/usr/bin/env python3
"""The part of the manual test that needs a client on the socket: asks for control, acts on a page,
and waits for the person to press Assumir, Devolver and the stop bubble. Started by manual.sh; talks to the person in Portuguese."""
import json, os, socket, sys

SOCK, SITE = os.environ["AGENS_SOCK"], "http://127.0.0.1:8765"


class Conn:  # one connection: control belongs to it
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(SOCK)
        self.f = self.s.makefile("r")
        self.n = 0
        self.events = []  # events that came while waiting for a reply

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
            if "event" in msg:
                self.events.append(msg)

    def event(self, seconds=180):  # None when the person took too long, so the script never hangs
        if self.events:
            return self.events.pop(0)
        self.s.settimeout(seconds)
        try:
            while True:
                msg = self.read()
                if "event" in msg:
                    return msg
        except (socket.timeout, TimeoutError):
            return None
        finally:
            self.s.settimeout(None)


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
      "Cada ato é um grupo: o nome e, LOGO ABAIXO dele, o interruptor \"Compartilhar cookies\",",
      "desligado, com o detalhe",
      "  \"Os logins valem nos outros atos que também ligaram.\"",
      "Ligue no Time B. A folha deve dizer:",
      "  \"Compartilhar os cookies de Time B?\"",
      "  \"Por enquanto nada é compartilhado: os logins de Time B só passam a valer em outro ato",
      "   quando ele também ligar esta opção.\" e depois o trecho sobre mesmo site, apagar cookies",
      "   e \"Só cookies: senhas, histórico e dados dos sites continuam separados.\"",
      "Toque em Compartilhar. Depois ligue no Time C. Agora a folha deve dizer:",
      "  \"Os logins de Time C passam a valer também em Time B, e os deles em Time C.\"",
      "Toque em Compartilhar.")
while True:
    pausa("Enter quando os dois estiverem ligados")
    lista = atos(c0)
    certo = lista["Time B"]["shared"] and lista["Time C"]["shared"] and not lista["Pessoal"]["shared"]
    resultado(certo, "Time B e Time C compartilham, Pessoal não. O navegador diz: "
              + ", ".join(f"{n}={'ligado' if a['shared'] else 'desligado'}" for n, a in lista.items()))
    if certo or input("  Acerte os interruptores e aperte Enter, ou digite s para seguir assim mesmo: ").strip() == "s":
        break

def espera(c, nome, **campos):  # the next event must be this one
    ev = c.event()
    ok = bool(ev) and ev.get("event") == nome and all(ev.get(k) == v for k, v in campos.items())
    resultado(ok, f"evento recebido: {json.dumps(ev)}" if ev else f"nenhum evento em 3 minutos (esperava {nome})")
    return ok


passo("2. A folha do controle e o aviso",
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
    print("  Confira na janela do Time B: a aba Form tem uma marca na lista, a página tem borda, e embaixo")
    print("  dela a pílula \"Python está usando esta aba / Teste manual do controle\" com o botão Assumir.")

    passo("3. Assumir", "Toque em Assumir.")
    espera(c, "control.paused", by="user")
    r = c.ask("page.snapshot", tab=tab)
    resultado(r.get("error") == "paused", f"enquanto você está no controle o agente não age ({r.get('error')})")
    print("  Confira: a pílula diz \"Você está no controle / o Python pausou e espera você\", com")
    print("  \"Devolver ao Python\" e, por último, a bolha com o quadrado de parar. O cursor do agente sumiu.")

    passo("4. Devolver", "Toque em Devolver ao Python.")
    espera(c, "control.resumed")
    r = c.ask("page.snapshot", tab=tab)
    resultado(bool(r.get("ok")), "depois de devolver o agente age de novo")

    passo("5. Assumir com um diálogo esperando",
          "O agente vai abrir uma página e tocar num botão que pergunta \"Proceed?\".",
          "Nada deve aparecer para você ainda: a pergunta fica esperando o agente.")
    c.ask("tab.navigate", tab=tab, url=f"{SITE}/agent")
    nos = c.ask("page.snapshot", tab=tab).get("nodes", [])
    botao = next((n for n in nos if n["role"] == "button" and n["name"] == "Ask"), None)
    if botao:
        c.ask("page.click", tab=tab, ref=botao["ref"])
        espera(c, "page.dialog", type="confirm", message="Proceed?")
        print("  Agora toque em Assumir: a pergunta \"Proceed?\" deve aparecer para você. Toque em OK.")
        espera(c, "control.paused", by="user")
        print("  Depois de responder, toque em Devolver ao Python.")
        espera(c, "control.resumed")
        nos = c.ask("page.snapshot", tab=tab).get("nodes", [])
        resultado(any("Answer: true" in n.get("name", "") for n in nos), "a página recebeu a sua resposta (Answer: true)")
    else:
        resultado(False, "não achei o botão Ask na página de teste")

    passo("6. Encerrar pela bolha", "Toque em Assumir e depois na bolha com o quadrado de parar.")
    espera(c, "control.paused", by="user")
    espera(c, "control.stopped", reason="user")
    r = c.ask("page.snapshot", tab=tab)
    resultado(r.get("error") == "unauthorized", f"depois de encerrar o agente não age mais ({r.get('error')})")
    print("  Confira: a pílula e a borda sumiram, e a aba continua aberta.")
    c.s.close()

    passo("7. O grupo de cookies muda no meio do controle",
          "Vou pedir controle de novo. Toque em Permitir.")
    if not atos(c0)["Time B"]["shared"]:
        print("  Pulado: o Time B não está compartilhando cookies, então o grupo dele não tem como mudar.")
    else:
        pausa("Enter para eu pedir o controle")
        c, tab = comecar_controle(lista["Time B"]["id"], "Segundo teste")
        if c:
            print("  Agora, em Configurações › Atos, desligue \"Compartilhar cookies\" do Time C.")
            espera(c, "control.stopped", reason="sharing_changed")
            c.s.close()

passo("8. Os cookies, à mão (opcional)",
      "Ligue de novo o interruptor do Time C.",
      f"No Time B abra {SITE}/login?auto=1 (cai em \"logged in\").",
      f"No Time C abra {SITE}/app/ : deve mostrar \"logged in\" sem pedir login.",
      f"No Pessoal abra {SITE}/app/ : deve voltar para a tela de login.",
      f"No Time C abra {SITE}/logout e recarregue /app/ no Time B: deve pedir login.")
pausa("Enter para fechar o navegador de teste")
