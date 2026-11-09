# Performance

É o porquê do produto.

## A meta

**Usar no máximo 50% da RAM do Brave**, na mesma máquina e com as mesmas 20 abas, sem piorar o Speedometer 3. (Willian, 07/11/2026)

As metas por área (por aba, por processo, perfil dormindo, UI nativa) saem da primeira medição (issue P2) e somam até essa.

## Alavancas

Tudo por cima do Chromium, em patches pequenos e em camadas, para o rebase mensal continuar barato. Antes de escrever, procurar o que o Chromium já tem (`performance_manager`, Memory Saver, Energy Saver, tab freezing) e só ajustar a regra.

| Área | O que fazer | Issue |
|---|---|---|
| Enxugar | o que ainda roda em segundo plano depois do ungoogled: serviços, timers, component updater, rede ociosa | P4 |
| Abas que dormem | congelar depois de X s em segundo plano; descartar depois de Y min com estado salvo; exceções: áudio, upload, formulário com texto, aba fixada a pedido | P5 |
| Perfis que dormem | só o perfil em uso carregado; os outros descarregam inteiros | P6 |
| Processos | teto de processos de página e quando juntar sites; sites com login continuam isolados | P7 |
| V8 | teto de heap por página, GC mais cedo, modo bateria | P8 |
| UI nativa | a camada SwiftUI/WinUI não pode comer o que economizamos no Chromium | P3 |

## Método de medição

- **Máquina:** o mesmo Mac Apple silicon (e depois o mesmo Windows), na tomada, sem outros apps abertos. Anotar modelo, RAM e versão do sistema.
- **Navegadores:** Brave (referência da meta), Chrome estável, ungoogled puro e o nosso, cada um na versão anotada.
- **Perfil:** perfil de medição separado, sem login e sem extensões (exceto na rodada "com 1Password", depois do M4).
- **Rodadas:** 3 por navegador, vale a mediana. Os navegadores são medidos um depois do outro, no mesmo dia, porque as lives mudam.
- **Conjunto fixo de 20 abas**, o uso real do Willian (09/11/2026): quase tudo Twitch e YouTube, sem login. A lista exata está em [`tools/tabs.txt`](../tools/tabs.txt):

  8 de Twitch (início, diretório, categorias e 4 canais), 8 de YouTube (início, live 24 h, vídeo 4K longo, vídeo, Shorts, busca, canal, explorar), GitHub, UOL, Google Maps e MDN.

- **Métricas:**

  | Métrica | Como |
  |---|---|
  | Memória total | soma do `phys_footprint` de todos os processos do navegador (`footprint`), o mesmo número do Monitor de Atividade; medida 5 min depois de abrir as 20 abas |
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
- O script mede o tempo do lançamento até o `load` de uma página local (com o perfil já existente), a memória total (`total footprint` do `footprint`, que conta a memória compartilhada uma vez), a memória por aba e o nº de processos. Speedometer 3 e bateria ainda são feitos à mão.
- Meça com o Mac parado: sem build rodando e na tomada.
