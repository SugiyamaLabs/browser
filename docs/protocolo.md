# Protocolo do socket (v1)

Referência para quem escreve um cliente (o time do Agens, em Go). O plano e o porquê estão em [agens.md](agens.md).

## O que existe hoje

| Fase | Operações | Estado |
|---|---|---|
| 1 | `hello`, `atos.*` | implementado |
| 2 | `login` | implementado |
| 2 | `session`, `renew`, evento `session.lost` | especificado, **não implementado** |
| 3 | `control.*`, `tab.*`, `page.*` | implementado |
| 5 | `host.*`, `view.*`, `ui.*` (a página dentro de outro app) | implementado |

Um navegador de fase 1 responde `unknown_op` às demais. Trate `unknown_op` como "este navegador ainda não faz isso".

## Onde fica o socket

Socket Unix, permissão `0600`, na pasta de dados do produto:

- AgensBrowser sozinho: `~/Library/Application Support/AgensBrowser/agens.sock`
- Dentro do Agens: `~/Library/Application Support/Agens/Browser/agens.sock`

Os dois produtos têm dados e sockets separados.

## Quem pode conectar

O navegador lê o processo do outro lado (`LOCAL_PEERTOKEN`) e confere a assinatura de código.

- Dentro do Agens: só o próprio Agens (mesmo Team ID e bundle id).
- AgensBrowser sozinho: apps assinados com o nosso Team ID (o mesmo da assinatura do próprio motor), depois da folha "O Agens quer usar o AgensBrowser" (**Permitir**, **Permitir sempre**, **Não permitir**).
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

