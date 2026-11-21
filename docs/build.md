# Build do Chromium no Mac

Chromium partindo do [ungoogled-chromium-macos](https://github.com/ungoogled-software/ungoogled-chromium-macos), na versão fixa de [`chromium/VERSION`](../chromium/VERSION). O código fica em `$BROWSER_WORK` (padrão `~/browser-work`), fora do repo.

## Passo a passo

```sh
./chromium/setup-mac.sh     # uma vez: Homebrew, Python 3.13 (venv), Metal toolchain, ccache
./chromium/fetch.sh         # baixa o Chromium da versão fixa e aplica os patches (ungoogled + chromium/patches)
./chromium/build.sh         # build oficial (release e medição), em out/Default; incremental
./chromium/build.sh dev     # build dev (dia a dia), em out/Dev: sem LTO e sem PGO
./chromium/run.sh [dev]     # abre o Chromium compilado em https://example.com, com perfil e Keychain descartáveis
```

- `fetch.sh` sempre começa de um código novo (os patches não podem ser aplicados duas vezes). Rode de novo só ao trocar `VERSION` ou mexer em `chromium/patches/`.
- `build.sh` mantém `out/Default` (e `out/Dev`) entre execuções. Depois de um `fetch.sh`, o ccache evita recompilar o que não mudou.
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

O `Chromium.app` final tem 370 MB. Desde a #40 o app sai como `out/<dir>/AgensBrowser.app` (binário `Contents/MacOS/AgensBrowser`, bundle id `com.sugiyamalabs.agensbrowser`, perfil em `~/Library/Application Support/AgensBrowser`; o nome não é só "Agens" porque esse é o do app Agens, instalado junto).

O build do zero usou 133.308 s de CPU em 52.797 s de relógio, só ~2,5 núcleos em média. Quem segura é o link com ThinLTO e PGO, que é quase todo serial. O ccache teve 0% de acerto no build do zero, como esperado. O ganho dele num segundo `fetch.sh` + `build.sh` **ainda não foi medido**.

## Modo dev (09/11/2026)

`build.sh dev` usa os mesmos códigos e patches, com [`chromium/args.dev.gn`](../chromium/args.dev.gn) por cima: `is_official_build=false`, sem ThinLTO, sem PGO e sem símbolos. Nunca serve para medir memória nem para release.

| Etapa | Tempo | Disco |
|---|---|---|
| `build.sh dev` do zero (56.348 passos) | 8 h 16 min (29.770 s) | 8,9 GB em `out/Dev` |
| `build.sh dev` depois de mudar um `.cc` do `chrome/browser/ui` | **23 s** | — |

O build do zero usou 139.495 s de CPU, ~4,7 núcleos em média. O ganho de verdade do modo dev está no incremental: o link sem LTO leva segundos.

Component build ficou de fora: com o toolchain Rust pronto do ungoogled, as `.dylib` não acham os símbolos do alocador do Rust (`__rustc::__rust_alloc`) e o link falha.

## Como foi verificado

`run.sh` com `--remote-debugging-port` abriu a janela, e a aba carregou `https://example.com/` com o título "Example Domain" (Chromium 156.0.8078.79).

## Armadilhas encontradas

| Sintoma | Causa | O que os scripts fazem |
|---|---|---|
| `ld64.lld: ... libSystem.tbd: malformed file ... unknown target` ao compilar o bindgen | o lld do Chromium 156 não conhece o alvo `arm64e.x1` do SDK do macOS 27 (Xcode 27.2) | fixam o SDK 26.5 dos Command Line Tools (`MAC_SDK` em `env.sh`, `SDKROOT` e `mac_sdk_path`) |
| `gn gen` falha em `update_pgo_profiles.py`: perfil `chrome-mac-arm-...profdata` não existe | o tarball (`retrieve_and_unpack_resource.py -d`) só traz o perfil de PGO do Linux | `fetch.sh` usa `-g` sem `-d`, que clona com o perfil `mac-arm` |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Xcode novo não traz o Metal toolchain | `setup-mac.sh` roda `xcodebuild -downloadComponent MetalToolchain` |
| a página não carrega e o macOS pede a senha do Keychain para "Chromium Safe Storage" | cada build sem assinatura é um app novo para o Keychain, e a rede espera a chave dos cookies | `run.sh` e `tools/measure.py` passam `--use-mock-keychain` |

## Assinatura e notarização (fase 6)

```sh
export AGENS_SIGN_IDENTITY="Developer ID Application: <nome> (<Team ID>)" AGENS_NOTARY_PROFILE=agens-notary
export AGENS_APP=~/browser-work/ungoogled-chromium-macos/build/src/out/Default/AgensBrowser.app
./chromium/sign.sh       # assina de dentro para fora
./chromium/notarize.sh   # envia, grampeia e confere
```

- `sign.sh` segue a ordem e as opções do próprio Chromium (`chrome/installer/mac/signing/parts.py`, as mesmas do `sign_and_package_app.sh` do ungoogled): bibliotecas, ferramentas, helpers, framework e, por último, o app. Tudo com hardened runtime. Os entitlements são os da árvore (`chrome/app/*.plist`): Renderer e GPU com `allow-jit`, o app com câmera, microfone, localização, Bluetooth, USB, impressão e fotos. Cada helper assina com o próprio bundle id.
- `AGENS_SIGN_IDENTITY=-` assina ad hoc, só para testar o script: sem Team ID, sem carimbo de tempo, não notariza.
- `notarize.sh` serve para qualquer `.app` assinado com Developer ID, inclusive o `Agens.app`. Ele manda um zip; o ticket fica grampeado no `.app`.
- Testado (11/11/2026): `sign.sh` ad hoc num clone do `out/Dev/AgensBrowser.app` passa em `codesign --verify --deep --strict`. Com certificado de verdade e notarização, ainda não.

### O que só você faz, uma vez

1. Em developer.apple.com › Certificates, crie um **Developer ID Application** (o pedido CSR sai do Acesso às Chaves) e abra o `.cer` para instalar no Keychain de login.
2. Confira com `security find-identity -v -p codesigning`. O nome entre aspas é o `AGENS_SIGN_IDENTITY`; o código entre parênteses é o Team ID.
3. Em account.apple.com › Senhas de app, crie uma senha de app.
4. Rode `xcrun notarytool store-credentials agens-notary --apple-id <seu e-mail> --team-id <Team ID>`. Ele pede a senha de app e guarda no Keychain. Não use `--password` na linha de comando: fica no histórico.
5. Exporte `AGENS_SIGN_IDENTITY` e `AGENS_NOTARY_PROFILE` (só os nomes; os segredos ficam no Keychain) e rode os dois scripts.

### O motor dentro do Agens

- Assine o motor com `sign.sh` **antes** de copiar para `Agens.app/Contents/Helpers/AgensBrowser.app`. Copie com `ditto`, que mantém a assinatura.
- Depois assine o `Agens.app` por fora, **sem `--deep`**: o `--deep` reassina o motor e tira os entitlements de cada helper. Testado com ad hoc: assinar o app de fora não muda o CDHash do motor, e `codesign --verify --deep --strict` passa no conjunto.
- Mesmo certificado nos dois. O motor só reconhece como "nosso" um cliente assinado pela mesma equipe (o app que abriu o motor entra pelo pid). O motor lê o Team ID da própria assinatura: build sem assinatura (ou ad hoc) não tem equipe, e nele nenhum cliente passa como "nosso". Isso ainda não foi testado com certificado de verdade.
- O `Agens.app` também precisa de hardened runtime e carimbo de tempo, ou a notarização recusa.
- Notarize o `Agens.app` inteiro: uma submissão cobre o motor de dentro, e o ticket vai no `Agens.app`. O AgensBrowser sozinho tem a submissão dele.
- Entitlements no Agens por causa do motor: nenhum para abrir o motor, que roda com a própria assinatura (nada de `allow-jit` nem `disable-library-validation` no Agens). Duas condições:
  - o Agens não pode usar App Sandbox: o filho herda a sandbox, e o Chromium não roda nela;
  - câmera, microfone e localização são pedidos em nome do app que abriu o motor. Se as abas forem usar isso, o Agens precisa de `com.apple.security.device.camera`, `com.apple.security.device.audio-input` (e `personal-information.location`) e das frases `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` e `NSLocationUsageDescription` no `Info.plist` dele. Sem isso, a página recebe "negado". Ainda não testado.

## Release e atualizações (Sparkle)

```sh
export AGENS_SIGN_IDENTITY="Developer ID Application: Willian Sugiyama (GHSUN7X4H6)" AGENS_NOTARY_PROFILE=agens-notary
BROWSER_WORK=~/browser-work-2 ./chromium/release.sh ~/Releases/AgensBrowser   # depois de build.sh official
```

`release.sh` copia o build oficial, põe o Sparkle (`chromium/sparkle.sh embed`), assina, notariza, gera o `.dmg` (assinado, notarizado, grampeado) e o `appcast.xml` (`chromium/sparkle.sh appcast`). No fim imprime o comando que publica; nada é publicado sozinho.

- **Sparkle 2.9.6**, de `~/Library/Caches/Agens-dev/sparkle-2.9.6` (`SPARKLE_DIR` troca). O `Sparkle.framework` vai em `Contents/Frameworks`, sem as XPC services: só servem para app com sandbox (docs do Sparkle, "Sandboxing"), e o nosso não tem. O app não linka o Sparkle: a casca carrega o framework em tempo de execução ([casca](casca.md#atualizações)).
- **Info.plist** (posto pelo `sparkle.sh`, antes de assinar): `SUFeedURL` = `https://github.com/SugiyamaLabs/browser/releases/latest/download/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks` e `SUAutomaticallyUpdate` ligados, `SUScheduledCheckInterval` 86400 (um dia).
- **Assinatura**: `sign.sh` assina o `Autoupdate`, o `Updater.app` e o framework do Sparkle (hardened runtime, carimbo de tempo, nossa Developer ID) depois do framework do Chromium e antes do app.
- **Chave EdDSA**: a privada fica no Keychain de login, conta `agensbrowser`; o `generate_appcast` lê de lá (o macOS pode pedir para liberar o acesso na primeira vez). Se a chave não bater com o `SUPublicEDKey`, o `generate_appcast` só avisa e deixa o item sem assinatura; o `sparkle.sh` para com erro nesse caso. `AGENS_ED_KEY_FILE` usa um arquivo de chave no lugar do Keychain (para testar com chave descartável).
- **Versão**: `CFBundleShortVersionString` continua a do Chromium (`156.0.8078.79`). O `CFBundleVersion`, que o Sparkle compara, é nosso: a hora UTC do release como `aaaammdd.HHMM` (ex. `20261119.1935`), sempre maior que o anterior, também ao trocar de Chromium. `AGENS_BUILD` fixa outro valor. O release se chama `<versão>-<build>`: tag `v156.0.8078.79-20261119.1935`, arquivo `AgensBrowser-156.0.8078.79-20261119.1935.dmg`. Dois releases da mesma versão do Chromium aparecem no Sparkle como "156.0.8078.79 (build)".
- **Appcast**: um item só, o mais novo, com o download em `https://github.com/SugiyamaLabs/browser/releases/download/v<release>/AgensBrowser-<release>.dmg`. O feed aponta para o `appcast.xml` do release marcado como *latest*, então cada release leva o seu.
- **Publicar** (o comando que o `release.sh` imprime; conta do GitHub da SugiyamaLabs por comando):

```sh
GH_TOKEN=$(gh auth token --user WillianSugiyama) gh release create v<release> <pasta>/AgensBrowser-<release>.dmg <pasta>/appcast.xml \
  --repo SugiyamaLabs/browser --title "AgensBrowser <release>" --notes ""
```

- Testado (19/11/2026): `sparkle.sh embed` + `sign.sh` com a Developer ID num clone do `out/Default` passam em `codesign --verify --deep --strict`; o framework assinado carrega e cria o `SPUStandardUpdaterController`; `sparkle.sh appcast` num `.dmg` local com chave descartável gera XML válido com `sparkle:edSignature` que o `sign_update --verify` confere, e para com erro quando a chave não bate. Não testado: notarização com o Sparkle dentro, a atualização de ponta a ponta (baixar, instalar, reabrir) e o `generate_appcast` com a chave do Keychain.

## Widevine (conteúdo protegido)

O Widevine **não vai no app** (licença do Google). O build já sai com `enable_widevine=true` (vem do `flags.gn` do ungoogled; nenhum arg nosso a mais): isso compila o suporte a EME e o instalador do componente, sem o CDM. O navegador baixa o CDM do Google na primeira abertura ([sem telemetria](sem-telemetria.md#widevine-conteúdo-protegido)).

O ungoogled troca os domínios do Google no código (`domain_substitution.py`), o que deixa o component updater sem servidor. O `chromium/webstore.py` (roda no `fetch.sh`, depois da troca) devolve só o endereço `https://update.googleapis.com/service/update2/json` em `component_updater_url_constants.cc` (o reserva HTTP também vira HTTPS). Nosso código na árvore:

| Arquivo | O que muda |
|---|---|
| `components/component_updater/component_updater_service.cc` | só o Widevine (`oimompecagnajdejgnnjijobebaeigek`) vai ao servidor, na checagem periódica e na pedida na hora; os outros componentes ficam registrados e nunca são perguntados |
| `components/component_updater/configurator_impl.cc` | sem pings (relatórios de instalação) |
| `components/update_client/update_checker.cc` | o ungoogled corta toda checagem aqui (`block-requests.patch`); passa só a que tem exatamente o Widevine |
| `chrome/browser/component_updater/chrome_component_updater_configurator.cc` | sem o downloader de segundo plano do macOS (`NSURLSession`): o download passa pela rede do Chromium e aparece na NetLog |
| `chrome/browser/component_updater/registration.cc` | registra o Widevine só com `agens.widevine.enabled`; desligado, apaga `WidevineCdm` |
| `chrome/browser/component_updater/widevine_cdm_component_installer.*` | id exposto e `UpdateWidevineCdmComponentNow` (amigo do `OnDemandUpdater`) para baixar ao ligar |
| `chrome/browser/browser_process_impl.cc` | a preferência `agens.widevine.enabled` (Local State, ligada) |
| `chrome/browser/agens/embed/native_shell.cc`, `agens_embed.h` | `agens_widevine_status`, `agens_widevine_set_enabled`, `agens_widevine_remove` para a casca |
| `chrome/browser/agens/ui/chrome_mac.mm` | Configurações › Privacidade › Conteúdo protegido |

### VMP (Netflix em HD): assinatura da Castlabs

Sem VMP, o Widevine funciona, mas a Netflix e outros limitam a qualidade ou recusam tocar. Tentamos a assinatura VMP pelo serviço EVS da Castlabs (conta gratuita, 21/11/2026): o `sign-pkg` só reconhece apps Electron, e assinar o binário do `AgensBrowser Framework` direto (`castlabs_evs.vmp sign`) volta **"Binary signature denied"**. O EVS só assina as builds Electron da própria Castlabs. Para um fork do Chromium, a assinatura VMP depende de licença direta com o Google (Widevine), que não temos. O `release.sh` não tem passo de VMP.

## Rede durante o build

O `fetch.sh` baixa o código de `chromium.googlesource.com` e o perfil de PGO do armazenamento do Google, e o `build.sh` baixa crates do crates.io para o bindgen. Isso acontece só no build. O navegador compilado não fala com o Google (é a base do ungoogled).

## Limpar

- Só o build: `rm -rf ~/browser-work/ungoogled-chromium-macos/build/src/out` (próximo `build.sh` compila do zero).
- Tudo: `rm -rf ~/browser-work` (próximo passo é `setup-mac.sh` de novo).

## Ainda não feito

- Windows: issue #3.
- CI no runner self-hosted: issue #2.
- Assinatura e notarização de verdade: falta o certificado (veja "O que só você faz"). O app local roda sem assinatura.
- Atualização de ponta a ponta pelo Sparkle: falta o primeiro release publicado.
