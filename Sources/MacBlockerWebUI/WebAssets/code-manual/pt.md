# Manual de código Mac Vault

[Manual do usuário](../manual/pt.md)

## Contrato da regra

Source: uma expressão de função `(on, v) => { ... }`. Apenas JavaScript síncrono e a API abaixo são compatíveis; não há callbacks de agendamento JavaScript, acesso à rede, APIs nativas do sistema nem acesso a páginas do navegador. Regras temporais usam os temporizadores/rastreadores gerenciados abaixo, ou `ev.now` e eventos. Regras do Safari usam o manual de código do navegador e são executadas no próprio app contêiner do Safari Vault.

- A edição salva um rascunho; **Run** ativa a regra e habilita o grupo. Grupos congelados não podem executar Run. Source vazio descarrega a regra.
- Um Run bem-sucedido substitui handlers/panels e limpa o app-block set deste grupo, preservando `v.state`. Falha de compilação/inscrição mantém a regra anterior; um timeout pode interrompê-la. Restart registra novamente a última source ativada; closure variables e app-block sets são redefinidos.
- A inscrição pode inicializar state, registrar handlers, exibir panels e gravar logs. Ações de app/arquivo e emits pertencem aos handlers; a fila da inscrição é descartada.
- Disable suspende handlers e remove panels/app blocks. Enable restaura a regra carregada e os panels/blocks retidos. Delete remove handlers/state/effects. Apps encerrados anteriormente não são reabertos; gravações de arquivos não são desfeitas.
- Events não se restringem aos alvos comuns do grupo; selecione os apps na regra. Actions entram em fila e são aplicadas após dispatch. Exceptions interrompem aquele handler sem reverter seu state/actions; handlers posteriores podem continuar. Somente ações de arquivo têm result events.

## Temporizadores gerenciados e uso em janela móvel

`v.timer(id, {direction:"down", durationMs:300000})` cria ou retorna uma contagem regressiva com nome, inicialmente pausada. Use `{direction:"up"}` para um temporizador de contagem crescente. O objeto oferece `start()`, `pause()`, `resume()`, `reset()` e `snapshot()`. Iniciar/retomar são idempotentes; redefinir deixa o temporizador pausado com zero tempo decorrido. Os campos do snapshot incluem `ready`, `error`, `elapsedMs`, `remainingMs` (null para contagem crescente), `running` e `completed`.

Os temporizadores em execução avançam de acordo com o tempo real decorrido enquanto o app/navegador está fechado ou a regra está desabilitada. Uma contagem regressiva concluída entrega `timerEnded` com `{id, direction, durationMs, generation, incarnation}` uma vez por encarnação e geração do temporizador para cada membro quando sua regra volta a executar; Run não repete o evento. A entrega depende dos eventos do host; não é um alarme em tempo real. Coloque `{type:"timer", timerId:"focus", label:"Focus"}` em um painel para exibi-lo pelo controle de texto existente.

`v.rolling(id, {windowMs:3600000, limitMs:600000})` cria ou retorna um rastreador com nome de uso ativo. `assign({websites:["youtube.com","reddit.com"], apps:[]})` substitui as atribuições de alvos deste membro. Regras nativas podem atribuir identificadores de apps da plataforma em vez disso. Os domínios incluem subdomínios. Um rastreador reúne seus alvos; outros identificadores têm cotas independentes. `snapshot()` retorna `ready`, `error`, `usedMs`, `remainingMs`, `available` e `nextReturnAtMs` (o próximo milissegundo em que algum uso registrado expira). `available(target?)` também verifica a atribuição quando um alvo é fornecido. `reset()` limpa o histórico deste objeto.

