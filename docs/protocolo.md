# Protocolo do socket (v1)

Referência para quem escreve um cliente (o time do Agens, em Go). O plano e o porquê estão em [agens.md](agens.md).

## O que existe hoje

| Fase | Operações | Estado |
|---|---|---|
| 1 | `hello`, `atos.*` | implementado |
| 2 | `login` | implementado |
| 2 | `session`, `renew`, evento `session.lost` | especificado, **não implementado** |
| 3 | `control.*`, `tab.*`, `page.*` | implementado |
| 5 | `host.*`, `view.*` (a página dentro de outro app) | especificado, **não implementado** |

Um navegador de fase 1 responde `unknown_op` às demais. Trate `unknown_op` como "este navegador ainda não faz isso".

## Onde fica o socket

Socket Unix, permissão `0600`, na pasta de dados do produto:

- AgensBrowser sozinho: `~/Library/Application Support/AgensBrowser/agens.sock`
- Dentro do Agens: `~/Library/Application Support/Agens/Browser/agens.sock`

Os dois produtos têm dados e sockets separados.

## Quem pode conectar

O navegador lê o processo do outro lado (`LOCAL_PEERTOKEN`) e confere a assinatura de código.

- Dentro do Agens: só o próprio Agens (mesmo Team ID e bundle id).
- AgensBrowser sozinho: apps assinados com o nosso Team ID, depois da folha "O Agens quer usar o AgensBrowser" (**Permitir**, **Permitir sempre**, **Não permitir**).
- Desenvolvimento: **Configurações › Sistema › Aceitar apps sem assinatura**. Vem desligado. O `agensctl` precisa dele enquanto não estiver assinado.

## Formato

UTF-8, um objeto JSON por linha (`\n`). Parâmetros ficam no mesmo objeto, sem aninhar.

```
→ {"id": 1, "op": "atos.list"}
← {"id": 1, "ok": true, "atos": [...]}
← {"id": 1, "ok": false, "error": "not_found", "message": "texto opcional"}
← {"event": "session.lost", "ato": "...", "from": "...", "name": "..."}
```

- `id` é do cliente e volta igual na resposta. Eventos não têm `id` e podem chegar entre um pedido e a resposta dele.
- `error` é um código fixo em `snake_case`; `message` é só para exibir.
- A resposta pode demorar (a folha de aprovação espera a pessoa). Não ponha timeout curto em `login`, `session` e `control.start`.
- **O campo `id` de correlação ocupa o nome `id`.** Por isso, onde a spec original punha um `id` de ato no pedido ou no resultado, este documento usa `ato` (`atos.create`, `atos.rename`, `atos.color`, `atos.open`). Só os itens de `atos.list` mantêm `id`, porque ficam aninhados.

## Versão

`hello` devolve `protocol` (inteiro). Mudança que quebra cliente sobe esse número. Se `protocol` for menor que o necessário, o cliente avisa "Atualize o navegador". `client` é um nome livre, só para diagnóstico.

## Operações

### hello

```
→ {"id": 1, "op": "hello", "client": "agens-engine"}
← {"id": 1, "ok": true, "protocol": 1, "browser": "156.0.8078.79"}
```

### atos (fase 1)

Um pedido para um ato dormindo acorda o ato. `tag` é uma etiqueta opaca do cliente: o navegador só guarda e devolve. Apagar ato não existe na v1.

- O id do ato é o nome da pasta do perfil (`Default`, `Profile 1`…) e não muda. O primeiro ato (`Default`) aparece como "Pessoal".
- `color` é uma de `orange`, `blue`, `pink`, `purple`, `teal`. Outra dá `bad_request`.
- Em `atos.create`, `color` e `tag` são opcionais. O ato é criado sem abrir janela.
- `atos.open` só aceita `url` com `http` ou `https`.