- **`control.start {ato, reason, agent?, allow?}`**: a pessoa vê a folha "O <app> quer usar abas do ato <ato>" com o `reason` (até 1024 caracteres), e pode escolher **Permitir sempre** (só vale para app assinado). Uma sessão por conexão, para um ato; um segundo `control.start` na mesma conexão dá `bad_request`.
- **Nome e permissões.** `agent` é o nome que aparece no aviso (até 40 caracteres; o padrão é o nome do app). `allow` é uma lista com qualquer um de: `"passwords"` (senhas salvas e preenchimento automático do navegador, inclusive endereços e cartões, voltam a funcionar nas abas da sessão), `"clipboard"` (copiar, recortar e colar pelo teclado, inclusive em campo de senha) e `"eval"` (`page.eval` em endereço local). A folha mostra o que foi pedido; com `clipboard`, avisa que o agente pode ler o que a pessoa copiou em qualquer app e trocar o que está copiado. Sem `allow`, os três ficam bloqueados. As extensões do ato rodam nas abas controladas com ou sem permissão. Pedir mais do que da última vez faz a folha aparecer de novo, mesmo com "Permitir sempre".
- **O que o agente está fazendo.** `control.status {title?, detail?}` (até 120 caracteres cada) troca as duas linhas do aviso; vazio volta ao padrão ("<agent> está usando esta aba" e o `reason`).
- **Assumir e devolver.** No aviso, a pessoa toca em **Assumir**: chega o evento `control.paused`, e `tab.*` e `page.*` respondem `paused` até ela tocar em **Devolver** (`control.resumed`). A bolha de parar encerra o controle (`control.stopped`).
- **Fim do controle**: `control.stop` fecha as abas da sessão. Ao desconectar, as abas ficam abertas, sem controle. Se a pessoa tocar em "Parar", chega o evento `control.stopped` e `tab.*` e `page.*` passam a dar `unauthorized`.
- **`tab.open` e `tab.navigate`**: só `http` e `https`, só no ato da sessão (outro ato dá `denied`). Respondem quando a navegação termina, com teto de 30 s; página que falhou ao carregar ainda é `ok`. O `tab` vale só nesta sessão: fora dela, ou depois de fechada, dá `not_found`.
- **`tab.back`, `tab.forward`, `tab.reload {tab}`**: respondem quando a navegação termina (teto de 30 s). Sem para onde ir, `bad_request`. `tab.reload` também dá `bad_request` se a página veio de um formulário enviado, para não reenviar.
- **`page.snapshot`**: lista plana, na ordem do documento, de controles, links, títulos, imagens com nome e texto. Cada nó tem `ref`, `role`, `name`, `value` e `depth`, e, quando vale, `focused`, `disabled`, `checked` e `password`. Os papéis são os nomes do Chromium (`textField`, `button`, `link`, `checkBox`, `comboBoxSelect`, `staticText`, `heading`, `image`). Teto de 2000 nós (`truncated: true`). O `ref` vale até a próxima navegação da aba; depois dá `not_found`.
- **`page.click`**: clique de mouse de verdade no centro do elemento, rolando até ele antes.
- **`page.type`**: foca o elemento e digita tecla a tecla, até 10000 caracteres. Quebra de linha e tab dão `bad_request`: use `page.key`.
- **`page.key`**: `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowUp/Down/Left/Right`, `PageUp`, `PageDown`, `Home`, `End` ou um caractere, com `modifiers` opcionais (`shift`, `meta`, `alt`, `ctrl`). Copiar, recortar e colar pelo teclado dão `denied`.
- **`page.hover {tab, ref}`** move o mouse até o elemento. **`page.scroll {tab, dy, ref?}`** rola `dy` pixels no elemento ou no centro da página.
- **`page.console {tab}`** → `{messages: [{level, text, url, line}]}`: as últimas 200 mensagens do console e erros não tratados desde que a sessão pegou a aba. `console.log` e `console.info` chegam como `info`; erro não tratado, como `error`.
- **`page.network {tab}`** → `{requests: [{url, method, status ou error, type}]}`: só as requisições que falharam (erro de rede ou status 400 ou mais), até 200. Nunca traz cabeçalhos, cookies nem corpo; a URL vem sem o trecho depois de `#`.
- **Diálogos.** `alert`, `confirm`, `prompt` e `beforeunload` de uma aba controlada não abrem janela: chega o evento `page.dialog {tab, type, message}`, as outras operações da aba respondem `dialog_open`, e o agente responde com `page.dialog {tab, action, text?}` (`accept` ou `dismiss`), na hora. Até 8 diálogos esperam em fila, o mais antigo primeiro. Se a pessoa assumir, o mais antigo aparece para ela e os outros são cancelados.
- **`page.eval {tab, js}`** → `{result}`: precisa de `"eval"` em `allow` e roda JavaScript **só em endereço local** (`localhost`, `*.localhost`, `127.0.0.1`, `[::1]`); sem a permissão ou em qualquer outro site responde `denied`. Numa página local o script lê tudo, inclusive senha que a pessoa digitou ali. O resultado tem de caber em JSON e em 1 MB; promessa não é esperada; teto de 10 s.
- **`page.screenshot`**: PNG da área visível da aba, a 1x. Funciona com a aba em segundo plano.
- **Senha**: campo de senha vem com `password: true` e sem `value`, inclusive depois de "mostrar senha". `page.type` nele dá `denied`. Com o foco nele, `page.key` só aceita teclas que movem (Tab, Enter, Escape, setas). `page.screenshot` dá `denied` enquanto houver senha revelada na página.
- Nas abas controladas não há senhas salvas, autofill nem downloads.

### host e view (fase 5): a página dentro de outro app

Só existem quando o motor roda **embutido** (aberto por outro app com `--agens-embedded`, sem ícone no Dock e sem janela). No AgensBrowser sozinho respondem `unknown_op`.

Quem desenha a interface é o app hospedeiro: barra de endereço, abas, atos, o aviso do agente. O motor entrega a página e os dados.

**Quem pode.** A conexão que manda `host.attach` vira a do hospedeiro. Tem de ser o processo que abriu o motor, e só pode haver uma. As outras conexões (a Engine, o MCP) seguem como clientes comuns e não usam `view.*`.

**Quem conecta no motor embutido.** O processo que abriu o motor, sempre. Outros apps só se forem assinados com o nosso Team ID e o identificador de assinatura deles estiver na lista que o hospedeiro passa ao abrir o motor (`--agens-allowed-clients=<id>,<id>`). Não há folha de conexão. Em build de desenvolvimento, `--agens-accept-unsigned` deixa entrar cliente sem assinatura.

