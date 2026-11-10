# Prova de conceito do embed: uma aba do navegador dentro de outro app

Issue #58. Estágio 1: leitura do código, implementação e compilação. **Nada foi executado com janela ainda.** O que é fato lido no código, o que compilou e o que é palpite está marcado.

## Resumo

- O `remote_cocoa` como o Chromium usa (app shim) **não serve para o Agens do jeito que está**: o processo que mostra a janela precisa carregar o framework inteiro do navegador e virar um processo do Chromium. É o que o plano descartou.
- O que serve é a metade de baixo do mesmo mecanismo: **a aba desenha num `CAContext` e outro processo mostra esse contexto num `CALayerHost`**, só com o número do contexto. Os eventos voltam pelo nosso socket.
- Caminho escolhido para provar primeiro: **(b)**. O app de exemplo é Swift puro, sem código do Chromium. O motor ganhou ~650 linhas nossas e 2 linhas em arquivo do Chromium.
- Motor e app de exemplo compilam. O autoteste do app (sem janela) passou neste Mac.

## Como o app shim funciona (lido no código, Chromium 156)

1. **O shim carrega o framework inteiro.** `chrome/app_shim/app_mode_loader_mac.mm:189` faz `dlopen` do framework do navegador e chama a entrada `ChromeAppModeStart`, que roda `content::ContentMain` (`chrome_main_app_mode_mac.mm`). O `chrome/app_shim/README.md` diz o mesmo: o shim "merely loads the framework".
2. **O shim é dono do processo.** `AppShimMainDelegate::RunProcess` (`app_shim_main_delegate.mm`) exige que o `NSApp` seja `AppShimApplication` (um `CrApplication`, com `CrAppProtocol` e `CrAppControlProtocol`; há um `CHECK`), cria a thread de IO, inicia o mojo como broker e fica em `base::RunLoop().Run()`. Features, PartitionAlloc e ThreadPool são configurados ali.
3. **Conexão:** o shim acha o navegador por um nome Mach (`<bundle id>.apps.<hash da pasta de dados>`), manda uma ponta de canal (`AppShimController::ConnectToBrowser`) e o navegador confere o processo pelo audit token (`app_shim_host_bootstrap_mac.cc`). Depois disso é mojo, sem versão: os dois lados têm de ser do mesmo build.
4. **Quem cria o quê:** o navegador pede pelo `remote_cocoa.mojom.Application` (`components/remote_cocoa/common/application.mojom`): `CreateNativeWidgetNSWindow` (a janela inteira fica no shim), `CreateWebContentsNSView` e `CreateRenderWidgetHostNSView`. As vistas são encaixadas por id numa tabela do próprio processo (`WebContentsNSViewBridge::SetParentNSView` → `GetNSViewFromId`).
5. **Pixels:** o processo de GPU cria um `CAContext` (`ui/accelerated_widget_mac/ca_layer_tree_coordinator.mm:182`) e manda só o `ca_context_id`. Quem mostra cria um `CALayerHost` com esse id (`display_ca_layer_tree.mm`). Numa janela do shim os pixels chegam pela janela (`NativeWidgetNSWindow.SetCALayerParams`), porque a aba entra na camada da janela (`SetParentUiLayer`). Sem camada-mãe, a aba tem compositor próprio e manda o contexto dela (`BrowserCompositorMac::UpdateState` → `HasOwnCompositor`). É o caminho do content_shell e do modo headless.
6. **Entrada:** a `RenderWidgetHostViewCocoa` (3.100 linhas, `content/app_shim_remote_cocoa/`) roda no shim e fala `RenderWidgetHostNSViewHost` (`content/common/render_widget_host_ns_view.mojom`): mouse e roda como eventos do Blink, teclado como evento do Blink **mais o `NSEvent` serializado** (`ui::EventToData`, porque o evento reconstruído "não chega nem perto do original"), IME (`ImeSetComposition`, `ImeCommitText`, e chamadas síncronas para o retângulo do cursor), foco (`OnFirstResponderChanged`, `OnWindowIsKeyChanged`), tamanho (`OnBoundsInWindowChanged`).
7. **Acessibilidade:** troca de tokens (`GetRenderWidgetAccessibilityToken`, `NSAccessibilityRemoteUIElement`). A árvore fica no navegador.

