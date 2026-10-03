# Manual de código Mac Vault

[Manual do usuário](../manual/pt.md)

## Contrato da regra

Source: uma expressão de função `(on, v) => { ... }`. Apenas JavaScript síncrono e a API abaixo são compatíveis; não há timers, network, native system APIs nem acesso à página do navegador. Regras temporais usam `ev.now` e events. Regras do Safari usam o manual de código do navegador e são executadas no próprio app contêiner do Safari Vault.

- A edição salva um rascunho; **Run** ativa a regra e habilita o grupo. Grupos congelados não podem executar Run. Source vazio descarrega a regra.
- Um Run bem-sucedido substitui handlers/panels e limpa o app-block set deste grupo, preservando `v.state`. Falha de compilação/inscrição mantém a regra anterior; um timeout pode interrompê-la. Restart registra novamente a última source ativada; closure variables e app-block sets são redefinidos.
- A inscrição pode inicializar state, registrar handlers, exibir panels e gravar logs. Ações de app/arquivo e emits pertencem aos handlers; a fila da inscrição é descartada.
- Disable suspende handlers e remove panels/app blocks. Enable restaura a regra carregada e os panels/blocks retidos. Delete remove handlers/state/effects. Apps encerrados anteriormente não são reabertos; gravações de arquivos não são desfeitas.
- Events não se restringem aos alvos comuns do grupo; selecione os apps na regra. Actions entram em fila e são aplicadas após dispatch. Exceptions interrompem aquele handler sem reverter seu state/actions; handlers posteriores podem continuar. Somente ações de arquivo têm result events.

## API

- `on(type, handler)` → boolean. Registra `handler(ev)`; vários handlers executam na ordem de inscrição. False indica argumentos inválidos ou limite de handlers atingido. `ev = { type: string, now: number, data }`; `now` é Unix em milissegundos.
- `v.state`: objeto JSON mutável, salvo depois do event dispatch. Inicialize fields ausentes em vez de sobrescrever o state atual. Atribuir non-object ou array redefine para `{}`; atualizações não serializáveis/grandes demais não são salvas.
- `v.log(...values)`: único produtor do Log deste grupo. Logs/Clear são independentes por grupo. Erros de carregamento aparecem no status Run; diagnósticos de handlers não preenchem Log.
- `v.emit(type, data)`: coloca uma cópia JSON de `data` na fila de handlers deste grupo após o event atual, com novo `now`; não é chamada síncrona.
- `v.panel(id, spec)`: substitui o panel flutuante nomeado deste grupo; `spec` null o remove. Consulte Panels.
- `v.file(op, path, payload?)` → string request ID. Consulte Files.
- `v.block(appId, on)`: true mantém o bloqueio de um app; false remove o bloqueio deste grupo. Bloqueios de grupos habilitados se combinam; a chamada não pode desbloquear o alvo de outro grupo. O bloqueio solicita um encerramento normal e tenta novamente no intervalo de Settings; não impede a inicialização do processo nem garante que o app aceite Quit.
- `v.quit(appId)`: uma solicitação normal de encerramento, sob a mesma política de proteção/tentativa; sem bloqueio contínuo.
- `v.open(appId)`: pede ao macOS para abrir um app instalado; sem callback de sucesso.

Outras chamadas retornam `undefined`. App IDs são bundle identifiers (por exemplo, `com.valvesoftware.steam`), disponíveis em events. Block/Quit ignoram `com.apple.*`, navegadores, Vault e seus helpers, além de IDs vazios. Panel IDs/state pertencem ao grupo, não ao nome exibido.

## Events

A notação de payload abaixo descreve os tipos; não é código executável. `?` indica fields opcionais.

```text
tick (~1 second): { frontmost: App | null, running: App[] }
app: { kind: "launch" | "quit" | "focus" | "blur" | "hide" | "unhide",
       appId: string, name: string, previousAppId?: string | null }
snooze: {}
panel: { panelId: string, controlId: string, eventName: string,
         value: string, values: { [controlId: string]: string } }
file: see Files
App = { appId: string, name: string }
```

- `tick` é aproximado; use timestamps, não contagem de ticks. Running inclui processos `.app` foreground, menu-bar e background com bundle IDs; não inclui todo processo Unix. Frontmost pode ser null ou ter app ID vazio.
- `app` relata mudanças de ciclo de vida observadas antes do event `tick` daquele tick. Somente focus inclui `previousAppId` (null se desconhecido). Nomes são nomes de exibição, não IDs estáveis.
- `snooze` significa que o botão Snooze do grupo foi pressionado. Ele não aplica pausa por si só.
- Respostas de arquivo vão para o grupo solicitante. Associe `requestId`, verifique `ok` e defina um deadline usando ticks: respostas podem se perder se a regra recarregar/for desativada. Request IDs podem se repetir após Run; requests pendentes não são trabalho duradouro.

## Panels

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

## Files

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

## Limites

Por event por group: 256 queued actions, 200 log calls, 64 emits; excesso é descartado. Por rule: 1000 handlers, 24 panels; cada control list tem 32 entries e cada choice 64 options; excesso é ignorado/truncado. Emit chains param após 16 gerações. Serialized state limit: 65536 JavaScript string characters. Mantenha registration e handlers combinados de cada event abaixo de 1 segundo; excessos repetidos ou hard timeout param a regra até Run. Log mantém 200 entries por grupo. Timing/replies são best-effort, sem garantias real-time.

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
