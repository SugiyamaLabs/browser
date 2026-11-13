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

`engine.tabs` é um modelo observável com as abas de cada ato: título, URL, carregando, áudio, se dá para voltar e avançar, ícone (PNG) e `control` quando um agente está usando a aba e `agentCursor`, o ponto onde está o ponteiro dele (o app desenha).

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

`title` e `detail` vêm sempre, prontos para mostrar. Para desenhar a folha em partes, `ApprovalRequest` traz também, quando o motor sabe (um motor mais antigo deixa tudo vazio):

- `kind`: `.control` (um agente quer usar abas), `.session` (um app quer cookies, `localStorage` ou headers), `.connect`, ou `.other("…")` para um tipo que este kit não conhece; nesse caso, e com `kind` nulo, mostre `title` e `detail`.
- `ato`, `atoName`, `reason`.
- `agent` e `allow` (`passwords`, `clipboard`, `eval`), em `.control`.
- `items: [ApprovalRequest.Item]` (`type`, `from`, `name`), em `.session`.
- `sharesWith`: nomes dos atos com que este divide cookies; vazio quando nenhum.

## Configurações do motor

Duas opções que o app liga e desliga, guardadas pelo motor entre um início e outro ([protocolo.md](protocolo.md), `host.settings`):

```swift
let now = try await engine.settings(siteRequests: true, agentExtensions: false)   // muda e devolve todas
let read = try await engine.settings()                                            // só lê
```

- `siteRequests` (padrão `false`): sites podem pedir localização e notificações (chega como `ui.ask` de permissão); desligado, ficam bloqueadas em todo ato.
- `agentExtensions` (padrão `true`): as extensões agem nas abas que um agente controla. Desligado, ficam fora delas (o que ainda passa está em protocolo.md).
- `webauthnPlatform` (padrão `false`): o app sabe criar e usar passkeys deste Mac; é o que o site vê em `isUserVerifyingPlatformAuthenticatorAvailable()`. Ligue só quando o app responde `.webauthn` com credenciais de verdade (veja "Passkeys", abaixo).
- Motor mais antigo lança `BrowserError` com `code` `unknown_op`; ali vale o padrão.

## Menus, diálogos e pedidos da página

O que a página abre por conta própria chega como `ui.ask` ([protocolo.md](protocolo.md), "Passo 5.3"): lista de `select`, botão direito, `alert`/`confirm`/`prompt`/`beforeunload`, escolher arquivo, login HTTP, permissão do site, instalar extensão, seletor de data e de cor, imprimir e passkey.

O kit já desenha tudo em AppKit, em português. Ligue com uma linha:

```swift
engine.onUIRequest = { [weak engine] in await engine?.presentDefaultUI($0) ?? .cancel }
```

- `select` e botão direito: `NSMenu` no ponto da página.
- Diálogo, login, permissão e extensão: folha na janela da vista. Login tem usuário e senha; permissão tem **Permitir**, **Não permitir** e **Lembrar**; extensão tem a escolha de atos (veja "Extensões", abaixo).
- Arquivo: `NSOpenPanel` ou `NSSavePanel`. Não filtra pelo `accept`.
- Data, hora, mês e cor: popover junto do campo, com `NSDatePicker` (em UTC, para mostrar o dia do campo) ou `NSColorWell`, e **Cancelar** / **OK**. A resposta já vem no passo e na faixa do campo.
- Imprimir: pede o PDF (`printPDF`), abre no PDFKit e mostra a folha de impressão do sistema (`NSPrintOperation`) na janela da vista; no fim responde cancelar, que é o "terminei" do protocolo.
- Passkey: responde `NotAllowedError` por enquanto (o site segue pelo caminho sem passkey). Veja "Passkeys", abaixo.
- Sem a vista da aba (ou sem janela, nas folhas), a resposta é cancelar.

