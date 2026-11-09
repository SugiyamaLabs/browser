# A casca (interface) do navegador

Decisão de 09/11 (issue #44): a interface é **nativa**. AppKit hoje e SwiftUI depois no Mac, WinUI no Windows. Não é HTML. O PoC está em `docs/poc/c1.md`.

## As três camadas

```
interface (AppKit/Swift)      chrome/browser/agens/ui/       a lateral do navegador; amanhã, o Agens
        │  só enxerga ↓
API em C (embed/)             chrome/browser/agens/embed/agens_embed.h
        │
cola com o Chromium (C++)     chrome/browser/agens/embed/native_shell_mac.mm
        │
janela do Chromium            WebUIBrowserWindow (Webium), sem a página HTML
```

- **Interface:** `ui/sidebar_mac.mm` só importa AppKit e `agens_embed.h`. Não usa nenhum tipo do Chromium, então pode ir para o `BrowserKit` (Swift) sem mudar nada.
- **API (`agens_embed.h`):** C puro, para o Swift importar direto. Tem a lista de abas (título, URL, ativa, carregando) com observador, e as ações: nova aba, ativar, fechar, navegar (endereço ou busca), voltar, avançar e recarregar. A interface entra pelos ganchos `agens_ui_create_sidebar`, `agens_ui_focus_address` e `agens_ui_destroy_sidebar`.
- **Cola:** implementa a API sobre o `TabStripModel` e põe a lateral e a aba ativa dentro da janela.
- **Janela:** a da Webium. O Chromium já reconhece essa "janela sem Views" em uns 20 pontos do núcleo, e uma cópia nossa obrigaria a mexer em todos eles. O nosso patch nela tem umas 20 linhas, atrás de `agens::IsNativeShellEnabled()`.

## Flags

- No nosso build, `Webium` e `AgensNativeShell` vêm **ligadas por padrão**.
- `--disable-features=Webium` volta para a janela Views do Chromium. Serve para comparar e para medir.
- `--disable-features=AgensNativeShell` mostra a Webium em HTML do Chromium (só referência).

Patch: `chromium/patches/sugiyamalabs/native-shell.patch`.

## Por que a lateral fica fora da área de conteúdo

No Mac, a área de conteúdo de uma janela do Chromium é *layer-hosting* e não desenha NSView filha. Por isso a lateral é irmã dela, no frame da janela, abaixo dos semáforos.

## Próximos passos

1. Testar o embed fora do processo: um app Swift de exemplo mostrando uma aba do navegador via `remote_cocoa`. É o caminho para o Agens.
2. Atualizar a ADR 0014 do Agens com esta casca e o caminho do embed.
3. Portar o protótipo para a lateral: favicon, estado de carregando, atos, nova aba e temas.
