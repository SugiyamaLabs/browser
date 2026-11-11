# BrowserKit: o navegador dentro do seu app

Guia para quem escreve o app hospedeiro (o Agens). O `BrowserKit` é um pacote Swift que abre o motor do navegador como processo auxiliar escondido, fala com ele pelo socket ([protocolo.md](protocolo.md), seção "host e view") e entrega uma `NSView` por aba. Ele não tem código do Chromium. Quem desenha barra de endereço, abas, atos e o aviso do agente é o app; o kit entrega a página e os dados.

- macOS 14 ou mais novo, Swift 6. Só Foundation, AppKit, QuartzCore e Observation.
- Tudo do kit roda no main actor.
- O código fica em `kit/apple/BrowserKit/` e o `Package.swift` na raiz do repositório; o app de exemplo, que usa o kit, em `kit/apple/exemplo/`.

## Adicionar o pacote

O `Package.swift` fica na raiz do repositório do navegador, então o app aponta para ele por URL, numa versão fixa:

```swift
// Package.swift do app
.package(url: "https://github.com/SugiyamaLabs/browser.git", exact: "<versão>"),
// no alvo:
.product(name: "BrowserKit", package: "browser"),
```

O pacote é só o código Swift de `kit/apple/BrowserKit/`; nada do Chromium é baixado ou compilado junto.

Atualizar o kit é trocar a versão. **Cada versão do kit vai com um motor de um protocolo que ela aceita** (veja "Versões", no fim).

## Abrir o motor

O motor vai dentro do app, em `Contents/Helpers/`. A pasta de dados é do app; o socket fica nela (`agens.sock`), e o caminho inteiro do socket tem de caber em 103 bytes.

```swift
import BrowserKit

let helper = Bundle.main.bundleURL
  .appendingPathComponent("Contents/Helpers/AgensBrowser.app/Contents/MacOS/AgensBrowser")
let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Agens/Browser")
let engine = BrowserEngine(executable: helper, dataDirectory: data)
// Em desenvolvimento, com o app sem assinatura: arguments: ["--agens-accept-unsigned"]

await engine.start()   // abre com --agens-embedded --user-data-dir=<data>, conecta, hello, host.attach
```

Ao encerrar o app, chame `engine.stop()` (por exemplo em `applicationWillTerminate`). O motor é filho do app, mas não morre sozinho quando o app sai.

## As telas de estado

`engine.state` (observável no SwiftUI; no AppKit, `engine.onStateChange`) diz qual tela mostrar nos painéis:

| Estado | O que o app mostra |
|---|---|
| `.starting` | "Abrindo o navegador…" |
| `.ready(protocol, browser)` | as abas |
| `.exited` | "Reabrindo o navegador…" e chama `start()` de novo. As vistas e os ids de aba antigos não valem mais: crie vistas novas |
| `.failed(motivo)` | o motivo e "Tentar de novo" (chama `start()`) |
| `.versionTooOld(protocol, browser)` | "Atualize o navegador" |
| `.stopped` | nada: o app mandou parar |

Reabrir é decisão do app: o kit só avisa. `start()` espera o socket por até 30 s.

## Um ato por time

O id do ato não muda, mas o nome muda (a pessoa renomeia). Ache o ato do time pela `tag`, que o navegador só guarda e devolve:

```swift
let connection = engine.connection!
var ato = try await connection.atos().first { $0.tag == team.id }?.id
if ato == nil { ato = try await connection.createAto(name: team.name, color: .blue, tag: team.id) }
```

Também há `renameAto`, `setColor` e `openAto`.

## Mostrar uma aba num painel

```swift
let tab = try await connection.openTab(ato: ato, url: "https://example.com")
let page = BrowserTabView(engine: engine, tab: tab)
panel.addSubview(page)   // na janela, ela pede para desenhar (view.attach); fora, para (view.detach)
```

A vista manda tamanho, escala, foco, mouse, roda, teclado (com acentos e IME) e os comandos do menu Editar (`cut:`, `copy:`, `paste:`, `selectAll:`, `undo:`, `redo:`). Para ⌘C e afins funcionarem, o menu Editar do app precisa ter esses itens. Pode haver várias vistas ao mesmo tempo, uma por aba. Uma aba que não está em nenhuma janela não desenha.

Navegação: `navigate(tab, to: texto)` (endereço ou busca, como na barra), `back`, `forward`, `reload`, `stop`, `closeTab`.

## As abas e os dados delas

`engine.tabs` é um modelo observável com as abas de cada ato: título, URL, carregando, áudio, se dá para voltar e avançar, ícone (PNG) e `control` quando um agente está usando a aba.