Para desenhar do seu jeito, troque o handler. `request.kind` diz o que é (`.select`, `.contextMenu`, `.dialog`, `.file`, `.auth`, `.permission`, `.extension`, `.date`, `.color`, `.print`, `.webauthn`), cada um com os campos do protocolo. Devolva o `UIAnswer` do mesmo kind, ou `.cancel`. Dá para chamar `presentDefaultUI` só nos kinds que você não quer desenhar.

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

**Itens do app no botão direito.** O menu que `presentDefaultUI` desenha aceita itens do app, depois das ações do motor e de um separador. Escolher um chama `onContextMenuItem` com o item e o pedido (aba, ponto, link, seleção) e responde cancelar ao motor. Sem itens, o menu é o de sempre. **Inspecionar** vem sempre por último, depois de outro separador, quando o motor oferece (`inspect`; veja "Inspecionar", abaixo). No menu do próprio DevTools encaixado, as entradas dele vêm antes das ações de edição.

```swift
engine.contextMenuItems = [HostMenuItem(id: "ask", title: "Perguntar ao bot"), HostMenuItem(id: "point", title: "Apontar elemento")]
engine.onContextMenuItem = { item, request in
  guard case .contextMenu(let menu) = request.kind, let tab = request.tab else { return }
  if item.id == "point" { Task { try? await engine.connection?.pick(tab) } }
  if item.id == "ask" { Task { askBot((try? await engine.connection?.selection(tab))?.text ?? menu.selection ?? "") } }
}
```

**Data e cor.** `DatePicker` traz `type` (`.date`, `.datetimeLocal`, `.month`, `.week`, `.time`), `value` (nil com o campo vazio), `min`, `max`, `step`, `suggestions` e `anchor` (a caixa do campo em pontos da vista, do canto de cima). Os números estão na unidade do campo (a do `valueAsNumber`): milissegundos desde 1970-01-01 UTC, desde a meia-noite em `.time`, meses desde janeiro de 1970 em `.month`; `DatePicker.date(_:)` e `DatePicker.value(_:)` convertem para `Date` e de volta. Responda `.date(value:)`; fora da faixa ou do passo o motor recusa. `ColorPicker` traz `value` (`"#rrggbb"`), `suggestions` e `anchor`; responda `.color(hex: "#1a2b3c")`.

**Links para outro app.** `mailto:`, `webcal:`, `zoommtg:` e afins chegam em `engine.onExternalLink` (`ExternalLink`: `tab`, `url`, `scheme`, `origin`, `gesture`); o motor não abre nada. Sem handler, o kit abre com `NSWorkspace.shared.open(url)`, o app do sistema para o esquema. Um app com e-mail e agenda próprios faz:

```swift
engine.onExternalLink = { link in
  switch link.scheme {
  case "mailto": composeMail(link.url)
  case "webcal": subscribeCalendar(link.url)
  default: NSWorkspace.shared.open(link.url)
  }
}
```

`navigator.registerProtocolHandler` chega como `.permission` com `permissions == ["protocol_handler"]`, `scheme` e `handlerURL`.

**Imprimir.** `window.print()` chega como `.print(PrintRequest)` (`title`, `url`) e a página segue na hora. O PDF é do app pedir, a qualquer momento, também sem `ui.ask`:

```swift
var options = PrintOptions(landscape: true, pageRanges: "1-2")
options.margins = (top: 0.4, bottom: 0.4, left: 0.4, right: 0.4)   // polegadas
let pdf = try await engine.connection?.printPDF(tab: tab, options: options)   // url, bytes, pages
```

O arquivo é do motor (`0600`) e vale até o próximo `printPDF` da aba, a aba fechar ou o app desconectar: leia ou copie logo. Responda o `.print` com `.cancel` quando terminar.

**Passkeys.** `navigator.credentials.create`/`get` chegam como `.webauthn(PasskeyRequest)`: `type` (`.create`/`.get`), `origin`, `crossOrigin` e `request`, as opções do site em JSON do WebAuthn. Responda `.webauthn(response:)` com a credencial em JSON (`RegistrationResponseJSON` ou `AuthenticationResponseJSON`), ou `.webauthnError("InvalidStateError")` e afins; `.cancel` é `NotAllowedError`. O caminho de verdade é o app chamar `ASAuthorizationController` (iCloud Keychain, celular por QR, chave de segurança, na folha do sistema) e devolver o resultado nesse JSON; isso pede o direito de navegador para passkeys da Apple, que ainda não foi liberado. Até lá, `presentDefaultUI` responde `NotAllowedError`.

