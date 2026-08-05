<img src="assets/logo.svg" width="78" align="right" alt="">

# BTYN

[English](README.md) · [Português](README.pt-BR.md) · [Español](README.es.md) · **中文**

[![CI](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml/badge.svg)](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-8570FF)](LICENSE)

一个面向 Roblox 的网络编译器。你写 schema，它为这个 schema 生成两端最快且正确的 Luau。

**[文档 →](https://ocauapaz.github.io/BTYN/)**

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
-- 服务端
Net.Attack.on(function(player, data)
    -- data.target: number, data.combo: number, data.heavy: boolean
end)

Net.Muzzle.all({ at = origin, dir = facing })

local health = Net.Health.of(entityId)
health.set({ hp = 80 })
health.audience(playersInRange)
```

```luau
-- 客户端
Net.Attack.fire({ target = id, combo = 2, heavy = false })
Net.Muzzle.on(function(data) spawnFlash(data.at, data.dir) end)
Net.Health.on(function(id, state) updateBar(id, state.hp) end)
```

## 为什么

Roblox 每个客户端大约只有 50 KB/s，超过就会限流**整个**复制流程；每次 remote 调用
还要付出约 9 字节的包头；而超出大小的 `UnreliableRemoteEvent` 负载会被静默丢弃。
公认的做法是：一个可靠 remote 加一个不可靠 remote，按帧打包，手写 `buffer` 序列化。
这确实有效，但繁琐且容易出错。

BTYN 就是这个做法的自动生成版本。整个游戏只用两个 remote。同一帧的数据包合并为一次
发送。每个字段都由针对其确切类型编写的编解码器打包，运行时不需要再遍历 schema。

### 编译器相比运行时 schema 的优势

| | |
|---|---|
| **常量偏移** | 固定大小的包会编译成一串 `buffer.writeu32(b, o + 4, v.target)`。没有游标变量，没有逐字段的类型分派。 |
| **布尔位打包** | 32 个标志位合并为一次 `u32` 写入，而不是 32 次字节写入。 |
| **一次边界检查** | 大小已知，因此整个包在入口处校验一次，而不是逐字段校验。 |
| **真正的类型** | Luau 没有 mapped types，所以基于表的 schema **无法**推导出自己的负载类型。而编译器直接写出 `export type Attack = { target: number, ... }`。 |
| **超限在构建期报错** | 编译器知道每个包的最坏情况大小；当 `unreliable` 装不下负载上限时直接构建失败，而不是让引擎在线上悄悄丢包。 |

### 现有库没有做的事

- **兴趣管理（Interest management）。** Channel 携带显式的接收者集合。最省的包是
  根本不发送的包；新加入接收者集合的玩家会自动收到一个关键帧。
- **优先级预算。** 每个 channel 声明优先级。当某个客户端超出每帧字节预算时，低优先级
  的增量会被推迟并合并；不会丢失任何内容，也永远不会触发限流。
- **一次序列化的广播。** 经过筛选的广播只编码一次，然后 memcpy 到每个接收者的批次中。
- **强制上限。** 没有上限的 `string` 或数组是编译错误，而不是默认行为。无界输入正是
  一个数据包变成放大攻击原语的方式。

## 快速开始

需要 [Rojo](https://rojo.space) 和 [Lune](https://lune-org.github.io/docs)，两者都在
`rokit.toml` 中固定了版本：

```bash
rokit install
```

把 `src/` 作为名为 `BTYN` 的模块放进你的游戏，写好 schema，然后编译：

```bash
lune run cli/main -- net.btyn
```

不写出任何文件地检查它 —— 大小、opcode，以及你最大的 unreliable 包离上限还有多远：

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

加上 `--watch` 可在保存时自动重新编译。

## 编辑器支持

一个 [VS Code 扩展](editors/vscode/)，提供语法高亮、上下文感知的自动补全、显示每个类型
线上开销的悬浮提示，以及来自编译器本身的实时诊断：

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## 安全性

Buffer 是混淆，不是安全措施。它只能让 RemoteSpy 的输出难以阅读，仅此而已；一个愿意花
一下午的攻击者就能解出你的格式。

真正保护你的是**由服务端做决定**，而不是客户端。BTYN 保证到达数据的**形状** —— 类型、
范围、长度、是否有限 —— 这消除了一整类攻击：畸形负载、超长字符串、无界数组、用 `NaN`
污染物理或经济计算。它无法保证某个玩家有资格在那个距离、那个冷却之外造成那次伤害。
那部分归你负责。

[阅读安全指南 →](https://ocauapaz.github.io/BTYN/en/security)

## 测试

除了那两个 RemoteEvent，其余全是纯 Luau，因此系统的绝大部分都可以在无引擎环境下测试
—— 包括生成的代码本身，它会被真正加载并做往返验证，而不只是被检视。

```bash
lune run tests/run      # 编译器与编解码器
lune run bench/run      # 编解码吞吐量与线上大小
```

需要引擎实际运行的部分由 [Studio 集成测试](tests/studio/)覆盖：它验证 25 个数据包只用
2 次 remote 发送、channel 增量为 7 B 而关键帧为 9 B，并且每一项线上大小都与 `--check`
的预测一致。

## 状态

已完成：事件（可靠与不可靠）、request、带增量编码与兴趣管理的 channel、按玩家的限流、
[schema 参考](https://ocauapaz.github.io/BTYN/en/schema)中的全部类型、`--watch`，以及
VS Code 扩展。

尚未完成：roblox-ts 的 `.d.ts` 输出和 Studio 插件。`typescript = true` 会让构建失败，
而不是静默地什么都不生成。

## 许可证

[MIT](LICENSE)
