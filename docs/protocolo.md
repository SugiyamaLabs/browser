# Protocolo do socket (v1)

Referência para quem escreve um cliente (o time do Agens, em Go). O plano e o porquê estão em [agens.md](agens.md).

## O que existe hoje

| Fase | Operações | Estado |
|---|---|---|
| 1 | `hello`, `atos.*` | implementado |
| 2 | `login` | implementado |
| 2 | `session`, `renew`, evento `session.lost` | implementado |
| 3 | `control.*`, `tab.*`, `page.*` | implementado |
| 5 | `host.*`, `view.*`, `ui.*` (a página dentro de outro app), `host.settings`, as partes de `approval.ask` | implementado |
| 5.4 | `view.pick`, `view.pick.step`, `view.selection`, evento `view.picked` (apontar um elemento) | implementado |
| 5.5 | `view.inspect`, ação `inspect` do botão direito (o DevTools); DevTools encaixado como vista (`dock`, `view.devtools.*`) | implementado |

Um navegador de fase 1 responde `unknown_op` às demais. Trate `unknown_op` como "este navegador ainda não faz isso".

## Onde fica o socket

Socket Unix, permissão `0600`, na pasta de dados do produto:

- AgensBrowser sozinho: `~/Library/Application Support/AgensBrowser/agens.sock`
- Dentro do Agens: `~/Library/Application Support/Agens/Browser/agens.sock`

Os dois produtos têm dados e sockets separados.

## Quem pode conectar

O navegador lê o processo do outro lado (`LOCAL_PEERTOKEN`) e confere a assinatura de código.

- AgensBrowser sozinho: apps assinados com o nosso Team ID (o mesmo da assinatura do próprio motor), depois da folha "O Agens quer usar o AgensBrowser" (**Permitir**, **Permitir sempre**, **Não permitir**).
- Motor embutido (dentro do Agens, aberto com `--agens-embedded`): não há folha de conexão. Entra sempre o processo que abriu o motor (o hospedeiro). Outro app entra só se for assinado com o nosso Team ID e o hospedeiro tiver passado o identificador de assinatura dele ao abrir o motor (`--agens-allowed-clients=<id>,<id>`). Ninguém mais.
- Desenvolvimento, sem assinatura: no AgensBrowser sozinho, **Configurações › Sistema › Aceitar apps sem assinatura** (vem desligado; o `agensctl` precisa dele enquanto não estiver assinado). No motor embutido, o hospedeiro abre o motor com `--agens-accept-unsigned`, que só vale em build que não é a oficial.

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
- `name` (em `atos.create` e `atos.rename`) tem até 256 caracteres, sem caractere de controle nem de direção de texto: o nome aparece nas folhas de aprovação. Outro dá `bad_request`.
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

Regras:
- **`need`**: de 1 a 32 itens `{type, from, name}`; `from` é só a origem (`https://host:porta`, sem caminho); `name` até 256 caracteres, sem caractere de controle nem de direção de texto (como U+202E), que reordenaria a linha da folha. Repetidos contam uma vez. `header` `Cookie` dá `bad_request`: peça cada cookie pelo nome. `reason` até 1024 caracteres (pode ser vazio).
- **A folha**: título "Entregar ao <app>: <primeiro item>" (com "…" quando há mais), e embaixo o `reason`, o ato e uma linha por item (`cookie d de app.slack.com`). Se o ato compartilha cookies, a folha diz com quais atos. Se esse grupo mudar com a folha aberta, a resposta é `denied`.
- **Permitir sempre**: só para app assinado, e vale para o mesmo app, ato e conjunto exato de itens (a ordem não importa). Pedir um item a mais ou a menos mostra a folha de novo.
- **Onde lê**: `localStorage` e `header` são lidos numa aba escondida do ato, que carrega a raiz de `from` (`https://app.slack.com/`) e fecha ao fim; o site precisa levar dali à página que grava a chave ou faz a requisição. Uma aba por origem, até 4 origens por pedido. Depois da aprovação, a leitura tem teto de 20 s; o que não chegou até lá conta como inexistente.
- **Item que não existe**: a resposta é tudo ou nada. Se algum item aprovado não existir (cookie ausente, chave que não existe, requisição que não veio a tempo), a resposta é `not_found`, e `message` diz quais (só nomes, nunca valores). Nenhum valor sai.
- **Limite**: até 4 `session` e `renew` em andamento por conexão, contando os que esperam a folha; o quinto dá `bad_request`.

### renew (fase 2)

Pega de novo sem janela, numa aba escondida do ato.

```
→ {"id": 9, "op": "renew", "ato": "Profile 1", "need": [...]}
← {"id": 9, "ok": true, "items": [...]}
← {"id": 9, "ok": false, "error": "needs_login"}
```