**O que a página abre por conta própria** (menu de `select`, botão direito, `alert`/`confirm`/`prompt`, escolher arquivo, login HTTP, pedido de permissão do site, instalar extensão) chega ao hospedeiro como `ui.ask`: veja "Passo 5.3", abaixo. Sem hospedeiro ligado, tudo isso é cancelado na hora.

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
- **Detalhes do formato.** `view.attach`, `view.resize` e `view.detach` vão com `id` e têm resposta; as operações de entrada vão sem `id`. Em `view.key`, só `tab` e `data` são obrigatórios (soltar tecla e mudar modificador não mandam o resto). `width` e `height` são pontos inteiros, até 8192; `scale`, `x` e `y` podem ter decimais; `context` é um número de 32 bits sem sinal. `ask` é texto. `control` ausente ou `null` quer dizer sem agente. Toda aba que aparece num ato gera `view.tab`, inclusive as que o próprio hospedeiro abriu. `hello` continua devolvendo `protocol` 1: um motor sem estas operações responde `unknown_op` a `host.attach`.
- **Se o motor cair**, a conexão fecha. O app abre o motor de novo, refaz `host.attach` e religa as vistas; os ids `v…` antigos não valem mais.

#### Passo 5.3: o hospedeiro desenha menus, diálogos e pedidos

São só adições, então o protocolo continua v1: um motor mais antigo simplesmente não manda `ui.ask` e cancela tudo na hora.

Um mecanismo só, no formato de `approval.ask` / `approval.answer`: o motor manda o evento `ui.ask {ask, kind, tab, ...}` com um `ask` próprio (texto, `"u1"`, `"u2"`...), o hospedeiro desenha e responde com a operação `ui.answer {ask, ...}`. O `kind` diz o que é: `select`, `context_menu`, `dialog`, `file`, `auth`, `permission` ou `extension`. `tab` é o id `v…` da aba que causou o pedido (ausente em `extension`, que não é de uma aba).

```
← {"event": "ui.ask", "ask": "u4", "kind": "select", "tab": "v3", "x": 120, "y": 340, "width": 180, "items": [{"label": "Brasil"}, {"label": "Chile", "disabled": true}, {"label": "Peru"}], "selected": 0}
→ {"id": 20, "op": "ui.answer", "ask": "u4", "index": 2}
← {"id": 20, "ok": true}
```

**Regras comuns.**
- **Só o hospedeiro.** `ui.ask` vai só para a conexão do `host.attach`; `ui.answer` de outra conexão dá `unauthorized`. Sem hospedeiro ligado, tudo é cancelado na hora, como hoje.
- **Resposta.** `ui.answer` leva `id` e tem resposta `{ok: true}`. `ask` que não existe mais (já respondido, cancelado, expirado) dá `not_found`. Campos que não cabem no `kind` dão `bad_request`. Um `ask` só se responde uma vez.
- **Cancelar.** O hospedeiro cancela com `ui.answer {ask, cancel: true}`. O motor cancela sozinho quando o hospedeiro desconecta, a aba fecha ou navega, ou a página desiste do pedido (o evento `ui.cancel {ask, reason}` avisa o hospedeiro para fechar o que desenhou; `reason` é `"closed"`, `"navigated"` ou `"gone"`; `"gone"` também vale quando o pedido volta para o agente no Devolver). Cancelar tem o mesmo efeito de hoje: `select` sem escolha, diálogo recusado (`beforeunload` sem hospedeiro é aceito, senão fechar a aba ou sair do motor travaria), arquivo nenhum, login sem credencial (a página mostra o 401), permissão negada sem lembrar, extensão não instalada.
- **Sem prazo.** Como em `approval.ask`, o pedido espera a pessoa o tempo que for; só os cancelamentos acima o encerram.
- **Fila.** Pedidos da mesma aba e do mesmo `kind` esperam em fila, o mais antigo primeiro; até 4 pedidos abertos por aba e 16 no total, e o que passar disso é cancelado.
- **Nada sensível em evento, erro ou log.** O motor nunca põe senha, cookie nem conteúdo de arquivo em `ui.ask`, em `ui.cancel`, em erro ou em log. O que a pessoa digitou no hospedeiro (senha, texto do `prompt`) só passa em `ui.answer`, e o motor não registra o corpo dessa operação.
- **Aba com agente.** Cada item diz quem responde. Valem as regras de "Assumir e devolver": com o agente trabalhando, `select`, `context_menu`, `file` e `auth` da aba não chegam ao hospedeiro (o agente responde pelo que já existe, ou fica cancelado); `permission` e `extension` são exceção, explicadas nos itens 6 e 7. Quando a pessoa toca em **Assumir**, o pedido mais antigo da aba chega ao hospedeiro e os outros são cancelados (a mesma regra da fila de `page.dialog`). Ela toca em **Devolver** e os pedidos novos voltam ao agente.

