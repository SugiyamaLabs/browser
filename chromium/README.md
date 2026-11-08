# chromium

Patches por cima do ungoogled-chromium e scripts de build. O código do Chromium é baixado em `$BROWSER_WORK` (padrão `~/browser-work`), nunca entra no git.

| Arquivo | O que faz |
|---|---|
| `VERSION` | tag fixa do [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos) |
| `setup-mac.sh` | instala o que o build precisa (Homebrew, Python 3.13, Metal, ccache) |
| `fetch.sh` | baixa o Chromium da versão fixa e aplica os patches do ungoogled e os nossos |
| `build.sh` | configura e compila, incremental e com ccache |
| `run.sh` | abre o Chromium compilado numa página, com perfil descartável |
| `args.gn` | nossos args do GN, por cima dos do ungoogled |
| `patches/` | nossos patches (`series` + `.patch`), aplicados por último |

Passo a passo, disco e tempo em [docs/build.md](../docs/build.md).
