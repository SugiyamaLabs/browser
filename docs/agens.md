# Plano: o navegador pronto para o Agens

O Agens precisa de quatro coisas do navegador (ADR 0014 do Agens):

1. criar e usar atos por código;
2. entregar a sessão de um site para as pontes, só com os itens do `Need` e com o OK da pessoa;
3. ser controlado por um agente (o MCP do Agens) de forma segura;
4. mostrar uma aba dentro do app do Agens (o `BrowserKit`).

Os itens 1 a 3 passam por **um socket local**, e é por eles que começamos, porque destravam as pontes e o MCP do time do Agens. O 4 é outro projeto e vem por último.

## Regras

- **O navegador não conhece o Agens.** Nada de time, Gerente ou ponte aqui: a API fala de atos, sites e itens. O Agens dá os nomes.
- **Nada de porta de depuração (CDP).** Com ela, qualquer processo da máquina controla o navegador inteiro sem pedir nada. Por dentro, onde for útil, usamos uma sessão de DevTools no próprio processo, que nunca abre porta.
- **Só o que foi pedido, e só com o OK da pessoa.** A sessão entrega exatamente os itens do `Need`, nunca o cookie jar inteiro. O controle por agente pede aprovação por ato e deixa um aviso visível enquanto dura.
- **Segredo não vai para disco nem para log.** O valor de um cookie ou header só passa pelo socket. Quem guarda é a Engine, no Keychain.
- **O controle não toca em senha.** Ele não lê campo de senha, não digita nele, e cookies e senhas salvas ficam fora do alcance dele.

## O socket

