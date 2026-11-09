# Logo do navegador

Três cartões inclinados (os atos) varrendo como um carro na reta; o da frente aceso. Vetorizado à mão a partir do conceito `r3-01` (cunha), gerado com o codex em 09/11/2026. Não usa a bola nem o quadrado mordido, que são do app Agens.

Tudo sai de uma geometria só: `python3 design/logo/gerar.py` reescreve os SVGs. Os vãos entre os cartões são recortes de verdade (máscara), então a marca funciona em qualquer fundo.

| Arquivo | Uso |
|---|---|
| `icone-macos-escuro.svg` / `-claro.svg` | ícone do app no macOS, no gabarito de 1024 da Apple (corpo de 824 em 100, cantos de ~185) |
| `icone-windows-escuro.svg` / `-claro.svg` | ícone do app no Windows 11: a marca solta, sem placa |
| `marca-escuro.svg` / `-claro.svg` | a marca sozinha, para a assinatura e as páginas internas |
| `marca-pequena-escuro.svg` / `-claro.svg` | 16 a 32 px (aba, barra de tarefas): sem o cartão de trás e com vão maior |
| `marca-uma-cor.svg` | uma cor (`currentColor`), para barra de menus e lugares monocromáticos |
| `marca-uma-cor-branca.svg` / `-preta.svg` | uma cor fixa, para quem não herda a cor do texto |

Prévia: `previa.html`.

Falta: `.icns` (macOS) e `.ico` (Windows) e os PNG de cada tamanho, depois da aprovação.
