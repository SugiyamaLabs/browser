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

## Privacidade no máximo por padrão (#42)

Auditoria dos padrões em 16/11/2026 (build dev, perfil novo, `chrome://prefs-internals` lido pelo DevTools em modo headless; cabeçalhos conferidos numa página local que devolve o que recebeu). Nenhum padrão precisou mudar para ficar mais forte. Em 16/11/2026 o WebRTC foi **afrouxado** de propósito para `default_public_interface_only`, para Meet e Discord funcionarem normalmente.

| Item | Pref | Padrão hoje | De onde vem | O que pode quebrar |
|---|---|---|---|---|
| Cookies de terceiros bloqueados | `profile.cookie_controls_mode` | 1 (bloqueia terceiros) | ungoogled (inox) | login embutido em outro domínio (SSO em iframe, alguns widgets de comentário e pagamento); a exceção por site resolve |
| Do Not Track | `enable_do_not_track` | ligado; a página recebe `DNT: 1` | ungoogled | nada conhecido |
| Global Privacy Control | `universal_optout.enabled` | ligado; `Sec-GPC: 1` e `navigator.globalPrivacyControl = true` | Chromium 156 | nada conhecido |
| Sem previsão nem pré-carga de rede | `net.network_prediction_options` | 2 (desligado): sem preconnect, DNS prefetch nem prerender | ungoogled | navegação um pouco mais lenta no primeiro clique |
| WebRTC | `webrtc.ip_handling_policy` | `default_public_interface_only` (mudado em 16/11/2026; o ungoogled vinha com `disable_non_proxied_udp`) | nosso (`browser_ui_prefs.cc`) | nada conhecido: só a interface da rota padrão, com o IP público; IP local nunca vaza. A chamada (Meet, Discord, Zoom web) segue direta por UDP, sem cair para TURN. Configurações › Privacidade, "Não revelar o IP local", liga e desliga entre este e `default` |
| HTTPS | `https_only_mode_enabled` | ligado (HTTPS-Only estrito), mais o upgrade automático | Chromium 156 | site só HTTP mostra um aviso antes de abrir; `localhost` não. Em aba de agente não há aviso: abre sozinha, marcada `insecure`, e digitar ali pede o OK da pessoa ([protocolo](protocolo.md#páginas-sem-https)) |
| Referrer | `enable_referrers` | ligado, política `strict-origin-when-cross-origin` (para outro site vai só a origem, salvo se a página pedir outra) | Chromium | nada; ver decisão abaixo |
| Sugestões de busca | `search.suggest_enabled` | desligado | ungoogled | nenhuma sugestão até a pessoa ligar |
| Safe Browsing | — | não existe no build | ungoogled | — |

De quebra: Privacy Sandbox (Topics, Protected Audience, medição de anúncios), `ping` de hyperlink, páginas de erro alternativas, serviço de ortografia, tradução, `canMakePayment`, salvar senha e autopreenchimento vêm desligados.

Não mudado, para decidir: cortar o referrer entre sites de vez (flag `NoCrossOriginReferrers` do ungoogled) quebra CDN com proteção contra hotlink, alguns fluxos de pagamento e de login e páginas que conferem a origem do clique.
