---
title: Segurança
lang: pt-br
---

# Segurança

[← Índice](README.md)

## Buffer não é segurança

Serializar em buffer é ofuscação. Torna um dump de RemoteSpy ilegível e eleva o
esforço necessário, e esse é o benefício inteiro. Um exploiter disposto a gastar
uma tarde no seu formato vai decodificá-lo.

Qualquer biblioteca que venda serialização em buffer como recurso de segurança
está te vendendo algo que ela não tem. Incluindo o BTYN — o que vem abaixo é o
que ele realmente entrega.

## O que de fato protege

### O servidor decide

Nada substitui isso. O cliente pede; o servidor manda. Dano, moeda, progressão,
inventário, cooldown — tudo decidido no servidor, a partir de estado do
servidor.

O BTYN torna esse o caminho de menor resistência: um evento `from client` dá ao
cliente `.fire` e só `.fire`. Não existe API para o cliente afirmar estado. Mas
o design é seu, e nenhum schema consegue impor isso.

### Validação de formato na recepção

Este é o ganho de segurança real e concreto sobre remotes crus, e não é pequeno.
Todo campo é validado antes do seu código rodar:

- **Limites** — um pacote que afirma ser maior do que o batch em que chegou é
  rejeitado
- **Faixas** — `u8(0..100)` rejeita 200 na chegada, não depois de chegar na sua
  fórmula de dano
- **Tamanhos** — `string(24)` e `[u16; 100]` rejeitam qualquer coisa maior,
  então não existe alocação ilimitada vinda de um remetente hostil
- **Finitude** — `NaN` e infinito são rejeitados em todo float, incluindo os
  componentes de um `vec3` e a posição de um `cframe`, o que fecha a rota
  clássica de envenenar um cálculo de física ou de economia
- **Enums** — um índice fora das variantes declaradas é rejeitado
- **Direções** — um `unit` é normalizado na chegada. A codificação crua permite
  um vetor de magnitude 1,73, que um hitscan confiando no nome do tipo
  transformaria em 73% de alcance extra
- **Instances** — um campo `Instance` é verificado como sendo mesmo uma. O array
  lateral que as carrega é controlado por quem envia, e nada mais impede um
  cliente de colocar uma string ou uma tabela onde o seu tipo diz `Instance`
- **Tamanho do batch** — um batch com mais de `max_packets_per_batch` pacotes
  (256 por padrão) é recusado. O menor pacote é um único byte de opcode, então
  sem esse teto um payload vira dezenas de milhares de chamadas de handler em um
  frame — uma amplificação que os rate limits por pacote não enxergam, porque só
  são alcançados depois que o trabalho já foi feito
- **Canais** — um pacote precisa chegar pelo remote que o schema declara. Os dois
  remotes alimentam a mesma tabela de despacho, então sem isso um cliente poderia
  mandar qualquer coisa por qualquer um deles e se servir dos dois throttles do
  motor

Limites são obrigatórios no schema exatamente por isso. Uma `string` sem limite
não é conveniência, é primitiva de amplificação, então o BTYN faz disso um erro
de compilação em vez de um padrão.

Junto, isso elimina uma classe inteira de ataque: payload malformado, string
gigante, array ilimitado, envenenamento por `NaN` e amplificação de batch. É a
maior diferença genuína de segurança entre um transporte validado por schema e
remotes escritos à mão.

O que ele **não** valida é `entity`. Esse tipo é um `u32` puro nomeando algo que
o seu jogo possui, e só o seu jogo sabe quais ids um determinado jogador pode
nomear — veja o exemplo de handler mais abaixo.

### Rate limiting

```btyn
event Attack from client rate 10 { target: entity }
```

Um token bucket por jogador por pacote, aplicado no lado que recebe. Sem isso,
um único cliente consome o orçamento de ~500 requisições/segundo do motor e
degrada o servidor para todo mundo.

Um pacote acima do orçamento é descartado e reportado — nunca enfileirado,
porque enfileirar um remetente abusivo só move o custo para um lugar menos
visível.

O rate precisa ser maior que zero. Um bucket que nunca reabastece entregaria a
rajada inicial e depois recusaria o pacote para sempre, o que parece o evento
estar quebrado em vez do limite que é, então isso é erro de compilação.

