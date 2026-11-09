# browser (nome provisório)

O navegador da SugiyamaLabs: Chromium, partindo dos patches do [ungoogled-chromium](https://github.com/ungoogled-software/ungoogled-chromium), com interface nativa (SwiftUI/AppKit no Mac, WinUI no Windows) e foco em memória. Funciona sozinho e o Agens usa por dentro, pelo `BrowserKit`.

A decisão que manda neste repo é a [ADR 0014 do Agens](https://github.com/SugiyamaLabs/agens/blob/main/docs/decisoes/0014-navegador-produto-proprio.md).

## Onde ler

| Doc | O que tem |
|---|---|
| [docs/plano.md](docs/plano.md) | Marcos M0–M7, trilhas e as issues de cada marco |
| [docs/visual.md](docs/visual.md) | Princípios visuais, abas em cima ou na lateral, atos |
| [docs/performance.md](docs/performance.md) | A meta (no máximo 50% da RAM do Brave), as alavancas e o método de medição |
| [docs/medicoes.md](docs/medicoes.md) | A tabela de medições |

## Pastas (nascem no M0)

```
chromium/        patches por cima do ungoogled-chromium e scripts de build (o Chromium é baixado, nunca versionado)
core/            a camada nossa (Rust onde fizer sentido): atos, abas, memória, sessão, atualização
embed/           API em C que expõe o Chromium para um app nativo
kit/apple/       BrowserKit para Swift (xcframework)
kit/windows/     BrowserKit para WinUI (DLL)
apps/mac/        o navegador para Mac (SwiftUI), em cima do BrowserKit
apps/windows/    o navegador para Windows (WinUI), em cima do BrowserKit
docs/            decisões, protocolo da sessão e medições
```

## Não fazer

- CEF, Electron ou WebView do sistema.
- Telemetria, sync do Google ou qualquer serviço que mande dado para fora.
- Gastar dinheiro (certificado, máquina, serviço) sem o OK do Willian.
