# Plano: o navegador dentro do Agens

O Agens precisa de quatro coisas do navegador (ADR 0014 do Agens):

1. criar e usar atos por código, um ou mais por time;
2. entregar a sessão de um site para as pontes, só com os itens do `Need` e com o OK da pessoa;
3. ser controlado por um agente (o MCP do Agens) de forma segura;
4. mostrar as abas dentro das janelas do Agens.

Tudo isso é requisito para lançar o Agens.

## Um código, dois produtos

- **Dentro do Agens:** quem usa o Agens não instala um segundo app. O motor do navegador vai dentro do `Agens.app`, como processo auxiliar (`Agens.app/Contents/Helpers/`). Ele não tem ícone no Dock, não aparece como app separado e é aberto e fechado pelo Agens. As abas aparecem nos painéis do Agens pelo embed (`BrowserKit`).
  - O motor não pode rodar dentro do processo do Agens: o Chromium precisa ser dono do próprio processo, e esse é o caminho do CEF, que descartamos.
- **AgensBrowser sozinho:** o navegador como produto próprio, com a nossa janela, para quem não usa o Agens.

Os dois saem do mesmo repositório e do mesmo build, empacotados de dois jeitos, e assinados com o mesmo Team ID.

### Dados separados, com opção de conectar

- Os atos do Agens e os do AgensBrowser sozinho **nunca se misturam**: cada um tem a própria pasta de dados (`~/Library/Application Support/Agens/Browser/` e `~/Library/Application Support/AgensBrowser/`) e o próprio socket.
- **Conectar:** quem tem os dois pode, no Agens, ligar um time a um ato do AgensBrowser sozinho, por exemplo para aproveitar logins que já existem lá. O Agens conecta no socket do AgensBrowser com o mesmo protocolo, e o AgensBrowser pede a aprovação da pessoa como pede para qualquer app (ver "Quem pode conectar"). Nada é copiado de um lado para o outro. Desligar a conexão volta ao normal.

## Regras

- **O navegador não conhece o Agens.** Nada de time, Gerente ou ponte no código daqui. A API fala de atos, sites e itens, e o Agens dá os nomes.
- **Nada de porta de depuração (CDP).** Com ela, qualquer processo da máquina controla o navegador inteiro sem pedir nada. Por dentro, onde for útil, usamos uma sessão de DevTools no próprio processo, que nunca abre porta.
- **Só o que foi pedido, e só com o OK da pessoa.** A sessão entrega exatamente os itens do `Need`, nunca o cookie jar inteiro. O controle por agente pede aprovação por ato e deixa um aviso visível enquanto dura.
- **Segredo não vai para disco nem para log.** O valor de um cookie ou header só passa pelo socket. Quem guarda é a Engine, no Keychain.
- **O controle não toca em senha.** Ele não lê nem digita em campo de senha, e cookies e senhas salvas ficam fora do alcance dele.
- **Isolamento entre times.** Cada ato é um perfil do Chromium (cookies, logins, extensões, histórico e cache próprios). Se a pessoa ligar "Compartilhar cookies entre atos", o isolamento acaba: enquanto ele estiver ligado, `session` e `control` respondem erro (`isolation_off`) e a interface explica o motivo.

## O socket

