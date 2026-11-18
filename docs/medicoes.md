# Medições

Método em [performance.md](performance.md#método-de-medição). Cada linha é a mediana de 3 rodadas com as mesmas 20 abas.

| Data | Máquina | Navegador e versão | Memória total | Memória por aba | Processos | Abrir frio / quente | Speedometer 3 | Bateria 1 h | % do Brave |
|---|---|---|---|---|---|---|---|---|---|
| 09/11/2026 | Apple M5 Pro, 64 GB | Brave 1.98.63 (Chromium 156) | 3.866 MB | 193 MB | 28 | — / 0,60 s | — | — | 100% |
| 09/11/2026 | Apple M5 Pro, 64 GB | nosso: ungoogled 156.0.8078.79, build oficial, sem patches nossos | 3.817 MB | 191 MB | 33 | — / 0,46 s | — | — | **99%** |
| 09/11/2026 | Apple M5 Pro, 64 GB | nosso: ungoogled 156.0.8078.79 oficial + abas que dormem (#8), medido aos 10 min | **291 MB** | 15 MB | 7 | — / 0,45 s | — | — | **8%** |
| 18/11/2026 | Apple M5 Pro, 64 GB | nosso: ungoogled 156.0.8078.79 oficial, HEAD `be454eb8c1` (casca, #9, #10, #11, #34, #63…), aos 10 min | 1.169 MB | 58 MB | 11 | — / 0,51 s | — | — | — |
| 18/11/2026 | Apple M5 Pro, 64 GB | nosso: o mesmo + título que a página ainda acerta não segura a aba (#8) e captura de vídeo solta depois de só listar (#34), aos 10 min | **465 MB** | 23 MB | 7 | — / 0,52 s | — | — | — |

## Notas da medição de 09/11/2026

- 20 abas de `tools/tabs.txt` (Twitch e YouTube, sem login), 5 min depois de abrir, 3 rodadas, mediana. Brave e o nosso medidos um logo depois do outro.
- Rodadas do Brave: 5.540 / 3.839 / 3.866 MB. A primeira teve 65 processos contra 28 das outras: era a primeira abertura do perfil (o Brave baixa listas e componentes). A mediana descarta essa rodada.
- Rodadas do nosso: 3.817 / 3.937 / 3.734 MB.
- O Brave bloqueia anúncios por padrão, e o nosso ainda não. Mesmo assim, os dois ficam praticamente iguais.
- Speedometer 3 e bateria ainda não foram medidos.
- Quebra por tipo de processo do nosso build (1 rodada, `tools/measure.py` imprime `by process kind`): abas 3.178 MB, GPU 257 MB, navegador 152 MB, rede 53 MB, captura de vídeo 27 MB, armazenamento 24 MB, áudio 23 MB. As metas por área estão em [performance.md](performance.md#onde-está-a-memória-hoje-09112026-1-rodada-de-3674-mb-o-nosso-build-oficial).
- **Abas que dormem (#8), 09/11/2026:** 3 rodadas de 10 min, 290,9 / 290,7 / 289,9 MB. Aos 10 min, as 19 abas escondidas estão descartadas e só a aba visível (MDN, a última aberta) tem processo. Por tipo: abas 108 MB, GPU 73 MB, navegador 70 MB, rede 24 MB, armazenamento 20 MB. O número mostra o navegador depois de 10 min de uso com uma aba à vista. Se a aba à vista for uma live, ou se a pessoa trocar de aba o tempo todo, a memória sobe: cada aba acordada volta ao custo normal (~190 MB em média).
- **Cenários extras das abas que dormem, 09/11/2026** (build oficial, `--mute-audio`, 1 rodada cada):
  - **Live visível** (YouTube 24 h na aba à vista, as outras 19 escondidas), aos 10 min: **728 MB**, 10 processos. Abas 358 MB, navegador 140 MB, GPU 117 MB, rede 47 MB, captura de vídeo 29 MB, áudio 24 MB, armazenamento 21 MB.
  - **Troca de aba a cada 30 s**, passando pelas 20 em sequência: ~4,7 GB nos 4 primeiros minutos (nada dorme ainda), e de 5 a 10 min fica entre **2,8 e 3,2 GB**, com 15–18 renderers. Nesse ritmo, cada aba é revisitada a cada 10 min e fica acordada por 5, então metade delas está sempre viva. É o pior caso, e **passa do teto de 1.933 MB**. Um `discard_after` menor (2 min) reduziria isso, ao custo de mais recargas.

## Notas da medição de 18/11/2026

- **Antes da correção** (build oficial do HEAD, 3 rodadas): 1.168 / 1.246 / 1.108 MB, 11 processos. Por tipo: abas ~700 MB, GPU 180–315 MB, navegador 140–170 MB, rede ~40 MB, captura de vídeo 30 MB, áudio ~22 MB, armazenamento ~20 MB. Resultado guardado em `$BROWSER_WORK/measurements/2026-11-18-ungoogled-antes.json`.
- **Por que as abas não dormiam:** lendo o `chrome://discards` aos 6–7 min, 16 das 19 abas escondidas estavam descartadas. Ficavam acordadas os 2 vídeos do YouTube (às vezes o terceiro) e o Google Maps, todos com o motivo "Tab is updating favicon or title in the background". Nenhuma delas mudava o título de verdade depois de abrir (`/json/list` a cada 2 s, 5 min): a marca vinha das trocas de título dos primeiros segundos (YouTube: título do vídeo → "YouTube" → título do vídeo), que caíam logo depois de o Chromium dar a página por carregada, com a aba já escondida. A marca não sai enquanto a aba não for vista, então essas abas nunca dormiam. Desligar o bloqueador (nível 0), o agrupamento (#10) ou a casca não mudou nada: não era código nosso, era a regra do Chromium com essas páginas. Correção em [performance.md](performance.md#abas-que-dormem-8).
- **Por que captura de vídeo e áudio continuavam vivos:** o YouTube chama `enumerateDevices()` ao abrir. Isso abre os dois serviços. O de vídeo só começava o prazo de 60 s para sair quando alguma página ouvia `devicechange` ou parava a câmera; com só a lista, ficava até fechar o navegador. O de áudio não tem prazo nenhum no Chromium. Corrigido o de vídeo; o de áudio fica (ver [performance.md](performance.md#captura-de-vídeo-só-com-câmera-em-uso-34)).
- **Depois da correção** (build oficial, 3 rodadas, aos 10 min): 473 / 465 / 464 MB, 7 processos, as 19 abas escondidas descartadas. Por tipo: GPU 172–177 MB, navegador 126–137 MB, abas ~85 MB (só a MDN, à vista), rede ~37 MB, áudio 23 MB, armazenamento ~21 MB. Só com a correção das abas (sem a do vídeo): 497 / 492 / 493 MB, 8 processos (captura de vídeo 27 MB).
- Diferença para os 291 MB de 09/11: GPU (+~100 MB) e navegador (+~57 MB), mais o áudio (23 MB). Não investigado; a casca nativa entrou depois de 09/11 e é a suspeita para GPU e navegador.

