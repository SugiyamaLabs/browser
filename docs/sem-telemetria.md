# Sem telemetria: como provamos

Promessa: o navegador não fala com ninguém que a pessoa não pediu. As exceções são a procura de atualização, uma vez por dia no GitHub ([abaixo](#atualizações)), e o Widevine, baixado do Google para tocar vídeo protegido ([abaixo](#widevine-conteúdo-protegido)). Baixar um idioma para traduzir vai à Apple só depois do OK da pessoa ([abaixo](#idiomas-da-tradução)). Esta página diz como isso é medido e o último resultado.

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

## Atualizações

A única conexão que o navegador faz sem a pessoa pedir: **uma vez por dia**, o Sparkle baixa `https://github.com/SugiyamaLabs/browser/releases/latest/download/appcast.xml` (GitHub, que redireciona para o armazenamento de arquivos dele). Vai o pedido HTTP comum do Sparkle, com o nome e a versão do app no User-Agent; nada de perfil do sistema (o `SUEnableSystemProfiling` fica desligado, o padrão). Havendo versão nova, baixa o `.dmg` do mesmo release. Detalhes em [casca](casca.md#atualizações).

- Desligar: na janela do Sparkle (aparece ao ter atualização, ou por **Procurar atualizações…** no menu AgensBrowser e no Sobre), desmarcando a procura automática; o Sparkle guarda a escolha nas preferências do app (`SUEnableAutomaticChecks`).
- Não existe no motor embutido no Agens, nem no build dev (sem `--agens-updates`).
- O `idle_audit.py` de 09/11/2026 é de antes disso. Num perfil novo o Sparkle só procura depois do intervalo, então 10 minutos parado ainda devem dar 0 conexões; não foi medido de novo.

## Widevine (conteúdo protegido)

Netflix, Disney+, Spotify e outros sites com DRM precisam do Widevine, um componente do Google. Ele não vem no app (licença): o navegador baixa sozinho, em segundo plano, pelo component updater do Chromium. Vem **ligado**.

- **Quando conecta:** cerca de 1 minuto depois de abrir, e de novo a cada 5 horas com o navegador aberto (o ciclo normal do component updater), pergunta se há versão nova. Na primeira vez, ou havendo versão nova, baixa o pacote (≈ 10 MB).
- **Para onde:** a pergunta vai a `https://update.googleapis.com/service/update2/json` (o protocolo Omaha do Google, com assinatura CUP na resposta). O download vem do endereço que a resposta der; no teste foi `http://edgedl.me.gvt1.com/edgedl/release2/chrome_component/…/oimompecagnajdejgnnjijobebaeigek_4.10.3112.0_mac_arm64_….crx3`, em **HTTP** (é o que o servidor do Google oferece; o pacote é um CRX3 assinado, conferido contra o hash fixo do Widevine antes de instalar, então não dá para trocá-lo no caminho, mas quem olha a rede vê que é o Widevine). O download passa pela rede do próprio Chromium (proxy, NetLog), nunca pelo `NSURLSession` de segundo plano do sistema (`chrome_component_updater_configurator.cc`).
- **O que vai:** o pedido padrão do component updater: o id do Widevine (`oimompecagnajdejgnnjijobebaeigek`) e a versão instalada, a versão do navegador, sistema, arquitetura e os ids de sessão e pedido do protocolo. Só o Widevine: os outros componentes do Chromium continuam registrados mas nunca são perguntados (`component_updater_service.cc`), e os relatórios de instalação (pings) estão desligados (`configurator_impl.cc`).
- **Onde fica:** `WidevineCdm/<versão>/` dentro da pasta de dados (`~/Library/Application Support/AgensBrowser`, ou a pasta do motor no Agens). Roda no Mac e conversa só com o site que toca o vídeo.
- **Desligar:** Configurações › Privacidade › Conteúdo protegido, "Permitir conteúdo protegido (Widevine)" (`agens.widevine.enabled`, Local State). Desligado, o componente nem é registrado: nenhum pedido ao Google; desligar apaga a versão instalada na hora, e a cada abertura com ele desligado a pasta `WidevineCdm` inteira é apagada. **Remover componente** apaga a versão instalada; com o interruptor ligado, ela volta a baixar na próxima abertura. Um vídeo que já carregou o Widevine continua com ele até o navegador fechar.
- **Motor embutido no Agens:** o mesmo comportamento e a mesma preferência (ligada), na pasta de dados do motor. Lá não há Configurações; desligar é pela preferência.
- Por isso o `idle_audit.py` de um perfil novo agora mostra `update.googleapis.com` e o download depois do primeiro minuto.

Medido em 19/11/2026 (build dev, motor escondido `--agens-embedded`, perfis novos, NetLog; script de teste fora do repo):

| Caso | Google na NetLog | Resultado |
|---|---|---|
| Ligado (padrão) | `update.googleapis.com/service/update2/json` (1 pedido) e o `.crx3` em `edgedl.me.gvt1.com` | `WidevineCdm/4.10.3112.0/` no perfil em ~3 min; nenhum outro componente perguntado |
| Mesmo perfil, reaberto | nada nos ~10 s do teste | `requestMediaKeySystemAccess('com.widevine.alpha')` + `createMediaKeys()` numa página local: ok |
| Desligado (`agens.widevine.enabled` false), 100 s, com uma pasta `WidevineCdm/1.0.0.0` posta antes | nada | pasta apagada |

As outras conexões do perfil novo no mesmo teste foram só as listas do bloqueador no GitHub ([bloqueador](bloqueador.md)). Não medido: tocar um vídeo com DRM de verdade (Netflix, Spotify), o interruptor e o Remover pela tela (sem abrir janela), e o build oficial.

## Idiomas da tradução

A tradução de páginas é da Apple, no próprio Mac (framework Translation, macOS 15 ou mais novo); o texto da página nunca sai do Mac e a tradução do Chromium (Google) continua desligada. A única conexão é **baixar um idioma da Apple**, e só com o OK da pessoa:

- Na primeira tradução de um idioma que o Mac ainda não tem, o popover pergunta "Baixar o idioma …?" (Da Apple. Fica no Mac). Só o **Baixar** chama o download, que o macOS faz e mostra na janela dele; o pedido sai do serviço de tradução do macOS, não do navegador. Cancelar não conecta nada.
- Idioma já baixado (por nós, pelo Safari ou pelo app Traduzir) traduz sem rede.
- Apagar: Ajustes do macOS › Geral › Idioma e Região › Idiomas da Tradução (o framework não deixa apagar de dentro do app; Configurações › Idiomas tem o botão que abre ali).
- Descobrir o idioma da página também é no Mac (NaturalLanguage da Apple sobre o texto da página, ou o `lang` que ela declara).

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

De quebra: Privacy Sandbox (Topics, Protected Audience, medição de anúncios), `ping` de hyperlink, páginas de erro alternativas, serviço de ortografia, tradução do Google (a nossa é a da Apple, no Mac: [acima](#idiomas-da-tradução)), `canMakePayment`, salvar senha e autopreenchimento vêm desligados.

Não mudado, para decidir: cortar o referrer entre sites de vez (flag `NoCrossOriginReferrers` do ungoogled) quebra CDN com proteção contra hotlink, alguns fluxos de pagamento e de login e páginas que conferem a origem do clique.