**1. Menu de `select`** (`kind: "select"`). Campos: `x`, `y` (canto de cima à esquerda do `<select>`, em pontos, contados do canto de cima da vista, como `view.mouse`), `width` (largura do controle), `items: [{label, disabled?, group?}]` (cada `label` até 200 caracteres; até 1000 itens, e `truncated: true` quando a lista da página é maior) (`group: true` é cabeçalho de `<optgroup>`, não se escolhe), `selected` (índice atual ou `-1`). Resposta: `ui.answer {ask, index}` com o índice em `items`, ou `cancel`. Índice de item `disabled` ou de cabeçalho dá `bad_request`. Quem responde: o hospedeiro. Aba com agente: o agente escolhe com `page.click` e o menu não chega ao hospedeiro; só depois do Assumir. Setas e Enter dentro do menu são do hospedeiro; o motor não manda teclas.

**2. Botão direito** (`kind: "context_menu"`). O app não precisa avisar o clique: o motor decide pelo `view.mouse` com o botão direito e manda `ui.ask` com `x`, `y` (ponto do clique) e `context`:

```
{"link": "https://example.com/a", "image": "https://example.com/i.png", "selection": "texto", "editable": true, "actions": ["open_link_new_tab", "copy_link", "copy_image", "save_image", "copy", "cut", "paste", "select_all", "back", "forward", "reload"]}
```

`link` e `image` só vêm se o clique foi neles (o endereço inteiro, o mesmo que as ações usam); `selection` vem cortado em 200 caracteres; `editable` diz que é campo de texto. `actions` é a lista do que vale agora (`open_link_new_tab` só para link `http(s)`, e abre em segundo plano), na ordem em que o motor sugere; o hospedeiro pode desenhar menos, nunca ação fora da lista. Resposta: `ui.answer {ask, action}` com um item de `actions`, ou `cancel`. O motor executa a ação. Ação fora da lista dá `bad_request`. Não há ação que leia o conteúdo para o hospedeiro: copiar vai para a área de transferência do sistema, pelo motor. Aba com agente: o botão direito da pessoa só chega depois do Assumir; o do agente não existe (não há operação para ele). `save_image` cai nas regras de download de hoje.

**3. `alert`, `confirm`, `prompt`, `beforeunload` de aba sem agente** (`kind: "dialog"`). Campos: `type` (`alert`, `confirm`, `prompt`, `beforeunload`), `message` (até 1024 caracteres), `origin` (de quem é o diálogo; o hospedeiro mostra), `default` (só em `prompt`, até 1024 caracteres). Resposta: `ui.answer {ask, accept: true|false, text?}`; `text` só em `prompt` aceito. `alert` aceita ou fecha: tanto faz. `beforeunload` aceito deixa a página sair. **Convivência com `page.dialog`:** o mecanismo de `page.dialog` não muda. Aba com agente: o diálogo vai para o agente como hoje (`page.dialog` e `dialog_open`) e `ui.ask` não é usado. Aba sem agente: `ui.ask` para o hospedeiro. Se um agente passa a controlar uma aba com `ui.ask` de diálogo aberto, o pedido é cancelado e o agente recebe `page.dialog` do mesmo diálogo. Se a pessoa assume, vale a regra de Assumir acima: o mais antigo vai ao hospedeiro por `ui.ask`, os outros são cancelados.

