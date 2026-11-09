# Visual

**Segue a marca do Agens** (decisão do Willian, 09/11/2026): o sistema de design é o `DESIGN.md` do Agens-Prototipos, com os temas Grafite (padrão) e Brasa, e a moldura do app Navegador que já existe no protótipo do Agens. A página é o produto, e a interface do navegador sai do caminho.

## Princípios

1. **A página manda.** Barra mínima, nenhum banner, nenhuma promo, nenhum aviso que não seja da pessoa.
2. **A marca do Agens.** Camadas de grafite e fios de 1 px, sem sombra; sem vermelho e sem verde; luz quente só no que está nas suas mãos (foco, cursor, escolhido); âmbar só para "precisa de você"; menus, seletores e alertas sempre do Agens, nunca os do sistema. No Mac continuam a janela, a tela cheia e os atalhos do sistema.
3. **Temas do Agens.** Grafite é o padrão e Brasa o segundo, os mesmos do Agens. Perfis são times, e a cor do time mora só no rosto (o monograma), nunca na janela.
4. **Abas em cima ou na barra lateral.** A pessoa escolhe e troca a qualquer hora, sem reiniciar (ajustes e atalho). A lateral recolhe para ícones e mostra o perfil no topo.
5. **Perfis à vista.** Cor, ícone e nome por perfil; seletor sempre à mão (na barra, com abas em cima; no topo da lateral, com abas na lateral); atalho para trocar. Trocar é instantâneo; perfil dormindo acorda sem tela de espera longa.
6. **Movimento curto.** Animações de até 200 ms, e nenhuma com Reduzir movimento ligado.
7. **A UI nunca trava.** Troca de aba, abrir aba e digitar na barra a 120 Hz em ProMotion. Orçamento em [performance.md](performance.md#orçamento-da-ui).
8. **Acessível desde o primeiro dia.** VoiceOver/Narrator em tudo, contraste AA, tudo alcançável pelo teclado, respeita o tamanho de texto do sistema.

## Referências

| Navegador | Copiar | Não copiar |
|---|---|---|
| Safari | barra compacta, integração com o sistema, leveza | abas pequenas demais para ler |
| Arc | abas na lateral, espaços por perfil com cor | onboarding longo, conta obrigatória |
| Edge | abas verticais opcionais, abas que dormem com indicador | barra lateral cheia de serviços, promoções |
| Zen | lateral recolhível, foco na página | personalização que vira trabalho |

A escolha final das referências é a issue V1.

## O que precisa de desenho

- Janela: abas em cima e abas na lateral (expandida e recolhida), tela cheia, janela estreita.
- Barra de endereço: vazia, digitando com sugestões, carregando, página segura/insegura, erro de certificado.
- Abas: normal, carregando, tocando áudio, mudo, fixada, **dormindo (congelada / descartada / acordando)**, com a memória da aba no cartão de hover.
- Perfis: seletor, criar/editar (nome, ícone, cor), perfil dormindo, trocando.
- Páginas internas: nova aba, ajustes, histórico, downloads, erro de rede, sem conexão.
- Ajustes de aparência: posição das abas, densidade, barra compacta, tema.

## Tokens

Os tokens do Grafite e da Brasa, um para um (cor, `--round`, `--pill`, movimento, luz). No Mac, o pacote `AgensDesign` do Agens (`packages/design/apple`) já tem o Grafite em Swift; o navegador usa o mesmo. Fonte do sistema (SF), mono só para dados. Issue #16.

## Protótipo

Antes da janela em SwiftUI, um protótipo navegável em HTML (como o `revisao.html` do Agens), com uma âncora por estado. Issue V4.