## Os caminhos

| | (a) Agens faz o papel do shim | (b) só a camada remota + eventos | (c) janela do motor colada por cima |
|---|---|---|---|
| O que o Agens carrega | O framework do navegador (573 MB no build Dev), com `ContentMain`, alocador, mojo e `NSApplication` do Chromium | Nada do Chromium. Swift + `CALayerHost` (classe privada do QuartzCore) | Nada |
| Mudança no motor | Pequena: um `Application` remoto para o Agens e ligar as abas nele | Pequena: publicar o id do contexto e receber eventos (feito aqui) | Pequena: janela sem borda que segue o painel |
| Teclado, IME, cursor, arrastar | De graça, mantidos pelo Chromium | **Nossos.** Teclado e IME básicos feitos; cursor, arrastar e soltar, posição da janela do IME faltam | De graça |
| Menus e balões da página (`select`, contexto, autofill, permissão, extensão) | Funcionam: abrem no processo do Agens | Não têm janela para ancorar. Precisam vir como dados para o Agens desenhar (permissão já vem pela `agens_embed.h`) | Funcionam |
| Foco | Normal | Normal no Agens; o motor recebe "focou/desfocou" | Ruim: clicar ativa o outro app, a janela do Agens perde o destaque. Só resolve com painel não ativante e API privada de ordem de janelas |
| Redimensionar | Sincronizado pelo Chromium | Segue, mas sem sincronia de quadro (pode piscar; ver riscos) | Atrasa: duas janelas de processos diferentes |
| Várias abas em vários painéis | Sim | Sim: um contexto por aba visível | Uma janela por painel, ordem entre janelas frágil |
| Tela cheia | Do Chromium | Nossa (o Agens decide) | Frágil |
| Acessibilidade | De graça | A fazer, com os mesmos tokens | De graça |
| Rebase mensal | Patch pequeno, mas o `BrowserKit` passa a depender do build exato do motor (mojo sem versão) e do arranque do Chromium dentro do Agens | Patch pequeno e a fronteira é o nosso protocolo. O que acompanha o Chromium é a tradução de eventos (~200 linhas) | Patch pequeno |
| Um `CHECK` do Chromium derruba | O Agens | Só o motor | Só o motor |

**(d) Outras saídas que o código sugere:**
- Tirar só o `remote_cocoa` e as vistas para uma biblioteca pequena. Não é uma flag: esses arquivos fazem parte do alvo `//content/browser` (`content/browser/BUILD.gn:2691`) e puxam base, mojo, ui e blink. Vira um alvo novo para manter a cada rebase. Só vale se (b) empacar.
- Não existe API pública do macOS para mostrar a vista de outro processo. A privada (`NSRemoteView`) exige serviço XPC.

## Por que (b) primeiro

- É o único que respeita "o motor não roda dentro do Agens" de verdade. O (a) põe o Chromium dentro do Agens em tudo menos o nome.
- O ponto mais incerto de todos os caminhos é o mesmo: **um app de fora consegue mostrar o `CAContext` do nosso processo de GPU?** O (b) testa isso com o mínimo de peças. O shim do Chrome já faz isso com assinatura diferente da do navegador, então a expectativa é que sim.
- Se a entrada reimplementada se mostrar cara demais, (a) continua aberto e aproveita o mesmo motor.
- (c) fica como último recurso: funciona no primeiro dia e incomoda para sempre.

## O que foi implementado

**Motor** (`~/browser-work-3/…/src`, commit `809011e2c7`, 10 arquivos, 651 linhas):

