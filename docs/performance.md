# Performance

É o porquê do produto.

## A meta

**Usar no máximo 50% da RAM do Brave**, na mesma máquina e com as mesmas 20 abas, sem piorar o Speedometer 3. (Willian, 07/11/2026)

**Em número (09/11/2026):** o Brave usa 3.866 MB com as 20 abas, então a meta é **no máximo 1.933 MB**. Hoje o nosso usa 3.817 MB (99% do Brave): faltam **~1.880 MB** (−49%).

### Onde está a memória hoje (09/11/2026, 1 rodada de 3.674 MB, o nosso build oficial)

| Tipo de processo | Hoje | % | Meta | Alavanca |
|---|---|---|---|---|
| Abas (renderers) | 3.178 MB | 86% | **≤ 1.450 MB** | abas que dormem (#8), teto de processos (#10), V8 (#11) |
| GPU | 257 MB | 7% | ≤ 230 MB | menos vídeo decodificando em aba que não aparece (#8) |
| Navegador (processo principal + UI) | 152 MB | 4% | ≤ 150 MB | a UI nativa não pode crescer isso (#6) |
| Serviços (rede, armazenamento, áudio, captura de vídeo) | 127 MB | 3% | ≤ 100 MB | enxugar (#7): a captura de vídeo (27 MB) não devia estar viva sem câmera em uso |
| **Total** | **3.674 MB** | | **≤ 1.930 MB** | |

- Quase tudo está nas abas. A meta inteira depende de as abas em segundo plano (16 das 20 são vídeo ou live) dormirem.
- A medição é feita 5 min depois de abrir as abas. Se a regra de dormir agir depois disso, a medição precisa de uma variante longa (por exemplo, 30 min), definida na #8.
- Os números por tipo somam a memória de cada processo e podem contar duas vezes a memória compartilhada. Por isso a soma (3.714 MB) passa um pouco do total (3.674 MB).

## Alavancas

Tudo por cima do Chromium, em patches pequenos e em camadas, para o rebase mensal continuar barato. Antes de escrever, procurar o que o Chromium já tem (`performance_manager`, Memory Saver, Energy Saver, tab freezing) e só ajustar a regra.

| Área | O que fazer | Issue |
|---|---|---|
| Enxugar | o que ainda roda em segundo plano depois do ungoogled: serviços, timers, component updater, rede ociosa | P4 |
| Abas que dormem | congelar depois de X s em segundo plano; descartar depois de Y min com estado salvo; exceções: áudio, upload, formulário com texto, aba fixada a pedido | P5 |
| Atos que dormem | só o ato em uso carregado; os outros descarregam inteiros | #9 (ver abaixo) |
| Processos | teto de processos de página e quando juntar sites; sites com login continuam isolados | #10 (ver abaixo) |
| V8 | teto de heap por página, GC mais cedo, modo bateria | #11 (ver abaixo) |
| UI nativa | a camada SwiftUI/WinUI não pode comer o que economizamos no Chromium | P3 |

## Método de medição

- **Máquina:** o mesmo Mac Apple silicon (e depois o mesmo Windows), na tomada, sem outros apps abertos. Anotar modelo, RAM e versão do sistema.
- **Navegadores:** Brave (a referência da meta) e o nosso (build oficial), cada um na versão anotada. Chrome fica de fora por decisão do Willian (09/11/2026).
- **Perfil:** perfil de medição separado, sem login e sem extensões (exceto na rodada "com 1Password", depois do M4).
- **Rodadas:** 3 por navegador, vale a mediana. Os navegadores são medidos um depois do outro, no mesmo dia, porque as lives mudam.
- **Conjunto fixo de 20 abas**, o uso real do Willian (09/11/2026): quase tudo Twitch e YouTube, sem login. A lista exata está em [`tools/tabs.txt`](../tools/tabs.txt):

  8 de Twitch (início, diretório, categorias e 4 canais), 8 de YouTube (início, live 24 h, vídeo 4K longo, vídeo, Shorts, busca, canal, explorar), GitHub, UOL, Google Maps e MDN.

- **Métricas:**

  | Métrica | Como |
  |---|---|
  | Memória total | `total footprint` de todos os processos do navegador (`footprint`), o mesmo número do Monitor de Atividade; medida **10 min** depois de abrir as 20 abas (até 09/11/2026 eram 5 min; mudou porque as abas dormem aos 5 min, #8) |
  | Memória por aba | memória total ÷ abas, e o processo de cada aba no gerenciador de tarefas do navegador |
  | Processos | quantos processos o navegador tem com as 20 abas |
  | Tempo para abrir | frio (depois de reiniciar) e quente, até a primeira página pintada |
  | Speedometer 3 | browserbench.org, numa aba sozinha |
  | Bateria | roteiro fixo de 1 h na bateria; `pmset -g batt` no início e no fim |

## Orçamento da UI

Números provisórios até a issue P3 medir:

| O quê | Alvo |
|---|---|
| Abrir a janela (quente) | aparecer em menos de 300 ms |
| Nova aba | foco na barra em menos de 100 ms |
| Troca de aba e digitação na barra | 120 Hz em ProMotion, sem frame perdido |
| Processo do app (sem o Chromium) | menos de 150 MB |

## Regressão

Cada release mede o conjunto no runner local. O release não sai se passar de 50% da RAM do Brave ou piorar mais de N% sobre o release anterior (N fixado na issue P9).

## Como rodar

```sh
tools/measure.py brave --login      # uma vez por navegador: só se algum dia o conjunto tiver aba com login: abre as abas no perfil de medição; entre e feche com ⌘Q
tools/measure.py brave              # 3 rodadas de 5 min; imprime a linha para docs/medicoes.md
```

- `BROWSER`: `brave`, `chrome`, `ungoogled` (build oficial), `dev` (build dev, nunca para medir) ou o caminho do executável.
- Os perfis de medição ficam em `~/browser-work/bench-profiles/<navegador>`, separados do perfil do dia a dia. Os JSON de cada rodada ficam em `~/browser-work/measurements/`.
- As abas estão em [`tools/tabs.txt`](../tools/tabs.txt). Trocou a lista, anote em `medicoes.md`.
- Cada rodada espera 10 min depois de abrir as abas (`--settle`).
- O script mede o tempo do lançamento até o `load` de uma página local (com o perfil já existente), a memória total (`total footprint` do `footprint`, que conta a memória compartilhada uma vez), a memória por aba e o nº de processos. Speedometer 3 e bateria ainda são feitos à mão.
- Meça com o Mac parado: sem build rodando e na tomada.
- **Motor escondido** (`--agens-embedded`, sem janela e sem roubar o foco): `tools/measure_hidden.py [--atos 3] [--show] [--settle 240] -- <flags do motor>`. Perfil descartável, o script é o hospedeiro e abre as abas com `view.open`; imprime memória total, processos e renderers a cada `--sample` s. Serve para comparar uma mudança no build dev (com e sem a feature, no mesmo dia); a linha de `medicoes.md` continua vindo do `measure.py` no build oficial.

## Abas que dormem (#8)

Patch [`chromium/patches/sugiyamalabs/sleeping-tabs.patch`](../chromium/patches/sugiyamalabs/sleeping-tabs.patch), em cima do Memory Saver do Chromium:

- Memory Saver **ligado por padrão**.
- Uma aba escondida há **5 min** é descartada: o processo dela fecha, e a URL, o histórico e a rolagem ficam guardados. Ao voltar, ela recarrega.
- O tempo é o parâmetro `discard_after` da feature `SleepingTabs` e muda sem recompilar: `--enable-features=SleepingTabs:discard_after/2m`. Desligar: `--disable-features=SleepingTabs`, que volta às 2/4/6 h do Chromium.
- Valem as proteções do Chromium. **Não dorme:** aba visível, aba ativa de qualquer janela, aba fixada, aba tocando áudio (e até 1 min depois), com formulário editado, usando câmera, microfone ou tela, em Picture-in-Picture, com DevTools aberto, ou que mudou título ou ícone em segundo plano. Também não dorme aba revisitada mais de 15 vezes.
- **Upload em andamento também não dorme** (patch [`upload-protection.patch`](../chromium/patches/sugiyamalabs/upload-protection.patch), #37). Vale para upload por script (`fetch`/XHR com corpo, como Gmail, Drive e WhatsApp), em que o Blink avisa o performance manager do primeiro envio que começa e do último que termina, e para formulário POST, enquanto a navegação espera a resposta.
- **Nova tentativa:** se a aba estava protegida quando o tempo acabou (upload, áudio, câmera…), o timer tenta de novo depois do mesmo intervalo, enquanto ela continuar escondida. No Chromium original, essa aba só voltava a ter chance depois de ser vista e escondida outra vez.

## Nova aba sem página por baixo (#54)

A casca desenha a nova aba, então a aba nova para `chrome://newtab` (⌘T, "+", a primeira aba da janela, `view.open` sem `url`) não carrega nada: fica no documento vazio inicial, sem renderer, até a pessoa navegar. Antes, cada nova aba subia um renderer com a página do Chromium por baixo da nossa. Patch em `browser_navigator.cc`, só com `AgensNativeShell` ligada. Diferença para o Chrome: a primeira página aberta nessa aba não tem "voltar" para a nova aba. Uma aba que navega para `chrome://newtab` (sem ser aba nova) continua carregando a página.

## Captura de vídeo só com câmera em uso (#34)

O serviço de captura de vídeo (27 MB na medição de 09/11) ficava vivo para sempre depois que uma página listava os dispositivos, porque o navegador ficava ouvindo as mudanças de câmera nele. Ligamos no Mac a feature do Chromium `ReleaseVideoSourceProviderIfNotInUse` (vinha desligada): sem página usando câmera nem ouvindo `devicechange`, o navegador solta o serviço depois de **60 s** e ele fecha 5 s depois. Ao soltar, a lista de câmeras guardada é jogada fora, para a próxima página pedir a lista nova (era o motivo de a feature vir desligada, crbug 377749384). Mudar o tempo: `--enable-features=ReleaseVideoSourceProviderIfNotInUse:release_video_source_provider_timeout/10s`; desligar: `--disable-features=ReleaseVideoSourceProviderIfNotInUse`. Uma página que ouve `devicechange` segura o serviço enquanto estiver aberta.

**Aba que parou de usar a câmera** (decisão de 17/11/2026): antes, a aba segurava o serviço até fechar, porque o Chromium só soltava quando não restava nenhum `VideoCaptureHost`, e esse objeto vive enquanto o frame vive. Agora conta só host com stream ao vivo (`video_capture_host.cc` avisa o `MediaStreamManager` quando o primeiro stream começa e quando o último para): parou o último `track.stop()`, o mesmo prazo de 60 s corre e o serviço fecha com a aba aberta. O gate escondido confere com `release_video_source_provider_timeout/2s` (`/camera`: liga a câmera falsa, para os tracks, o serviço sai em até 20 s). Continua valendo o limite do `devicechange`.


## Agrupar abas do mesmo site (#10)

Em cima do `ProcessPerSiteUpToMainFrameThreshold` do Chromium, que no desktop só valia para o buscador padrão:

- Abas do **mesmo site** dividem um processo, **até 4 por processo** (Chromium: 2, e só no buscador). Desligamos `ProcessPerSiteForDSE` em `chrome_features.cc` e o padrão do limite em `content_features.cc` vira 4.
- **O isolamento de sites fica.** Um processo só recebe páginas de um site; site com login nunca divide processo com outro site. Só divide com abas dele mesmo (duas abas do Gmail podem ficar juntas). Sandbox igual.
- Um processo ainda abrindo (abas abertas de uma vez, sessão voltando) também pode receber a aba seguinte do mesmo site. Antes ele era recusado por ainda não ter memória medida, e cada aba ganhava um processo.
- Ficam valendo as travas do Chromium: processo com DevTools aberto não recebe outra aba, e o processo não passa de 2 GB estimados.
- **Teto de processos:** não mudamos. Com o isolamento estrito, o teto só faz juntar mais abas do mesmo site depois de atingido; para testar existe `--renderer-process-limit=N`.
- Ajustar: `--enable-features=ProcessPerSiteUpToMainFrameThreshold:ProcessPerSiteMainFrameThreshold/2`. Voltar ao Chromium: `--enable-features=ProcessPerSiteForDSE` (e o limite 2).

Medido no motor escondido (build dev, 16/11/2026, 20 abas de `tabs.txt`, abas que dormem desligadas para isolar, ~110 s depois de abrir, 1 rodada cada): **23 → 16 renderers** e 5.097 → 4.480 MB. A memória varia ±0,5 GB entre rodadas por causa das lives; o número de processos é estável.

## V8: teto de heap, GC mais cedo e modo bateria (#11)

- **Teto de heap por renderer: 1 GB** (`--max-old-space-size=1024` no `--js-flags` de cada renderer; o padrão do V8 nesta máquina é 4 GB; era 2 GB até 17/11/2026, o Willian achou demais). É um teto para página descontrolada: página normal usa bem menos (dezenas a poucas centenas de MB de heap). Com o #10 um renderer é um site com até 4 abas. Uma página que passa disso termina em "sem memória" sozinha, em vez de levar a máquina junto. Ajustar: `--enable-features=AgensV8HeapCap:max_mb/2048`; desligar: `--disable-features=AgensV8HeapCap`. Um `--js-flags=--max-old-space-size=…` passado ao navegador vence.
- **GC mais cedo em segundo plano:** um renderer sem nada à vista devolve memória (GC completo do V8 e limpeza do alocador) **1 min** depois de ir para o fundo. No Chromium era um sorteio entre 1 e 4 min. É o parâmetro `memory_purge_background_max_delay` da feature `MemoryPurgeInBackground`.
- **Pressão de memória:** fica como no Chromium. O sinal do macOS já chega ao V8 (moderada: GC incremental; crítica: GC completo).
- **Modo bateria:** a Economia de energia do Chromium liga **sempre que o Mac está na bateria** (Chromium: só abaixo de 20%). Ela limita a 30 fps, põe o V8 no modo bateria, que otimiza menos e coleta mais cedo, e, com `BatterySaverModeAlignWakeUps` (ligada por nós), junta os timers de fundo para acordar a CPU menos vezes. A pessoa pode mudar nas configurações (`performance_tuning.battery_saver_mode.state`). Na tomada nada muda, então o Speedometer 3 (medido na tomada) não muda por isso.

Medido no motor escondido (16/11/2026, 20 abas, 1 rodada cada, ~3 min): com os ajustes, 4.230–5.154 MB; sem eles, 3.795–4.449 MB. A diferença some no ruído das lives: nesse cenário **não deu para medir ganho**. Não medidos: Speedometer 3 e bateria em 1 h (pedem o build oficial com janela).

**Achado (#11, #8):** no motor escondido, uma aba que o hospedeiro nunca mostrou fica **visível para o Chromium** para sempre: o Chromium mantém o primeiro estado até a aba aparecer de verdade. Por isso, no motor escondido, as abas que dormem (#8), o GC de fundo e a prioridade baixa de renderer em segundo plano não valem para essas abas, e 20 abas pesam ~4,5–5 GB (no build com janela, 3,8 GB). Os atos que dormem (#9) contornam isso; a correção geral fica para uma decisão (as abas de agente rodam escondidas e ficariam mais lentas).

## Atos que dormem (#9)

Arquivo `chrome/browser/agens/embed/agens_ato_sleep.cc`:

- Um ato **sem aba à vista e sem aba de agente por 10 min** (configurável) dorme: as abas dele são descartadas, os processos de página fecham, e cada aba continua na lista com URL, título e histórico. "À vista" é a aba na janela visível (motor sozinho) ou a que o hospedeiro mostra (`view.attach`, motor escondido).
- **Acorda ao usar:** mostrar uma aba dele (trocar para o ato, `view.attach`) recarrega a página. As outras abas recarregam quando forem mostradas. O id `v…` da aba não muda ao dormir (antes, um descarte trocava o id no motor escondido).
- Não dorme: aba de agente (o ato inteiro fica acordado), aba tocando áudio, usando câmera, microfone ou tela, em upload, com formulário editado, em Picture-in-Picture, com DevTools, PDF, com notificações ligadas e os "sites que nunca dormem". Essas ficam acordadas e o resto do ato dorme. Diferente das abas que dormem (#8), aqui **a aba ativa, a fixada e a que muda o título no fundo também dormem**: é o ato inteiro que saiu de uso. A ativa e as fixadas podem ficar acordadas pela preferência abaixo.
- O ato continua carregado (`asleep: false`); o socket mostra `sleeping: true` em `atos.list` ([protocolo.md](protocolo.md#atos-fase-1)). Descarregar o perfil inteiro (o `asleep` de verdade) fica para depois: fecha as janelas do ato e depende do `view.restore` para voltar.
- **Configurações › Abas que dormem** (decisão de 17/11/2026; Local State, a casca lê e grava com `agens_pref_get/set_*` em `kAgensLocal`; a tela espera o protótipo):
  - `agens.atos_sleep_after_min` (int): a espera, **5, 10, 30 ou 60 min**, ou **0 = nunca**. Padrão 10.
  - `agens.atos_sleep_active_pinned` (bool): a aba ativa e as fixadas dormem junto com o ato. Padrão ligado. Desligado, elas ficam acordadas e o resto do ato dorme. "Pôr o ato para dormir" (do menu) põe todas, independente disso.
  - A mudança vale na próxima volta da regra (até 1 min).
- Ajustar sem rebuild: `--enable-features=AgensAtoSleep:after/30m` (o `after` passado vence a preferência); desligar: `--disable-features=AgensAtoSleep`. O gate escondido usa `after/6s`.

Medido no motor escondido (build dev, 16/11/2026, 20 abas de `tabs.txt` divididas em 3 atos, uma aba do primeiro ato à vista, `after/2m`, abas que dormem desligadas para isolar): aos 2 min, **3.956 MB e 14 renderers**; aos 3 min, com os 2 atos fora de uso dormindo, **2.137 MB e 7 renderers**. Os renderers dos 2 atos somam zero; o que sobra deles está no processo do navegador (perfil carregado). Tempo para acordar: o de carregar a página de novo (não medido nas 20 abas; o gate confere que volta em menos de 20 s).
