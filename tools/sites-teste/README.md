# Sites de teste

Servidor local para as fases 2 e 3 do protocolo (`docs/protocolo.md`). Só escuta em `127.0.0.1`. Todos os valores são falsos.

```
tools/sites-teste/serve.py [PORTA]   # padrão 8765
```

| Página | Para quê |
|---|---|
| `/login` | Formulário (usuário e senha, qualquer valor serve). O POST põe o cookie `sid` (httpOnly) e o cookie `d` (legível pela página) e vai para `/app/`. Use com `login --done cookie:http://127.0.0.1:8765:d` ou `--done url_prefix:http://127.0.0.1:8765/app/`. |
| `/app/` | Mostra "logged in" só com o cookie `sid`; senão volta para `/login`. Grava `localStorage` `token` e a cada 3 s faz `fetch("/api/ping")` com `Authorization: Bearer test-bearer-123` (para testar `session` com `cookie`, `localStorage` e `header`). |
| `/api/ping` | Responde `{"ok": true, "bearer": true}` quando recebe o header acima. |
| `/logout` | Apaga os cookies e volta para `/login` (para testar `session.lost` e `needs_login`). |
| `/form` | Para o controle: campo de texto, campo de senha, checkbox, select, botão "Show" que escreve o digitado em `#out`, e link para `/other`. O `type` no campo de senha deve ser recusado. |
| `/other` | Destino do link, para testar `tab.navigate` e o clique em link. |
| `/post` | Um formulário POST ("Send") para `/posted`, que responde "Posted": `tab.reload` ali deve ser recusado. |
| `/agent` | Para o resto do controle: "Hover me" escreve "Hovered: yes" ao passar o mouse, "Ask" abre um `confirm()` e escreve "Answer: true/false", a página é alta e um texto fixo mostra "Scrolled: N". Ao abrir, faz `console.log("agens-console-test")`, lança um erro não tratado ("agens-uncaught-test"), busca `/missing-404#frag-secret` (404; o fragmento não pode aparecer em `page.network`) e `/api/ping` (200). |
| `/whoami?tag=X` | Anota se esse pedido veio com o cookie de login (`sid`). Serve para ver se um ato está logado sem nenhuma op de sessão: `atos open <ato> …/whoami?tag=X`. |
| `/seen?tag=X` | Devolve o que `/whoami` anotou: `{"seen": true, "logged_in": false}`. Para o `curl` do gate. |
| `/ui/dialog` | Para o gate embutido (passo 5.3). Botões "Alert", "Confirm" e "Prompt" (`Heads up`, `Proceed?`, `Name?` com padrão `anon`); o resultado vai para o título: `alert:done`, `confirm:true`, `prompt:texto` ou `prompt:null`. Com `?auto=alert`, `?auto=confirm` ou `?auto=prompt` o diálogo abre sozinho depois do carregamento (para aba em que ninguém clica). |
| `/ui/perm` | Pede geolocalização e, depois que essa responde, notificações, ao carregar. O título fica `perm geo=allowed\|denied notif=granted\|no` (`?` enquanto espera). Só o código 1 de geolocalização conta como recusa. |
| `/ui/pick` | `<input type=file>` simples (`.txt`), `multiple`, um `<select>` (Brasil, Chile desligado, Peru), um campo de texto e um link. Cada botão "Open … later" abre o controle 2,5 s depois do clique, ainda dentro da ativação do usuário: o agente clica e a pessoa assume a aba antes do pedido. Títulos: `file:nome`, `files:a,b`, `select:pe`. |
| `/ext` | Para o gate embutido (extensões em abas de agente). A extensão de teste `extensao/` (só um content script em `document_start`, carregada com `--load-extension`) acrescenta ` +ext` ao título "Ext (test)" quando roda. Também em `http://localhost:8765/ext`, outra origem para o mesmo servidor. |
| `/auth`, `/auth/NOME` | Responde 401 com `WWW-Authenticate: Basic realm="teste"` (em `/auth/NOME` o realm é `teste-NOME`, porque o Chromium reaproveita a credencial de um realm repetido). Aceita `test-user` / `fake-password` (título "Auth ok"); sem credencial o título é "Auth 401". |

`/` vai para `/app/` com o cookie `sid` e para `/login` sem ele: `session` e `renew` carregam a raiz da origem numa aba escondida, então é por aqui que chegam ao `localStorage` e ao header. Valores falsos que o gate `tools/gates/sessao.sh` espera: cookie `sid` = `sid-fake-123` (httpOnly), cookie `d` = `fake-d-cookie-456`, `localStorage` `token` = `fake-local-token-789`, header `Authorization` = `Bearer test-bearer-123`.

`/login?auto=1` entra sozinho (grava os cookies e vai para `/app/`), para os gates que não podem digitar.
