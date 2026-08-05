---
title: API gerada
lang: pt-br
---

# A API gerada

[← Índice](README.md)

Compilar um schema escreve dois módulos. Cada um carrega só a metade do
protocolo da qual aquele lado participa: o arquivo do cliente não tem leitor
para um pacote que o servidor nunca manda para ele, nem escritor para um que o
cliente nunca envia.

```luau
-- servidor
local Net = require(ServerScriptService.Net)
-- cliente
local Net = require(ReplicatedStorage.Net)
```

Todo tipo de payload é exportado, então `Net.Attack.on` te entrega uma tabela
totalmente tipada sem nenhuma anotação da sua parte.

## Eventos

Dado:

```btyn
event Attack from client rate 10 { target: entity, combo: u8 }
event Damaged from server { victim: entity, amount: u16 }
```

### Lado que envia

```luau
-- cliente, porque Attack é `from client`
Net.Attack.fire({ target = id, combo = 2 })
```

```luau
-- servidor, porque Damaged é `from server`
Net.Damaged.to(player, data)          -- um jogador
Net.Damaged.all(data)                 -- todo mundo
Net.Damaged.list(players, data)       -- um conjunto escolhido
Net.Damaged.except(player, data)      -- todos menos um
```

`all`, `list` e `except` serializam uma vez só e copiam os bytes para o batch de
cada destinatário. `list` é o que você quer quando sabe quem se importa —
diferente do `FireAllClients`, ele deixa você filtrar.

### Lado que recebe

```luau
-- servidor
Net.Attack.on(function(player, data)
    -- data.target: number, data.combo: number
end)

-- cliente
Net.Damaged.on(function(data) end)
```

Um handler por pacote; registrar de novo substitui o anterior.

### Como os handlers rodam

Todo handler — de evento, de channel, de request — é retomado numa **thread
própria**. Duas consequências valem saber:

**Você pode dar yield.** Uma chamada de datastore ou um `task.wait` dentro do
handler não segura mais nada. Os pacotes atrás dele no mesmo batch continuam
sendo entregues.

**Um erro fica contido.** Um handler que lança não descarta o resto do batch, e
não é reportado erroneamente pelo `onAbuse` como culpa de quem enviou. Ele
aparece como um erro de script comum.

O preço é que dois handlers do mesmo batch não têm ordem de conclusão se o
primeiro der yield. Se um par de pacotes só é seguro em sequência — um
carregamento e sua liberação — valide antes de ceder, ou carregue a ordem no
payload em vez de depender da ordem de chegada.

### O que o schema não verifica

O formato é validado antes do seu handler rodar: faixas, tamanhos, finitude,
variantes de enum, e que um campo `Instance` realmente contenha uma. O que ele
não consegue verificar é significado.

`entity` em especial é um `u32` puro nomeando algo que o seu jogo possui.
Qualquer valor cabe, então todo id vindo do cliente é uma afirmação a conferir:

```luau
Net.Attack.on(function(player, data)
    local target = entities[data.target]     -- existe?
    if not target or not canReach(player, target) then
        return                               -- é dele para mexer?
    end
    ...
end)
```

## Requests

```btyn
request Buy from client { item: u16 } -> { ok: bool, balance: u32 }
```

```luau
-- cliente
local reply = Net.Buy.call({ item = 12 })       -- dá yield; lança em falha
local ok, reply = Net.Buy.try({ item = 12 })    -- dá yield; nunca lança
```

```luau
-- servidor
Net.Buy.on(function(player, request)
    if not canAfford(player, request.item) then
        return nil          -- nil rejeita; o `call` de quem pediu lança
    end
    return { ok = true, balance = balanceOf(player) }
end)
```

Retornar `nil` rejeita, e lançar erro também — o handler roda dentro de um
`pcall`, então um erro chega a quem chamou como falha e não como timeout.

Para um `request X from server` a direção inverte e o `call` do servidor recebe
um alvo: `Net.Ping.call(player, data)`. Uma resposta só é aceita do jogador para
quem o request foi enviado, então um cliente não consegue responder uma pergunta
que o servidor fez a outra pessoa.

Toda requisição carrega um prazo (`request_timeout`, 10s por padrão). Uma
resposta que nunca chega faz a chamada falhar em vez de deixar a thread presa, e
uma que chega depois do prazo é descartada em vez de entregue atrasada.

## Channels

```btyn
channel Health priority high { hp: u8(0..100), downed: bool }
```

### Servidor

```luau
local health = Net.Health.of(entityId)

health.set({ hp = 80 })              -- só os campos que mudaram ficam sujos
health.audience(playersInRange)      -- quem recebe
health.destroy()                     -- manda quem tem descartar
```

`of` devolve o mesmo handle para o mesmo id, então chamar em loop não aloca.
Depois de `destroy` o id fica livre de novo: chamar `of` com ele — mesmo no
mesmo frame — devolve uma entidade nova, e o cliente recebe a remoção antes do
novo keyframe.

`set` compara antes de marcar. Reatribuir um campo com o valor que ele já tem
não faz nada, o que significa que você pode jogar o estado inteiro nele todo
frame sem destruir o delta encoding.

`audience` substitui o conjunto. Quem entrou recebe um **keyframe** — uma
atualização completa — para nunca tentar aplicar um delta sobre um estado que
nunca teve. Quem saiu é avisado para descartar a entidade.

Essa chamada é o interest management. O BTYN não decide quem é relevante, porque
só o seu jogo sabe; ele torna barato e correto agir sobre a resposta.

```luau
-- formato típico
Net.Health.of(id).audience(playersWithin(120, position))
```

### Cliente

```luau
Net.Health.on(function(id, state, changed)
    -- state:   a visão mesclada, sempre completa
    -- changed: só os campos que chegaram nesta atualização
    updateBar(id, state.hp)
end)

Net.Health.onRemove(function(id) removeBar(id) end)

local current = Net.Health.get(id)   -- nil se nunca recebeu
```

Use `state` para qualquer coisa que precise do quadro inteiro e `changed` quando
quiser reagir só ao que mudou — redisparar o flash de dano a cada tick de
armadura sem relação é o bug clássico aqui.

## Nível de módulo

```luau
Net.flush()
```

Envia todos os batches pendentes agora. Só necessário com `manual = true`; caso
contrário isso acontece uma vez por frame no Heartbeat.

```luau
Net.onAbuse(function(player, reason)
    warn(`{player}: {reason}`)
end)
```

Dispara quando um batch recebido falha na validação, ou quando um rate limit é
estourado. No servidor isso significa que um cliente mandou algo que o schema
não permite, o que nenhum cliente honesto consegue fazer — o mesmo compilador
escreveu os dois lados. É um sinal forte, vale logar e vale agir.

Rate limits são declarados no schema (`rate 10`) e aplicados no lado que recebe,
por jogador, com token bucket. Um pacote acima do orçamento é descartado e
reportado, nunca enfileirado. O bucket guarda um segundo de orçamento, então
`rate 10` permite uma rajada de dez e reabastece a dez por segundo.

---

Próximo: [resolvendo problemas](troubleshooting.md) · [performance](performance.md) · [segurança](security.md) · [referência do schema](schema.md)
