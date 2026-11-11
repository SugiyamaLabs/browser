# Sessão: a leitura dos valores

O que falta em `session` e `renew` é uma coisa só: ler o valor de cada item. Todo o resto está feito em `session_ops.cc`: validar o pedido, a folha de aprovação, "Permitir sempre", acordar o ato, abrir e fechar a aba escondida, o teto de tempo, a resposta, `needs_login` e `session.lost`. As regras do lado do cliente estão em [protocolo.md](protocolo.md).

## O que escrever

Um arquivo: `chrome/browser/agens/bridge/session_read.cc`, na árvore do Chromium (`$BROWSER_WORK/ungoogled-chromium-macos/build/src`). Hoje é um stub que responde "não existe" para tudo. A interface está em `session_read.h`, e o comentário de lá é o briefing completo (thread, quando chamar `done`, quem é dono do quê, as APIs do Chromium). Não mude o `.h` sem ajustar `session_ops.cc`.

Duas funções. As duas rodam no thread de UI e chamam `done` uma vez, sempre numa tarefa postada, com um valor por item, na mesma ordem dos itens (`std::nullopt` quando o item não existe).

**`ReadCookies(profile, items, done)`**
- Entrada: o perfil do ato, já carregado, e itens só do tipo `cookie` (podem ser de várias origens).
- Saída: para cada item, o valor do cookie `name` que o ato mandaria para `origin` (inclusive httpOnly).
- Caminho: o `CookieManager` da storage partition do ato, `GetCookieList(...)` com `CookieOptions::MakeAllInclusive()`. A `HasCookie()` de `session_ops.cc` faz a mesma chamada, só olhando o nome.

**`ReadFromPage(tab, origin, items, done)`** devolve um `PageReader`
- Entrada: uma aba escondida do ato (um `WebContents` sem janela), a origem e itens só `localStorage` ou `header` dessa origem. É chamada logo antes de a aba carregar a raiz da origem, para a sessão de DevTools ver a primeira requisição.
- Saída: `localStorage` é o valor da chave `name` na origem, depois que a página carregou. `header` é o valor do header `name` (sem diferenciar maiúscula de minúscula) na primeira requisição que a própria página faz para a origem.
- Caminho: `localStorage.getItem` num isolated world, ou `DOMStorage` do DevTools. Header: sessão interna de DevTools (`DevToolsAgentHost::GetOrCreateFor(tab)->AttachClient`), `Network.enable`, `Network.requestWillBeSent` e `Network.requestWillBeSentExtraInfo`.
- Quem cuida da vida: `session_ops.cc` é dono da aba e do reader e sempre destrói o reader antes da aba (quando `done` roda, no teto de 20 s, se o cliente desconectar ou o perfil fechar). Destruir o reader tem de parar tudo e nunca chamar `done` depois.

**Nunca**: valor em log, pref, arquivo, histograma ou mensagem de erro. Nem outros cookies, chaves ou headers além dos pedidos: filtre cedo e jogue fora o resto.

## Compilar

Diga uma vez, no terminal, em qual árvore do Chromium você está trabalhando:

```
export BROWSER_WORK=~/browser-work-5
```

```
cd ~/Documents/AgensBrowser
CCACHE_DIR=~/browser-work/ccache bash chromium/build.sh dev
```

A lógica pura (folha, chave de "Permitir sempre", origens) tem checagem própria:

```
cd $BROWSER_WORK/ungoogled-chromium-macos/build/src
ninja -C out/Dev agens_bridge_selfcheck && out/Dev/agens_bridge_selfcheck
```

## Testar

```
tools/gates/sessao.sh
```

Abre o motor escondido (`--agens-embedded`), sem janela e sem pegar o teclado, e usa o site de teste (`tools/sites-teste`, valores falsos). As linhas `[waits for session_read.cc]` precisam dos valores de verdade: com o stub elas dão FAIL, e o gate lista essas falhas no fim como esperadas, sem reprovar. Depois de escrever o arquivo, rode com `SESSAO_STUB=0`: aí toda linha tem de dar PASS. São elas: os quatro valores do `session` (cookie `d`, cookie httpOnly `sid`, `localStorage` `token`, header `Authorization`), o `renew` com os mesmos valores, `session.lost` depois do logout do site e `needs_login` no `renew` seguinte.

O gate não testa "Permitir sempre" de app assinado (o build de desenvolvimento não tem Team ID) nem o aviso de cookies compartilhados (só a pessoa liga o interruptor).
