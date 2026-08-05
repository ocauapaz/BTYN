---
title: Linguagem de schema
lang: pt-br
---

# A linguagem `.btyn`

[← Índice](README.md)

Um schema é um arquivo de texto puro. Comentários seguem Luau: `--` até o fim da
linha e `--[[ ]]` para bloco. Não existem palavras reservadas — `from`, `rate` e
`event` são reconhecidos por posição, então um campo pode se chamar qualquer um
deles.

## Declarações

### `event`

Confiável, ordenado, agrupado uma vez por frame.

```btyn
event Attack from client {
    target: entity,
    combo:  u8,
}
```

`from` é obrigatório e diz quem envia. Ele decide qual metade da API cada lado
recebe: um evento `from client` dá `.fire` ao cliente e `.on` ao servidor.
Chamar o lado errado é erro de tipo, não um silêncio.

### `unreliable`

Mesmo formato, enviado por `UnreliableRemoteEvent`. Pode chegar fora de ordem ou
simplesmente não chegar.

```btyn
unreliable Muzzle from server {
    at:  vec3,
    dir: unit,
}
```

Use quando perder um pacote é invisível: fogo de boca, poeira de passo,
atualização de mira que a próxima substitui de qualquer jeito. Nunca para nada
que tenha consequência.

O compilador calcula o pior caso de tamanho de todo pacote unreliable e quebra o
build se ele não couber no limite de payload. Isso importa porque o
comportamento do motor com um payload unreliable grande demais é **descartar em
silêncio**.

```
error: unreliable event 'Snapshot' can reach 1003 bytes, over the 800 byte cap
  --> net.btyn:12:12
   |
12 | unreliable Snapshot from server {
   |            ^^^^^^^^ worst case is 1003 bytes
   |
help: the engine drops an oversized unreliable payload without telling you.
      Shrink the packet (quantise floats, cap arrays tighter), split it, or
      make it a reliable `event`
```

### `request`

Requisição e resposta pelos mesmos dois remotes. Nenhum `RemoteFunction` está
envolvido — RemoteFunction bloqueia quem chamou e, no servidor, uma invocação
que dá yield trava a replicação atrás dela.

```btyn
request Buy from client rate 4 {
    item:     u16,
    quantity: u8(1..99),
} -> {
    ok:      bool,
    balance: u32,
    reason:  string(64),
}
```

Quem pede recebe `.call` (dá yield, lança em falha) e `.try` (devolve
`ok, value`). Quem responde recebe `.on`, e o handler pode dar yield à vontade —
ele roda na própria thread, então uma chamada de datastore não trava o batch.

Toda requisição tem prazo (`request_timeout`, padrão 10s). Uma resposta que
nunca chega falha a chamada em vez de deixar a thread presa para sempre.

### `channel`

Estado replicado, codificado em delta, com audiência explícita. Sempre servidor
→ cliente, então não aceita `from`.

```btyn
channel Health priority high {
    hp:     u8(0..100),
    armor:  u8,
    downed: bool,
}
```

Só os campos que mudaram são enviados, atrás de uma bitmask de sujos. Um tick de
vida custa um byte de máscara mais um byte de valor, não o registro inteiro.

`priority` é `low`, `normal` (padrão) ou `high`. Quando um cliente passa do
orçamento de bytes do frame, `low` é adiado primeiro e `high` nunca é adiado.
Deltas adiados se fundem com a próxima atualização, então nada se perde — só
atrasa.

Limitado a 32 campos, o que mantém a máscara em um único acesso. Dividir é
melhor design de qualquer forma: campos que mudam em ritmos diferentes querem
prioridades diferentes.

Um channel não aceita `rate` nem `from`. Ele já envia no máximo uma vez por
frame por jogador, e sempre replica do servidor para o cliente; os dois são
rejeitados em tempo de compilação em vez de aceitos e ignorados.

### `struct` e `enum`

```btyn
struct Vec2i { x: i16, y: i16 }

enum Team { Red, Blue, Spectator }
```

Uma struct é organizada recursivamente e empacota os próprios booleanos
internamente. Um enum viaja em um byte (dois acima de 256 variantes) e aparece
no Luau como união de strings — `"Red" | "Blue" | "Spectator"` — para o código
continuar legível.

### `config`

```btyn
config {
    server = "src/Server/Net.luau"
    client = "src/Client/Net.luau"
}
```