Todo uso elegível observado conta, inclusive o que ultrapassa a cota; o rastreador em si não bloqueia páginas/apps. Intervalos sobrepostos de páginas visíveis contam uma vez, e apps nativos contam o uso observado em primeiro plano. Regras desabilitadas não adicionam uso; o histórico continua expirando nos limites exatos dos intervalos. A disponibilidade só retorna quando o histórico restante fica abaixo do limite. As amostras periódicas são limitadas a cinco segundos; lacunas por encerramento ou desabilitação não geram atividade. Eventos emitidos pelo usuário não adicionam uso.

Os mesmos identificadores de objeto em grupos personalizados vinculados compartilham uma única autoridade local no hub nativo. A vinculação combina o histórico e as atribuições dos rastreadores e mantém o estado do temporizador que iniciou a vinculação; configurações incompatíveis impedem a vinculação. Cada membro recebe seu próprio evento de conclusão. A desconexão deixa os rastreadores compartilhados indisponíveis e rejeita os comandos dos temporizadores até que uma autoridade atualizada volte a estar disponível. Ao desvincular, cada membro mantém o uso compartilhado final e o estado do temporizador, restaura seus próprios alvos e descarta os comandos do vínculo antigo. O hub mantém o snapshot final até que o membro que retorna o salve e confirme o recebimento; as transferências pendentes terminam antes que um novo vínculo fique disponível.

Os objetos com nome sobrevivem a Run e à reinicialização no campo reservado `v.state.$vaultTime`; não edite esse campo diretamente. Remova-os explicitamente com `v.removeTime(id)`. Os identificadores contêm de 1 a 80 letras ASCII, dígitos, `_` ou `-`; nomes de propriedades reservados são rejeitados. Até 32 objetos compartilham o limite de estado da regra de 64 KiB em UTF-8. As durações são milissegundos inteiros de até 365 dias. O histórico móvel é limitado a 1024 blocos de um minuto e 2048 intervalos mesclados. Erros de capacidade do histórico deixam o rastreador indisponível até uma redefinição explícita; configurações inválidas e salvamentos grandes demais relatam erros sem apagar os dados salvos.

```js
(on, v) => {
  const timer = v.timer("focus", {durationMs: 300000});
  v.panel("focus", {controls: [
    {type: "timer", timerId: "focus", label: "Focus"},
    {id: "start", type: "button", label: "Start"},
    {id: "pause", type: "button", label: "Pause"},
    {id: "reset", type: "button", label: "Reset"}
  ]});
  on("panel", ev => {
    if (ev.data.eventName !== "click") return;
    if (ev.data.controlId === "start") timer.start();
    if (ev.data.controlId === "pause") timer.pause();
    if (ev.data.controlId === "reset") timer.reset();
  });
  on("timerEnded", ev => v.log("Finished", ev.data.id));
}
```

## API

- `on(type, handler)` → boolean. Registra `handler(ev)`; vários handlers executam na ordem de inscrição. False indica argumentos inválidos ou limite de handlers atingido. `ev = { type: string, now: number, data }`; `now` é Unix em milissegundos.
- `v.state`: objeto JSON mutável, salvo depois do event dispatch. Inicialize fields ausentes em vez de sobrescrever o state atual. Atribuir non-object ou array redefine para `{}`; atualizações não serializáveis/grandes demais não são salvas.
- `v.log(...values)`: adiciona entradas ao Log deste grupo. Falhas de execução e entrega aparecem como entradas de erro explícitas no mesmo fluxo. Logs/Clear são independentes por grupo. Erros de carregamento também aparecem no status Run; eventos parcialmente executados não são repetidos automaticamente.
- `v.emit(type, data)`: coloca uma cópia JSON de `data` na fila de handlers deste grupo após o event atual, com novo `now`; não é chamada síncrona.
- `v.panel(id, spec)`: substitui o panel flutuante nomeado deste grupo; `spec` null o remove. Consulte Panels.
- `v.file(op, path, payload?)` → string request ID. Consulte Files.
- `v.block(appId, on)`: true mantém o bloqueio de um app; false remove o bloqueio deste grupo. Bloqueios de grupos habilitados se combinam; a chamada não pode desbloquear o alvo de outro grupo. O bloqueio solicita um encerramento normal e tenta novamente no intervalo de Settings; não impede a inicialização do processo nem garante que o app aceite Quit.
- `v.quit(appId)`: uma solicitação normal de encerramento, sob a mesma política de proteção/tentativa; sem bloqueio contínuo.
- `v.open(appId)`: pede ao macOS para abrir um app instalado; sem callback de sucesso.

