<img src="assets/logo.svg" width="78" align="right" alt="">

# BTYN

[English](README.md) · [Português](README.pt-BR.md) · **Español** · [中文](README.zh-CN.md)

[![CI](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml/badge.svg)](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-8570FF)](LICENSE)

Un compilador de networking para Roblox. Tú escribes un esquema; él escribe el
Luau más rápido y correcto para ese esquema exacto, para ambos lados.

**[Documentación →](https://ocauapaz.github.io/BTYN/)**

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

## Por qué

Roblox te da unos 50 KB/s por cliente antes de limitar **toda** la replicación,
cobra alrededor de 9 bytes de cabecera por llamada a un remote, y descarta en
silencio un payload de `UnreliableRemoteEvent` demasiado grande. La respuesta
conocida es un remote confiable más uno no confiable, agrupados por frame, con
serialización manual en `buffer`. Funciona, y es tedioso y fácil de equivocar.

BTYN es esa respuesta, generada. Todo tu juego usa dos remotes. Los paquetes se
agrupan en un solo envío por frame. Cada campo lo empaqueta un códec escrito
para su tipo exacto, sin recorrer un esquema en tiempo de ejecución.

### Lo que compra un compilador frente a un esquema en runtime

| | |
|---|---|
| **Offsets constantes** | Un paquete de tamaño fijo compila a una línea recta de `buffer.writeu32(b, o + 4, v.target)`. Sin variable de cursor, sin dispatch de tipo por campo. |
| **Booleanos empaquetados** | 32 flags se vuelven un solo `u32`, no 32 escrituras de byte. |
| **Una sola verificación de límites** | Los tamaños se conocen, así que el paquete se valida una vez al entrar en lugar de campo por campo. |
| **Tipos reales** | Luau no tiene mapped types, así que un esquema en tabla **no puede** inferir su propio tipo de payload. Un compilador simplemente escribe `export type Attack = { target: number, ... }`. |
| **Exceso detectado al compilar** | El compilador conoce el peor caso de cada paquete y falla la compilación si un `unreliable` no cabe en el límite de payload — en lugar de dejar que el motor lo descarte en producción sin decir nada. |

### Lo que hace y las bibliotecas no

- **Interest management.** Los channels llevan una audiencia explícita. El
  paquete más barato es el que nunca se envía, y quien entra en la audiencia
  recibe un keyframe automáticamente.
- **Presupuesto por prioridad.** Cada channel declara una prioridad. Cuando un
  cliente supera su presupuesto de bytes por frame, los deltas de baja prioridad
  se aplazan y se fusionan; no se pierde nada, y nunca se alcanza el límite.
- **Broadcast serializado una sola vez.** Un broadcast filtrado codifica una vez
  y hace memcpy al lote de cada destinatario.
- **Límites obligatorios.** Un `string` o array sin límite es un error de
  compilación, no un valor por defecto. La entrada sin límite es como un paquete
  se convierte en una primitiva de amplificación.

## Inicio rápido

Requiere [Rojo](https://rojo.space) y [Lune](https://lune-org.github.io/docs),
ambos fijados en `rokit.toml`:

```bash
rokit install
```

Pon `src/` en tu juego como un módulo llamado `BTYN`, escribe un esquema y
compila:

```bash
lune run cli/main -- net.btyn
```

Inspecciónalo sin escribir nada — tamaños, opcodes, y qué tan cerca está tu
paquete unreliable más grande del límite:

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

Añade `--watch` para recompilar al guardar.

## Soporte en el editor

Una [extensión de VS Code](editors/vscode/) con resaltado, autocompletado
consciente del contexto, hover que muestra el coste en bytes de cada tipo, y
diagnósticos en vivo del propio compilador:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## Seguridad

Los buffers son ofuscación, no seguridad. Hacen ilegible un volcado de RemoteSpy
y nada más; un exploiter con una tarde decodifica tu formato.

Lo que realmente te protege es que decida el servidor, no el cliente. BTYN
garantiza la **forma** de lo que llega — tipo, rango, longitud, finitud — lo que
elimina una clase real de ataque: payloads malformados, strings gigantes,
arrays sin límite, `NaN` envenenando un cálculo de física o de economía. No
puede garantizar que ese jugador pudiera causar ese daño, a esa distancia, fuera
de ese cooldown. Esa parte es tuya.

[Lee la guía de seguridad →](https://ocauapaz.github.io/BTYN/en/security)

## Pruebas

Todo excepto los dos RemoteEvents es Luau puro, lo que mantiene la mayor parte
del sistema comprobable sin el motor — incluido el código generado, que se carga
y se somete a un round trip real, no solo se inspecciona.

```bash
lune run tests/run      # compilador y códecs
lune run bench/run      # rendimiento del códec y tamaños en el cable
```

La parte que necesita el motor en marcha la cubre el
[test de integración en Studio](tests/studio/): verifica que 25 paquetes salen
en 2 disparos de remote, que un delta de channel cuesta 7 B frente a un keyframe
de 9 B, y que cada tamaño en el cable cuadra con lo que predice `--check`.

## Estado

Funcionando: eventos (confiables y no confiables), requests, channels con delta
encoding e interest management, rate limiting por jugador, todos los tipos de la
[referencia del esquema](https://ocauapaz.github.io/BTYN/en/schema), `--watch`, y
la extensión de VS Code.

Aún no hecho: salida `.d.ts` para roblox-ts y el plugin de Studio.
`typescript = true` falla la compilación en lugar de no emitir nada en silencio.

## Licencia

[MIT](LICENSE)