```
→ {"id": 2, "op": "atos.create", "name": "Cliente A", "color": "blue", "tag": "time-123"}
← {"id": 2, "ok": true, "ato": "Profile 1"}

→ {"id": 3, "op": "atos.list"}
← {"id": 3, "ok": true, "atos": [{"id": "Profile 1", "name": "Cliente A", "color": "blue", "tag": "time-123", "asleep": false, "shared": false}]}

→ {"id": 4, "op": "atos.rename", "ato": "Profile 1", "name": "Cliente B"}
→ {"id": 5, "op": "atos.color", "ato": "Profile 1", "color": "teal"}
→ {"id": 6, "op": "atos.open", "ato": "Profile 1", "url": "https://example.com"}
← {"id": 6, "ok": true}
```

### login (fase 2)

Abre o site no ato; a pessoa entra como sempre. A aba fecha quando `done` acontece. `done` é a regra que a ponte conhece: o navegador não adivinha.

- `url` só `http` ou `https`. Não há folha de aprovação: a pessoa vê a aba.
- Regra de cookie: vale assim que o cookie existir para aquela origem, inclusive se a pessoa já estava logada.
- Regra `url_prefix`: vale quando a aba carrega uma URL que começa com o prefixo.
- Se o cliente desconectar antes, a aba fica aberta.

```
→ {"id": 7, "op": "login", "ato": "Profile 1", "url": "https://app.slack.com", "done": {"cookie": "d", "from": "https://app.slack.com"}}
→ {"id": 7, "op": "login", "ato": "Profile 1", "url": "https://outlook.office.com", "done": {"url_prefix": "https://outlook.office.com/mail/"}}
← {"id": 7, "ok": true}
← {"id": 7, "ok": false, "error": "cancelled"}
```

### session (fase 2)

Mostra a folha "Entregar ao Agens: cookie `d` de app.slack.com…" com o motivo e os itens exatos. Só com **Permitir** (ou **Permitir sempre**) os valores saem.

```
→ {"id": 8, "op": "session", "ato": "Profile 1", "reason": "Ponte do Slack",
   "need": [{"type": "cookie", "from": "https://app.slack.com", "name": "d"}]}
← {"id": 8, "ok": true, "items": [{"type": "cookie", "from": "https://app.slack.com", "name": "d", "value": "..."}]}
```

Tipos de `need`:
- `cookie`: lido no cookie store do ato, inclusive httpOnly.
- `localStorage`: lido numa aba do ato aberta naquela origem.
- `header`: capturado das requisições que a própria página faz para `from`; só dura enquanto o pedido está aberto.

### renew (fase 2)

Pega de novo sem janela, numa aba escondida do ato.

```
→ {"id": 9, "op": "renew", "ato": "Profile 1", "need": [...]}
← {"id": 9, "ok": true, "items": [...]}
← {"id": 9, "ok": false, "error": "needs_login"}
```

### control, tab, page (fase 3)

O controle vale **para a conexão**: quando o cliente desconecta, o controle acaba. Um fluxo de vários passos usa uma conexão só.

```
→ {"id": 1, "op": "control.start", "ato": "Profile 1", "reason": "Preencher o formulário"}
← {"id": 1, "ok": true}
→ {"id": 2, "op": "tab.open", "ato": "Profile 1", "url": "https://example.com"}
← {"id": 2, "ok": true, "tab": "t1"}
→ {"id": 3, "op": "page.snapshot", "tab": "t1"}
← {"id": 3, "ok": true, "nodes": [{"ref": "e1", "role": "textField", "name": "Text", "value": "", "depth": 0}, ...]}
→ {"id": 4, "op": "page.type", "tab": "t1", "ref": "e1", "text": "olá"}
→ {"id": 5, "op": "page.click", "tab": "t1", "ref": "e4"}
→ {"id": 6, "op": "page.key", "tab": "t1", "key": "Enter", "modifiers": ["shift"]}
→ {"id": 7, "op": "page.screenshot", "tab": "t1"}
← {"id": 7, "ok": true, "png": "<base64>"}
→ {"id": 8, "op": "tab.navigate", "tab": "t1", "url": "https://example.com/b"}
→ {"id": 9, "op": "tab.close", "tab": "t1"}
→ {"id": 10, "op": "control.stop"}
```