- `content/public/browser/agens_embed_mac.h` e `content/browser/renderer_host/agens_embed_mac.mm`: o lado do navegador do contrato da `RenderWidgetHostViewCocoa`, sem mojo. Avisa a cada quadro o id do contexto da aba; recebe foco, mouse, roda, teclado (com o resultado do sistema de texto: texto inserido, comandos de edição, composição) e os comandos do menu Editar. Mouse, roda e tecla chegam como `NSEvent` serializado e passam pelos mesmos construtores de evento que o Chromium usa.
- `render_widget_host_view_mac.mm`: **1 linha** em `AcceleratedWidgetCALayerParamsUpdated` (mais o `#include`). É a única mudança em código do Chromium, além de 5 linhas em três `BUILD.gn`.
- `chrome/browser/agens/embed/embed_host_mac.cc`: o servidor da prova. Socket Unix `0600`, uma mensagem JSON por linha, um cliente. Só existe com `--agens-embed-socket=<caminho>`.
- `native_shell_mac.mm`: enquanto um cliente está ligado, a casca não põe a aba na janela dela. A aba fica sem janela, visível e no tamanho que o cliente pediu, e por isso desenha sozinha. Quando o cliente sai, a aba volta para a janela.

**App de exemplo** (`kit/apple/exemplo/`): `main.swift` (~380 linhas, AppKit puro) e `build.sh`. Janela com voltar, avançar, recarregar, endereço, "+", fileira de abas e a página. A vista da página repete a montagem de camadas do Chromium (`DisplayCALayerTree`) e implementa `NSTextInputClient`.

**Protocolo da prova** (provisório; o definitivo é o socket de `docs/agens.md`):

| Do app para o motor | |
|---|---|
| `attach {width,height}` / `resize {width,height}` | Liga na primeira janela; tamanho da página em pontos |
| `focus {on}` | A vista virou (ou deixou de ser) a que recebe teclado |
| `mouse {data,x,y}` / `mouse.leave` / `wheel {data,x,y}` | `data` é o `NSEvent` (`CGEventCreateData`, base64); `x,y` a partir do canto de cima |
| `key {data,text,commands,marked,sel_start,sel_end,had_marked,unmarked}` | A tecla e o que o `interpretKeyEvents:` fez com ela |
| `edit {command}` | `cut`, `copy`, `paste`, `selectAll`, `undo`, `redo` |
| `navigate {text}`, `tab.new`, `tab.activate {index}`, `tab.close {index}`, `back`, `forward`, `reload` | Pela `agens_embed.h` |

| Do motor para o app | |
|---|---|
| `layer {context,width,height,scale}` | O id para o `CALayerHost`; muda ao trocar de aba ou de processo |
| `tabs {tabs:[{title,url,active,loading}]}` | A cada mudança |

**Atalhos assumidos na prova** (estão marcados com `shortcut:` no código):
- ninguém confere quem conecta no socket (a conferência de assinatura é da fase 1 do plano);
- uma janela só, e ela continua aparecendo no motor, com o cartão da página vazio;
- botão direito não é enviado (o menu de contexto abriria no motor, sem janela para ancorar);
- sem forma do cursor, dica (tooltip), arrastar e soltar, acessibilidade, tela cheia;
- a janela do IME aparece sob a vista, não no cursor de texto; texto que chega fora de uma tecla (emoji, ditado) é descartado;
- posição na tela enviada ao Blink é a posição na vista.

## O que está verificado

| | Como |
|---|---|
| O shim carrega o framework inteiro e é dono do processo | Lido (arquivos acima) |
| Aba sem janela-mãe usa compositor próprio e publica `ca_context_id` | Lido: `BrowserCompositorMac::UpdateState`, `AcceleratedWidgetMac::UpdateCALayerTree` |
| Aba sem janela aceita tamanho e foco | Lido: `RenderWidgetHostViewMac::IsHeadless()` e os desvios que ele ativa; `sendViewBoundsInWindowToHost` trata vista sem janela |
| O motor compila e liga com a mudança | `build.sh dev` terminou com `ok:` |
| O app de exemplo compila | `kit/apple/exemplo/build.sh` terminou com `ok:` |
| `CALayerHost` existe no macOS 27 e guarda o `contextId`; um `NSEvent` sobrevive à ida e volta como dados de `CGEvent`; uma mensagem é sempre uma linha | Autoteste do app (`exemplo --selftest`), sem janela |
| **Todo o resto** (aparece? clica? digita?) | **Não testado.** Só rodando |

## Como rodar o primeiro teste (estágio 2)

Abre duas janelas e rouba o foco. Só no horário combinado.

