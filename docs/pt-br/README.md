---
permalink: /pt-br/
title: Começando
lang: pt-br
---

# Documentação do BTYN

**Português** · [English](../en/README.md)

- **[Linguagem de schema](schema.md)** — declarações, tipos, config
- **[API gerada](api.md)** — o que você chama de cada lado
- **[Compilador e editor](cli.md)** — flags, watch mode, VS Code
- **[Performance](performance.md)** — os limites do motor, o que o BTYN faz, o que cabe a você
- **[Segurança](security.md)** — o que buffer protege e o que não protege
- **[Resolvendo problemas](troubleshooting.md)** — quando alguma coisa não funciona

## Começando

### 1. Instale as ferramentas

O BTYN precisa do [Rojo](https://rojo.space) para sincronizar arquivos com o
Studio e do [Lune](https://lune-org.github.io/docs) para rodar o compilador. Os
dois estão fixados no `rokit.toml`:

```bash
rokit install
```

### 2. Coloque o runtime no seu jogo

Os módulos gerados procuram o runtime em `ReplicatedStorage.BTYN` por padrão. O
`default.project.json` mapeia `src/` para lá:

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

O que dá:

```
ReplicatedStorage
└── BTYN              (ModuleScript, de src/init.luau)
    ├── Stream
    ├── Transport
    ├── Channel
    ├── RateLimiter
    └── Request
```

Guarda pacotes em outro lugar? Deixe onde estão e aponte o schema para lá, com a
chave `runtime` mostrada abaixo. O valor é colado dentro de um `require` nos
dois lados, então qualquer expressão que resolva funciona.

Esse é o passo que a maioria das primeiras tentativas erra, e aparece como
`Infinite yield possible on 'ReplicatedStorage:WaitForChild("BTYN")'`.

### 3. Escreva um schema

`net.btyn`:

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

### 4. Compile

```bash
lune run cli/main -- net.btyn
```

```
btyn: wrote src/Server/Net.luau
btyn: wrote src/Client/Net.luau
```

Enquanto trabalha, deixe o compilador observando ao lado do `rojo serve` para os
módulos acompanharem o schema a cada save:

```bash
lune run cli/main -- net.btyn --watch
```

Os arquivos gerados são saída de build. Coloque no `.gitignore`, a menos que seu
time prefira revisar diff de código gerado — mas se for commitar, commite os
**dois**, porque os opcodes são atribuídos olhando o schema inteiro e os dois
lados precisam concordar.

### 5. Use

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

### 6. Instale a extensão do editor

Opcional, e vale os dois minutos. Ela dá highlight, autocomplete que entende o
contexto, hover com o custo em bytes de cada tipo, e os erros do próprio
compilador sublinhados enquanto você digita:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

Veja [compilador e editor](cli.md#suporte-a-editor) para as configurações.

## Para onde ir depois

Se o caso é **replicar estado** em vez de disparar eventos — barra de vida,
nameplate, posição de NPC — vá para [channels](api.md#channels). É onde a
economia de banda realmente está.

Se banda é a preocupação, leia [performance](performance.md). A seção de
técnicas importa mais do que a escolha de qualquer biblioteca, inclusive esta.

Antes de **publicar**, leia [segurança](security.md), principalmente a parte
sobre o que o BTYN não faz por você.

Quando alguma coisa **não funcionar**, [resolvendo problemas](troubleshooting.md)
lista as falhas na ordem em que as pessoas esbarram nelas.