- **`control.start {ato, reason}`**: a pessoa vê a folha "O <app> quer usar abas do ato <ato>" com o `reason` (até 1024 caracteres), e pode escolher **Permitir sempre** (só vale para app assinado). Uma sessão por conexão, para um ato; um segundo `control.start` na mesma conexão dá `bad_request`.
- **Fim do controle**: `control.stop` fecha as abas da sessão. Ao desconectar, as abas ficam abertas, sem controle. Se a pessoa tocar em "Parar", chega o evento `control.stopped` e `tab.*` e `page.*` passam a dar `unauthorized`.
- **`tab.open` e `tab.navigate`**: só `http` e `https`, só no ato da sessão (outro ato dá `denied`). Respondem quando a navegação termina, com teto de 30 s; página que falhou ao carregar ainda é `ok`. O `tab` vale só nesta sessão: fora dela, ou depois de fechada, dá `not_found`.
- **`page.snapshot`**: lista plana, na ordem do documento, de controles, links, títulos, imagens com nome e texto. Cada nó tem `ref`, `role`, `name`, `value` e `depth`, e, quando vale, `focused`, `disabled`, `checked` e `password`. Os papéis são os nomes do Chromium (`textField`, `button`, `link`, `checkBox`, `comboBoxSelect`, `staticText`, `heading`, `image`). Teto de 2000 nós (`truncated: true`). O `ref` vale até a próxima navegação da aba; depois dá `not_found`.
- **`page.click`**: clique de mouse de verdade no centro do elemento, rolando até ele antes.
- **`page.type`**: foca o elemento e digita tecla a tecla, até 10000 caracteres. Quebra de linha e tab dão `bad_request`: use `page.key`.
- **`page.key`**: `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowUp/Down/Left/Right`, `PageUp`, `PageDown`, `Home`, `End` ou um caractere, com `modifiers` opcionais (`shift`, `meta`, `alt`, `ctrl`). Copiar, recortar e colar pelo teclado dão `denied`.
- **`page.screenshot`**: PNG da área visível da aba, a 1x. Funciona com a aba em segundo plano.
- **Senha**: campo de senha vem com `password: true` e sem `value`, inclusive depois de "mostrar senha". `page.type` nele dá `denied`. Com o foco nele, `page.key` só aceita teclas que movem (Tab, Enter, Escape, setas). `page.screenshot` dá `denied` enquanto houver senha revelada na página.
- Nas abas controladas não há senhas salvas, autofill nem downloads.

### host e view (fase 5): a página dentro de outro app

Só existem quando o motor roda **embutido** (aberto por outro app com `--agens-embedded`, sem ícone no Dock e sem janela). No AgensBrowser sozinho respondem `unknown_op`.

Quem desenha a interface é o app hospedeiro: barra de endereço, abas, atos, o aviso do agente. O motor entrega a página e os dados.

**Quem pode.** A conexão que manda `host.attach` vira a do hospedeiro. Tem de ser o processo que abriu o motor, e só pode haver uma. As outras conexões (a Engine, o MCP) seguem como clientes comuns e não usam `view.*`.

```
→ {"id": 1, "op": "host.attach"}
← {"id": 1, "ok": true}
→ {"id": 2, "op": "view.open", "ato": "Profile 1", "url": "https://example.com"}
← {"id": 2, "ok": true, "tab": "v3"}
→ {"id": 3, "op": "view.attach", "tab": "v3", "width": 1000, "height": 640, "scale": 2}
← {"id": 3, "ok": true}
← {"event": "view.layer", "tab": "v3", "context": 3626435823, "width": 1000, "height": 640, "scale": 2}
← {"event": "view.tab", "tab": "v3", "ato": "Profile 1", "title": "Example Domain", "url": "https://example.com/", "loading": false, "audible": false, "can_back": false, "can_forward": false}
```