```swift
try await engine.tabs.load(ato: ato)        // as abas que já existem (inclui as do agente)
engine.tabs.tabs(in: ato)                   // [BrowserTab], na ordem em que o kit soube delas
engine.tabs[tab]?.favicon                   // Data? com o PNG
```

O modelo segue os eventos `view.tab`, `view.closed` e `view.favicon` sozinho; aba fechada sai da lista.

**Aba com agente.** `tab.control` traz `agent`, `title`, `detail` e `state` (`"working"` ou `"paused"`). O app desenha o aviso e manda o que a pessoa escolheu: `connection.control(tab, action: .take)` (Assumir), `.give` (Devolver), `.end` (encerrar).

## Aprovações

Embutido, o motor não mostra folha: ele pede ao app. Sem resposta definida, o kit responde `deny`.

```swift
engine.onApproval = { request in
  // request.title, request.detail, request.offerAlways
  await showSheet(request)   // devolve .allow, .always ou .deny
}
```

## Menus, diálogos e pedidos da página

O que a página abre por conta própria chega como `ui.ask` ([protocolo.md](protocolo.md), "Passo 5.3"): lista de `select`, botão direito, `alert`/`confirm`/`prompt`/`beforeunload`, escolher arquivo, login HTTP, permissão do site e instalar extensão. O motor de hoje ainda não manda nada disso.

O kit já desenha tudo em AppKit, em português. Ligue com uma linha:

```swift
engine.onUIRequest = { [weak engine] in await engine?.presentDefaultUI($0) ?? .cancel }
```

- `select` e botão direito: `NSMenu` no ponto da página.
- Diálogo, login, permissão e extensão: folha na janela da vista. Login tem usuário e senha; permissão tem **Permitir**, **Não permitir** e **Lembrar**.
- Arquivo: `NSOpenPanel` ou `NSSavePanel`. Não filtra pelo `accept`.
- Sem a vista da aba (ou sem janela, nas folhas), a resposta é cancelar.

Para desenhar do seu jeito, troque o handler. `request.kind` diz o que é (`.select`, `.contextMenu`, `.dialog`, `.file`, `.auth`, `.permission`, `.extension`), cada um com os campos do protocolo. Devolva o `UIAnswer` do mesmo kind, ou `.cancel`. Dá para chamar `presentDefaultUI` só nos kinds que você não quer desenhar.

```swift
engine.onUIRequest = { [weak engine] request in
  guard case .auth(let auth) = request.kind else { return await engine?.presentDefaultUI(request) ?? .cancel }
  let (user, password) = await myLoginSheet(auth.origin)   // ou do Keychain do app
  return .auth(username: user, password: password)
}
```

- **Fechar.** Se o motor desiste (`ui.cancel`: a aba fechou ou navegou, a página desistiu) ou cai, o kit cancela a `Task` do handler e não responde nada. Feche o que desenhou num `withTaskCancellationHandler`. O motivo vem em `engine.onEvent`.
- Sem handler, o kit cancela na hora. Pedido que o kit não entende também é cancelado.
- Fora do handler: `connection.answerUI(ask, .select(index: 2))`; `.cancel` cancela.
- A senha só vai no `ui.answer`. O `description` de `UIAnswer` esconde a senha.

**Cursor e IME.** A vista troca o cursor do mouse pelo `view.cursor` (o que ela não conhece vira seta) e põe a janela de candidatos do IME no lugar que `view.caret` diz.

## O que não está no kit

- Operações sem atalho tipado: `connection.send(op: "login", params: [...])` devolve a resposta inteira, ou lança `BrowserError` com o `code` do protocolo (`not_found`, `denied`…) e a `message`. `engine.onEvent` recebe todos os eventos.
- O kit não desenha nada além da página e dos pedidos dela: barra de endereço, abas, atos e aviso do agente são do app.
- **Ainda não chegam ao app:** autofill. O botão direito ainda não é enviado ao motor, então o menu de contexto não vem.
- **Não feito:** arrastar e soltar, acessibilidade, tela cheia e dica (tooltip). Texto que não vem de tecla (emoji, ditado) é descartado.
- Nunca testado com motor real: tela Retina e monitores com escalas diferentes.

## Versões

`hello` devolve `protocol`. O kit precisa de no mínimo `BrowserEngine.minimumProtocol` (hoje 1) e de um motor que conheça `host.attach`; abaixo disso o estado vira `.versionTooOld`. Ao fixar uma versão do kit, empacote junto um motor de um protocolo que ela aceita: os dois saem da mesma tag deste repositório.
