---
title: Compilador e editor
lang: pt-br
---

# O compilador

[← Índice da documentação](README.md)

Um argumento, um schema:

```bash
lune run cli/main -- net.btyn
```

Os caminhos de saída ficam no bloco `config` do próprio schema, não na linha de
comando, então o schema continua sendo a única fonte de verdade e o comando
nunca muda conforme o projeto cresce.

```
btyn: wrote src/Server/Net.luau
btyn: wrote src/Client/Net.luau
```

Diretórios que faltam nesses caminhos são criados. Os dois arquivos são
reescritos a cada execução — são saída de build, então coloque no `.gitignore`,
a menos que seu time prefira revisar diff de código gerado.

## Flags

| Flag | Efeito |
|---|---|
| *(nenhuma)* | Compila e escreve os dois módulos |
| `--check` | Valida e reporta tamanhos, não escreve nada |
| `--watch` | Recompila sempre que o schema muda |
| `--json` | Diagnósticos e dados de pacote legíveis por máquina, não escreve nada |
| `--help`, `-h` | Uso |

`--check` e `--watch` combinam: `--watch --check` reporta os tamanhos de novo a
cada save sem tocar na sua árvore de código.

### `--check`

A flag certa para saber quanto um schema custa antes de se comprometer com ele.

```bash
lune run cli/main -- net.btyn --check
```

```
btyn: net.btyn is valid — 9 packet(s), 1 byte opcodes

  [0    ] Aim            unreliable     client -> server  4 B  rate 120/s
  [2    ] Attack         event          client -> server  6 B  rate 10/s
  [3,4  ] Buy            request        client -> server  3 B -> 6-70 B  rate 4/s
  [7,8  ] Health         channel/high   server -> client  3 B

  largest unreliable packet: 19 B of the 800 B cap
```

Como ler: os números entre colchetes são opcodes — um request e um channel usam
dois cada, um para a resposta ou para a remoção. Um tamanho único é pacote fixo;
um intervalo significa que uma string ou array faz o tamanho variar, e é o valor
de cima que é conferido contra o limite de `unreliable`.

A última linha é a que importa acompanhar. É a distância entre o seu maior
pacote unreliable e o tamanho a partir do qual o motor passa a descartá-lo sem
avisar.

### `--watch`

Fica de olho no schema e recompila quando ele muda. Deixe rodando ao lado do
`rojo serve` e os módulos gerados acompanham o schema a cada save.

```bash
lune run cli/main -- net.btyn --watch
```

Uma compilação com erro imprime o erro e continua observando, então um typo não
custa o loop. Editores que apagam e recriam o arquivo ao salvar são tratados — o
watcher espera o arquivo voltar em vez de encerrar.

### `--json`

Para editores e ferramentas. Nunca escreve arquivos, e sempre sai com `0`, então
quem chama nunca precisa tratar schema quebrado como caso especial.

```bash
lune run cli/main -- net.btyn --json
```

```json
{
  "ok": true,
  "diagnostics": [],
  "warnings": [
    {
      "severity": "warning",
      "message": "'Aim' is sent by the client and has no rate limit",
      "label": "no `rate` here",
      "help": "add `rate <n>` — ...",
      "line": 52,
      "column": 12,
      "length": 3
    }
  ],
  "packets": [
    { "name": "Attack", "kind": "event", "from": "client", "opcode": 2,
      "size": 6, "maxSize": 6, "fixed": true, "rate": 10, "line": 30 }
  ],
  "opcodeBytes": 1,
  "unreliableCap": 800,
  "budget": 40000
}
```

`line` e `column` começam em 1, que é o que editores esperam receber. Consuma
isso em vez de tentar reinterpretar a saída bonita — aquela saída existe para
humanos e pode mudar de formato a qualquer momento.

## Erros e avisos

Um **erro** interrompe o build e não escreve nada:

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

O analisador junta todos os erros que consegue antes de parar, então uma
execução conta todos de uma vez em vez de fazer você corrigir um por um. O
parser é a exceção: uma vez que o fluxo de tokens está errado, toda mensagem
seguinte é invenção, então ele para no primeiro erro de sintaxe.

Um **aviso** é impresso e o build continua:

```
warning: 'Aim' is sent by the client and has no rate limit
  --> net.btyn:52:12
   |
52 | unreliable Aim from client {
   |            ^^^ no `rate` here
   |
help: add `rate <n>` — without one a single client can send this as fast as it
      likes, and only the batch ceiling of 256 packets stands in the way
```

Faltar `rate` num pacote enviado pelo cliente é o único item da
[checklist de segurança](security.md#checklist) que o compilador consegue
verificar por você, então ele verifica. Um schema ainda em construção tem todo
direito de estar incompleto, e é por isso que não quebra o build.

## Códigos de saída

| Código | Quando |
|---|---|
| `0` | Compilou, ou `--check` passou, ou **qualquer** execução com `--json` |
| `1` | Erros, ou o arquivo de schema não existe |

Em CI, `--check` é o comando certo: quebra o build num schema ruim sem produzir
arquivos que ninguém vai commitar.

```yaml
- name: Validate the schema
  run: lune run cli/main -- net.btyn --check
```

# Suporte a editor

A [extensão do VS Code](https://github.com/ocauapaz/BTYN/tree/main/editors/vscode)
cobre arquivos `.btyn`:

- **Highlight** de declarações, tipos, modificadores e comentários
- **Autocomplete** que sabe onde está — palavras-chave de declaração no topo,
  tipos depois de um `:`, chaves de config dentro de um bloco `config`
- **Hover** mostrando o custo em bytes de cada tipo e o porquê
- **Diagnósticos ao vivo** vindos do próprio compilador, então o sublinhado é
  exatamente o que o build vai dizer

Ela não está no Marketplace. Empacote e instale a partir do repositório:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## Configurações

| Configuração | Padrão | Significado |
|---|---|---|
| `btyn.diagnostics.enabled` | `true` | Roda o compilador enquanto você digita |
| `btyn.lunePath` | `lune` | Caminho do executável do Lune |
| `btyn.compilerPath` | *(vazio)* | Caminho do `cli/main.luau`; vazio procura o mais próximo acima do arquivo aberto |

Os diagnósticos chamam `lune run <compilador> -- <arquivo> --json`, com debounce
para digitar não disparar um compilador por tecla. Se o sublinhado nunca
aparece, é esse comando que vale rodar na mão — na maioria das vezes o Lune não
está no `PATH`, o que `btyn.lunePath` resolve.

A extensão não precisa de configuração num checkout normal: ela sobe a partir do
arquivo aberto até encontrar `cli/main.luau`.

---

Próximo: [resolvendo problemas](troubleshooting.md) · [referência de schema](schema.md) · [API](api.md)
