<img src="assets/logo.svg" width="78" align="right" alt="">

# BTYN

[English](README.md) · **Português** · [Español](README.es.md) · [中文](README.zh-CN.md)

[![CI](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml/badge.svg)](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-8570FF)](LICENSE)

Um compilador de networking para Roblox. Você escreve um schema; ele escreve o
Luau mais rápido e correto para aquele schema exato, dos dois lados.

**[Documentação →](https://ocauapaz.github.io/BTYN/pt-br/)**

```btyn
event Attack from client rate 10 {
    target: entity,
    combo:  u8,
    heavy:  bool,
}

unreliable Muzzle from server {
    at:  vec3,
    dir: unit,
}

channel Health priority high {
    hp:     u8(0..100),
    downed: bool,
}
```

```luau
-- servidor
Net.Attack.on(function(player, data)
    -- data.target: number, data.combo: number, data.heavy: boolean
end)

Net.Muzzle.all({ at = origin, dir = facing })

local health = Net.Health.of(entityId)
health.set({ hp = 80 })
health.audience(playersInRange)
```

```luau
-- cliente
Net.Attack.fire({ target = id, combo = 2, heavy = false })
Net.Muzzle.on(function(data) spawnFlash(data.at, data.dir) end)
Net.Health.on(function(id, state) updateBar(id, state.hp) end)
```

## Por quê

A Roblox te dá cerca de 50 KB/s por cliente antes de throttlar **toda** a
replicação, cobra uns 9 bytes de cabeçalho por chamada de remote, e descarta em
silêncio um payload de `UnreliableRemoteEvent` grande demais. A resposta
conhecida é um remote confiável mais um não confiável, com batch por frame e
serialização manual em `buffer`. Funciona, e é tedioso e fácil de errar.

O BTYN é essa resposta, gerada. Seu jogo inteiro usa dois remotes. Os pacotes
são agrupados em um envio por frame. Cada campo é empacotado por um codec
escrito para o tipo exato dele, sem percorrer schema em runtime.

### O que um compilador compra sobre um schema em runtime

| | |
|---|---|
| **Offsets constantes** | Um pacote de tamanho fixo compila para uma linha reta de `buffer.writeu32(b, o + 4, v.target)`. Sem variável de cursor, sem dispatch de tipo por campo. |
| **Booleanos empacotados** | 32 flags viram um único `u32`, não 32 escritas de byte. |
| **Uma checagem de limites** | Os tamanhos são conhecidos, então o pacote é validado uma vez na entrada em vez de campo a campo. |
| **Tipos de verdade** | Luau não tem mapped types, então um schema em tabela **não consegue** inferir o próprio tipo de payload. Um compilador simplesmente escreve `export type Attack = { target: number, ... }`. |
| **Estouro pego no build** | O compilador conhece o pior caso de cada pacote e quebra o build se um `unreliable` não couber no limite de payload — em vez de deixar o motor descartar em produção sem avisar. |

### O que ele faz que as bibliotecas não fazem

- **Interest management.** Channels carregam uma audiência explícita. O pacote
  mais barato é o que nunca é enviado, e quem entra na audiência recebe keyframe
  automaticamente.
- **Orçamento por prioridade.** Cada channel declara uma prioridade. Quando um
  cliente passa do orçamento de bytes do frame, deltas de baixa prioridade são
  adiados e se fundem; nada se perde, e o throttle nunca é alcançado.
- **Broadcast serializado uma vez.** Um broadcast filtrado codifica uma única
  vez e faz memcpy para o batch de cada destinatário.
- **Limites obrigatórios.** Uma `string` ou array sem limite é erro de
  compilação, não um padrão. Entrada ilimitada é como um pacote vira primitiva
  de amplificação.

## Começando

Precisa de [Rojo](https://rojo.space) e [Lune](https://lune-org.github.io/docs),
ambos fixados no `rokit.toml`:

```bash
rokit install
```

Coloque `src/` no seu jogo como um módulo chamado `BTYN`, escreva um schema e
compile:

```bash
lune run cli/main -- net.btyn
```

Inspecione sem escrever nada — tamanhos, opcodes, e o quão perto seu maior
pacote unreliable está do limite:

```bash
lune run cli/main -- net.btyn --check
```

```
btyn: net.btyn is valid — 9 packet(s), 1 byte opcodes

  [0    ] Aim            unreliable     client -> server  4 B
  [2    ] Attack         event          client -> server  6 B  rate 10/s
  [3,4  ] Buy            request        client -> server  3 B -> 6-70 B  rate 4/s
  [7,8  ] Health         channel/high   server -> client  3 B
  [9    ] Muzzle         unreliable     server -> client  18 B

  largest unreliable packet: 19 B of the 800 B cap
```

Use `--watch` para recompilar ao salvar.

## Suporte no editor

Uma [extensão para VS Code](editors/vscode/) com highlight, completion ciente do
contexto, hover mostrando o custo em bytes de cada tipo, e diagnostics ao vivo
vindos do próprio compilador:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## Segurança

Buffer é ofuscação, não segurança. Torna um dump de RemoteSpy ilegível e nada
além disso; um exploiter com uma tarde decodifica seu formato.

O que de fato protege é o servidor decidir, não o cliente. O BTYN garante o
**formato** do que chega — tipo, faixa, tamanho, finitude — o que elimina uma
classe real de ataque: payload malformado, string gigante, array ilimitado,
`NaN` envenenando um cálculo de física ou economia. Ele não garante que aquele
jogador podia causar aquele dano, naquela distância, fora daquele cooldown. Essa
parte é sua.

[Leia o guia de segurança →](https://ocauapaz.github.io/BTYN/pt-br/security)

## Testes

Tudo exceto os dois RemoteEvents é Luau puro, o que mantém a maior parte do
sistema testável sem o motor — inclusive o código gerado, que é carregado e
round-trippado de verdade, não só inspecionado.

```bash
lune run tests/run      # compilador e codecs
lune run bench/run      # throughput do codec e tamanhos no fio
```

A parte que precisa do motor rodando está coberta pelo
[teste de integração no Studio](tests/studio/): ele verifica que 25 pacotes saem
em 2 fires de remote, que um delta de channel custa 7 B contra um keyframe de
9 B, e que todo tamanho no fio bate com o que o `--check` prevê.

## Status

Funcionando: eventos (confiáveis e não confiáveis), requests, channels com delta
encoding e interest management, rate limiting por jogador, todos os tipos da
[referência do schema](https://ocauapaz.github.io/BTYN/pt-br/schema), `--watch`,
e a extensão do VS Code.

Ainda não feito: saída `.d.ts` para roblox-ts e o plugin de Studio.
`typescript = true` quebra o build em vez de emitir nada em silêncio.

## Licença

[MIT](LICENSE)