- **Onde:** `~/Library/Application Support/AgensBrowser/agens.sock`, socket Unix com permissão `0600`. No Windows será um named pipe (#61).
- **Formato:** uma mensagem JSON por linha. Pedido: `{"id": 1, "op": "atos.list", ...}`. Resposta: `{"id": 1, "ok": true, ...}` ou `{"id": 1, "ok": false, "error": "..."}`. Evento, sem `id`: `{"event": "session.lost", ...}`.
- **Quem pode conectar:** o navegador lê o processo do outro lado (`LOCAL_PEERTOKEN`) e confere a assinatura de código. Por padrão, só apps assinados com o nosso Team ID. Para desenvolvimento, Configurações › Sistema tem "Aceitar apps sem assinatura", que vem desligado.
- **Primeira conexão de um app:** aparece "O Agens quer usar o AgensBrowser" com **Permitir**, **Permitir sempre** e **Não permitir**. A escolha fica salva por app.
- **Navegador fechado:** quem conecta abre o navegador em segundo plano (`open -g -b com.sugiyamalabs.agensbrowser`) e espera o socket aparecer.
- **Versão:** `hello` devolve a versão do protocolo. Mudança que quebra cliente sobe a versão.

## As operações (v1)

### Atos

| Operação | O que faz |
|---|---|
| `hello {client}` | Versão do protocolo e do navegador. |
| `atos.list` | `[{id, name, color, asleep}]`. O `id` é estável (a pasta do perfil). |
| `atos.create {name, color}` | Cria o ato e devolve o `id`. Aparece na lateral na hora. |
| `atos.rename {id, name}` / `atos.color {id, color}` | Renomeia e troca a cor. |
| `atos.open {id, url?}` | Abre ou traz para a frente a janela do ato, opcionalmente numa URL. |

Apagar ato não entra na v1: é irreversível e fica só na interface, com confirmação.

### Sessão (as pontes)

| Operação | O que faz |
|---|---|
| `login {ato, url, done}` | Abre o site no ato. A pessoa entra como sempre, e a aba fecha quando `done` acontece. Responde `ok` ao fim, ou `cancelled` se a pessoa fechar a aba. |
| `session {ato, need, reason}` | Mostra a folha "Entregar ao Agens: cookie `d` de app.slack.com…", com o motivo e os itens exatos. Com **Permitir** (ou **Permitir sempre** para esse ato + esses itens), devolve os valores. |
| `renew {ato, need}` | Tenta pegar de novo sem janela: carrega o site numa aba escondida do ato e lê os itens. Se o site pedir login, responde `needs_login`. |
| evento `session.lost {ato, from, name}` | Um item vigiado sumiu ou expirou (observador de cookies do perfil). |

`done` é a regra de fim de login que a ponte conhece, por exemplo `{"cookie": "d", "from": "https://app.slack.com"}` ou `{"url_prefix": "https://outlook.office.com/mail/"}`. O navegador não adivinha.

Os tipos de item seguem o `SessionItem` do Agens:
- `cookie`: lido no cookie store do ato (`CookieManager`), inclusive httpOnly;
- `localStorage`: lido numa aba do ato aberta naquela origem;
- `header`: capturado das requisições que a própria página faz para `from`, por uma sessão de DevTools interna (`Network.requestWillBeSent` e `ExtraInfo`). É o caso do Bearer do Outlook, como na POC `outlookctl`. A captura só dura enquanto o pedido está aberto.

### Controle (o MCP)

| Operação | O que faz |
|---|---|
| `control.start {ato, reason}` | Pede aprovação ("O Agens quer usar abas do ato Cliente A: reason"). Aprovado, as abas controladas ganham borda e faixa "Controlado pelo Agens · Parar". |
| `tab.open {ato, url}` / `tab.navigate` / `tab.close` | Abas do ato, só as abertas pelo controle. |
| `page.snapshot {tab}` | A página como árvore de acessibilidade simplificada, com `ref` em cada elemento: papel, nome, valor. Campo de senha aparece sem valor. |
| `page.click {tab, ref}` / `page.type {tab, ref, text}` / `page.key {tab, key}` | Ação num elemento do snapshot. `type` em campo de senha é recusado. |
| `page.screenshot {tab}` | PNG da aba. |
| `control.stop` | Encerra o controle. "Parar" na faixa faz o mesmo e avisa o cliente. |

O agente nunca vê as abas que a pessoa abriu, só as que ele abriu.

## Onde fica no código

- `chrome/browser/agens/bridge/`: o servidor do socket (no thread de IO), o despacho para o thread de UI e cada operação. A cola é a `AgensWindow`, sem passar pela interface.
- As folhas de aprovação e o aviso de controle ficam na interface (`ui/chrome_mac.mm`), por ganchos novos na API C (`agens_embed.h`), como as outras telas nativas.
- `tools/agensctl`: cliente de linha de comando para o protocolo, a nossa bancada. Comandos como `agensctl atos create "Cliente A" --cor azul` e `agensctl session --ato … --need cookie:https://app.slack.com:d`. O time do Agens usa para testar sem a Engine.
- `docs/protocolo.md`: a referência do protocolo para o time do Agens, com exemplos.

## Fases

| Fase | O que entra | Pronto quando | Estimativa |
|---|---|---|---|
| 0 | Este plano e o protocolo aprovados | Willian aprova | — |
| 1 | Socket, autenticação do cliente, `hello`, atos, `agensctl`, `protocolo.md` | `agensctl atos create "Cliente A" --cor azul` cria o ato, e ele aparece na lateral | ~1 dia |
| 2 | `login`, `session`, `renew`, `session.lost`, com as folhas de aprovação | Login no Slack de teste por `agensctl login`, depois `session` entrega o cookie `d` só depois do OK. Um header Bearer capturado de um site de teste | 1–2 dias |
| 3 | Controle: `control.*`, `tab.*`, `page.*`, aviso visível e recusa em senha | `agensctl` abre um site, lê o snapshot, clica e digita; a faixa aparece; digitar em senha é recusado | 2–3 dias |
| 4 | Build assinado para o time do Agens usar | O time do Agens instala e conecta com o app deles assinado | depende do #51 e do #55 |
| 5 | `BrowserKit`: a aba dentro do app do Agens (#58, #59) | O Agens mostra uma aba do ato num painel | 1–2 semanas, plano à parte |

Cada fase é uma branch e um PR. Os testes usam perfis e sites de teste locais, nunca contas reais.

## O lado do Agens (repositório deles)

Fica registrado aqui só para combinar a fronteira:
- um cliente do socket na Engine (Go), que troca a bancada de Chromium com CDP sem mudar as pontes (ADR 0014, "Enquanto o navegador não chega");
- o servidor MCP: as ferramentas para o modelo, os nomes de time e quais atos o agente pode usar. Ele fala com o `control.*` daqui.

## Decisões para o Willian

1. **Quem pode conectar:** só apps assinados com o nosso Team ID (recomendado), ou também um token em arquivo para scripts?
2. **Aprovação:** o "Permitir sempre" vale para app + ato + itens (recomendado), ou só para app + ato?
3. **Aviso de controle:** borda colorida na aba mais faixa no topo com "Parar" (recomendado), ou só a faixa?