**Cursor e IME.** A vista troca o cursor do mouse pelo `view.cursor` (o que ela não conhece vira seta) e põe a janela de candidatos do IME no lugar que `view.caret` diz.

## Apontar um elemento

A pessoa aponta um elemento da página e o app recebe o que é ([protocolo.md](protocolo.md), "Passo 5.4"). O motor desenha o destaque dentro da página: a vista não precisa de nada.

```swift
engine.onPick = { result in
  switch result {
  case .picked(let element): showComposer(element)   // selector, html, text, frame, styles, png
  case .cancelled(let tab): closeComposer(tab)       // Escape na página, navegou, agente voltou
  }
}
try await engine.connection?.pick(tab)               // liga; o próximo clique escolhe
try await engine.connection?.stepPick(tab, to: .parent)   // ou .child: chega um .picked novo
try await engine.connection?.pick(tab, on: false)    // desliga e tira o destaque
let selected = try await engine.connection?.selection(tab)   // o texto selecionado, até 16 KiB
```

- `PickedElement`: `selector` (caminho CSS), `html` (até 16 KiB, `htmlTruncated`), `text` (até 2000 caracteres, `textTruncated`), `frame` (`CGRect` em pontos da vista, do canto de cima, como o mouse), `styles` (uns 14 valores, `[String: String]`), `png` (`Data?`, só a parte visível; `nil` com `pngSkipped` quando não coube). Tudo vem da página: mostre, não execute.
- Campo de senha não leva o valor em `html` nem em `text`, e `selection` nunca lê dentro de `<input>`.
- Depois da escolha, o destaque fica até `pick(on: false)`, um novo `pick`, navegação ou Escape. Enquanto isso, o motor ignora o movimento do mouse sem botão naquela aba.
- Com o agente trabalhando na aba, `pick` lança `denied`; depois do Assumir, vale. Se o agente volta, chega `.cancelled`.
- `stepPick` sem pai ou filho lança `not_found` e a escolha fica.
- Motor mais antigo lança `unknown_op` nas três; nada mais muda.
- Elemento dentro de `iframe` de outra origem não se escolhe nesta versão.

## Inspecionar

O DevTools do Chromium, em um de três lugares ([protocolo.md](protocolo.md), "Passo 5.5"): **encaixado embaixo** ou **à direita** da página, como uma vista que o app mostra igual a uma aba (`BrowserTabView`), ou **em janela própria**, a janela do motor (a única que o motor embutido põe na tela, e só quando a pessoa pede).

```swift
engine.devToolsDock = .bottom                                   // o lado que a pessoa usou por último (guarde você)
let devtools = try await engine.inspect(tab)                    // abre; encaixado devolve o id da vista
try await engine.inspect(tab, at: CGPoint(x: 120, y: 80))       // Elements no elemento desse ponto da vista
try await engine.inspect(tab, dock: .window)                    // em janela própria (devolve nil)
try await engine.setDevToolsDock(tab, .right)                   // muda de lado, ou vai para a janela e volta
try await engine.closeDevTools(tab)
```

