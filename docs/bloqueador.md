# Bloqueador de anúncios e rastreadores (#41)

Primeira versão: bloqueio de rede, ligado por padrão, em todos os atos (inclusive aba anônima). Patch [`chromium/patches/sugiyamalabs/adblock.patch`](../chromium/patches/sugiyamalabs/adblock.patch).

## Caminho escolhido: `subresource_filter` do Chromium

Dos dois caminhos da issue, foi o (1).

- **Já está no binário.** É o filtro que o Chrome usa contra anúncio abusivo: o processo do navegador decide se a página é filtrada e cada renderer bloqueia script, imagem, XHR, iframe e worker com a lista indexada, mapeada em memória e compartilhada entre os processos. Não entra nenhuma dependência nova no build.
- **O patch é pequeno** (~180 linhas, 7 arquivos). O `adblock-rust` exigiria integrar o crate no GN, escrever o throttle de rede e a ponte C++/Rust: isso não sai em um dia.
- O que ele não faz (filtro cosmético, scriptlets) foi feito à parte, em código nosso: [#63, parte 2](#filtro-cosmético-avisos-de-cookies-e-youtube-63-parte-2).

### `adblock-rust` ou código nosso (#63)

A direção registrada era o `adblock-rust` (Brave, MPL-2.0). Ficou o subconjunto nativo:

- **Peso.** O Chromium já compila Rust, mas o crate traz ~15 dependências que teriam de entrar em `third_party/rust` com `gnrt` e licenças, mais a ponte C++/Rust e um throttle de rede próprio, duplicando o `subresource_filter` que já bloqueia por URL. Os scriptlets do `adblock-rust` também não vêm com ele: são o `scriptlets.js` do uBlock (GPLv3), que teria de ser distribuído junto.
- **O que o nativo cobre.** Regras de URL (subresource_filter), regras cosméticas `##`/`#@#` e as regras `+js(...)` das listas com os 12 scriptlets mais usados (~85% das ~5,2 mil regras `+js` das nossas listas; as de cookies sozinhas são ~2 mil `set-cookie`), mais o scriptlet próprio do YouTube.
- **O que fica de fora** (e o `adblock-rust` + `scriptlets.js` dariam): `$redirect`, `$removeparam`, `$replace`, `$csp`, `$important`, filtros procedurais (`:has-text`, `:upward`, `:xpath`…), scriptlets `trusted-*`, `json-prune-fetch-response`/`-xhr-response`, `remove-attr`/`remove-class`, `href-sanitizer` e entidades `site.*`. Se isso pesar em sites reais, o `adblock-rust` continua sendo a opção.

### Como funciona

| Peça | O que faz |
|---|---|
| `third_party/sugiyamalabs_adblock/BUILD.gn` | no build, o `ruleset_converter` do Chromium transforma as listas em **um `adblock_rules_N` por nível** (só regras de URL, ~4 MB cada) e os dois entram em `Resources/` do framework, junto com as listas cruas em `Resources/adblock_lists/*.txt` |
| `chrome/browser/sugiyamalabs/adblock.cc` | níveis, atualização diária e conversor (abaixo). `browser_process_impl.cc` só chama `Start()` ao criar o serviço de regras |
| `content_subresource_filter_throttle_manager.cc` | ativa o filtro em toda página (no Chromium, só em sites marcados pelo Safe Browsing, que o ungoogled não tem), **exceto** com o nível em 0 ou em site liberado |
| `registration.cc` | não registra o componente "Subresource Filter Rules" do Google: a única lista é a nossa |
| feature `NativeAdblock` | ligada por padrão. Desligar para comparar: `--disable-features=NativeAdblock` |

## Níveis

Pref `agens.adblock.level` (Local State, inteiro). **Padrão de fábrica: 2 (Forte)**, a privacidade máxima é o padrão do produto.

| Nível | Listas | Regras de URL |
|---|---|---|
| 0 Desligado | nenhuma; o filtro nem ativa nas páginas | 0 |
| 1 Padrão | EasyList + EasyPrivacy | `adblock_rules_1` |
| 2 Forte | Padrão + uBlock filters + uBlock privacy + EasyList Cookie List | `adblock_rules_2` |

O `subresource_filter` aceita **um** ruleset, então o build gera um por nível (escolha mais simples: sem trabalho em runtime, ~8 MB a mais no app, e o conversor roda uma vez só no build). Ao trocar o nível a pref dispara a indexação do arquivo do nível novo em segundo plano (~2 s; a versão é `nível-tamanho-data`, então cada nível tem o seu índice no perfil) e vale a partir da próxima página. Nível 0 liga um flag global (`IsNativeAdblockActive()`), sem precisar indexar nada.

Outras prefs (Local State): `agens.adblock.auto_update` (bool, padrão true), `agens.adblock.last_update` (hora), `agens.adblock.hide_cookie_notices` (bool, padrão true; quem lê é o filtro cosmético).

## Sites liberados

Content setting `ADS` do Chromium, por ato. Uma exceção ALLOW para o site desliga o filtro nele: o throttle manager pergunta `ProfileInteractionManager::IsSiteAllowlisted(url)` (o mesmo `GetSitePermission` que o Chromium usa) antes de ativar. A API grava o padrão de domínio `[*.]site` (o site e os subdomínios, qualquer esquema e porta; um `www.` na frente é ignorado). Funciona igual na aba anônima (herda do ato). Limite: a decisão é tomada com a URL em que a navegação começou, não depois dos redirecionamentos.

## Atualização diária das listas

- Uma vez por dia (checa 2 min depois de abrir e depois de hora em hora; se falhar, tenta de novo só depois de 6 h), com `agens.adblock.auto_update` ligado e nível > 0. Nunca no caminho da abertura.
- Baixa **só** de `https://raw.githubusercontent.com/SugiyamaLabs/browser/main/chromium/adblock/lists/<lista>.txt`, GET sem cookies e sem identificador. Essa é a única conexão de um navegador parado, fora a atualização de extensões. **O repositório precisa ser público** para o raw funcionar.
- Guarda em `<user-data-dir>/AgensAdblock/lists/*.txt`. Qualquer falha (rede, HTTP != 200, arquivo que não parece lista, conversão) mantém as anteriores. Só troca depois de baixar e converter tudo.
- **Conversão em runtime: feita.** O conversor (`RulesetConverter`, código de biblioteca do Chromium) roda num processo filho: o próprio executável com `--agens-convert-rules=<saída> --agens-convert-inputs=<listas>` (gancho no início de `ChromeMainDelegate::BasicStartupComplete`). Processo separado porque o conversor dá `CHECK` em entrada ruim e uma lista malformada não pode derrubar o navegador; sem binário novo para assinar. Gera `AgensAdblock/rules_1` e `rules_2`; se existirem, valem no lugar dos do app.
- Depois: grava `last_update`, reindexa o nível atual. Medido no build dev (servidor local, 5 listas, ~7 MB): do início da checagem até o filtro novo valendo em menos de 45 s (não cronometrado com precisão).
- Para o app e o filtro cosmético: lista = `AgensAdblock/lists/` se existir, senão `Resources/adblock_lists/`.
- Opção de teste (não usar fora disso): `--agens-adblock-lists-url=http://127.0.0.1:porta/` troca o endereço base e antecipa a 1ª checagem para 5 s.

## API para a interface

`chrome/browser/agens/embed/agens_adblock.h` (C puro): `agens_adblock_level/set_level`, `..._auto_update/set_auto_update`, `..._last_update` (segundos, 0 = nunca), `..._hide_cookie_notices/set_...`, `..._update_now(fn, ctx)` (ok + mensagem em pt-BR), `..._allowed_sites(window, fn, ctx)`, `..._allow_site(window, site, allow)`, `..._credits()` (texto em pt-BR com as listas, autores e licenças, para a tela Sobre ou Configurações › Bloqueador). Contagem de regras por nível: não feita (o conversor não devolve; dá para ler do tamanho dos `adblock_rules_N`).

## Listas e licenças

Ficam em [`chromium/adblock/lists/`](../chromium/adblock/lists/); o `fetch.sh` copia para a árvore do Chromium.

| Lista | Origem | Licença |
|---|---|---|
| EasyList | easylist.to | GPLv3 ou CC BY-SA 3.0, à escolha |
| EasyPrivacy | easylist.to | GPLv3 ou CC BY-SA 3.0, à escolha |
| uBlock filters | github.com/uBlockOrigin/uAssets | GPLv3 |
| uBlock filters – Privacy | github.com/uBlockOrigin/uAssets | GPLv3 |
| EasyList Cookie List (EasyList – Cookie Notices) | easylist.to, cópia em ublockorigin.github.io/uAssets | GPLv3 ou CC BY-SA 3.0, à escolha |

O app distribui uma versão convertida das listas. Para cumprir GPL/CC BY-SA: dar crédito às listas (o texto pronto vem de `agens_adblock_credits()`; falta a interface mostrar, na tela Sobre ou em Configurações › Bloqueador), manter o texto original das listas disponível (já está no repositório) e não colocar restrição extra sobre o arquivo de regras. Os scriptlets usam os nomes e argumentos do uBlock, mas o código é nosso (não copia o `scriptlets.js` GPLv3).

Das ~111 mil regras de URL das quatro primeiras listas, ~105,8 mil entram. As outras usam sintaxe só do uBlock (`$redirect`, `$removeparam`, `$replace`, `3p`, `$important`…) e o conversor descarta. Regras cosméticas (`##`) ficam de fora por enquanto.

## Como atualizar as listas

```sh
chromium/adblock/update-lists.sh      # baixa as 5 listas; o navegador as baixa de main uma vez por dia
git add chromium/adblock/lists && git commit -m "Update ad blocker filter lists"
cp chromium/adblock/lists/*.txt "$SRC_DIR/third_party/sugiyamalabs_adblock/lists/"   # ou fetch.sh
chromium/build.sh                     # o conversor roda de novo só se uma lista mudou
```

O conversor imprime no log do build um aviso para cada regra que descartou. É esperado.

## Medido (09/11/2026, build dev)

Teste com o mesmo binário, ligado e desligado (`--disable-features=NativeAdblock`), perfil novo a cada rodada. A janela própria (Webium) estava quebrando na árvore nesse dia por um trabalho em andamento de outra issue, então o teste usou `--disable-features=Webium` (janela clássica do Chromium). O bloqueador não depende da janela.

| Página | Desligado | Ligado |
|---|---|---|
| Página local com `adsbygoogle.js`, `gpt.js` (doubleclick), `googletagservices`, `google-analytics`, `googletagmanager` | 5 de 5 carregam | **5 de 5 bloqueados**; jQuery e imagem da Wikipedia (controle) carregam |
| YouTube, vídeo 4K | toca | **toca** (avançou ~4 s em 4 s); 14 bloqueados: `googleads.g.doubleclick.net`, `static.doubleclick.net`, `/pagead/`, `/pcs/activeview`, `log_event` |
| UOL | abre | **abre** (453 links, 37 imagens); 22 bloqueados: `tm.jsuol.com.br`, `me.jsuol.com.br`, doubleclick, scorecardresearch, permutive, chartbeat, cxense, google-analytics |
| YouTube, live 24 h | `readyState` 0 em 25 s | igual (não é o bloqueador); 14 bloqueados |
| Twitch, canal ao vivo | não medido | **toca**; bloqueados: `amazon-adsystem.com`, `scorecardresearch.com` |
| Twitch, diretório | não medido | abre (105 cards); bloqueados `edge.ads.twitch.tv`, `amazon-adsystem.com` |

- **`tools/idle_audit.py`, 10 min, perfil novo, ligado** (a lista é indexada durante a janela): NetLog **0**, lsof **0**, CPU 1,6 s.
- **Memória, 1 aba (UOL), `tools/measure.py --runs 3 --settle 60`, build dev** (não vale como número oficial, só como comparação): desligado **1.283 MB** (mediana; 17–18 processos), ligado **~525 MB** (516 e 535; 8 processos). A diferença vem sobretudo dos iframes de anúncio, que viram processos próprios. A 1ª rodada ligada fechou sem aba (243 MB, 0 páginas) e ficou fora da conta.

## Medido: níveis, sites liberados e atualização (10/11/2026, build dev, perfil novo por rodada)

Página local (`localhost`) que carrega 8 scripts de terceiros; controle `/ok.js` sempre carrega. Bloqueado = `blockedReason: subresource-filter` no DevTools.

| Rodada | Bloqueados |
|---|---|
| Nível 0 | **0 de 8**; o controle carrega |
| Nível 1 | **5 de 8**: adnxs, criteo, `td.doubleclick.net`, `adsbygoogle.js`, `gpt.js` (EasyList/EasyPrivacy); passam `app.secureprivacy.ai` e `axeptio.eu` (só na lista de cookies) |
| Nível 2 | **7 de 8**: os 5 do nível 1 + `app.secureprivacy.ai` + `axeptio.eu` |
| Nível 2 + `localhost` liberado (exceção `ADS` ALLOW no perfil) | **0**; o mesmo site sem a exceção bloqueia 7 |
| Atualização (servidor local nos 5 arquivos, com 1 regra nova `\|\|updatetest.example^` na EasyList) | 5 GETs, `Cookie: None`, só o host dado; criou `AgensAdblock/lists/*.txt` (5), `rules_1` (4,1 MB), `rules_2` (4,3 MB); `last_update` gravado; a regra nova passou a bloquear (**8 de 9**) |
| Atualização com servidor fora do ar | listas e regras anteriores mantidas, sem `last_update`, regra nova continua valendo |

Não testado: troca de nível com o navegador aberto (testado trocando a pref e reabrindo), a API C chamada por uma interface (só compila e linka; o filtro honrando a exceção foi testado semeando o `Preferences`), a atualização contra o `raw.githubusercontent.com` real (o caminho ainda não existe em `main`: 404).

## O que falta para fechar a #41

- **Anúncio no vídeo do YouTube**: feito (scriptlet próprio + regras `+js` das listas, abaixo). **Twitch: não feito.** O anúncio é costurado no HLS do mesmo domínio e o player da Twitch baixa a playlist num Web Worker, onde os nossos scriptlets (só no main world do documento) não chegam. Os contornos conhecidos (vaft, TTV LOL) pedem outra playlist com outro tipo de player ou passam por um proxy de terceiros, o que quebra o "zero conexões". Fica para quando valer reescrever a resposta da playlist no processo de rede (`$replace`).
- **Filtro cosmético**: feito (parte 2). O índice de regras CSS do `subresource_filter` não foi usado.
- **Configurações › Bloqueador**: a tela usa a API acima (parte 2 da #63), inclusive o texto de créditos.
- **Medir com as 20 abas** (`tools/measure.py` no build oficial) e comparar com antes.
- Na primeira abertura de um perfil, as páginas abertas nos ~2 s antes de a lista ser indexada não são filtradas.

## Filtro cosmético, avisos de cookies e YouTube (#63, parte 2)

Patch [`adblock-cosmetic.patch`](../chromium/patches/sugiyamalabs/adblock-cosmetic.patch). Não usa extensão: é um observer no renderer mais um serviço no navegador.

| Peça | O que faz |
|---|---|
| `chrome/browser/agens_adblock/cosmetic_engine.*` | lê as listas (`##seletor`, `dominio##seletor`, `~dominio`, `#@#`) e monta o CSS de cada host. Regras de sintaxe só do uBlock (`:has-text`, `:xpath`, `+js(`, `:style(`…) são ignoradas |
| `cosmetic_service.cc` | carrega as listas numa thread (22 ms para ~47 mil regras), lê `agens.adblock.level` e `agens.adblock.hide_cookie_notices` (Local State; sem registro = padrão 2 / ligado), confere o content setting `ADS` do site |
| `youtube_scriptlet.cc` | scriptlet do YouTube, mesma ideia do `json-prune` do uBlock |
| `scriptlets.cc` | as regras `dominio##+js(...)` das listas viram um script só por página (abaixo) |
| `chrome/renderer/agens_adblock/cosmetic_observer.cc` | em cada documento http(s) novo, antes de qualquer script da página, faz **uma** chamada mojo síncrona ao navegador e aplica o CSS (`InsertStyleSheet`, origem usuário) e o scriptlet (main world) |

- **Por que renderer e não extensão ou injeção pelo navegador.** Só o gancho do renderer roda antes do primeiro script e do primeiro paint, sem corrida com o commit da navegação, e dispensa componente de extensão (que traria service worker e mensagens só para entregar CSS por domínio). A chamada síncrona é um lookup em hash no navegador; sem ela haveria corrida com o JSON do player.
- **Níveis.** 0 = nada. 1 (Padrão) = EasyList + lista de cookies (se `hide_cookie_notices`) + YouTube. 2 (Forte) = + listas uBlock. O nível de uma lista vem do nome do arquivo (`*cookie*` = cookies, `*ublock*` = Forte, o resto = Padrão). Site liberado (`ADS` = ALLOW) não recebe nada; subframe segue o site da aba.
- **Subframes** recebem só as regras do próprio domínio (sem as genéricas), para o CSS por frame ficar pequeno.
- **Onde ficam as listas.** `<perfil>/AgensAdblock/lists/*.txt` se existir (atualização diária), senão `Resources/adblock_lists/*.txt` do app. A cada 10 min o serviço confere tamanho/data e recarrega sozinho. Só para teste: `--agens-adblock-lists-dir=<pasta>`. Nenhuma conexão de rede nova.
- **YouTube.** No documento (antes do script da página): `ytInitialPlayerResponse` ganha um setter que remove `adPlacements`, `playerAds`, `adSlots` e `auxiliaryUi.messageRenderers.enforcementMessageViewModel`; `JSON.parse`, `fetch` e `XMLHttpRequest` de `/youtubei/v1/player` e `get_watch` passam pelo mesmo filtro (navegação SPA). Há uma rede de segurança que pula o anúncio se mesmo assim um começar (`.ad-showing`). Medido em 3 vídeos reais: sem pré-roll, reproduz, sem o aviso "bloqueadores violam os termos", a rede de segurança nunca disparou.
- **Scriptlets das listas** (`dominio##+js(nome, args…)`, `#@#+js(...)` e `#@#+js()` para desligar todos no domínio). Código nosso, com os nomes e argumentos do uBlock: `set` (set-constant), `aopr`, `aopw`, `acs` (abort-current-script), `aeld`, `nostif`, `nosiif`, `nowoif`, `json-prune` (com `[]` e `[-]`), `set-cookie`, `set-local-storage-item` e `set-session-storage-item`, mais os aliases longos e `.js`. `set-cookie` e o storage só aceitam valores de consentimento (`accept`, `true`, `0`…) e nunca sobrescrevem um cookie que já existe; `trusted-*` e os outros nomes são ignorados. Só regras com domínio (o uBlock também recusa `##+js` genérico); seguem o nível como o CSS (o `set-cookie` da lista de cookies só com `hide_cookie_notices`). Rodam antes do scriptlet do YouTube, que fica com a última palavra sobre `ytInitialPlayerResponse`.
- **Primeira página depois de abrir o navegador.** Se as listas ainda estão carregando, a resposta ao renderer espera o fim da carga (~50 ms, uma vez) em vez de deixar a página sem filtro.
- **Twitch: não feito** (ver [O que falta](#o-que-falta-para-fechar-a-41)).
- **Teste sem build:** `chromium/adblock/cosmetic_selftest.cc` (instruções no topo) cobre o parser; com listas reais mede tempo e tamanho.
- **Teste com o navegador, sem janela:** [`tools/sites-teste/bloqueador/`](../tools/sites-teste/bloqueador/). `serve.py 8766` serve `/` (CSS, cookies e os scriptlets das listas, em `localhost`) e `/youtube` (player falso: `ytInitialPlayerResponse` inline, `JSON.parse`, `fetch` e XHR de `/youtubei/v1/player` com anúncio). A página põe `PASS`/`FAIL` e o resultado de cada item no título. Com as listas reais mais `lista.txt` e `lista-cookie.txt` numa pasta:

  ```sh
  Agens --headless=new --user-data-dir=<perfil novo> --agens-adblock-lists-dir=<pasta> \
    --virtual-time-budget=3000 --dump-dom http://localhost:8766/ | grep '<title>'
  # YouTube falso: serve.py --tls 8443 e
  #   --host-resolver-rules="MAP www.youtube.com 127.0.0.1:8443" --ignore-certificate-errors https://www.youtube.com/watch
  ```

### Custo medido (build dev, listas reais, nível 2 com a lista de cookies)

- CSS por página: ~1,19 MB nas genéricas; montar no navegador leva ~0,05–0,6 ms. As genéricas da lista de cookies (~650 KB) são mais da metade.
- Renderer: ~+35 ms no DOMContentLoaded de uma página local simples (parse do CSS) e ~+13 MB por renderer de aba. É o custo do desenho "uma folha por frame". Se pesar: indexar as genéricas por classe/id e só injetar as que existem na página (como o uBlock), ao custo de um piscar nos elementos já existentes.
- Navegador: ~15 MB de pico ao carregar as listas (parse), menos depois.

### Medido: scriptlets das listas e YouTube falso (16/11/2026, build dev, headless, perfil novo por rodada)

Listas reais mais `tools/sites-teste/bloqueador/lista*.txt`, servidas com `--agens-adblock-lists-dir`.

| Rodada | Resultado |
|---|---|
| `/`, padrão (nível 2, cookies ligado) | **PASS** nos 14 itens: CSS do anúncio e do aviso de cookies, exceção `#@#`, `set`, `aopr`, `acs` (e outro script intacto), `nostif`, `json-prune`, `set-cookie`, `set-local-storage-item`, `aeld`, `nowoif`, `trusted-*` ignorado. É a **primeira página do perfil**: antes da espera pela carga das listas, a mesma página saía sem CSS nem scriptlets |
| `/`, `hide_cookie_notices` desligado | só o CSS do aviso e o `set-cookie` deixam de valer; o resto igual |
| `/`, nível 0 | nada aplicado |
| `/youtube` como `https://www.youtube.com/watch` (servidor local com certificado próprio) | **PASS**: `ytInitialPlayerResponse`, `JSON.parse`, `fetch` e XHR de `/youtubei/v1/player` chegam sem `adPlacements`/`playerAds`/`adSlots`, junto com as regras `+js` reais do YouTube; nível 0 = tudo com anúncio |

Não testado: YouTube e sites reais com rede e janela (pré-roll de verdade, quebra de site por algum scriptlet das listas), tempo e memória a mais por página, o texto de créditos numa interface.
