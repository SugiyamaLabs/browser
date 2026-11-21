# Sessão: a leitura dos valores

`session` e `renew` leem o valor de cada item num arquivo só: `chrome/browser/agens/bridge/session_read.cc`, na árvore do Chromium. A interface e as regras (thread, quando chamar `done`, quem é dono do quê) estão no comentário de `session_read.h`. Todo o resto fica em `session_ops.cc`: validar o pedido, a folha de aprovação, "Permitir sempre", acordar o ato, abrir e fechar a aba escondida, o teto de tempo, a resposta, `needs_login` e `session.lost`. As regras do lado do cliente estão em [protocolo.md](protocolo.md).

## Como lê

As duas funções rodam no thread de UI e chamam `done` uma vez, sempre numa tarefa postada, com um valor por item, na mesma ordem dos itens (`std::nullopt` quando o item não existe).

**`ReadCookies(profile, items, done)`**
- Uma chamada `GetCookieList` por origem, com `CookieOptions::MakeAllInclusive()`: cookie httpOnly entra.
- Para cada item vale o primeiro cookie da lista com aquele nome.

**`ReadFromPage(tab, origin, items, done)`** devolve um `PageReader`
- `localStorage`: quando o quadro principal termina de carregar e a origem ainda é a pedida, `localStorage.getItem` num isolated world. Chave ausente é `nullopt`; texto vazio é valor. Se a página terminou em outra origem, tudo é `nullopt`.
- `header`: uma sessão interna de DevTools na aba (`Network.requestWillBeSent` e `requestWillBeSentExtraInfo`). Vale a primeira requisição da própria página para a origem pedida, sem diferenciar maiúscula de minúscula no nome; o resto da mensagem é jogado fora.
- `done` sai quando todo item tem valor, ou cerca de 3 s depois do carregamento sem a requisição.
- Destruir o reader para tudo e nunca chama `done` depois.

**O perfil não dorme no meio:** o reader e a leitura de cookies seguram um `ScopedProfileKeepAlive` enquanto vivem. Sem ele, fechar a última aba do ato punha o perfil para dormir e o `renew` seguinte respondia `failed`.

**Nunca**: valor em log, pref, arquivo, histograma ou mensagem de erro. Nem outros cookies, chaves ou headers além dos pedidos.

## Compilar

Diga uma vez, no terminal, em qual árvore do Chromium você está trabalhando:

```
export BROWSER_WORK=~/browser-work-2
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

Abre o motor escondido (`--agens-embedded`), sem janela e sem pegar o teclado, e usa o site de teste (`tools/sites-teste`, valores falsos). Confere os quatro valores do `session` (cookie `d`, cookie httpOnly `sid`, `localStorage` `token`, header `Authorization`), o `renew` com os mesmos valores, `session.lost` depois do logout do site e `needs_login` em seguida.

O gate não testa "Permitir sempre" de app assinado (o build de desenvolvimento não tem Team ID) nem o aviso de cookies compartilhados (só a pessoa liga o interruptor).
