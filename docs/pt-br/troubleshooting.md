---
title: Resolvendo problemas
lang: pt-br
---

# Resolvendo problemas

[← Índice da documentação](README.md)

Sintomas na ordem em que as pessoas realmente esbarram neles.

## `Infinite yield possible on 'ReplicatedStorage:WaitForChild("BTYN")'`

O runtime não está no jogo, ou não está onde o código gerado procura.

Os módulos gerados chegam ao runtime pela chave de config `runtime`, que por
padrão aponta para `ReplicatedStorage.BTYN`. Alguma coisa precisa colocar `src/`
lá. Neste repositório, isso é o `default.project.json`:

```json
{
  "name": "BTYN",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "BTYN": { "$path": "src" }
    }
  }
}
```

O que produz:

```
ReplicatedStorage
└── BTYN              (ModuleScript, de src/init.luau)
    ├── Stream
    ├── Transport
    ├── Channel
    ├── RateLimiter
    └── Request
```

Se o seu jogo guarda pacotes em outro lugar, deixe onde estão e aponte o schema
para lá:

```btyn
config {
    runtime = "game.ReplicatedStorage.Packages.BTYN"
}
```

O valor é uma expressão Luau colada dentro de um `require` nos dois lados, então
qualquer coisa que resolva funciona.

## `attempt to call a nil value` em `Net.Alguma.fire` ou `.on`

Você está do lado errado do `from`.

A API gerada é assimétrica de propósito — cada lado recebe só a metade da qual
participa, então chamar a errada falha alto em vez de silenciosamente não fazer
nada.

| Declaração | Cliente recebe | Servidor recebe |
|---|---|---|
| `event X from client` | `.fire` | `.on` |
| `event X from server` | `.on` | `.to` `.all` `.list` `.except` |
| `request X from client` | `.call` `.try` | `.on` |
| `request X from server` | `.on` | `.call` `.try` |
| `channel X` | `.on` `.onRemove` `.get` | `.of` |

Se a intenção era o outro sentido, mude o `from` no schema e recompile.

## `btyn: unknown opcode 7` chegando no `onAbuse`

Os dois lados foram gerados a partir de versões diferentes do schema.

Opcodes são atribuídos por nome de pacote em ordem alfabética, então adicionar
um pacote chamado `Aaa` renumera tudo depois dele. Isso não é problema — os dois
arquivos saem da mesma execução — mas significa que **os módulos do servidor e
do cliente precisam ir juntos**. Um servidor atualizado sem o cliente, ou um
cliente em cache de um build anterior, vão discordar sobre o que é o opcode 7.

Recompile e publique os dois. Se isso aparecer em produção, verifique se o que
copia os arquivos gerados não está tratando os dois como artefatos
independentes.

## Um channel não envia nada

A audiência dele está vazia, que é o padrão.

```luau
local health = Net.Health.of(id)
health.set({ hp = 100 })     -- não vai a lugar nenhum: ninguém está escutando
```

Um channel replica para os jogadores que você nomear e para mais ninguém — essa
é a gestão de interesse, e o padrão vazio é o seguro. Diga quem se importa:

```luau
health.audience(playersWithin(120, position))
```

Jogadores que entram na audiência recebem um keyframe automaticamente; os que
saem são avisados para descartar a entidade.

## Nada é enviado, e `manual = true`

Com `manual` ligado, nada é enviado sozinho. Chame:

```luau
Net.flush()
```

Os batches acumulam até você chamar. Se você ligou `manual` para controlar
*quando* o tráfego sai, garanta que todo caminho capaz de enfileirar um pacote
chegue a um flush — inclusive os que só rodam de vez em quando.

## `btyn: 'hp' is not a field of this channel`

Um typo no `set`, ou um campo que pertence a outro channel. O erro nomeia a
chave que recebeu; o bloco `channel` do schema é a lista do que é válido.

Isso é verificado em runtime e não pelo sistema de tipos porque `set` recebe uma
tabela parcial, e Luau não consegue expressar "algum subconjunto destas chaves"
com precisão suficiente para pegar no ponto da chamada.

## Um valor chega truncado ou limitado

Ou o tipo declarado é estreito demais, ou as checagens de escrita estão
desligadas.

