# Visual

Marca própria com cara de app nativo. A página é o produto; a interface do navegador sai do caminho.

## Princípios

1. **A página manda.** Barra mínima, nenhum banner, nenhuma promo, nenhum aviso que não seja da pessoa.
2. **Nativo primeiro.** No Mac: toolbar unificada, traffic lights, tela cheia, menus e atalhos do sistema. No Windows: Mica, Fluent e o que o WinUI já dá. A marca aparece no ícone, na cor de acento, nas páginas internas (nova aba, ajustes, erro) e nos perfis.
3. **Sistema decide o tema.** Claro/escuro e acento seguem o sistema (com opção de forçar). A cor do perfil tinge a janela.
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

Cor, tipografia, espaço e raio num formato único que gera SwiftUI e WinUI, partindo dos tokens base do `SugiyamaLabs/design-system`. Fonte do sistema (SF no Mac, Segoe no Windows). Issue V3.

## Protótipo

Antes da janela em SwiftUI, um protótipo navegável em HTML (como o `revisao.html` do Agens), com uma âncora por estado. Issue V4.
