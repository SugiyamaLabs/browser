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
| `/whoami?tag=X` | Anota se esse pedido veio com o cookie de login (`sid`). Serve para ver se um ato está logado sem nenhuma op de sessão: `atos open <ato> …/whoami?tag=X`. |
| `/seen?tag=X` | Devolve o que `/whoami` anotou: `{"seen": true, "logged_in": false}`. Para o `curl` do gate. |

`/login?auto=1` entra sozinho (grava os cookies e vai para `/app/`), para os gates que não podem digitar.
