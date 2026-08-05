---
title: Performance
lang: pt-br
---

# Performance

[← Índice](README.md)

## Os limites contra os quais você realmente joga

| | | |
|---|---|---|
| Banda por cliente | ~50 KB/s antes do throttling | Passar disso atrasa **toda** a replicação — personagens, física, propriedades — não só os seus pacotes |
| Overhead por chamada de remote | ~9 bytes | 100 mensagens pequenas por frame são ~900 bytes só de cabeçalho |
| Taxa de requisição do cliente | ~500/s, compartilhada entre remotes do mesmo tipo | Spam de remote é throttlado antes de você perceber |
| Payload unreliable | descartado acima do limite | Sem erro. O pacote simplesmente não chega |
| Taxa segura de envio | degrada acima de ~60 Hz | Batching por frame não é opcional |

Os 50 KB/s são compartilhados com a replicação de personagem e física do próprio
motor. Só uma parte é sua para gastar.

## O que o BTYN faz a respeito

### Dois remotes, batch por frame

Todo pacote de um frame vai em um envio só. O overhead de cabeçalho é pago duas
vezes por frame em vez de uma vez por mensagem, e tráfego normal de gameplay
deixa de conseguir alcançar o limite de taxa de requisição.

### Offsets constantes

Um pacote de tamanho fixo compila para uma linha reta, sem cursor e sem dispatch
de tipo:

```luau
local function writeAttack(b: buffer, o: number, v: Attack, refs: { Instance }): number
    local w1 = 0
    if v.crit then w1 += 1 end
    if v.stun then w1 += 2 end
    buffer.writeu8(b, o, w1)
    buffer.writeu32(b, o + 1, v.target)
    buffer.writeu8(b, o + 5, v.combo)
    return 6
end
```

É isso que um compilador compra. Um schema em runtime precisa percorrer uma
tabela e ramificar pelo tipo de cada campo em toda chamada; aqui não sobrou nada
para percorrer.

### Booleanos empacotados

Todo booleano do pacote divide um bitfield na frente. 32 flags custam 4 bytes e
um `writeu32`. É o caso onde a distância entre schema compilado e interpretado é
maior.

### Uma checagem de limites por pacote

Os tamanhos são conhecidos, então um pacote fixo é validado uma vez na entrada
em vez de antes de cada campo. Mais rápido **e** mais seguro do que não checar.

### Broadcast serializado uma vez

`all`, `list` e `except` codificam o pacote uma única vez num buffer de rascunho
e fazem `buffer.copy` para o batch de cada destinatário. Quarenta jogadores
custam uma serialização e quarenta memcpys.

### Uma alocação por flush

Os streams são reaproveitados entre frames e crescem dobrando. A única alocação
no caminho de envio é o buffer de tamanho exato entregue ao remote, uma vez por
flush.

### Delta encoding e interest management

Cobertos no [guia da API](api.md#channels). Dois efeitos, e o segundo é maior:
enviar só o que mudou, e só para quem importa.

## Técnicas que importam mais do que qualquer biblioteca

Em ordem aproximada de impacto. Uma biblioteca otimiza o caso genérico; estas
tratam do **seu** caso, e ganham por mais.

**1. Não envie.** O pacote mais barato é o que não existe. Replique só o que
está no raio de relevância do jogador, envie por mudança em vez de por timer, e
deixe o cliente derivar o que der para derivar.

**2. Baixe a taxa.** Muita coisa rodando a 60 Hz fica idêntica a 10 Hz com
interpolação no cliente. Movimento de NPC é o clássico: seis atualizações por
segundo, interpoladas, são indistinguíveis de sessenta na prática.

**3. Quantize.** Posição raramente precisa de `f64`. Ângulos cabem em um ou dois
bytes. Vida cabe num `u8` se o máximo for 100. Use `fixed(min, max, bytes)` e
`angle` em vez de ir de `f32` por reflexo.

**4. Bitpacking.** 32 booleanos cabem num `u32` — o BTYN faz isso por você.
Enums viram um byte.

**5. Delta encoding.** Envie o que mudou, atrás de uma máscara. É o que os
channels são.

**6. Opcodes, nunca strings.** Nunca mande `"FireballCast"`. O BTYN atribui um
opcode numérico a cada pacote em tempo de compilação; você nunca vê um nome no
fio.

**7. Cuidado com `Instance`.** Referências são caras e chegam `nil` quando quem
recebe ainda não fez streaming do objeto. Prefira `entity`.

## Medindo

Confie no seu jogo mais do que no benchmark de qualquer um, incluindo esta
página. Use o **network profiler do MicroProfiler** e o painel de estatísticas
de rede, com contagem realista de jogadores, e olhe três coisas:

- **KB/s recebido por cliente** — alvo confortavelmente abaixo de 50
- **Tempo de CPU em serialização por frame**
- **Crescimento de memória ao longo de uma sessão longa**

O `--check` te diz o que o compilador sabe estaticamente:

```bash
lune run cli/main -- net.btyn --check
```

```
  [9    ] Muzzle         unreliable     server -> client  18 B

  largest unreliable packet: 19 B of the 800 B cap
```

Existe um benchmark headless do codec no repositório:

```bash
lune run bench/run
```

```
  fixed, 3 fields             7 B   encode     8.0M/s   decode    10.9M/s
  32 booleans                 4 B   encode     1.3M/s   decode     1.6M/s
  quantised vec3 + unit      18 B   encode     3.2M/s   decode     3.4M/s
  dynamic string              6 B   encode     4.0M/s   decode     7.1M/s
```

Ele mede CPU e tamanho no fio dos codecs gerados, com payloads que variam a cada
iteração. E de propósito **não** se apresenta como comparação entre bibliotecas
— isso exigiria as outras bibliotecas e um place de verdade para rodar. Repare
nos 4 bytes para 32 booleanos; é esse o número que interessa naquela linha.

### Sobre benchmarks

Benchmark de networking neste ecossistema é excepcionalmente fácil de errar. Um
resultado bastante divulgado uma vez mostrou uma biblioteca enviando quase nada,
porque ela fazia XOR contra um frame anterior idêntico — o payload era
constante, então os deltas eram todos zero. Estava medindo um bug.

Se for medir:

- Use dados que **mudam a cada frame**. Payload constante favorece
  enormemente qualquer esquema de delta ou XOR.
- **Meça memória**, não só throughput e frame rate.
- Desconfie de **batching que empurra bytes para fora da janela de medição** em
  vez de eliminá-los.
- Compare coisas comparáveis: a diferença de banda entre bibliotecas baseadas em
  buffer costuma ficar abaixo de 3%. A diferença real está na CPU.

---

Próximo: [segurança](security.md) · [referência do schema](schema.md) · [API](api.md)