- **Sem desenhar nada:** ponha `BrowserDevToolsSplit(engine: engine, tab: tab)` onde poria a `BrowserTabView` da aba. Ela segue os eventos sozinha: página em cima (ou à esquerda), divisor para arrastar (pelo menos 120 pt de DevTools e 200 pt de página, com "312 px · 42%" enquanto arrasta) e uma barra sobre o DevTools com embaixo, à direita, janela própria e fechar. O lado escolhido vai para `engine.devToolsDock`; os tamanhos ficam em `bottomSize` e `rightSize` (o padrão é 40% embaixo e 420 pt à direita), e `onResize` avisa para guardar.
- **Desenhando você:** `engine.devTools[tab]` (observável) diz se a aba tem DevTools, o id da vista (`devtools`) e onde ele está (`dock`). `onDevTools` e `onDevToolsClosed` avisam cada mudança, também as que vêm do botão direito. Em `.bottom` e `.right`, mostre `BrowserTabView(engine: engine, tab: state.devtools)` ao lado da página, no tamanho que quiser; a página e o DevTools não se sobrepõem, cada vista tem o seu tamanho. Em `.window`, não há o que mostrar. O id é o mesmo enquanto o DevTools viver, também quando muda de lado ou vai e volta da janela.
- **Um por aba.** `inspect` numa aba que já tem DevTools só muda de lado (se você pediu outro), mostra de novo e escolhe o elemento. O foco é seu: `window.makeFirstResponder(devtoolsView)`.
- **Botão direito.** No `presentDefaultUI`, **Inspecionar** faz o mesmo no elemento do clique, no lado de `devToolsDock` (sem ele, onde o motor o deixou por último; no começo, em janela). Num menu seu, responda `.contextMenu(action: "inspect")` (o kit põe o lado) ou `.inspect(dock: .right)`.
- **Os menus do próprio DevTools.** Encaixado, o DevTools não tem janela: o botão direito dentro dele chega como `.contextMenu` com `items` (as entradas do DevTools, com submenus) e só as ações de edição. O `presentDefaultUI` desenha as entradas primeiro; num menu seu, responda `.contextMenuItem(id:)`. As listas (`select`), salvar HAR, escolher pasta e `alert` do DevTools chegam também, com o `tab` da vista do DevTools, e o `presentDefaultUI` já desenha.
- **Teclado.** A vista do DevTools pega os atalhos ⌘ do DevTools (⌘F, ⌘[ e ⌘], ⌘P, ⌘K…) antes do menu do app, enquanto tem o foco. ⌘C, ⌘V, ⌘X, ⌘A e ⌘Z continuam no menu Editar (vão como `view.edit`); ⌘Q, ⌘W, ⌘H, ⌘M, ⌘, e ⌥⌘I continuam do app. Esc fecha a gaveta do DevTools como sempre.
- **Janela própria.** O motor é outro processo, sem ícone no Dock. Antes de pedir a janela (`inspect` com `.window` ou sem lado, `setDevToolsDock(.window)`, a resposta `inspect`), o kit entrega a ativação ao motor (`NSApplication.yieldActivation(to:)`), para ela vir para a frente e pegar o teclado. Por isso só funciona com o motor que o próprio kit abriu (`start()`). Encaixado, não precisa.
- Com o agente trabalhando na aba, `inspect` lança `denied` e o botão direito nem chega. Com o DevTools desligado por política, lança `failed` e o menu não traz o item. Sem DevTools aberto, `setDevToolsDock` e `closeDevTools` lançam `not_found`.
- O DevTools fecha sozinho quando a aba fecha ou quando o app desconecta do motor (inclusive ao sair).
- Abrir o DevTools desliga o `pick` daquela aba (chega `.cancelled`): os dois usam o mesmo modo da página.
- Motor mais antigo: sem `dock` ele sempre abre em janela e não manda `view.devtools`; `setDevToolsDock` e `closeDevTools` lançam `unknown_op`.

## Extensões

As extensões de cada ato, os botões delas por aba, o popup e instalar de um arquivo ([protocolo.md](protocolo.md), "Passo 5.6").

```swift
let list = try await connection.extensions(in: ato, tab: tab)        // [BrowserExtension]
for e in list where e.pinned { drawButton(e.id, e.action) }           // action: título, selo, cor, visível
let png = try await connection.extensionIcon(e.id, ato: ato, tab: tab)   // Data? (PNG 32 px)
engine.onExtensionAction = { update in redraw(update.id, update.tab, update.state) }   // tab nil: todas as abas
engine.onExtensionChange = { change in reload(change.ato) }           // installed, removed, pinned…

if let popup = try await connection.clickExtension(e.id, tab: tab) { opened(popup) }
engine.onExtensionPopup = { [weak engine] popup in engine?.presentExtensionPopup(popup, from: button) }
```

