# Plano

Marcos da [ADR 0014 do Agens](https://github.com/SugiyamaLabs/agens/blob/main/docs/decisoes/0014-navegador-produto-proprio.md). As issues ficam no Project **Navegador** e cada uma tem um label de trilha:

- **Build:** Chromium, build e CI (pré-requisito de tudo).
- **Visual:** a marca do Agens, abas em cima ou na lateral, atos à vista, macOS e Windows. Ver [visual.md](visual.md) e os protótipos em `prototipos/`.
- **Performance:** no máximo 50% da RAM do Brave com as mesmas 20 abas. Ver [performance.md](performance.md).

## Marcos e issues

| Marco | Pronto quando | Build | Performance | Visual |
|---|---|---|---|---|
| **M0** · Chromium compilando | um build abre uma página no Mac e no Windows | #1 compila no Mac · #2 CI no Mac · #3 Windows | #4 banco de medição · #5 primeira medição e meta em número | |
| **M1** · Navegador mínimo no Mac | navega no dia a dia sem travar | | #6 orçamento da UI · #7 enxugar | #14 referências · #15 nome de trabalho e ícone · #16 tokens · #17 protótipo · #18 janela · #19 abas na lateral · #20 ajustes de aparência · #21 páginas internas · #25 acessibilidade |
| **M2** · Atos e socket de sessão | o Agens (ou a bancada) pede um login e recebe só o `Need` | | | #22 atos na interface |
| **M3** · Memória | a tabela de medições no repo | | #8 abas que dormem · #9 atos que dormem · #10 teto de processos · #11 V8 · #12 medição por release | #23 ato dormindo · #24 aba dormindo |
| **M4** · Login e extensões | a matriz de login passa inteira | | | |
| **M5** · BrowserKit em release | o Agens importa uma versão e abre um painel | | | |
| **M6** · Windows | os mesmos M1–M4 no Windows | | #13 medição no Windows | #26 visual no Windows |
| **M7** · Lançamento | baixa, instala e se atualiza sozinho | | | #27 nome final, logo e site |

M2 (socket de sessão), M4 e M5 ainda não têm issues: ficam fora das trilhas Visual e Performance e entram quando chegarem perto.

## Ordem sugerida

1. #5 dá para começar já: medir Brave e Chrome com o banco de medição (#4) mostra quanto é "50% do Brave" antes de existir build.
2. #1 → #2 fecham o M0 no Mac; #3 em paralelo quando o Windows estiver livre.
3. #14 → #16 → #17 antes de qualquer SwiftUI; #18 e #19 só depois do protótipo aprovado.