- **Sem folha, só o que já foi aprovado.** `renew` vale para o mesmo `ato` e o mesmo conjunto exato de itens de um `session` que a pessoa aprovou **nesta conexão**, ou que ela marcou com **Permitir sempre** (app assinado). Fora disso, `unauthorized`: peça com `session` primeiro. Ao reconectar, o primeiro pedido é `session` de novo (com "Permitir sempre" ele passa sem folha).
- Lê como `session` (mesmo teto de 20 s e mesmos limites). Se algum item faltar, a resposta é `needs_login` (e `message` diz quais, só nomes): em geral o site pediu login; use `login`.
- **`session.lost`**: cada cookie entregue por `session` ou `renew` passa a ser vigiado no cookie store do ato para aquela conexão. Quando ele é apagado ou expira, chega `session.lost {ato, from, name}` uma vez, e a vigília acaba. Trocar o valor não conta como perda. Só cookies (nunca `localStorage` nem `header`), até 64 por conexão; acabam quando a conexão fecha.

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
- **Nome e permissões.** `agent` é o nome que aparece no aviso (até 40 caracteres; o padrão é o nome do app). `allow` é uma lista com qualquer um de: `"passwords"` (senhas salvas e preenchimento automático do navegador, inclusive endereços e cartões, voltam a funcionar nas abas da sessão), `"clipboard"` (copiar, recortar e colar pelo teclado, inclusive em campo de senha) e `"eval"` (`page.eval` em endereço local). A folha mostra o que foi pedido; com `clipboard`, avisa que o agente pode ler o que a pessoa copiou em qualquer app e trocar o que está copiado. Sem `allow`, os três ficam bloqueados. As extensões do ato rodam nas abas controladas, a não ser que o hospedeiro do motor embutido tenha desligado `agent_extensions` (`host.settings`, em "host e view"). Pedir mais do que da última vez faz a folha aparecer de novo, mesmo com "Permitir sempre".
- **O que o agente está fazendo.** `control.status {title?, detail?}` (até 120 caracteres cada) troca as duas linhas do aviso; vazio volta ao padrão ("<agent> está usando esta aba" e o `reason`).
- **Assumir e devolver.** No aviso, a pessoa toca em **Assumir**: chega o evento `control.paused`, e `tab.*` e `page.*` respondem `paused` até ela tocar em **Devolver** (`control.resumed`). A bolha de parar encerra o controle (`control.stopped`).
- **Fim do controle**: `control.stop` fecha as abas da sessão. Ao desconectar, as abas ficam abertas, sem controle. Se a pessoa tocar em "Parar", chega o evento `control.stopped` e `tab.*` e `page.*` passam a dar `unauthorized`.
- **`tab.open` e `tab.navigate`**: só `http` e `https`, só no ato da sessão (outro ato dá `denied`). Respondem quando a navegação termina, com teto de 30 s; página que falhou ao carregar ainda é `ok`. O `tab` vale só nesta sessão: fora dela, ou depois de fechada, dá `not_found`.
- **`tab.back`, `tab.forward`, `tab.reload {tab}`**: respondem quando a navegação termina (teto de 30 s). Sem para onde ir, `bad_request`. `tab.reload` também dá `bad_request` se a página veio de um formulário enviado, para não reenviar.
- **`page.snapshot`**: lista plana, na ordem do documento, de controles, links, títulos, imagens com nome e texto. Cada nó tem `ref`, `role`, `name`, `value` e `depth`, e, quando vale, `focused`, `disabled`, `checked` e `password`. Os papéis são os nomes do Chromium (`textField`, `button`, `link`, `checkBox`, `comboBoxSelect`, `staticText`, `heading`, `image`). Teto de 2000 nós (`truncated: true`). O `ref` vale até a próxima navegação da aba; depois dá `not_found`.
- **`page.click`**: clique de mouse de verdade no centro do elemento, rolando até ele antes.
- **A resposta vem com a página em dia.** `page.click`, `page.type`, `page.key`, `page.hover` e `page.scroll` com `ref` só respondem depois que a página tratou a entrada e a árvore que `page.snapshot` lê já tem o resultado: o `page.snapshot` logo em seguida mostra o valor digitado, a caixa marcada etc. Numa página que ainda está carregando, a espera tem teto de 1 s a mais.
- **`page.type`**: foca o elemento e digita tecla a tecla, até 10000 caracteres. Quebra de linha e tab dão `bad_request`: use `page.key`. Um `ref` que não recebe foco (o texto de um rótulo, um campo desabilitado) dá `bad_request`: as teclas iriam para a página e se perderiam.
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

Só existem quando o motor roda **embutido** (aberto por outro app com `--agens-embedded`, sem ícone no Dock e sem janela, a não ser a do DevTools que a pessoa pede em janela própria: veja "Passo 5.5"). No AgensBrowser sozinho respondem `unknown_op`.

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
- **Aprovações.** Embutido, o motor não mostra folha: manda `approval.ask {ask, title, detail, offer_always, ...}` ao hospedeiro, que desenha e responde `approval.answer {ask, answer}` com `allow`, `always` ou `deny`. Sem hospedeiro ligado, a resposta é `denied`. `title` e `detail` vêm sempre, prontos para mostrar (o texto da folha do AgensBrowser sozinho). Para quem desenha a própria folha, vêm também as partes, quando o motor as conhece (motor mais antigo não manda nenhuma; `kind` desconhecido: mostre `title` e `detail`):
  - `kind`: `"control"` (`control.start`) ou `"session"` (`session`). Existe também `"connect"` (a folha de conexão), que embutido não chega ao hospedeiro, porque ali não há folha de conexão.
  - `ato` (id) e `ato_name`.
  - `agent` (só `control`): o nome que as abas vão mostrar, o `agent` do `control.start` ou, sem ele, o nome do app.
  - `reason`: o motivo que o app deu; ausente quando vazio.
  - `allow` (só `control`): a lista de permissões extras pedidas (`passwords`, `clipboard`, `eval`); vazia quando nenhuma.
  - `shares_with`: os nomes dos atos com que este divide cookies; ausente quando nenhum.
  - `items` (só `session`): `[{type, from, name}]`, os itens exatos do `need`.

```
← {"event": "approval.ask", "ask": "a2", "title": "O Agens quer usar abas do ato Trabalho", "detail": "Ler a caixa de entrada\n\n…", "offer_always": true,
   "kind": "control", "ato": "Profile 1", "ato_name": "Trabalho", "agent": "Popi", "reason": "Ler a caixa de entrada", "allow": ["clipboard"], "shares_with": ["Casa"]}
```
- **Configurações do hospedeiro.** `host.settings {site_requests?, agent_extensions?}` → `{site_requests, agent_extensions}`, só da conexão do hospedeiro (de outra, `unauthorized`). Muda as que vierem (booleanos; outro tipo dá `bad_request`) e responde as duas como valem agora; sem campo, só lê. O motor guarda as duas no `Local State` (`agens.bridge.site_requests`, `agens.bridge.agent_extensions`) e elas valem para todos os atos, também os que abrirem depois. Motor mais antigo responde `unknown_op`: ali vale o padrão.
  - `site_requests` (padrão `false`): com `true`, geolocalização e notificações ficam em "perguntar" em todo ato, e o pedido do site chega como `ui.ask` `permission`; com `false`, ficam bloqueadas e o site nem chega a pedir. O motor aplica isso como o padrão do ato a cada início e a cada mudança, por cima do que a pessoa tenha escolhido para o mesmo ato no AgensBrowser sozinho (**Configurações › Permissões**); as exceções por site continuam valendo.
  - `agent_extensions` (padrão `true`, o comportamento de antes): com `false`, as extensões não agem nas abas que um agente controla, enquanto o controle durar: nenhum content script (do manifesto, dinâmico ou `userScripts`) nem `tabs.executeScript`, `tabs.insertCSS` ou `scripting.*` roda ou injeta CSS nelas, em nenhum quadro, nem depois de navegar para outro site; o botão da extensão na barra não faz nada nelas; e as APIs que pegam a aba pelo id (`tabs.get`, `tabs.update`, `tabs.sendMessage`…) não a encontram. Vale na hora, inclusive para abas já controladas (o que já rodou numa página continua nela até a próxima navegação). Quando o controle acaba, a aba volta ao normal na próxima página. **O que não fica de fora:** `tabs.query` e `tabs.onUpdated` ainda mostram a aba; `webRequest` e `declarativeNetRequest` continuam valendo nela (bloqueio de anúncio e de rastreador por extensão segue funcionando); as APIs de cookies e de armazenamento são por ato, não por aba; e uma janela que a aba controlada abre (pop-up) não é controlada, então as extensões agem nela.