| Chave | Padrão | Significado |
|---|---|---|
| `server` | *obrigatório* | Onde escrever o módulo do servidor |
| `client` | *obrigatório* | Onde escrever o módulo do cliente |
| `runtime` | `game:GetService("ReplicatedStorage"):WaitForChild("BTYN")` | Expressão Luau que os arquivos gerados usam para achar o runtime |
| `budget` | `40000` | Orçamento suave de saída por cliente, bytes/segundo |
| `unreliable_cap` | `800` | Maior payload unreliable, em bytes |
| `max_packets_per_batch` | `256` | Máximo de pacotes num batch recebido, no servidor |
| `request_timeout` | `10` | Segundos até uma requisição sem resposta falhar |
| `write_checks` | `true` | Validar na saída além da entrada |
| `manual` | `false` | Dar flush na mão em vez de no Heartbeat |

Sobre `unreliable_cap`: a Roblox não publica esse número, e medição da
comunidade coloca ele perto de 1000 bytes. O padrão fica bem abaixo disso de
propósito — errar para baixo custa alguns bytes por pacote, errar para cima
custa perda silenciosa de dados. Meça no seu próprio place antes de aumentar.

Sobre `write_checks`: o lado que recebe **sempre** valida, porque ali é a
fronteira de confiança. Essa flag controla só o lado que envia, onde o custo
compra pegar `hp = 300` no ponto da chamada em vez de vê-lo truncar em silêncio
para 44 e chegar do outro lado como um mistério. Deixe ligado até um profile
dizer o contrário.

## Tipos

### Números

`u8` `u16` `u32` · `i8` `i16` `i32` · `f32` `f64`

Todos aceitam uma faixa inclusiva opcional, validada nos dois lados:

```btyn
hp:   u8(0..100),
temp: i16(-50..50),
```

Uma faixa que não cabe no tipo é erro de compilação.

### `bool`

Custa um **bit**, não um byte. Todo booleano do pacote entra em um bitfield na
frente, escrito com um único acesso por 32 flags.

### `entity`

Um `u32` cujo significado é seu. Existe com nome próprio para te afastar de
`Instance`, que não cabe em buffer, custa banda de verdade, e chega `nil` quando
quem recebe ainda não carregou o objeto.

### `string(n)`

O limite é **obrigatório**. Uma string sem limite é um pacote sem limite, o que
é vazamento de banda e primitiva de amplificação de graça. O prefixo de tamanho
é um byte até 255, dois acima disso.

### `[T; n]`

Array com limite obrigatório, mesma razão. `[u16; 100]` tem no máximo 201 bytes.

### `T?`

Opcional. Quando `T` tem tamanho fixo isso custa **um bit** e mantém o pacote no
caminho rápido de offset constante — os bytes do payload são sempre escritos,
zerados quando ausente. Quando `T` é dinâmico, custa um byte de presença.

Esse bit de presença vive no bitfield do pacote (ou do struct), que elementos
de array e campos de channel não têm — então um opcional de tipo *fixo* é
rejeitado nesses dois lugares. Embrulhe num struct, que carrega seu próprio
bitfield: `struct Slot { value: u16? }`. Opcionais de tipos dinâmicos gastam um
byte de presença e funcionam em qualquer lugar.

### Valores da Roblox

| Tipo | Bytes | Observação |
|---|---|---|
| `vec3` | 12 | 3 × `f32` |
| `cframe` | 18 | posição em 3 × `f32`, rotação em ângulos de Euler quantizados |
| `color3` | 3 | um byte por canal |
| `unit` | 6 | vetor unitário, cada componente quantizado em `i16`; normalizado na leitura |
| `angle` | 2 | radianos quantizados em `[-pi, pi]` |
| `Instance` | 2 | índice em um array lateral — veja abaixo |

### `fixed(min, max, bytes)`

Um float quantizado numa faixa fixa. `bytes` é 1, 2 ou 4.

```btyn
blend: fixed(-1, 1, 2),
```

Dois bytes dão 65536 passos na faixa, mais fino do que qualquer jogador percebe.
Normalmente é a resposta certa quando você ia usar `f32` no reflexo.

### `Instance`

Buffer guarda bytes, então uma Instance não cabe. O BTYN escreve um índice e
leva a referência ao lado do payload.

Funciona, e ainda assim prefira `entity`. Referência de Instance custa banda e
chega `nil` quando quem recebe ainda não fez streaming do objeto — um bug que só
aparece em conexão ruim. Um broadcast com `Instance` também abre mão do caminho
de serializar uma vez só, porque os índices são relativos ao batch que os
carrega.

---

Próximo: [a API gerada](api.md) · [performance](performance.md) · [segurança](security.md)