Outras chamadas retornam `undefined`. Os identificadores de apps são identificadores de bundle (por exemplo, `com.valvesoftware.steam`), disponíveis em eventos. Block/Quit podem ter como alvo apps da Apple e navegadores inteiros. Eles ignoram o identificador de bundle do Mac Vault e seus helpers, incluindo qualquer outro app que compartilhe essa identidade, além de IDs vazios. Panel IDs/state pertencem ao grupo, não ao nome exibido.

## Eventos

A notação de payload abaixo descreve os tipos; não é código executável. `?` indica fields opcionais.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
record: { requestId: string, ok: boolean, op?: string, key?: string,
          record?: Record | null, entries?: Header[], next?: string | null,
          deleted?: number, error?: string }
App = { appId: string, name: string }
```

- `tick` é aproximado; use timestamps, não contagem de ticks. Running inclui processos `.app` foreground, menu-bar e background com bundle IDs; não inclui todo processo Unix. Frontmost pode ser null ou ter app ID vazio.
- `app` relata mudanças de ciclo de vida observadas antes do event `tick` daquele tick. Somente focus inclui `previousAppId` (null se desconhecido). Nomes são nomes de exibição, não IDs estáveis.
- `snooze` significa que o botão Snooze do grupo foi pressionado. Ele não aplica pausa por si só.
- Respostas de arquivo vão para o grupo solicitante. Associe `requestId`, verifique `ok` e defina um deadline usando ticks: respostas podem se perder se a regra recarregar/for desativada. Request IDs podem se repetir após Run; requests pendentes não são trabalho duradouro.

## Painéis

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

Padrão: posição no canto inferior direito, largura 300px; presets small/medium/large de 220/280/360px; largura numérica limitada a 180–520px e que aceita pixel strings. Panels/sections native empilham controls verticalmente; browser layout, alignment, role, autofocus e campos control-dimension não afetam o native renderer.

IDs são normalizados para ASCII letters/digits/`_`/`-` (máx. 80); escolha IDs únicos e estáveis. Control ID omitido vira `control-N`; type omitido/desconhecido vira text. text/lists omitidos ficam vazios; disabled é false. Cada chamada substitui a spec inteira. `value` explícito prevalece; se omitido, usa o event value mais recente e aplica a normalização do type. Native events fornecem strings: analise-as no value type declarado antes de renderizar o panel atualizado. Fields desconhecidos são descartados; cores/fonts/CSS do panel pertencem ao Vault.

Campos e valores iniciais dos controles:

- `text`: string `text`; padrão igual ao label. `html`: string `html`, sanitizado e exibido como texto simples no Mac.
- `button`: `label`, `action: "submit" | "cancel" | "close"` opcional. O valor de click é a string action ou vazio. Actions não enviam/fecham nada automaticamente.
- `checkbox`, `toggle`: boolean `value` (padrão false); o event value é `"true"`/`"false"`.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; string value (padrão vazio). Values de opções vazios são removidos; labels usam value por padrão. Atualize o value tipado do panel após a seleção.
- `textInput`, `textarea`: string value (padrão vazio); textInput `placeholder`; textarea `rows` 1–12 (padrão 3). Textarea native ignora placeholder.
- `numberInput`, `range`: numeric value (padrão 0), `min`, `max`, `step` positivo. Em atualizações do panel os values ficam nos limites; limites de normalização omitidos são −1000000…1000000. numberInput native é entrada de texto: valide `Number(event.value)`; min/max/step não restringem a digitação. Range native padrão de 0…100 com step 1.
- `date`, `time`: entrada de texto; formats iniciais `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS` (formats inválidos ficam vazios). Valide alterações manualmente. `color`: `#RRGGBB` (padrão `#000000`).
- `pin`: string de dígitos; `length` 3–12 (padrão 6), `masked` true por padrão, `autoSubmit` false. `section`: `text`, `controls`; child sections no depth 3 não têm children (root controls depth 0).