- **Abas.** `view.tabs {ato}` lista as abas do ato: `{tabs: [{tab, ato, title, url, loading, audible, can_back, can_forward, control?}]}`. O id `v…` vale enquanto a aba existir e inclui as abas que um agente abriu. `view.open {ato, url?}`, `view.close {tab}`, `view.navigate {tab, text}` (endereço ou busca, como na barra), `view.back`, `view.forward`, `view.reload`, `view.stop`. Eventos: `view.tab` a cada mudança, `view.closed {tab}` e `view.favicon {tab}` quando o ícone muda (`view.favicon {tab}` como pedido devolve `{png}`).
- **Mostrar.** `view.attach {tab, width, height, scale}` faz a aba desenhar naquele tamanho (em pontos) e manda `view.layer {tab, context, width, height, scale}`: o app mostra o `context` num `CALayerHost`. O `context` muda ao trocar de processo ou de tamanho, e o evento vem de novo. `view.resize {tab, width, height, scale}` e `view.detach {tab}`. Várias abas podem estar ligadas ao mesmo tempo (painéis lado a lado).
- **Entrada.** O app manda o que a vista recebeu: `view.focus {tab, on}`, `view.mouse {tab, data, x, y}`, `view.mouse.leave {tab}`, `view.wheel {tab, data, x, y}`, `view.key {tab, data, text, commands, marked, sel_start, sel_end, had_marked, unmarked}` e `view.edit {tab, command}` (`cut`, `copy`, `paste`, `selectAll`, `undo`, `redo`). `data` é o `NSEvent` serializado (`CGEventCreateData`, em base64); `x` e `y` contam do canto de cima da vista, em pontos. Sem `id`, o motor não responde.
- **Aba com agente.** Quando um agente controla a aba, `view.tab` traz `control: {agent, title, detail, state}`, com `state` `"working"` ou `"paused"`, para o app desenhar o aviso. O app manda `view.control {tab, action}` com `take` (Assumir), `give` (Devolver) ou `end` (encerrar). A pessoa pode ver a aba do agente o tempo todo; com `take`, as teclas e os cliques dela passam a valer e os do agente respondem `paused`.
- **Aprovações.** Embutido, o motor não mostra folha: manda `approval.ask {ask, title, detail, offer_always}` ao hospedeiro, que desenha e responde `approval.answer {ask, answer}` com `allow`, `always` ou `deny`. Sem hospedeiro ligado, a resposta é `denied`.
- **Detalhes do formato.** `view.attach`, `view.resize` e `view.detach` vão com `id` e têm resposta; as operações de entrada vão sem `id`. Em `view.key`, só `tab` e `data` são obrigatórios (soltar tecla e mudar modificador não mandam o resto). `width` e `height` são pontos inteiros; `scale`, `x` e `y` podem ter decimais; `context` é um número de 32 bits sem sinal. `ask` é texto. `control` ausente ou `null` quer dizer sem agente. Toda aba que aparece num ato gera `view.tab`, inclusive as que o próprio hospedeiro abriu. `hello` continua devolvendo `protocol` 1: um motor sem estas operações responde `unknown_op` a `host.attach`.
- **Se o motor cair**, a conexão fecha. O app abre o motor de novo, refaz `host.attach` e religa as vistas; os ids `v…` antigos não valem mais.

## Erros

| Código | Quando |
|---|---|
| `bad_request` | JSON inválido, campo faltando ou com tipo errado. |
| `unknown_op` | Operação que o navegador não conhece (inclusive fases ainda não implementadas). |
| `not_found` | Ato, aba ou `ref` que não existe. |
| `unauthorized` | O cliente não passou na checagem de assinatura ou de aprovação, ou usou `tab`/`page` sem `control.start` nesta conexão. |
| `denied` | A pessoa tocou em **Não permitir**, ou a operação é proibida (ex.: `page.type` em campo de senha). |
| `failed` | O navegador não conseguiu criar ou abrir o ato, ou está fechando. |
| `cancelled` | `login`: a pessoa fechou a aba antes do fim. |
| `needs_login` | `renew`: o site pediu login; use `login`. |