- `BrowserExtension`: `id`, `name`, `version`, `enabled`, `source` (`.store`, `.file`, `.folder`), `pinned`, `hasOptions`, `permissions`, `hostPermissions`, `atos` (os ids dos atos que têm) e `action` (`ExtensionActionState`: `title`, `badge`, `badgeColor`, `visible`, `hasPopup`; `nil` sem botão).
- `setExtension(_:ato:enabled:)`, `pinExtension(_:ato:pinned:)`, `removeExtension(_:ato:everywhere:)` (`everywhere`: de todos os atos que têm), `openExtensionOptions(_:ato:)` (devolve a aba nova).
- **Popup.** `clickExtension` devolve o id do popup (ou `nil`, quando a extensão tratou o clique sozinha); o tamanho que a página quer chega em `onExtensionPopup`, de novo a cada mudança. `presentExtensionPopup(_:from:)` mostra num `NSPopover` transitório sob o botão, com a vista do popup (`BrowserTabView(engine:tab:)`, a mesma das abas): segue o tamanho, e clicar fora ou Esc fecha e avisa o motor (`closeExtensionPopup`). Fechado pelo motor (`window.close()`, a aba navegou, extensão desligada), chega `onExtensionPopupClosed` e o popover fecha sozinho. Para desenhar o seu, ponha a `BrowserTabView` do popup onde quiser e chame `closeExtensionPopup` quando a pessoa clicar fora.
- **Instalar de um arquivo.** `installExtension(ato:from:)` com a URL de um `.crx` ou de uma pasta descompactada: o motor pergunta à pessoa (o `ui.ask` de extensão, abaixo) e só volta depois que ela respondeu e a extensão entrou, com o id. `denied` se ela disse não, `failed` se não instalou, `bad_request` para um caminho que não serve.
- **A pergunta de instalar** (`UIRequest.Kind.extension`) traz agora `ato`, `id`, `icon` (PNG) e `atos` (`[ExtensionInstall.Ato]`: `id`, `name`, `color`, `installed`). Responda `.extension(allow: true, atos: [...])` para instalar também nesses atos; sem `atos`, só no ato que pediu. O `presentDefaultUI` já desenha a escolha: "Só no ato X" (padrão) ou "Em todos os atos", com uma caixa por ato (o atual e os que já têm ficam marcados e travados), e o botão diz para onde vai ("Instalar no ato X", "Instalar em 3 atos").
- Na aba que um agente está usando com `agentExtensions` desligado, `clickExtension` lança `denied`.
- Motor mais antigo lança `unknown_op` nas operações e manda a pergunta de instalar sem `atos`: a folha fica sem a escolha e a resposta vai sem `atos`.

## O que não está no kit

- Operações sem atalho tipado: `connection.send(op: "login", params: [...])` devolve a resposta inteira, ou lança `BrowserError` com o `code` do protocolo (`not_found`, `denied`…) e a `message`. `engine.onEvent` recebe todos os eventos.
- O kit não desenha nada além da página e dos pedidos dela: barra de endereço, abas, atos e aviso do agente são do app.
- **Ainda não chegam ao app:** autofill.
- **Não feito:** arrastar e soltar, acessibilidade, tela cheia e dica (tooltip). Texto que não vem de tecla (emoji, ditado) é descartado.
- Nunca testado com motor real: tela Retina e monitores com escalas diferentes.

## Versões

`hello` devolve `protocol`. O kit precisa de no mínimo `BrowserEngine.minimumProtocol` (hoje 1) e de um motor que conheça `host.attach`; abaixo disso o estado vira `.versionTooOld`. Ao fixar uma versão do kit, empacote junto um motor de um protocolo que ela aceita: os dois saem da mesma tag deste repositório.