Deixar `rate` de fora de um pacote enviado pelo cliente é um **aviso** de
compilação. Ele ainda compila — um schema em andamento tem todo direito de estar
incompleto — mas é o único item da checklist abaixo que o compilador consegue
verificar por você, então ele verifica.

```luau
Net.onAbuse(function(player, reason)
    warn(`{player}: {reason}`)
end)
```

`onAbuse` também dispara em falha de validação. No servidor isso significa que
um cliente mandou algo que o schema não permite, o que um cliente honesto não
consegue fazer — o mesmo compilador escreveu os dois lados. É um sinal forte,
vale logar e vale agir.

### Superfície menor

Dois remotes para o jogo inteiro, chamados `R` e `U`, em vez de oitenta com
nomes prestativos. Um exploiter enumerando remotes não aprende nada com os
nomes, e não há endpoint por funcionalidade para sondar isoladamente.

O módulo do cliente também carrega só a própria metade do protocolo — sem leitor
para pacotes que o servidor nunca manda para ele, sem escritor para pacotes que
ele nunca envia.

### A separação do próprio motor

`UnreliableRemoteEvent` tem throttle interno próprio, separado do caminho
confiável. Abuso do canal unreliable não derruba a replicação geral junto —
outro motivo para manter tráfego cosmético em `unreliable` e tráfego com
consequência em `event`.

### Respostas são presas ao seu par

Um `request` do servidor carrega um id de correlação, e o registro que guarda
esses ids é compartilhado por todos os jogadores do servidor. Uma resposta só é
aceita do jogador para quem o request foi de fato enviado. Sem esse vínculo, e
sendo os ids sequenciais, qualquer cliente poderia responder — ou varrer todos os
ids às cegas e responder — uma pergunta que o servidor fez a outra pessoa.

Uma resposta forjada é descartada tão silenciosamente quanto uma atrasada. Um
atacante não aprende nada com a diferença.

## Handlers rodam na própria thread

Seu handler é retomado numa thread nova, e não em linha na varredura do batch.
Um erro em um handler não descarta o resto do batch nem é reportado como abuso de
quem enviou, e um handler que cede não trava os pacotes atrás dele.

O preço é que dois handlers do mesmo batch não têm ordem de conclusão se o
primeiro ceder. Se um par de pacotes só é seguro em sequência — um carregamento e
sua liberação — valide antes de ceder, ou carregue a ordem no payload em vez de
depender da chegada.

## O que o BTYN não faz por você

O schema garante que `amount` é um `u16` na faixa que você declarou. Só você
pode garantir que aquele jogador podia causar aquele dano, naquele alvo, naquela
distância, fora daquele cooldown, naquele estado de jogo.

Validação semântica é a parte que de fato impede trapaça, e ela mora nos seus
handlers:

```luau
Net.Attack.on(function(player, data)
    -- O schema provou o formato. Tudo abaixo é com você.
    local attacker = characterOf(player)
    if not attacker then return end
    if not onCooldown:ready(player) then return end

    local target = entities[data.target]
    if not target then return end
    if (target.position - attacker.position).Magnitude > MAX_REACH then return end

    applyDamage(target, weaponDamage(player))   -- estado do servidor, nunca enviado
end)
```

Repare na última linha: o número do dano vem do estado do servidor, não do
pacote. Se um valor pode ser derivado no servidor, ele não deveria estar no fio
— um campo que não existe não pode ser forjado.

## Checklist

- [ ] Toda decisão com consequência é tomada no servidor, a partir de estado do servidor
- [ ] Valores que o servidor pode derivar não são enviados pelo cliente
- [ ] Pacotes cliente → servidor têm `rate` (o compilador avisa quando não têm)
- [ ] Todo id `entity` tem existência e posse verificadas antes de ser usado
- [ ] `onAbuse` está ligado ao seu log
- [ ] Faixas são declaradas (`u8(0..100)`) em vez de deixadas largas
- [ ] Limites são tão apertados quanto o dado real, não só o suficiente para compilar
- [ ] Handlers validam posse, distância, cooldown e estado de jogo
- [ ] `write_checks` está ligado, ou desligado de propósito e com motivo

---

Próximo: [referência do schema](schema.md) · [API](api.md) · [performance](performance.md)
