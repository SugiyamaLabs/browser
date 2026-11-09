# Build do Chromium no Mac

Chromium partindo do [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos), na versão fixa de [`chromium/VERSION`](../chromium/VERSION). O código fica em `$BROWSER_WORK` (padrão `~/browser-work`), fora do repo.

## Passo a passo

```sh
./chromium/setup-mac.sh     # uma vez: Homebrew, Python 3.13 (venv), Metal toolchain, ccache
./chromium/fetch.sh         # baixa o Chromium da versão fixa e aplica os patches (ungoogled + chromium/patches)
./chromium/build.sh         # configura e compila; incremental
./chromium/run.sh           # abre o Chromium compilado em https://example.com, com perfil descartável
```

- `fetch.sh` sempre começa de um código novo (os patches não podem ser aplicados duas vezes). Rode de novo só ao trocar `VERSION` ou mexer em `chromium/patches/`.
- `build.sh` mantém `out/Default` entre execuções. Depois de um `fetch.sh`, o ccache evita recompilar o que não mudou.
- Os flags são os oficiais do ungoogled (`is_official_build`, ThinLTO, PGO), mais os nossos em [`chromium/args.gn`](../chromium/args.gn). O binário é o mesmo que vai para a pessoa, e é ele que vale para medir memória.

## Medido de verdade (08/11/2026)

Máquina: MacBook Pro M5 Pro (18 núcleos, 64 GB), macOS 27.0.1, Xcode 27.2, rede doméstica. Versão: ungoogled-chromium `156.0.8078.79-1.1`.

| Etapa | Tempo | Disco |
|---|---|---|
| `setup-mac.sh` | 1 min 5 s | ~1 GB (Metal toolchain 839 MB + Homebrew) |
| `fetch.sh` (clone + patches + toolchains) | 9 min 6 s | 19 GB de código |
| `build.sh` do zero (57.403 passos) | **14 h 40 min** (52.797 s) | 18 GB em `out/Default` + 6 GB de ccache |
| `build.sh` sem mudança | 25 s | — |
| **Total em `~/browser-work`** | | **46 GB** |

O `Chromium.app` final tem 370 MB.

O build do zero usou 133.308 s de CPU em 52.797 s de relógio, só ~2,5 núcleos em média. Quem segura é o link com ThinLTO e PGO, que é quase todo serial. O ccache teve 0% de acerto no build do zero, como esperado. O ganho dele num segundo `fetch.sh` + `build.sh` **ainda não foi medido**.

## Como foi verificado

`run.sh` com `--remote-debugging-port` abriu a janela, e a aba carregou `https://example.com/` com o título "Example Domain" (Chromium 156.0.8078.79).

## Armadilhas encontradas

| Sintoma | Causa | O que os scripts fazem |
|---|---|---|
| `ld64.lld: ... libSystem.tbd: malformed file ... unknown target` ao compilar o bindgen | o lld do Chromium 156 não conhece o alvo `arm64e.x1` do SDK do macOS 27 (Xcode 27.2) | fixam o SDK 26.5 dos Command Line Tools (`MAC_SDK` em `env.sh`, `SDKROOT` e `mac_sdk_path`) |
| `gn gen` falha em `update_pgo_profiles.py`: perfil `chrome-mac-arm-...profdata` não existe | o tarball (`retrieve_and_unpack_resource.py -d`) só traz o perfil de PGO do Linux | `fetch.sh` usa `-g` sem `-d`, que clona com o perfil `mac-arm` |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode novo não traz o Metal toolchain | `setup-mac.sh` roda `xcodebuild -downloadComponent MetalToolchain` |

## Rede durante o build

O `fetch.sh` baixa o código de `chromium.googlesource.com` e o perfil de PGO do armazenamento do Google, e o `build.sh` baixa crates do crates.io para o bindgen. Isso acontece só no build. O navegador compilado não fala com o Google (é a base do ungoogled).

## Limpar

- Só o build: `rm -rf ~/browser-work/ungoogled-chromium-macos/build/src/out` (próximo `build.sh` compila do zero).
- Tudo: `rm -rf ~/browser-work` (próximo passo é `setup-mac.sh` de novo).

## Ainda não feito

- Windows: issue #3.
- CI no runner self-hosted: issue #2.
- Assinatura e notarização: M7. O app local roda sem assinatura.
