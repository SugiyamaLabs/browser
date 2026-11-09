# Medições

Método em [performance.md](performance.md#método-de-medição). Cada linha é a mediana de 3 rodadas com as mesmas 20 abas.

| Data | Máquina | Navegador e versão | Memória total | Memória por aba | Processos | Abrir frio / quente | Speedometer 3 | Bateria 1 h | % do Brave |
|---|---|---|---|---|---|---|---|---|---|
| 09/11/2026 | Apple M5 Pro, 64 GB | Brave 1.98.63 (Chromium 156) | 3.866 MB | 193 MB | 28 | — / 0,60 s | — | — | 100% |
| 09/11/2026 | Apple M5 Pro, 64 GB | nosso: ungoogled 156.0.8078.79, build oficial, sem patches nossos | 3.817 MB | 191 MB | 33 | — / 0,46 s | — | — | **99%** |

## Notas da medição de 09/11/2026

- 20 abas de `tools/tabs.txt` (Twitch e YouTube, sem login), 5 min depois de abrir, 3 rodadas, mediana. Brave e o nosso medidos um logo depois do outro.
- Rodadas do Brave: 5.540 / 3.839 / 3.866 MB. A primeira teve 65 processos contra 28 das outras: era a primeira abertura do perfil (o Brave baixa listas e componentes). A mediana descarta essa rodada.
- Rodadas do nosso: 3.817 / 3.937 / 3.734 MB.
- O Brave bloqueia anúncios por padrão, e o nosso ainda não. Mesmo assim, os dois ficam praticamente iguais.
- Speedometer 3 e bateria ainda não foram medidos.
- Quebra por tipo de processo do nosso build (1 rodada, `tools/measure.py` imprime `by process kind`): abas 3.178 MB, GPU 257 MB, navegador 152 MB, rede 53 MB, captura de vídeo 27 MB, armazenamento 24 MB, áudio 23 MB. As metas por área estão em [performance.md](performance.md#onde-está-a-memória-hoje-09112026-1-rodada-de-3674-mb-o-nosso-build-oficial).
