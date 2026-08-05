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

O handler roda na própria thread, então dar yield ali — uma chamada de
datastore, um `task.wait` — não segura nada do resto do batch.

Para um `request X from server` a direção inverte e o `call` do servidor recebe
um alvo: `Net.Ping.call(player, data)`.

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
reportado, nunca enfileirado.

---

Próximo: [performance](performance.md) · [segurança](security.md) · [referência do schema](schema.md)