Escrever `300` num `u8` trunca para `44`. Com `write_checks` ligado — o padrão —
você recebe um erro no ponto da chamada:

```
btyn: hp must be between 0 and 255, got 300
```

Se você desligou `write_checks` para builds de produção e algo está chegando
errado, ligue de volta num build de desenvolvimento e reproduza lá. O lado que
recebe sempre valida, independente dessa configuração, então o pacote seria
rejeitado no caminho em vez de entregue errado — confira o `onAbuse`.

Tipos quantizados perdem precisão por definição: `fixed(-1, 1, 2)` tem ~65536
passos na faixa, `angle` resolve cerca de 0,0001 radiano, e `unit` é normalizado
na chegada. Se você precisa do float exato de volta, use `f32`.

## Um request sempre estoura o prazo

Três causas, em ordem de probabilidade.

**O respondedor retornou `nil`.** Esse é o caminho de rejeição, e chega a quem
chamou como falha e não como timeout — `call` lança erro, `try` retorna `false`.
Se a intenção era responder, retorne uma tabela.

**O respondedor lançou erro.** O handler dele roda dentro de um `pcall`, então
um erro vira rejeição. Procure o erro em si na saída do servidor.

**Nada está sendo enviado.** Veja `manual` acima. Requests andam no batch
comum, então um request enviado sem flush nunca sai.

O prazo é `request_timeout`, 10 segundos por padrão. Uma resposta que chega
depois disso é descartada em vez de entregue atrasada.

## `exceeded its rate limit` em tráfego que parece razoável

O bucket guarda um segundo de orçamento. `rate 10` permite uma rajada de dez e
reabastece a dez por segundo — então dez chamadas num frame estão de bom
tamanho, e vinte não estão, mesmo que vinte ao longo de dois segundos
estivessem.

Se uma rajada legítima é maior que a taxa sustentada, aumente o rate para cobrir
a rajada, não a média. Se a rajada é um laço, pense se aquilo não deveria ser um
pacote carregando um array em vez de muitos pacotes.

## `batch carries more than 256 packets`

Um cliente enviou mais pacotes num frame do que o teto permite. De um cliente
comum isso não acontece: um frame movimentado de input são alguns poucos
pacotes.

Se você tem um caso legítimo — um jogo de construção enviando uma edição grande
como muitos pacotes pequenos — aumente o teto:

```btyn
config { max_packets_per_batch = 1024 }
```

Prefira reestruturar antes. Um pacote carregando `[Edit; 512]` custa uma fração
de 512 pacotes carregando uma edição cada, tanto em bytes quanto em CPU.

## Um campo `Instance` chega `nil`

O receptor ainda não recebeu aquele objeto por streaming, ou ele foi destruído
entre o envio e a chegada.

Isso é inerente a referências de Instance, não algo que o BTYN possa resolver —
é por isso que `entity` existe. Um id `u32` que o seu jogo controla sempre
chega, significa a mesma coisa nos dois lados, e custa quatro bytes sem array
lateral. Prefira ele.

## A saída `typescript` quebra o build

```
error: `typescript` output is not implemented yet
```

Não está implementado, e falhar é proposital — aceitar a flag e emitir nada em
silêncio deixaria um build roblox-ts descobrir as declarações faltando muito
depois. Remova a chave. O Luau gerado é totalmente tipado e usável a partir de
Luau hoje.

## O Studio não vê a recompilação

O Rojo sincroniza os arquivos que está observando. Verifique se os caminhos do
seu bloco `config` ficam dentro da árvore que o `default.project.json` mapeia, e
se o `rojo serve` está rodando. Compilar escreve os arquivos independente de
alguém estar sincronizando.

Rodar o compilador em `--watch` ao lado do `rojo serve` é exatamente o fluxo
para o qual isso foi desenhado — veja [compilador e editor](cli.md).

## Outra coisa

O [teste de integração no Studio](https://github.com/ocauapaz/BTYN/tree/main/tests/studio)
exercita todo tipo de pacote contra remotes reais e imprime a contagem de bytes
no caminho. Rodá-lo num place de rascunho costuma ser mais rápido do que
instrumentar o seu próprio jogo, e os números batem com o que o `--check`
prevê.

---

Próximo: [compilador e editor](cli.md) · [API](api.md) · [segurança](security.md)