**4. Escolher arquivo** (`kind: "file"`). Campos: `mode` (`open`, `open_multiple`, `folder`, `save`), `accept` (lista de extensões que a página pediu, ex. `[".png", ".jpg"]`; tipo MIME como `image/*` já chega convertido em extensões; é sugestão, o hospedeiro pode filtrar o painel), `suggested` (nome sugerido, só em `save`). Resposta: `ui.answer {ask, paths: ["/abs/a.png"]}`, caminhos absolutos; um só se não for `open_multiple`, até 100 se for; `paths` vazio equivale a cancelar. O motor confere o tipo: caminho que não existe ou que não bate com `mode` dá `bad_request`. Em `save`, o motor grava depois e o hospedeiro só escolhe o destino. O conteúdo do arquivo nunca passa pelo socket, e o motor só lê o caminho no momento em que a página envia. Aba com agente: não existe `page.*` para arquivo; fica cancelado (nenhum arquivo) para o agente, e só a pessoa, depois do Assumir, chega ao painel.

**5. Login HTTP** (`kind: "auth"`). Campos: `origin` (esquema, host e porta de quem pede), `realm` (texto do servidor, até 200 caracteres), `proxy` (`true` se quem pede é um proxy), `retry` (`true` se o hospedeiro já mandou credencial para a mesma aba, origem e `realm`: em geral, a anterior foi recusada). Resposta: `ui.answer {ask, username, password}`; o hospedeiro pode pegar do Keychain dele. O motor entrega a credencial ao Chromium e esquece; não guarda nem lembra. `password` nunca aparece em `ui.ask`, em erro nem em log, e o motor tira `username` e `password` do que registra de `ui.answer`. Aba com agente: o agente não recebe nem responde; fica cancelado até a pessoa assumir (ela vê o pedido no hospedeiro). `retry` ajuda o hospedeiro a não repetir a mesma senha.

**6. Permissão do site** (`kind: "permission"`). Campos: `origin`, `permission` (`camera`, `microphone`, `geolocation`, `notifications`; mais de uma pedida junto, como câmera e microfone, chega como um pedido com `permissions: ["camera", "microphone"]` e `permission` ausente). Resposta: `ui.answer {ask, allow: true|false, remember?}`. `remember: true` guarda a resposta por origem e ato, no perfil do ato; o motor só aceita `remember` com `allow` falso ou verdadeiro, nunca sem `allow`. Sem `remember`, vale só desta vez (a permissão de uma vez do Chromium). Em `notifications` não existe "só desta vez": permitir fica gravado, com ou sem `remember`. Outros tipos de permissão são negados sem `ui.ask`. **O navegador bloqueia geolocalização e notificações por padrão:** o site nem chega a pedir, e o `ui.ask` só vem em ato onde esse padrão foi mudado para perguntar. Aba com agente: quem responde é a pessoa; o pedido vai ao hospedeiro mesmo com o agente trabalhando, e o agente só vê que a página ficou esperando. O agente nunca concede permissão. Por isso o hospedeiro recebe o pedido sem a pessoa ter tocado em Assumir.

**7. Instalar extensão** (`kind: "extension"`). Campos: `name`, `version`, `permissions` (lista de textos prontos para mostrar, em português quando o motor os tem), `host_permissions` (lista de padrões de endereço), `from` (`"store"` quando veio da loja; senão a origem `http(s)` da aba que pediu; senão `"file"`). Resposta: `ui.answer {ask, allow: true|false}`. Sem `remember`. Quem responde: só a pessoa, sempre pelo hospedeiro, mesmo com agente controlando alguma aba (como em 6). O agente não instala extensão.

**8. Cursor e posição do texto.** Dois eventos, só para o hospedeiro, sem resposta. `view.cursor {tab, cursor}` quando o cursor do mouse sobre a página muda: `default`, `pointer`, `text`, `wait`, `crosshair`, `grab`, `grabbing`, `not_allowed`, `move`, `resize_ew`, `resize_ns`, `resize_nesw`, `resize_nwse` ou `none` (o que o motor não conhece vira `default`). `view.caret {tab, x, y, width, height}` quando muda o lugar do texto em edição (em pontos, do canto de cima da vista): o hospedeiro usa para pôr a janela de candidatos do teclado (IME) e o painel de acentos no lugar certo.