- **Pop-up.** O que a página abre como janela pop-up (`window.open` com `popup`, `width` ou `height`) vira uma aba nova, em primeiro plano, do mesmo ato, e chega ao hospedeiro como qualquer aba (`view.tab`). Nunca vira janela.
- **Nenhuma outra janela.** Embutido, o motor não põe na tela janela nenhuma além do DevTools em janela própria (passo 5.5; encaixado, ele é uma vista, sem janela). Caso a caso:
  - `chrome.windows.create` de uma extensão, com `type` `popup`, `panel` ou `normal`: abre uma janela normal escondida do mesmo ato (como as outras, nunca aparece), e as abas dela chegam como `view.tab`. A promessa resolve com essa janela, com `type: "normal"`, então `chrome.windows.remove` dela fecha só as abas dela. O mesmo vale para qualquer janela pop-up ou de app que o Chromium abriria (um login de extensão, por exemplo).
  - Apps da web (PWA): desligados no modo embutido, como numa janela anônima. Nada oferece instalar, nenhum app abre na janela dele e nenhum link é capturado por app; os apps instalados no AgensBrowser sozinho continuam lá, só não valem aqui.
  - Picture-in-picture: recusado. `video.requestPictureInPicture()` rejeita com `NotSupportedError` (o PiP automático também não abre) e `documentPictureInPicture` não existe na página. Mostrar a janelinha como mais uma vista do hospedeiro dá para fazer depois; a janela de vídeo PiP é um desenho próprio do Chromium, não uma página, então não cabe em `view.layer` sem trabalho novo.
  - Imprimir: desligado. `window.print()` volta na hora sem fazer nada (a prévia ficaria numa janela que ninguém vê, com a página esperando por ela).
  - `mailto:` e esquemas de outro app: recusados, com erro no console da página; nenhum outro app abre.
  - Seletor de data, hora e cor de `<input>`: não abre (seria uma janela do sistema na tela). A página continua; o campo aceita digitação. Levar ao hospedeiro como `ui.ask` fica para depois.
  - Passkeys (WebAuthn), Payment Request, `navigator.share` e o conta-gotas (`EyeDropper`): não existem na página no modo embutido, porque a interface deles é do sistema ou ficaria numa janela que ninguém vê; o site vê que não há e segue pelo caminho sem eles.
  - Rede de segurança: qualquer outra janela do Chromium (Views) que tente aparecer fica escondida, e o log do motor ganha a linha `agens: kept off screen (embedded): <nome>`. Ela não fecha: quem a abriu segue rodando, só ninguém a vê. Se essa linha aparecer, é um caso a tratar na origem.
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
{"link": "https://example.com/a", "image": "https://example.com/i.png", "selection": "texto", "editable": true, "actions": ["open_link_new_tab", "copy_link", "copy_image", "save_image", "copy", "cut", "paste", "select_all", "back", "forward", "reload", "inspect"]}
```

`link` e `image` só vêm se o clique foi neles (o endereço inteiro, o mesmo que as ações usam); `selection` vem cortado em 200 caracteres; `editable` diz que é campo de texto. `actions` é a lista do que vale agora (`open_link_new_tab` só para link `http(s)`, e abre em segundo plano), na ordem em que o motor sugere; o hospedeiro pode desenhar menos, nunca ação fora da lista. Resposta: `ui.answer {ask, action}` com um item de `actions`, ou `cancel` (para `inspect`, também `dock`: veja o passo 5.5). O motor executa a ação. Ação fora da lista dá `bad_request`. Não há ação que leia o conteúdo para o hospedeiro: copiar vai para a área de transferência do sistema, pelo motor. Aba com agente: o botão direito da pessoa só chega depois do Assumir; o do agente não existe (não há operação para ele). `save_image` cai nas regras de download de hoje. `inspect` vem por último, quando o DevTools vale para a página (não vem se uma política o desliga): abre o DevTools no elemento do clique, como `view.inspect` (passo 5.5); `{ask, action: "inspect", dock}` diz onde (`bottom`, `right` ou `window`; sem `dock`, onde o hospedeiro o deixou por último). `dock` com outra ação, ou fora desses três, dá `bad_request`. Motor mais antigo não manda `inspect`.

**Botão direito no DevTools encaixado.** Na vista do DevTools (passo 5.5) o botão direito também vira `ui.ask` `context_menu`, com o `tab` da vista do DevTools, mas o menu é o do próprio DevTools: `context.items` traz as entradas dele, na ordem dele, e `actions` só as de edição (`copy`, `cut`, `paste`, `select_all`, quando valem); nada de link, voltar, recarregar ou `inspect`. Cada entrada de `items` é `{id, label, disabled?, checked?}` (escolhível; `checked` só nas que têm marca), `{separator: true}`, `{label, group: true}` (cabeçalho) ou `{label, items: [...]}` (submenu, até 4 níveis; até 500 entradas no total; `label` até 200 caracteres). Resposta: `ui.answer {ask, item}` com o `id` de uma entrada escolhível (desabilitada, separador, cabeçalho, submenu ou id que não veio dão `bad_request`), `{ask, action}` com uma de `actions`, ou `cancel`. O DevTools roda o que foi escolhido. Aba de página nunca manda `items`.

**3. `alert`, `confirm`, `prompt`, `beforeunload` de aba sem agente** (`kind: "dialog"`). Campos: `type` (`alert`, `confirm`, `prompt`, `beforeunload`), `message` (até 1024 caracteres), `origin` (de quem é o diálogo; o hospedeiro mostra), `default` (só em `prompt`, até 1024 caracteres). Resposta: `ui.answer {ask, accept: true|false, text?}`; `text` só em `prompt` aceito. `alert` aceita ou fecha: tanto faz. `beforeunload` aceito deixa a página sair. **Convivência com `page.dialog`:** o mecanismo de `page.dialog` não muda. Aba com agente: o diálogo vai para o agente como hoje (`page.dialog` e `dialog_open`) e `ui.ask` não é usado. Aba sem agente: `ui.ask` para o hospedeiro. Se um agente passa a controlar uma aba com `ui.ask` de diálogo aberto, o pedido é cancelado e o agente recebe `page.dialog` do mesmo diálogo. Se a pessoa assume, vale a regra de Assumir acima: o mais antigo vai ao hospedeiro por `ui.ask`, os outros são cancelados.

**4. Escolher arquivo** (`kind: "file"`). Campos: `mode` (`open`, `open_multiple`, `folder`, `save`), `accept` (lista de extensões que a página pediu, ex. `[".png", ".jpg"]`; tipo MIME como `image/*` já chega convertido em extensões; é sugestão, o hospedeiro pode filtrar o painel), `suggested` (nome sugerido, só em `save`). Resposta: `ui.answer {ask, paths: ["/abs/a.png"]}`, caminhos absolutos; um só se não for `open_multiple`, até 100 se for; `paths` vazio equivale a cancelar. O motor confere o tipo: caminho que não existe ou que não bate com `mode` dá `bad_request`. Em `save`, o motor grava depois e o hospedeiro só escolhe o destino. O conteúdo do arquivo nunca passa pelo socket, e o motor só lê o caminho no momento em que a página envia. Aba com agente: não existe `page.*` para arquivo; fica cancelado (nenhum arquivo) para o agente, e só a pessoa, depois do Assumir, chega ao painel.

**5. Login HTTP** (`kind: "auth"`). Campos: `origin` (esquema, host e porta de quem pede), `realm` (texto do servidor, até 200 caracteres), `proxy` (`true` se quem pede é um proxy), `retry` (`true` se o hospedeiro já mandou credencial para a mesma aba, origem e `realm`: em geral, a anterior foi recusada). Resposta: `ui.answer {ask, username, password}`; o hospedeiro pode pegar do Keychain dele. O motor entrega a credencial ao Chromium e esquece; não guarda nem lembra. `password` nunca aparece em `ui.ask`, em erro nem em log, e o motor tira `username` e `password` do que registra de `ui.answer`. Aba com agente: o agente não recebe nem responde; fica cancelado até a pessoa assumir (ela vê o pedido no hospedeiro). `retry` ajuda o hospedeiro a não repetir a mesma senha.

**6. Permissão do site** (`kind: "permission"`). Campos: `origin`, `permission` (`camera`, `microphone`, `geolocation`, `notifications`; mais de uma pedida junto, como câmera e microfone, chega como um pedido com `permissions: ["camera", "microphone"]` e `permission` ausente). Resposta: `ui.answer {ask, allow: true|false, remember?}`. `remember: true` guarda a resposta por origem e ato, no perfil do ato; o motor só aceita `remember` com `allow` falso ou verdadeiro, nunca sem `allow`. Sem `remember`, vale só desta vez (a permissão de uma vez do Chromium). Em `notifications` não existe "só desta vez": permitir fica gravado, com ou sem `remember`. Outros tipos de permissão são negados sem `ui.ask`. **O navegador bloqueia geolocalização e notificações por padrão:** o site nem chega a pedir. Embutido, o hospedeiro liga os pedidos com `host.settings {site_requests: true}`, e aí o `ui.ask` vem de qualquer ato. Aba com agente: quem responde é a pessoa; o pedido vai ao hospedeiro mesmo com o agente trabalhando, e o agente só vê que a página ficou esperando. O agente nunca concede permissão. Por isso o hospedeiro recebe o pedido sem a pessoa ter tocado em Assumir.

**7. Instalar extensão** (`kind: "extension"`). Campos: `name`, `version`, `permissions` (lista de textos prontos para mostrar, em português quando o motor os tem), `host_permissions` (lista de padrões de endereço), `from` (`"store"` quando veio da loja; senão a origem `http(s)` da aba que pediu; senão `"file"`). Resposta: `ui.answer {ask, allow: true|false}`. Sem `remember`. Quem responde: só a pessoa, sempre pelo hospedeiro, mesmo com agente controlando alguma aba (como em 6). O agente não instala extensão.

**8. Cursor e posição do texto.** Dois eventos, só para o hospedeiro, sem resposta. `view.cursor {tab, cursor}` quando o cursor do mouse sobre a página muda: `default`, `pointer`, `text`, `wait`, `crosshair`, `grab`, `grabbing`, `not_allowed`, `move`, `resize_ew`, `resize_ns`, `resize_nesw`, `resize_nwse` ou `none` (o que o motor não conhece vira `default`). `view.caret {tab, x, y, width, height}` quando muda o lugar do texto em edição (em pontos, do canto de cima da vista): o hospedeiro usa para pôr a janela de candidatos do teclado (IME) e o painel de acentos no lugar certo.

**9. Cursor do agente.** `view.agent_cursor {tab, x, y}`, só para o hospedeiro, sem resposta: onde está o ponteiro do agente na página (em pontos, do canto de cima da vista), para o hospedeiro desenhar. Sem `x` e `y`, não há cursor para desenhar: a pessoa assumiu, o controle acabou ou o agente ainda não apontou para nada. Vem logo depois do `view.tab` da aba.

**Operação e campos novos depois do passo 5.3** (também só adições à v1): `host.settings`, as partes de `approval.ask` e a resposta de `page.click`/`page.type`/`page.key` com a página em dia (descritos acima).

**Erros novos.** Nenhum código novo: `unauthorized` (`ui.answer` de quem não é o hospedeiro), `not_found` (`ask` que não vale mais), `bad_request` (campos errados). **Eventos novos:** `ui.ask` e `ui.cancel`, na tabela de Eventos. **Operação nova:** `ui.answer`.

#### Passo 5.4: apontar um elemento e ler a seleção

Também só adições à v1. A pessoa aponta um elemento da página, o motor diz ao hospedeiro o que é, e o hospedeiro deixa a pessoa escrever um pedido sobre ele para um bot. Tudo só da conexão do hospedeiro (de outra, `unauthorized`), com `id` e resposta. Motor mais antigo responde `unknown_op` às três operações.

```
→ {"id": 30, "op": "view.pick", "tab": "v3", "on": true}
← {"id": 30, "ok": true}
   (a pessoa passa o mouse: o elemento embaixo fica destacado; ela clica)
← {"event": "view.picked", "tab": "v3", "selector": "#card > p:nth-of-type(2)", "html": "<p class=\"preco\">R$ 10</p>", "text": "R$ 10",
   "x": 48, "y": 120.5, "width": 300, "height": 24, "styles": {"display": "block", "font-size": "16px", "color": "rgb(17, 17, 17)", ...}, "png": "iVBORw0KGgo..."}
→ {"id": 31, "op": "view.pick.step", "tab": "v3", "to": "parent"}
← {"id": 31, "ok": true}
← {"event": "view.picked", "tab": "v3", "selector": "#card", ...}
→ {"id": 32, "op": "view.pick", "tab": "v3", "on": false}
← {"id": 32, "ok": true}
```

- **`view.pick {tab, on}`.** Só em aba ligada (`view.attach`; senão `not_found`). `on: true` liga o modo: o mouse sobre a página destaca o elemento embaixo (o destaque do próprio motor, âmbar claro, com a etiqueta de tag e tamanho, desenhado dentro da página, então o hospedeiro não desenha nada) e o próximo clique, de qualquer botão, escolhe o elemento em vez de clicar na página. Responde depois que o modo está valendo. Mandar `on: true` de novo, inclusive depois de escolher, liga para outra escolha. `on: false` desliga e tira o destaque; a resposta vem quando a página já saiu do modo, então um clique mandado depois dela já age na página. Sem `on` booleano: `bad_request`.
- **Aba com agente.** Com o agente trabalhando (`control.state` `"working"`), `view.pick on:true` dá `denied`. Depois do Assumir, vale. Se o agente volta a trabalhar na aba (Devolver), o modo acaba sozinho com `view.picked {tab, cancelled: true}`.
- **Evento `view.picked`.** Uma escolha traz:
  - `selector`: caminho CSS que acha o elemento de novo (para num `#id` único; senão `tag:nth-of-type(n)` separados por ` > `), até 1024 caracteres.
  - `html`: o `outerHTML`, até 16 KiB, com `truncated: true` quando foi cortado. Campo de senha nunca leva o valor: o atributo `value` sai da cópia (vale para `type=password` e para campo com `autocomplete` de senha).
  - `text`: o texto visível (`innerText`), até 2000 caracteres, com `text_truncated: true` quando cortado; vazio num campo de senha.
  - `x`, `y`, `width`, `height`: a caixa do elemento em pontos, do canto de cima da vista, o mesmo espaço de `view.mouse` (já com o zoom da página). Pode passar da vista.
  - `styles`: 14 valores calculados (`display`, `position`, `width`, `height`, `margin`, `padding`, `font-family`, `font-size`, `font-weight`, `line-height`, `color`, `background-color`, `border`, `border-radius`), cada um até 40 caracteres.
  - `png`: base64 do recorte do elemento como está na tela, sem o destaque, na escala da tela, só da parte visível. Até uns 600 KB de base64: se passar, vai com metade do tamanho; se ainda passar, ou se nada do elemento estiver na vista, `png` não vem e vem `png_skipped: true`.

  O motor corta tudo de novo do lado dele: esses textos vêm da página. Quando o modo acaba sem escolha, vem `{tab, cancelled: true}`: Escape dentro da página, navegação (outro documento), o processo da página caiu, ou um agente voltou a trabalhar na aba. Também vem depois de uma escolha, se o destaque dela some por um desses motivos. `view.pick on:false`, um novo `on:true`, `view.detach`, `view.close` e o hospedeiro desconectar não mandam nada.
- **Depois da escolha.** O elemento escolhido continua destacado (rola junto com a página) até `view.pick on:false`, um novo `on:true`, navegação, Escape ou a aba fechar. Enquanto isso, o motor não passa à página o movimento do mouse sem botão sobre aquela aba (o destaque sumiria no primeiro movimento); clique, roda e teclado passam normalmente. Arrastar sobre a página tira o destaque, sem evento.
- **`view.pick.step {tab, to}`.** `to` é `"parent"` ou `"child"`. Só depois de uma escolha: passa ao elemento pai ou a um filho, destaca e manda um `view.picked` novo. O pai para no `<body>` (nunca `<html>` nem `<head>`). O filho refaz o caminho que o pai subiu; sem caminho para refazer, é o primeiro filho que aparece na tela. Sem escolha, ou sem pai ou filho elemento, `not_found` (a escolha fica como está). `to` de outro valor: `bad_request`.
- **`view.selection {tab}`** → `{text, truncated?}`: o texto selecionado agora na página (no quadro com o foco), até 16 KiB, com `truncated: true` quando cortado. O `selection` do `ui.ask` `context_menu` só leva 200 caracteres; este é para quando o hospedeiro precisa do texto todo. Vazio quando nada está selecionado. Seleção dentro de `<textarea>` vem; dentro de `<input>` nunca (pode ser um campo de senha, mesmo mostrando o texto). Vale em qualquer aba que o hospedeiro conhece, ligada ou não.
- **O que fica de fora nesta versão.** Elemento dentro de `iframe` de outra origem não se escolhe: com o modo ligado, o clique sobre ele cai no elemento `<iframe>` da página, não dentro dele, e não escolhe nada. `iframe` da mesma origem funciona. Campo de senha que a página trocou para `type=text` (o "mostrar senha") é tratado como campo comum em `html`; `png` mostra o que está na tela. **Melhoria registrada:** escolher dentro de `iframe` de outra origem pede uma sessão interna de DevTools por quadro (`Target.setAutoAttach` com `flatten`, os mesmos comandos em cada sessão filha e `DOM.getFrameOwner` para somar a posição do quadro).

**Erros novos.** Nenhum: `bad_request`, `not_found`, `denied`, `unauthorized`, `failed` (o motor não conseguiu ligar o modo na página). **Evento novo:** `view.picked`. **Operações novas:** `view.pick`, `view.pick.step`, `view.selection`.

#### Passo 5.5: inspecionar (DevTools)

Também só adição à v1. O DevTools do Chromium vai para um de três lugares, que o hospedeiro escolhe (`dock`):

- **`bottom` ou `right`: encaixado.** O DevTools é uma **vista**, como uma aba: tem um id `v<n>` (o `devtools`), o hospedeiro a liga com `view.attach`, muda o tamanho com `view.resize`, solta com `view.detach`, recebe `view.layer` dela e manda a entrada dela (`view.mouse`, `view.wheel`, `view.key`, `view.focus`, `view.edit`). Ela desenha sozinha, fora de qualquer janela: nada aparece na tela. Quem desenha a divisão é o hospedeiro: a página e o DevTools lado a lado (embaixo ou à direita), cada um no seu tamanho; o DevTools não sabe que está encaixado, então mostra o desenho de janela solta, sem área reservada para a página e sem as opções de "Dock side" no menu ⋮ dele (o lado é do hospedeiro). A vista fica fora de `view.tab` e de `view.tabs`; só serve para mostrar: outra operação de aba sobre ela (`view.navigate`, `view.inspect`, `view.close`…) dá `bad_request`. O que age sobre ela vai pela aba inspecionada (`view.devtools.*`).
- **`window`: janela própria.** Como antes: a janela do DevTools do motor, a única janela que o motor embutido põe na tela. A pessoa usa a janela normalmente (teclado, menus, painéis de arquivo do próprio DevTools); nada disso passa pelo socket nem vira `ui.ask`.

```
→ {"id": 40, "op": "view.inspect", "tab": "v3", "x": 120, "y": 80, "dock": "bottom"}
← {"id": 40, "ok": true, "devtools": "v9"}
← {"event": "view.devtools", "tab": "v3", "devtools": "v9", "dock": "bottom"}
→ {"id": 41, "op": "view.attach", "tab": "v9", "width": 1100, "height": 320, "scale": 2}
→ {"id": 42, "op": "view.devtools.dock", "tab": "v3", "dock": "right"}
← {"event": "view.devtools", "tab": "v3", "devtools": "v9", "dock": "right"}
→ {"id": 43, "op": "view.devtools.close", "tab": "v3"}
← {"event": "view.devtools.closed", "tab": "v3", "devtools": "v9"}
```

- **`view.inspect {tab, x?, y?, dock?}`** → `{ok, devtools?}`. Só da conexão do hospedeiro (de outra, `unauthorized`), com `id`. Abre o DevTools da aba; com `x` e `y` (em pontos, do canto de cima da vista, como `view.mouse`), no painel Elements com o elemento desse ponto escolhido. Sem ponto, só abre. `dock` é `bottom`, `right` ou `window`; sem `dock`, vai para onde o hospedeiro o deixou por último nesta conexão (no começo, `window`, o comportamento de antes). `devtools` vem quando ele fica encaixado. Vale em qualquer aba que o hospedeiro conhece, ligada ou não.
- **Um por aba.** Se o DevTools da aba já está aberto, `view.inspect` não abre outro: muda para o `dock` pedido (se veio), mostra de novo e escolhe o elemento do ponto; devolve o mesmo `devtools`. Em janela, a janela vem para a frente. O foco da vista é do hospedeiro (`view.focus`).
- **`view.devtools.dock {tab, dock}`** → `{ok, devtools?}`. Muda de lado, ou entre encaixado e janela própria. O id `devtools` é o mesmo a vida toda, também quando vai para a janela e volta (em janela não há o que ligar: o hospedeiro solta a vista). Aba sem DevTools aberto: `not_found`.
- **`view.devtools.close {tab}`** → `{ok}`. Fecha o DevTools da aba (encaixado ou em janela); `view.devtools.closed` vem em seguida. Aba sem DevTools aberto: `not_found`.
- **Evento `view.devtools {tab, devtools, dock}`.** Quando o DevTools da aba abre e sempre que ele muda de lugar, também quando a mudança vem de outro caminho (o botão direito, um atalho). `tab` é a aba inspecionada.
- **Evento `view.devtools.closed {tab, devtools}`.** Quando ele fecha: por `view.devtools.close`, porque a aba inspecionada fechou, porque a pessoa fechou a janela dele, porque a página dele saiu do DevTools (navegou para outro endereço) ou porque uma política o desligou para a página. Quando o hospedeiro desconecta, todos fecham (encaixados e em janela), sem evento.
- **Pelo botão direito.** A ação `inspect` do `context_menu` (passo 5.3, item 2) faz o mesmo no elemento do clique, inclusive dentro de `iframe`, com o `dock` da resposta (ou o último).
- **O que o DevTools encaixado pede ao hospedeiro.** Sem janela, nada dele pode aparecer por conta própria: o botão direito vira `ui.ask` `context_menu` com as entradas do DevTools (`context.items`, passo 5.3, item 2); `<select>` do DevTools vira `ui.ask` `select`; salvar um HAR ou escolher a pasta de um workspace vira `ui.ask` `file`; `alert`/`confirm` dele viram `ui.ask` `dialog`. Tudo com o `tab` da vista do DevTools. Em janela própria, tudo isso fica com a janela, como antes.
- **Teclado.** A tecla vai para onde o hospedeiro manda: com a vista do DevTools focada, `view.key` com o id dela. Os atalhos do DevTools (⌘F, ⌘[ e ⌘], ⌘P, Esc da gaveta) são do próprio DevTools e só funcionam se chegarem a ela como `view.key`, então o hospedeiro não deve tomá-los para o menu dele enquanto o DevTools tem o foco; ⌘C, ⌘V, ⌘X e ⌘A podem ir como `view.edit`.
- **Trazer para a frente (só `window`).** O motor é outro processo, sem ícone no Dock: o macOS só deixa a janela dele vir para a frente e pegar o teclado se o hospedeiro entregar a ativação antes de mandar `view.inspect`, `view.devtools.dock` com `window` ou a resposta `inspect` (`NSApplication.yieldActivation(to:)` com o `NSRunningApplication` do motor, macOS 14). O kit faz isso. Encaixado, não precisa.
- **Erros.** Aba que não existe: `not_found`. `x` sem `y` (ou o contrário), ponto que não é número, ou `dock` fora de `bottom`, `right` e `window`: `bad_request`. Agente trabalhando na aba: `denied` (depois do Assumir, vale). DevTools desligado por política para a página: `failed`.
- **Junto com o apontar.** Abrir o DevTools acaba o `view.pick` daquela aba, com `view.picked {tab, cancelled: true}`: os dois usam o mesmo modo de inspeção da página.
- **A rede de segurança** (passo 5.2, "Nenhuma outra janela") continua deixando passar só a janela de verdade do DevTools; encaixado não há janela.

- **O que fica de fora nesta versão.** Com `x` e `y` sobre um `iframe` de outra origem, `view.inspect` escolhe o elemento `<iframe>`, não o de dentro (pelo botão direito, escolhe o de dentro). Se um agente passa a trabalhar na aba com o DevTools aberto, o DevTools continua aberto. O modo de dispositivo do DevTools (o ícone de celular) não tem onde desenhar a página encaixado (ele espera estar dono da área da página), então fica como está no DevTools solto. Os itens do menu do DevTools não trazem o atalho de teclado nem ícone.

**Erros novos.** Nenhum. **Operações novas:** `view.inspect` (com `dock`), `view.devtools.dock`, `view.devtools.close`. **Eventos novos:** `view.devtools`, `view.devtools.closed`. **Ação nova:** `inspect` em `context_menu` (com `dock`); **resposta nova:** `item` em `context_menu`.

#### Passo 5.6: extensões

Também só adições à v1. O hospedeiro lista as extensões de cada ato, desenha os botões delas (ícone, selo, título) por aba, mostra o popup de uma extensão como mais uma vista e instala de um arquivo. Tudo só da conexão do hospedeiro (de outra, `unauthorized`), com `id` e resposta. Motor mais antigo responde `unknown_op`.

**O nome do campo.** Nas operações e nos eventos, a extensão vai em `extension` (o id dela, 32 letras de `a` a `p`). `id` já é o número do pedido: um `{"id": 7, ..., "id": "abc"}` perderia um dos dois. Dentro da lista de `extensions.list` e em `ui.ask` ela continua `id`.

```
→ {"id": 50, "op": "extensions.list", "ato": "Profile 1", "tab": "v3"}
← {"id": 50, "ok": true, "extensions": [{"id": "iebb…", "name": "1Password", "version": "8.10.48", "enabled": true, "from": "store",
     "action": true, "title": "1Password", "badge": "", "badge_color": "", "visible": true, "popup": true, "pinned": true, "options": true,
     "permissions": ["Ler e mudar os dados de todos os sites"], "host_permissions": ["<all_urls>"], "atos": ["Profile 1", "Default"]}]}
→ {"id": 51, "op": "extension.click", "tab": "v3", "extension": "iebb…"}
← {"id": 51, "ok": true, "popup": "v12"}
← {"event": "extension.popup", "popup": "v12", "tab": "v3", "extension": "iebb…", "width": 300, "height": 420}
→ {"id": 52, "op": "view.attach", "tab": "v12", "width": 300, "height": 420, "scale": 2}
```

- **`extensions.list {ato, tab?}`** → `{extensions: [...]}`. As extensões que a pessoa instalou no ato (não as internas), cada uma com `id`, `name`, `version`, `enabled`, `from` (`"store"`, `"file"` para um `.crx`, `"folder"` para uma pasta descompactada), `action` (tem botão), `pinned` (fixada na barra; vale por ato e fica salvo), `options` (tem página de opções), `permissions` (textos prontos para mostrar), `host_permissions` (padrões de endereço) e `atos` (os ids dos atos que têm a extensão, este incluído). Com `action`, vêm também `title`, `badge` (`""` sem selo), `badge_color` (`"#RRGGBB"`, ou `""` para a cor do hospedeiro), `visible` (desligada nesta aba: desenhe apagada) e `popup` (o clique abre popup), como a aba `tab` mostra; sem `tab`, o padrão de todas as abas. Ato dormindo é acordado para a lista. Ato que não existe: `not_found`; `tab` que não existe: `not_found`.
- **`extension.icon {ato, extension, tab?}`** → `{png}`. PNG de 32 px em base64: com `tab`, o ícone do botão naquela aba (o que a extensão mudou com `action.setIcon`, senão o do botão); sem `tab`, o da extensão. `""` quando não tem.
- **`extension.enable {ato, extension, on}`**, **`extension.pin {ato, extension, on}`**: liga ou desliga; fixa na barra ou tira. `on` não booleano: `bad_request`.
- **`extension.remove {ato, extension, all?}`**: tira do ato; com `all: true`, de todos os atos que a têm (os que dormem são acordados). Responde quando terminou.
- **`extension.options {ato, extension}`** → `{tab}`: abre a página de opções numa aba nova do ato, como `view.open` (`chrome-extension://…/options.html`). Sem página de opções, ou extensão desligada: `not_found`.
- **`extension.install {ato, crx}`** ou **`{ato, folder}`** → `{extension}` (o id) depois que ela entrou. Caminho absoluto de um arquivo `.crx` ou de uma pasta com `manifest.json` ("Adicionar de um arquivo"). Quem decide é a pessoa: o motor manda o `ui.ask` `extension` de sempre (com a escolha de atos, abaixo) e só instala com `allow`. Erros: `denied` (a pessoa disse não), `failed` (não instalou: arquivo estragado, manifesto inválido), `bad_request` (caminho relativo, que não existe, `.crx` que é pasta, pasta sem manifesto, os dois campos juntos). `.crx` e pasta não se atualizam sozinhos; a pasta fica ligada ao lugar onde está (mudou a pasta, mudou a extensão ao recarregar), e adicionar uma pasta liga o modo de desenvolvedor do ato (sem ele o Chromium desliga extensão descompactada). A resposta só vem depois da pessoa: pode demorar.
- **`extension.click {tab, extension}`** → `{popup?}`: o mesmo que clicar no botão da extensão naquela aba. Quando a extensão abre popup, vem o id dele (`v<n>`, da mesma numeração das abas); senão a extensão tratou o clique sozinha e não vem nada. Extensão desligada ou sem botão: `not_found`. Aba que um agente está usando com `agent_extensions` desligado (`host.settings`): `denied`, como o botão da casca, que não faz nada ali.
- **O popup.** É a página da extensão numa vista própria, que nunca aparece em `view.tab` nem em `view.tabs`. O hospedeiro faz com ela o que faz com uma aba ligada: `view.attach`, `view.resize`, `view.detach`, a entrada (`view.mouse`, `view.key`…) e os `ui.ask` dela (`select`, escolher arquivo, `alert`). O tamanho é o que a página pede, entre 25 × 25 e 800 × 600: vem em `extension.popup {popup, tab, extension, width, height}` quando ela carrega e de novo a cada mudança; ligue a vista nesse tamanho. Um popup por vez: abrir outro fecha o anterior. Fecha com `window.close()` da página, quando a aba dele navega para outro documento ou fecha, quando a extensão é desligada ou removida, quando o hospedeiro desconecta e com **`extension.popup.close {popup}`**, que o hospedeiro manda quando a pessoa clica fora ou aperta Esc fora dele (o motor não vê o foco do hospedeiro). Em todos os casos vem `extension.popup.closed {popup}` e o id deixa de valer (`not_found`). `view.close` no popup também fecha.
- **Instalar com escolha de atos.** O `ui.ask` `extension` (passo 5.3, item 7) ganha `ato` (onde está sendo instalada), `id` (da extensão), `icon` (PNG pequeno, 32 px, base64) e, quando é uma instalação nova, `atos: [{id, name, color, installed}]` (todos os atos; `installed` diz quem já tem). O `from` pode vir também `"folder"`. A resposta `ui.answer {ask, allow: true, atos: ["Default", "Profile 3"]}` instala também nesses atos (sem `atos`, ou vazio, só no ato que pediu). O motor confere: `atos` só com `allow: true`, só ids que vieram no pedido, sem repetir; fora disso, `bad_request`. Depois que o ato que pediu tem a extensão, ela entra nos outros sem perguntar de novo (a escolha da pessoa já autorizou) e sem rede: uma cópia do que foi instalado (da loja ou de um `.crx`) ou a mesma pasta. Ato dormindo é acordado na hora para receber. Ato que já tem é pulado. Só esse pedido da pessoa espalha uma extensão por atos; nenhuma operação de agente faz isso. Uma extensão que abre uma aba de boas-vindas sozinha pode abrir essa aba fora do controle de um agente.
- **Eventos.** `extension.changed {ato, extension, change}`, com `change` `installed`, `updated`, `enabled`, `disabled`, `removed` ou `pinned`, para qualquer ato acordado. `extension.action {ato, tab?, extension, title, badge, badge_color, visible, popup}` quando o botão muda (selo, título, ícone, visível); sem `tab`, mudou o padrão de todas as abas do ato; o ícone novo se pede com `extension.icon`. `extension.popup` e `extension.popup.closed`, acima.
- **O que fica de fora nesta versão.** Instalar da loja pelo id, sem a página: depois. Instalar pela página da Chrome Web Store funciona como antes (o botão "Instalar no AgensBrowser" chega como `ui.ask`), agora com a escolha de atos. `alert` de uma página de fundo de extensão (não do popup) não chega ao hospedeiro.

**Erros novos.** Nenhum. **Operações novas:** `extensions.list`, `extension.icon`, `extension.enable`, `extension.remove`, `extension.pin`, `extension.options`, `extension.install`, `extension.click`, `extension.popup.close`. **Eventos novos:** `extension.changed`, `extension.action`, `extension.popup`, `extension.popup.closed`. **Campos novos:** `ato`, `id`, `icon`, `atos` no `ui.ask` `extension`; `atos` no `ui.answer` dele.

## Erros

| Código | Quando |
|---|---|
| `bad_request` | JSON inválido, campo faltando ou com tipo errado. |
| `unknown_op` | Operação que o navegador não conhece (inclusive fases ainda não implementadas). |
| `not_found` | Ato, aba ou `ref` que não existe; em `session`, item aprovado que não existe. |
| `unauthorized` | O cliente não passou na checagem de assinatura ou de aprovação, usou `tab`/`page` sem `control.start` nesta conexão, ou pediu `renew` de itens que não foram aprovados. |
| `denied` | A pessoa tocou em **Não permitir**, ou a operação é proibida (ex.: `page.type` em campo de senha). |
| `failed` | O navegador não conseguiu criar ou abrir o ato, ou está fechando. |
| `paused` | A pessoa assumiu a aba: o agente espera ela devolver. |
| `dialog_open` | A aba tem um diálogo aberto: responda com `page.dialog`. |
| `cancelled` | `login`: a pessoa fechou a aba antes do fim. |
| `needs_login` | `renew`: algum item não veio (em geral o site pediu login); use `login`. |

## Eventos

| Evento | Campos | Quando |
|---|---|---|
| `session.lost` | `ato`, `from`, `name` | Um cookie entregue por `session`/`renew` nesta conexão foi apagado ou expirou no cookie store do ato. |
| `control.paused` / `control.resumed` | — | A pessoa tocou em Assumir ou em Devolver. |
| `page.dialog` | `tab`, `type`, `message` | Uma aba controlada abriu um diálogo e espera resposta. |
| `approval.ask` | `ask`, `title`, `detail`, `offer_always`, e quando o motor sabe `kind`, `ato`, `ato_name`, `agent`, `reason`, `allow`, `shares_with`, `items` | (fase 5, só o hospedeiro) O motor embutido pede uma aprovação; responda com `approval.answer`. |
| `ui.ask` | `ask`, `kind`, `tab?`, mais os campos do `kind` | (passo 5.3, só o hospedeiro) O motor pede para o hospedeiro desenhar algo; responda com `ui.answer`. |
| `view.cursor` / `view.caret` | `tab`, `cursor` / `tab`, `x`, `y`, `width`, `height` | (passo 5.3, só o hospedeiro) O cursor sobre a página mudou / o texto em edição mudou de lugar. |
| `view.agent_cursor` | `tab`, `x?`, `y?` | (passo 5.3, só o hospedeiro) Onde está o ponteiro do agente na página; sem `x` e `y`, não há o que desenhar. |
| `ui.cancel` | `ask`, `reason` | (passo 5.3) O motor desistiu do pedido: `"closed"`, `"navigated"` ou `"gone"`. |
| `view.picked` | `tab`, `selector`, `html`, `truncated?`, `text`, `text_truncated?`, `x`, `y`, `width`, `height`, `styles`, `png?`, `png_skipped?` / `tab`, `cancelled` | (passo 5.4, só o hospedeiro) A pessoa escolheu um elemento com `view.pick` (ou `view.pick.step` mudou a escolha) / o modo acabou sem escolha, ou o destaque da escolha sumiu. |
| `view.devtools` / `view.devtools.closed` | `tab`, `devtools`, `dock` / `tab`, `devtools` | (passo 5.5, só o hospedeiro) O DevTools da aba abriu ou mudou de lugar (`bottom`, `right`: a vista `devtools` para ligar; `window`: janela própria) / fechou. |
| `extension.changed` | `ato`, `extension`, `change` | (passo 5.6, só o hospedeiro) Uma extensão foi instalada, atualizada, ligada, desligada, removida ou fixada/desafixada num ato acordado. |
| `extension.action` | `ato`, `tab?`, `extension`, `title`, `badge`, `badge_color`, `visible`, `popup` | (passo 5.6, só o hospedeiro) O botão da extensão mudou naquela aba (sem `tab`: em todas as abas do ato). |
| `extension.popup` / `extension.popup.closed` | `popup`, `tab`, `extension`, `width`, `height` / `popup` | (passo 5.6, só o hospedeiro) O popup tem (ou mudou) de tamanho / fechou. |
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