Panel events: entradas comuns enviam `change`; buttons somente `click`; PIN envia `change` e `submit` quando autoSubmit é preenchido. Não há native mount/unmount/focus/key events. Values são strings, incluindo numbers/booleans. `values` contém os inputs do snapshot renderizado e pode ficar atrás da edição que disparou o evento; `value` identifica essa edição. Salve em `v.state` e renderize values tipados para forms confiáveis. Non-click events são agrupados em até 100ms por control; não conte events como teclas pressionadas.

Limites de texto: title/label 240; description/text 1000; HTML 20000; placeholder 500; input text 2000; outras value strings 512; option value/label 256. O excesso é truncado.

## Arquivos

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. Requer **Pasta de regras personalizadas** em Settings e sua permissão.

- `path` é relativo; `/` separa directories. Segmentos permitem ASCII letters/digits, espaços e `_.,@()-`; sem ponto inicial, `.`/`..`, absolute path ou URL. Extensões: `.txt`, `.csv`, `.json` (sem diferenciar maiúsculas/minúsculas). List path é um directory; `""` lista a root escolhida. Paths que saem da pasta escolhida, inclusive por symlinks, são rejeitados.
- Read retorna texto UTF-8. Write substitui/cria; append cria/anexa sem newline automático. Diretórios pais são criados nas gravações. String payload é gravado literalmente; outros payloads JSON são serializados; null/omitido significa texto vazio. Interpretar JSON/CSV é responsabilidade da regra. Tamanho máximo: 1048576 UTF-8 bytes.
- List retorna subdirectories e arquivos compatíveis imediatamente visíveis. Entries: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; extension de arquivos inclui o ponto. Exists retorna boolean para file path compatível.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

result fields não usados são null; sucesso tem error vazio. Falhas incluem invalid-path, unsupported-file-type, pasta indisponível, arquivo ausente e file-too-large. Trate error como string, não um enum fixo e completo. Não há transaction API; serialize operações read-modify-write por path.

## Registros do grupo