**9. Cursor do agente.** `view.agent_cursor {tab, x, y}`, só para o hospedeiro, sem resposta: onde está o ponteiro do agente na página (em pontos, do canto de cima da vista), para o hospedeiro desenhar. Sem `x` e `y`, não há cursor para desenhar: a pessoa assumiu, o controle acabou ou o agente ainda não apontou para nada. Vem logo depois do `view.tab` da aba.

**Erros novos.** Nenhum código novo: `unauthorized` (`ui.answer` de quem não é o hospedeiro), `not_found` (`ask` que não vale mais), `bad_request` (campos errados). **Eventos novos:** `ui.ask` e `ui.cancel`, na tabela de Eventos. **Operação nova:** `ui.answer`.

## Erros

| Código | Quando |
|---|---|
| `bad_request` | JSON inválido, campo faltando ou com tipo errado. |
| `unknown_op` | Operação que o navegador não conhece (inclusive fases ainda não implementadas). |
| `not_found` | Ato, aba ou `ref` que não existe. |
| `unauthorized` | O cliente não passou na checagem de assinatura ou de aprovação, ou usou `tab`/`page` sem `control.start` nesta conexão. |
| `denied` | A pessoa tocou em **Não permitir**, ou a operação é proibida (ex.: `page.type` em campo de senha). |
| `failed` | O navegador não conseguiu criar ou abrir o ato, ou está fechando. |
| `paused` | A pessoa assumiu a aba: o agente espera ela devolver. |
| `dialog_open` | A aba tem um diálogo aberto: responda com `page.dialog`. |
| `cancelled` | `login`: a pessoa fechou a aba antes do fim. |
| `needs_login` | `renew`: o site pediu login; use `login`. |

## Eventos

| Evento | Campos | Quando |
|---|---|---|
| `session.lost` | `ato`, `from`, `name` | Um item de sessão vigiado sumiu ou expirou no cookie store do ato. |
| `control.paused` / `control.resumed` | — | A pessoa tocou em Assumir ou em Devolver. |
| `page.dialog` | `tab`, `type`, `message` | Uma aba controlada abriu um diálogo e espera resposta. |
| `approval.ask` | `ask`, `title`, `detail`, `offer_always` | (fase 5, só o hospedeiro) O motor embutido pede uma aprovação; responda com `approval.answer`. |
| `ui.ask` | `ask`, `kind`, `tab?`, mais os campos do `kind` | (passo 5.3, só o hospedeiro) O motor pede para o hospedeiro desenhar algo; responda com `ui.answer`. |
| `view.cursor` / `view.caret` | `tab`, `cursor` / `tab`, `x`, `y`, `width`, `height` | (passo 5.3, só o hospedeiro) O cursor sobre a página mudou / o texto em edição mudou de lugar. |
| `view.agent_cursor` | `tab`, `x?`, `y?` | (passo 5.3, só o hospedeiro) Onde está o ponteiro do agente na página; sem `x` e `y`, não há o que desenhar. |
| `ui.cancel` | `ask`, `reason` | (passo 5.3) O motor desistiu do pedido: `"closed"`, `"navigated"` ou `"gone"`. |
| `control.stopped` | `reason` | O controle desta conexão acabou: `"user"` (a pessoa tocou na bolha de parar) ou `"sharing_changed"` (mudou o grupo de atos que compartilham cookies com este). |

## Regras de segurança que o cliente sente

- **Valores nunca em log.** Os valores de `session`/`renew` só passam pelo socket. Guarde no Keychain; não escreva em log nem em mensagem de erro.
- **Só os itens exatos do `need`.** Nunca o cookie jar inteiro. Item novo é aprovação nova.
- **Aprovação.** `session` e `control.start` esperam a pessoa. "Permitir sempre" vale por app, ato e itens exatos.
- **Controle só vê as abas que ele abriu**, no ato aprovado. As abas da pessoa não aparecem.
- **Senha é recusada**, salvo o que a pessoa liberou em `allow`. O snapshot traz campo de senha sem valor, e `page.type` nele dá `denied`. Cookies e senhas salvas ficam fora do controle.
- **Aviso visível** nas abas controladas: quem é o agente, o que está fazendo, e o botão Assumir.
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

