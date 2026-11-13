# Extensões e a Chrome Web Store

Como no Brave: a pessoa instala extensões direto da Chrome Web Store, e elas se atualizam sozinhas.

## O que fala com o Google

- **Instalar:** baixa a extensão dos servidores da loja (`clients2.google.com`, que redireciona para `*.googleusercontent.com`). Só quando a pessoa clica em instalar.
- **Atualizar:** de tempos em tempos (a cada poucas horas, com variação), o navegador pergunta à loja se há versão nova das extensões instaladas. Vem **ligado**. Desliga em Configurações › Extensões › "Atualizar extensões sozinhas" (pref `agens.extensions.auto_update`).

É a segunda exceção ao "zero conexões com o navegador parado", junto com as listas do bloqueador. Sem extensão da loja instalada, nada disso acontece.

## Por ato

Cada ato tem as próprias extensões. Ao instalar, a pessoa escolhe: só no ato atual (padrão) ou em vários. "Em vários" acorda os atos que dormem e instala em cada um na hora, sem baixar de novo: uma cópia do que acabou de entrar (da loja ou do `.crx`), ou a mesma pasta. Quem autoriza é a pessoa, na folha; nenhum agente espalha extensão por atos. O que cada ato dormindo tem fica anotado no `Local State` (junto dos extras do ato, `agens.atos`), para a lista e para "Remover de todos os atos".

## De um arquivo

Configurações › Extensões › **Adicionar de um arquivo** (ou `extension.install` no Agens) aceita um `.crx` ou uma pasta descompactada, com a mesma folha da loja. O `.crx` instala como no `chrome://extensions` (fora da loja, permitido porque a pessoa escolheu o arquivo) e não se atualiza. A pasta fica ligada ao lugar onde está e liga o modo de desenvolvedor do ato (sem ele o Chromium desliga extensão descompactada). `.crx` aberto, arrastado ou baixado de um site continua recusado. Instalar da loja pelo id, sem abrir a página, fica para depois.

## Como está feito

O ungoogled bloqueia a loja em três lugares; desfazemos os três:

| Onde | O que o ungoogled faz | O que fazemos |
|---|---|---|
| Troca de domínios (`domain_substitution.py`) | troca `google.com` no código todo, então a página da loja não acha a API de instalação e o endereço de atualização não existe | `chromium/webstore.py`, que roda depois da troca, devolve só os endereços da loja (`extension_urls.cc`) e a liberação da API para a página dela (`_api_features.json`) |
| `disable-webstore-urls.patch` | tira a busca de atualizações e o endereço padrão de atualização | `webstore.patch` devolve os dois e o processo próprio da loja |
| Inox `0005-disable-default-extensions.patch` | esvazia o download e a instalação do instalador da loja | `webstore.patch` devolve os dois |

O patch não tem nenhum domínio do Google (a troca de domínios os estragaria); os endereços ficam só no script.

Na página da loja, o botão "Usar no Chrome" vira "Instalar no AgensBrowser", e os avisos "Mudar para o Chrome?" somem. É texto da página do Google, trocado depois que ela carrega (`AgensPageError::DOMContentLoaded`); se a loja mudar as palavras, o botão volta a dizer o do Google, sem quebrar nada.

Não ligamos a verificação de conteúdo da loja (`chrome_content_verifier_delegate.cc`): ela baixa hashes do Google e desativa a extensão se não conseguir.
