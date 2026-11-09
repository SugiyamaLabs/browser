# A casca (interface) do navegador

![A casca hoje](casca.png)

| Nova aba (escuro) | Modo claro |
|---|---|
| ![](casca-nova-aba.png) | ![](casca-claro.png) |

Decisão de 09/11 (issue #44): a interface é **nativa**. AppKit hoje e SwiftUI depois no Mac, WinUI no Windows. Não é HTML. O PoC está em `docs/poc/c1.md`.

## As três camadas

```
interface (AppKit/Swift)      chrome/browser/agens/ui/       barra, abas e cartão da página; amanhã, o Agens
        │  só enxerga ↓
API em C (embed/)             chrome/browser/agens/embed/agens_embed.h
        │
cola com o Chromium (C++)     chrome/browser/agens/embed/native_shell_mac.mm
        │
janela do Chromium            WebUIBrowserWindow (Webium), sem a página HTML
```

- **Interface:** `ui/chrome_mac.mm` só importa AppKit e `agens_embed.h`. Segue o protótipo `prototipos/janela.html` com abas na lateral e o Grafite escuro: barra de 52 pt (voltar, avançar, recarregar/parar, endereço num poço com cadeado e sugestões), abas com favicon, carregando e dormindo, o ato atual no topo da coluna e a fileira de atos no pé, a página num cartão de 12 pt e a nossa nova aba (logo, saudação e busca). Claro e escuro seguem o sistema; os tokens ficam em `Token` no topo do arquivo. Não usa nenhum tipo do Chromium, então pode ir para o `BrowserKit` (Swift) sem mudar nada.
- **API (`agens_embed.h`):** C puro, para o Swift importar direto. Tem:
  - abas, com observador (título, URL, favicon, ativa, carregando, dormindo, voltar/avançar possíveis) e as ações nova aba, ativar, fechar, navegar (endereço ou busca), voltar, avançar, recarregar e parar;
  - sugestões do endereço, só de fontes locais (histórico, favoritos, atalhos e a busca do que foi digitado). As sugestões remotas de busca seguem desligadas, como o ungoogled deixa;
  - atos (um perfil do Chromium cada): lista com observador, trocar e criar. Trocar abre a janela do outro ato no lugar desta;
  - os ganchos da interface: `agens_ui_create_chrome`, `agens_ui_layout` (diz onde fica a página), `agens_ui_colors` (as cores que o motor pinta atrás), `agens_ui_focus_address` e `agens_ui_destroy_chrome`; e `agens_window_relayout` para a interface pedir nova pintura ao trocar claro/escuro.
- **Cola:** implementa a API sobre o `TabStripModel`, põe a interface por cima da janela e a aba ativa onde a interface mandar.
- **Janela:** a da Webium. O Chromium já reconhece essa "janela sem Views" em uns 20 pontos do núcleo, e uma cópia nossa obrigaria a mexer em todos eles. O nosso patch nela tem umas 20 linhas, atrás de `agens::IsNativeShellEnabled()`.

## Flags

- No nosso build, `Webium` e `AgensNativeShell` vêm **ligadas por padrão**.
- `--disable-features=Webium` volta para a janela Views do Chromium. Serve para comparar e para medir.
- `--disable-features=AgensNativeShell` mostra a Webium em HTML do Chromium (só referência).

Patch: `chromium/patches/sugiyamalabs/native-shell.patch`.

## Por que a interface fica fora da área de conteúdo

No Mac, a área de conteúdo de uma janela do Chromium é *layer-hosting* e não desenha NSView filha. Por isso a interface é uma NSView irmã dela, do tamanho da janela, abaixo dos semáforos. Onde fica a página, ela deixa o clique passar (`hitTest:` devolve `nil`).

## Próximos passos

1. Testar o embed fora do processo: um app Swift de exemplo mostrando uma aba do navegador via `remote_cocoa`. É o caminho para o Agens.
2. Atualizar a ADR 0014 do Agens com esta casca e o caminho do embed.
3. Continuar o protótipo: recolher a lateral, temas (Vidro, Seu), escolher claro/escuro/sistema nas configurações, atalhos na nova aba, favoritos, menu, configurar e apagar ato, e cookies compartilhados entre atos (desligado).
4. A nova aba de verdade ainda carrega a do Chromium por baixo da nossa (um renderer a mais). Trocar por uma página vazia é um ganho de memória fácil.
