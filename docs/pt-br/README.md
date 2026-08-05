---
permalink: /pt-br/
title: Começando
lang: pt-br
---

# Documentação do BTYN

**Português** · [English](../en/README.md)

- **[Linguagem de schema](schema.md)** — declarações, tipos, config
- **[API gerada](api.md)** — o que você chama de cada lado
- **[Performance](performance.md)** — os limites do motor, o que o BTYN faz, o que cabe a você
- **[Segurança](security.md)** — o que buffer protege e o que não protege

## Começando

Instale as ferramentas ([Rojo](https://rojo.space), [Lune](https://lune-org.github.io/docs)):

```bash
rokit install
```

Escreva um schema. `net.btyn`:

```btyn
config {
    server = "src/Server/Net.luau"
    client = "src/Client/Net.luau"
}

event Attack from client rate 10 {
    target: entity,
    combo:  u8,
}

event Damaged from server {
    victim: entity,
    amount: u16,
}
```

Compile:

```bash
lune run cli/main -- net.btyn
```

Garanta que `src/` esteja no jogo como um módulo chamado `BTYN` — veja o
mapeamento em `default.project.json`, ou aponte `runtime` para outro lugar no
seu bloco `config`.

Use:

```luau
-- src/Server/init.server.luau
local Net = require(script.Parent.Net)

Net.Attack.on(function(player, data)
    -- Valide o significado; o schema já validou o formato.
    local target = entities[data.target]
    if not target or not inReach(player, target) then
        return
    end

    local amount = weaponDamage(player)   -- estado do servidor, nunca enviado
    target.hp -= amount

    Net.Damaged.all({ victim = data.target, amount = amount })
end)
```

```luau
-- src/Client/init.client.luau
local Net = require(script.Parent.Net)

Net.Damaged.on(function(data)
    showHitmarker(data.victim, data.amount)
end)

mouse.Button1Down:Connect(function()
    Net.Attack.fire({ target = currentTarget, combo = combo })
end)
```

## Para onde ir depois

Se o caso é **replicar estado** em vez de disparar eventos — barra de vida,
nameplate, posição de NPC — vá para [channels](api.md#channels). É onde a
economia de banda realmente está.

Se banda é a preocupação, leia [performance](performance.md). A seção de
técnicas importa mais do que a escolha de qualquer biblioteca, inclusive esta.

Antes de **publicar**, leia [segurança](security.md), principalmente a parte
sobre o que o BTYN não faz por você.