- **Onde:** dentro da pasta de dados de cada produto: `…/Agens/Browser/agens.sock` ou `…/AgensBrowser/agens.sock`. É um socket Unix com permissão `0600`, dentro da pasta do usuário, então só os apps daquele usuário do Mac o enxergam. No Windows será um named pipe (#61).
- **Formato:** uma mensagem JSON por linha. Pedido: `{"id": 1, "op": "atos.list", ...}`. Resposta: `{"id": 1, "ok": true, ...}` ou `{"id": 1, "ok": false, "error": "..."}`. Evento, sem `id`: `{"event": "session.lost", ...}`.
- **Quem pode conectar:** o navegador lê o processo do outro lado (`LOCAL_PEERTOKEN`) e confere a assinatura de código.
  - Dentro do Agens: só o próprio Agens (o mesmo Team ID e o bundle id do Agens).
  - No AgensBrowser sozinho: apps com o nosso Team ID, depois da aprovação "O Agens quer usar o AgensBrowser", com **Permitir**, **Permitir sempre** e **Não permitir**.
  - Para desenvolvimento, "Aceitar apps sem assinatura" em Configurações › Sistema, que vem desligado.
- **Versão:** `hello` devolve a versão do protocolo. Mudança que quebra cliente sobe a versão. Navegador velho demais responde e o cliente avisa "Atualize".

## O motor ausente ou fechado

- **Dentro do Agens:** o motor vem no próprio `Agens.app`, então não tem como faltar. Se ele cair, o Agens abre de novo e mostra "Reabrindo o navegador…" nos painéis afetados.
- **Conexão com o AgensBrowser sozinho:** o Agens procura o app pelo bundle id (`com.sugiyamalabs.agensbrowser`, via `NSWorkspace`).
  - Não instalado: a opção de conectar não aparece.
  - Instalado e fechado: o Agens abre o app em segundo plano e espera o socket.
  - Aberto: conecta direto.
- **Aberto em segundo plano antes da primeira vez:** os primeiros passos não aparecem. Eles ficam para quando a pessoa abrir o app por conta própria.
- **Sem o navegador**, o resto do Agens funciona. As partes que dependem dele (login das pontes, sessão, agente no navegador) mostram o motivo e o que fazer.

## As operações (v1)

### Atos

| Operação | O que faz |
|---|---|
| `hello {client}` | Versão do protocolo e do navegador. |
| `atos.list` | `{atos: [{id, name, color, tag, asleep}]}`. O `id` é estável (a pasta do perfil). |
| `atos.create {name, color, tag}` | Cria o ato e devolve `{ato}`, o id dele (o campo `id` da mensagem já é o da correlação). `tag` é uma etiqueta opaca do cliente (o Agens põe o id do time): o navegador só guarda e devolve. Assim o Agens acha o ato do time mesmo se a pessoa o renomear. |
| `atos.rename {ato, name}` / `atos.color {ato, color}` | Renomeia e troca a cor. |
| `atos.open {ato, url?}` | Abre o ato, opcionalmente numa URL. No Agens, num painel. No AgensBrowser, na janela dele. |

- Um pedido para um ato dormindo acorda o ato sozinho. Os atos que dormem (#9) precisam respeitar isso: um ato com uma operação do socket em andamento não dorme.
- Apagar ato não entra na v1. É irreversível e fica só na interface, com confirmação.

### Sessão (as pontes)

| Operação | O que faz |
|---|---|
| `login {ato, url, done}` | Abre o site no ato. A pessoa entra como sempre, e a aba fecha quando `done` acontece. Responde `ok` ao fim, ou `cancelled` se a pessoa fechar a aba. |
| `session {ato, need, reason}` | Mostra a folha "Entregar ao Agens: cookie `d` de app.slack.com…", com o motivo e os itens exatos. Com **Permitir** (ou **Permitir sempre** para esse ato e esses itens), devolve os valores. |
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

O agente nunca vê as abas que a pessoa abriu, só as que ele abriu, e só no ato aprovado.

## O embed (`BrowserKit`)

- O motor desenha a aba, e o Agens mostra essa vista dentro do painel dele. No Mac, o caminho a provar é o `remote_cocoa` do Chromium, o mesmo mecanismo que já põe a janela do navegador num processo e o conteúdo em outro (#58).
- O `BrowserKit` é a parte Swift que o Agens importa: abre o motor auxiliar, conecta no socket e entrega uma `NSView` por aba, mais as chamadas do protocolo em Swift (#59). Ele vem como `xcframework` com checksum nos Releases daqui, e o Agens fixa a versão.
- Barra de endereço, abas e atos no Agens são desenhados pelo Agens. O kit entrega a página e os eventos (título, ícone, carregando, áudio, URL).

## Onde fica no código

- `chrome/browser/agens/bridge/`: o servidor do socket (no thread de IO), o despacho para o thread de UI e cada operação. A cola é a `AgensWindow`, sem passar pela interface.
- As folhas de aprovação e o aviso de controle ficam na interface (`ui/chrome_mac.mm`), por ganchos novos na API C (`agens_embed.h`). Dentro do Agens, o kit repassa esses pedidos para o Agens desenhar.
- `kit/apple/`: o `BrowserKit`.
- `tools/agensctl`: cliente de linha de comando para o protocolo, a nossa bancada. Comandos como `agensctl atos create "Cliente A" --cor blue --tag time-123` e `agensctl session --ato … --need cookie:https://app.slack.com:d`. O time do Agens usa para testar sem a Engine.
- `docs/protocolo.md`: a referência do protocolo para o time do Agens, com exemplos.

## Fases

| Fase | O que entra | Pronto quando | Estimativa |
|---|---|---|---|
| 0 | Este plano e o protocolo aprovados | Willian aprova | — |
| 1 | Socket, autenticação do cliente, `hello`, atos com `tag`, `agensctl`, `protocolo.md` | `agensctl atos create "Cliente A" --cor blue --tag t1` cria o ato, e ele aparece na lateral | ~1 dia |
| 2 | `login`, `session`, `renew`, `session.lost`, folhas de aprovação, recusa com cookies compartilhados | Login num Slack de teste por `agensctl login`, depois `session` entrega o cookie `d` só depois do OK. Um header Bearer capturado de um site de teste | 1–2 dias |
| 3 | Controle: `control.*`, `tab.*`, `page.*`, aviso visível, recusa em senha | `agensctl` abre um site, lê o snapshot, clica e digita; a faixa aparece; digitar em senha é recusado | 2–3 dias |
| 4 | Prova do embed: um app Swift de exemplo mostra uma aba do motor auxiliar | A aba aparece e responde a clique e teclado dentro do app de exemplo, com o motor em outro processo | ~1 semana, a parte mais incerta |
| 5 | `BrowserKit` e o empacotamento dentro do `Agens.app` | O Agens importa o kit, abre o motor auxiliar sem ícone no Dock e mostra uma aba do ato do time num painel | ~1 semana |
| 6 | Build assinado e notarizado dos dois produtos | O Agens instala e funciona num Mac limpo, sem o AgensBrowser sozinho | depende do #51 e do #55 |

- As fases 1 a 3 já destravam as pontes e o MCP do time do Agens, que podem usar o AgensBrowser sozinho enquanto o embed não fica pronto.
- Cada fase é uma branch e um PR. Os testes usam perfis e sites de teste locais, nunca contas reais.

## O lado do Agens (repositório deles)

Fica registrado aqui só para combinar a fronteira:
- o cliente do socket na Engine (Go), que troca a bancada de Chromium com CDP sem mudar as pontes (ADR 0014, "Enquanto o navegador não chega");
- o servidor MCP: as ferramentas para o modelo, os nomes de time e quais atos cada agente pode usar. Ele fala com o `control.*` daqui;
- os painéis com as abas, usando o `BrowserKit`;
- a tela "conectar ao AgensBrowser" por time.

## Decisões para o Willian

1. **Quem pode conectar no AgensBrowser sozinho:** só apps assinados com o nosso Team ID (recomendado), ou também um token em arquivo para scripts?
2. **"Permitir sempre":** vale para app + ato + itens exatos (recomendado), ou para app + ato?
3. **Aviso de controle:** borda na aba e faixa com "Parar" (recomendado), ou só a faixa?
