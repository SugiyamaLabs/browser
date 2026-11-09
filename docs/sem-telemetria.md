# Sem telemetria: como provamos

Promessa: o navegador não fala com ninguém que a pessoa não pediu. Esta página diz como isso é medido e o último resultado.

## Como medir

```sh
tools/idle_audit.py ungoogled --minutes 10
```

Abre o navegador num perfil novo, sem abas, e deixa parado. Duas fontes, para nada escapar:

- o **NetLog** do próprio Chromium (`--log-net-log`), que registra toda requisição, DNS e socket do processo de rede, desde a abertura;
- o **`lsof`** a cada 2 s sobre todos os processos do navegador, que pega socket aberto fora do processo de rede.

Também mede a CPU usada no período parado. Antes de valer, o script foi conferido abrindo `https://example.com`: o NetLog pegou `example.com` e `example.com/s.js`, e o `lsof` pegou 2 sockets.

## Resultado

| Data | Build | Janela | Conexões (NetLog / lsof) | CPU parado |
|---|---|---|---|---|
| 09/11/2026 | ungoogled 156.0.8078.79, oficial, sem patches nossos | 10 min, perfil novo, sem abas | **0 / 0** | 0,8 s (0,13% de um núcleo) |

Processos vivos no fim: navegador, GPU, rede, armazenamento e 3 renderers (a nova aba e páginas internas).

## O que isso ainda não cobre

- Janelas mais longas (horas) e perfil usado há dias: tarefas agendadas podem aparecer depois.
- O que acontece ao navegar (DNS prefetch, pré-conexão, verificação de certificado). Fica para quando tivermos o app próprio.
- O nosso código (`core/`, `embed/`, app). Cada release roda o `idle_audit.py` de novo.