## Eventos

| Evento | Campos | Quando |
|---|---|---|
| `session.lost` | `ato`, `from`, `name` | Um item de sessão vigiado sumiu ou expirou no cookie store do ato. |
| `control.stopped` | `reason` | O controle desta conexão acabou: `"user"` (a pessoa tocou em "Parar") ou `"sharing_changed"` (mudou o grupo de atos que compartilham cookies com este). |

## Regras de segurança que o cliente sente

- **Valores nunca em log.** Os valores de `session`/`renew` só passam pelo socket. Guarde no Keychain; não escreva em log nem em mensagem de erro.
- **Só os itens exatos do `need`.** Nunca o cookie jar inteiro. Item novo é aprovação nova.
- **Aprovação.** `session` e `control.start` esperam a pessoa. "Permitir sempre" vale por app, ato e itens exatos.
- **Controle só vê as abas que ele abriu**, no ato aprovado. As abas da pessoa não aparecem.
- **Senha é recusada.** O snapshot traz campo de senha sem valor, e `page.type` nele dá `denied`. Cookies e senhas salvas ficam fora do controle.
- **Faixa visível** nas abas controladas: "Controlado pelo Agens · Parar".
- **Cookies compartilhados.** Cada ato tem o interruptor "Compartilhar cookies"; os atos com ele ligado dividem os cookies entre si, e `atos.list` traz `shared` em cada ato. Um ato que compartilha funciona normalmente com `login`, `session` e `control`: a folha de aprovação avisa com quais atos ele divide os cookies. Se esse grupo mudar durante um controle, o controle acaba com `control.stopped` e `reason` `"sharing_changed"`. Só a pessoa muda o interruptor, pela interface.

## Testando com agensctl

`tools/agensctl` (`--socket PATH` ou `AGENS_SOCK`). Sai com 0 se `ok`, 1 se `ok:false`, 2 se não conseguiu falar com o navegador.

```
agensctl hello
agensctl atos create "Cliente A" --cor blue --tag time-123
agensctl atos list
agensctl atos rename ID "Cliente B"
agensctl atos color ID teal
agensctl atos open ID https://example.com
agensctl login --ato ID --url http://127.0.0.1:8765/login --done cookie:http://127.0.0.1:8765:d
agensctl login --ato ID --url http://127.0.0.1:8765/login --done url_prefix:http://127.0.0.1:8765/app/
agensctl session --ato ID --need cookie:http://127.0.0.1:8765:d --reason "teste"
agensctl renew --ato ID --need header:http://127.0.0.1:8765:Authorization
agensctl listen
```

`--need` é `TIPO:ORIGEM:NOME`. A origem tem `:` (porta), então o tipo é o que vem antes do primeiro `:` e o nome o que vem depois do último.

Cada subcomando abre uma conexão e fecha ao responder, então o controle acabaria junto. Para controle use `raw`, que manda uma linha por vez na mesma conexão e imprime cada resposta e evento. Ele lê do stdin, então dá para digitar a linha seguinte depois de ver o `tab` devolvido:

```
agensctl raw
{"id": 1, "op": "control.start", "ato": "ID", "reason": "teste"}
{"id": 2, "op": "tab.open", "ato": "ID", "url": "http://127.0.0.1:8765/form"}
{"id": 3, "op": "page.snapshot", "tab": "t1"}
```

Ao fechar o stdin (Ctrl-D) a conexão cai e o controle acaba. Pedido sem `id` não espera resposta. Os subcomandos `control`, `tab` e `page` (`agensctl page screenshot T1 --out a.png`) servem para um passo só, por exemplo para ver o `unauthorized` sem controle aberto.

Sites de teste locais (login com cookie httpOnly, Bearer, formulário): [tools/sites-teste](../tools/sites-teste/README.md).

