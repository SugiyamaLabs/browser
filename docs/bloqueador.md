# Bloqueador de anúncios e rastreadores (#41)

Primeira versão: bloqueio de rede, ligado por padrão, em todos os atos (inclusive aba anônima). Patch [`chromium/patches/sugiyamalabs/adblock.patch`](../chromium/patches/sugiyamalabs/adblock.patch).

## Caminho escolhido: `subresource_filter` do Chromium

Dos dois caminhos da issue, foi o (1).

- **Já está no binário.** É o filtro que o Chrome usa contra anúncio abusivo: o processo do navegador decide se a página é filtrada e cada renderer bloqueia script, imagem, XHR, iframe e worker com a lista indexada, mapeada em memória e compartilhada entre os processos. Não entra nenhuma dependência nova no build.
- **O patch é pequeno** (~180 linhas, 7 arquivos). O `adblock-rust` exigiria integrar o crate no GN, escrever o throttle de rede e a ponte C++/Rust: isso não sai em um dia.
- O que ele não faz (filtro cosmético, scriptlets) está em [O que falta](#o-que-falta-para-fechar-a-41). Se isso pesar, o `adblock-rust` continua sendo a opção para depois.

### Como funciona

| Peça | O que faz |
|---|---|
| `third_party/sugiyamalabs_adblock/BUILD.gn` | no build, o `ruleset_converter` do Chromium transforma as listas em `adblock_rules` (só regras de URL, ~4 MB) e o arquivo entra em `Agens Framework.framework/Resources` |
| `browser_process_impl.cc` | ao criar o serviço de regras, entrega o `adblock_rules` do app para ser indexado (em segundo plano, ~2 s na primeira abertura; 7,8 MB em `Subresource Filter/Indexed Rules` no perfil). A versão é tamanho + data do arquivo: só reindexa quando o app atualiza |
| `content_subresource_filter_throttle_manager.cc` | ativa o filtro em toda página. No Chromium, ele só ativa em sites marcados pelo Safe Browsing, que o ungoogled não tem |
| `registration.cc` | não registra o componente "Subresource Filter Rules" do Google: a única lista é a nossa |
| feature `NativeAdblock` | ligada por padrão. Desligar para comparar: `--disable-features=NativeAdblock` |

O bloqueador **nunca baixa nada**: as listas mudam só com uma atualização do app.

## Listas e licenças

Ficam em [`chromium/adblock/lists/`](../chromium/adblock/lists/); o `fetch.sh` copia para a árvore do Chromium.

| Lista | Origem | Licença |
|---|---|---|
| EasyList | easylist.to | GPLv3 ou CC BY-SA 3.0, à escolha |
| EasyPrivacy | easylist.to | GPLv3 ou CC BY-SA 3.0, à escolha |
| uBlock filters | github.com/uBlockOrigin/uAssets | GPLv3 |
| uBlock filters – Privacy | github.com/uBlockOrigin/uAssets | GPLv3 |

O app distribui uma versão convertida das listas. Para cumprir GPL/CC BY-SA: dar crédito às listas (tela Sobre ou Configurações › Bloqueador), manter o texto original das listas disponível (já está no repositório) e não colocar restrição extra sobre o arquivo de regras.

Das ~111 mil regras de URL das quatro listas, ~105,8 mil entram. As outras usam sintaxe só do uBlock (`$redirect`, `$removeparam`, `$replace`, `3p`, `$important`…) e o conversor descarta. Regras cosméticas (`##`) ficam de fora por enquanto.

## Como atualizar as listas

```sh
chromium/adblock/update-lists.sh      # baixa as 4 listas (à mão, antes do release)
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

## O que falta para fechar a #41

- **Anúncio dentro do vídeo do YouTube e da Twitch.** Eles vêm do mesmo domínio do vídeo (o player do YouTube recebe os anúncios no JSON de `youtubei/v1/player`; a Twitch os costura no stream HLS). Bloqueio por URL não alcança: precisa de reescrita de resposta / scriptlets, como o uBlock (`json-prune`, `$replace`) ou o `adblock-rust`. É o item mais caro e o que decide entre continuar no (1) ou ir para o (2).
- **Filtro cosmético** (esconder elementos e avisos de cookies). O Chromium 156 já tem um índice de regras CSS no `subresource_filter` e o Blink já consulta, mas indexar as listas como estão dispara um `DCHECK` de ordem das regras. Avaliar se vale ordenar as regras no build e ligar.
- **Níveis Padrão e Forte.** Hoje há um nível só, com as quatro listas. Forte pode virar "+ bloqueio de terceiros mais agressivo + cosmético".
- **Configurações › Bloqueador** (`prototipos/janela.html`): liga/desliga, nível, sites liberados. Para sites liberados dá para usar o content setting `ADS` do Chromium.
- **Medir com as 20 abas** (`tools/measure.py` no build oficial) e comparar com antes.
- Na primeira abertura de um perfil, as páginas abertas nos ~2 s antes de a lista ser indexada não são filtradas.