`v.store(request)` inicia uma operação assíncrona de registro JSON dentro de um handler. Os registros são privados do grupo, persistem após Run e reinicialização e são removidos com o grupo. Grupos vinculados têm stores separados. A regra escolhe chaves, valores, versões, invalidação de cache e prioridade do feedback. Regras Mac e navegador usam a mesma API, mas cada app/navegador possui store próprio.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` ou `null` |
| `{op:"put", key, value, version?, ifRevision?}` | `record` salvo |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | `entries` ordenadas e `next` |
| `{op:"clear", prefix?}` | contagem `deleted` |

Cada registro é `{value, revision, version, updatedAt}`. A `revision` opaca muda numa gravação real; `version` é metadado do chamador. `list` retorna cabeçalhos sem valores; use `get` para ler e `after: next` para a página seguinte. Sem `ifRevision`, put/delete são incondicionais; `null` exige chave ausente e string de revisão exige correspondência exata. Conflito retorna `ok:false`, `error:"store-conflict"` e o `record` atual, impedindo resposta automática atrasada de substituir feedback do usuário. `v.context.revision` é um marcador opaco de configuração que a regra pode incluir em sua versão. O framework não impõe política de cache.

Limites: chave 1–2048 caracteres, versão ≤128, valor JSON ≤64KiB, profundidade ≤32, 10000 chaves por grupo, documento inteiro16MiB. `list` retorna até100 cabeçalhos e96KiB por página. No máximo32 pedidos por grupo e128 inícios/segundo no total. Sobrecarga informa `store-busy` uma vez por grupo por segundo e descarta os demais. Erros de armazenamento retornam `ok:false`; documento futuro/malformado é preservado e sinaliza `store-unavailable`. Não há retry nem eviction automáticos. Use ticks para prazos.

## Limites

Por evento e grupo: 256 ações em fila, 200 chamadas de log, 64 emissões; o excesso é descartado. Por regra: 1000 handlers, 24 painéis; cada lista de controles tem 32 entradas e cada seleção 64 opções; o excesso é ignorado/truncado. As cadeias de emissões param após 16 gerações. Limite do estado serializado: 65536 bytes UTF-8. Mantenha o registro da regra e os handlers combinados de cada evento abaixo de 1 segundo; excessos repetidos ou um timeout rígido param a regra até Run. O Log mantém 200 entradas por grupo. Tempos/respostas funcionam conforme o melhor esforço, sem garantias de tempo real.

## Regra completa

Steam é bloqueado, exceto durante uma pausa de cinco minutos iniciada pelo Snooze ou por seu botão panel:

```javascript
(on, v) => {
  v.state.pauseUntil ??= 0;
  const pause = ev => { v.state.pauseUntil = ev.now + 300000; };
  v.panel("pause", { controls: [{ id: "pause", type: "button", label: "Pause 5 min" }] });
  on("snooze", pause);
  on("panel", ev => {
    if (ev.data.panelId === "pause" && ev.data.controlId === "pause" && ev.data.eventName === "click") pause(ev);
  });
  on("tick", ev => v.block("com.valvesoftware.steam", ev.now >= v.state.pauseUntil));
}
```

## Chamadas de IA em uma regra em execução

Cada custom group escolhe conexão/modelo e reasoning effort em **AI calls**. Regras Mac e navegador usam a mesma API; pedidos do navegador exigem Mac Vault conectado e as credenciais do provedor ficam lá. Grupos vinculados compartilham seleção e limite diário opcional. Em branco significa sem limite do grupo; limites da conta continuam valendo. O limite usa o dia UTC, persiste após reinício e conta tentativas enviadas, inclusive falhas. Link combina uso existente; unlink mantém o uso anterior.

`v.ai({ prompt, input? })` retorna um request ID imediatamente. Chame dentro de um handler, não ao registrar a regra. `input` pode ser qualquer JSON; prompt/input limitados a20KB cada. Respostas chegam como eventos `ai`: `{requestId, ok, text, citations, error}`. Texto de sucesso até48KB; citations `{url,title}`. Preserve links de fonte visíveis e clicáveis ao exibir respostas da pesquisa Web. Search está sempre disponível ao modelo. Não há prazo fixo do app; concorrência limitada; sem fallback de provedor ou retry automático. Respostas são dados, nunca executadas como JavaScript. A regra decide quais ações existentes tomar.

```javascript
(on, v) => {
  let pending = null;
  on("panel", ({ data }) => {
    if (data.controlId !== "ask" || pending) return;
    pending = v.ai({ prompt: "Summarize this text.", input: data.values?.note ?? "" });
  });
  on("ai", ({ data }) => {
    if (data.requestId !== pending) return;
    pending = null;
    if (!data.ok) { v.log("AI request failed:", data.error); return; }
    v.log(data.text, data.citations);
  });
}
```

Chamadas pendentes não são reproduzidas após reiniciar. Run, desabilitar/habilitar e exclusão descartam respostas antigas; navegador desconectado informa `ai-unavailable`. Outros erros: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. Chamadas falhas não substituem resultado anterior que a regra escolheu manter. O estado da regra continua limitado a64KB.

Descubra opções sem credenciais com `rule_ai_models` no Mac ou `settings-rule-ai-models` no navegador; configure `ruleAI` pelo caminho set-group existente. Campos: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`) e `dailyRequestLimit` (null ou1–100000). Use uma opção retornada; não coloque chave ou URL do provedor no código-fonte.