```sh
SOCK=/tmp/agens-embed.sock
ENGINE=~/browser-work-3/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app/Contents/MacOS/AgensBrowser
"$ENGINE" --user-data-dir="$(mktemp -d)" --agens-embed-socket="$SOCK" --enable-logging=stderr \
  https://example.com 2> /tmp/agens-embed-motor.log &
until [ -S "$SOCK" ]; do sleep 0.2; done
/Users/williansugiyama/Documents/AgensBrowser/kit/apple/exemplo/build/exemplo "$SOCK"
```

Se a janela "Primeiros passos" aparecer, feche. Para encerrar: ⌘Q no exemplo e `kill %1`.

**O que olhar, em ordem:**

1. `grep "agens embed" /tmp/agens-embed-motor.log` mostra `listening on` e depois `client connected`. Sem isso: a casca nativa não subiu ou o socket falhou (o erro está no log).
2. O terminal do exemplo imprime `tabs [...]` e logo `layer context=<número> <largura>x<altura> scale=2`. **Sem a linha `layer`, a aba não está desenhando sozinha**: o problema está no motor (visibilidade ou compositor), não no app.
3. A página aparece na janela do exemplo e o cartão da página na janela do motor fica vazio. Linha `layer` com janela em branco: o `CALayerHost` não mostrou o contexto de outro app. É o resultado que derruba o caminho (b) e também o (a).
4. Página de cabeça para baixo, deslocada ou em escala errada: é a montagem de camadas no `main.swift`, corrige-se lá.
5. Clicar num link navega; passar o mouse muda o estado dos links; a roda rola, com inércia.
6. Clicar num campo e digitar: letras, acentos (`´` + `a`), Backspace, setas, Enter, Tab, ⌘A, ⌘C, ⌘V.
7. Digitar um endereço no campo do exemplo e Enter; "+" cria aba; clicar na fileira de abas troca; trocar a aba pela lateral do motor também troca no exemplo.
8. Redimensionar a janela do exemplo: a página acompanha.
9. Memória: `footprint -p exemplo` deve ficar em poucas dezenas de MB e não crescer com a página.

**Sucesso da prova:** itens 1 a 7. **Falha que muda a arquitetura:** item 3.

## O que só se aprende rodando (em ordem)

1. O `CALayerHost` de um app de fora mostra o contexto do nosso processo de GPU? (Palpite: sim, o shim faz igual.)
2. A aba sem janela produz quadros, e continua produzindo com a janela do motor minimizada, coberta ou escondida? O macOS pode pôr o motor em App Nap quando ele não tem janela visível.
3. Orientação, posição e escala da camada; monitor com escala diferente do principal (o motor usa a escala do monitor principal).
4. Redimensionar sem sincronia de quadro: pisca, estica? O Chromium usa uma porta Mach de "fence" para isso (`ca_context_fence_mach_port`), que hoje descartamos.
5. Teclado: teclas que a página não trata. O Chromium as reenvia para a janela dele (`HandleKeyboardEvent`); aqui elas podem cair na barra de endereço do motor. No produto têm de voltar para o Agens.
6. Composição (acentos, japonês) pela nossa versão resumida da lógica da `RenderWidgetHostViewCocoa`.
7. O que acontece quando a página abre algo do motor: lista de `select`, autofill, `alert`, pedido de permissão, balão de extensão. Hoje aparecem na janela do motor ou em lugar errado; pode haver crash por falta de janela.
8. Troca de processo ao navegar entre sites (vista nova, contexto novo): o exemplo troca de camada sem piscar?
9. Vídeo, WebGL e rolagem suave: desempenho igual ao do navegador?
10. Fechar o exemplo devolve a aba para a janela do motor sem defeito.

## Depois da prova, se (b) passar

- Trocar o transporte pelo socket do plano (`docs/agens.md`), com a conferência de quem conecta.
- Motor sem janela: uma "janela" por painel do Agens que nunca aparece na tela.
- Mandar para o app, como dados: forma do cursor, menu de contexto, lista de `select`, tecla não tratada, retângulo do cursor de texto, tooltip.
- Acessibilidade pelos tokens remotos, arrastar e soltar, tela cheia.
- Windows (#61): o equivalente é outro mecanismo; nada daqui se aproveita além do protocolo.
