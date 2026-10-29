# Mac Vault 코드 설명서

[사용자 설명서](../manual/ko.md)

## 규칙 계약

소스는 함수 표현식 `(on, v) => { ... }` 하나입니다. 동기 JavaScript와 아래 API만 지원합니다. JavaScript 예약 실행 콜백, 네트워크, 네이티브 시스템 API, 브라우저 페이지 접근은 허용되지 않습니다. 시간 기반 규칙은 아래의 관리형 타이머/추적기 또는 `ev.now`와 이벤트를 사용합니다. 브라우저 규칙은 브라우저 확장 프로그램 코드 설명서를 사용합니다.

- 편집하면 초안이 저장됩니다. **Run**은 규칙을 활성화하고 그룹을 켭니다. 동결된 그룹은 Run할 수 없습니다. 빈 소스는 규칙을 언로드합니다.
- Run에 성공하면 핸들러/패널을 바꾸고 이 그룹의 앱 차단 집합을 지우면서 `v.state`를 보존합니다. 컴파일/등록 실패 시 이전 규칙이 남고 timeout으로 중지될 수 있습니다. 재시작하면 마지막 활성 소스를 등록하고 클로저 변수 및 앱 차단 집합을 초기화합니다.
- 등록 시 state 초기화, 핸들러 등록, 패널 표시, 로그 기록을 할 수 있습니다. 앱/파일 작업과 emit은 핸들러 안에 둡니다. 등록 중 대기열은 폐기됩니다.
- Disable은 핸들러를 억제하고 패널/앱 차단을 해제합니다. Enable은 로드된 규칙과 유지된 패널/차단을 재개합니다. Delete는 핸들러/state/효과를 제거합니다. 종료된 앱을 다시 열지 않으며 파일 쓰기도 되돌리지 않습니다.
- 이벤트는 일반 그룹 대상에 제한되지 않습니다. 규칙에서 앱을 선택하세요. 작업은 대기열에 들어간 뒤 dispatch 후 적용됩니다. 예외는 해당 핸들러를 중지하지만 state/작업은 롤백되지 않고 다음 핸들러는 실행될 수 있습니다. 결과 이벤트가 있는 것은 파일 작업뿐입니다.

## 관리형 타이머와 이동 구간 사용량

`v.timer(id, {direction:"down", durationMs:300000})`는 이름 있는 카운트다운을 만들거나 기존 것을 반환하며, 처음에는 일시정지 상태입니다. 카운트업 타이머에는 `{direction:"up"}`을 사용합니다. 핸들은 `start()`, `pause()`, `resume()`, `reset()`, `snapshot()`을 제공합니다. 시작/재개는 여러 번 호출해도 효과가 같으며, 초기화하면 경과 시간이 0인 일시정지 상태로 돌아갑니다. 스냅샷 필드에는 `ready`, `error`, `elapsedMs`, `remainingMs`(카운트업은 null), `running`, `completed`가 있습니다.

실행 중인 타이머는 앱/브라우저가 닫히거나 규칙이 비활성화되어도 실제 시간에 따라 진행됩니다. 완료된 카운트다운은 각 구성원의 규칙이 다음에 실행될 때 타이머 인스턴스와 세대별로 한 번씩 `timerEnded`를 `{id, direction, durationMs, generation, incarnation}`과 함께 전달합니다. Run은 이를 다시 전달하지 않습니다. 전달은 호스트 이벤트에 달려 있으며 실시간 알람이 아닙니다. 패널에 `{type:"timer", timerId:"focus", label:"Focus"}`를 넣으면 기존 텍스트 컨트롤을 통해 표시할 수 있습니다.

`v.rolling(id, {windowMs:3600000, limitMs:600000})`는 이름 있는 실제 사용 추적기를 만들거나 기존 것을 반환합니다. `assign({websites:["youtube.com","reddit.com"], apps:[]})`는 이 구성원의 대상 할당을 교체합니다. 네이티브 규칙은 대신 플랫폼 앱 ID를 할당할 수 있습니다. 도메인은 하위 도메인을 포함합니다. 한 추적기는 대상들의 사용량을 합산하며, 다른 ID는 독립적인 허용량을 가집니다. `snapshot()`은 `ready`, `error`, `usedMs`, `remainingMs`, `available`, `nextReturnAtMs`(기록된 사용량 중 일부가 다음에 만료되는 밀리초 시각)를 반환합니다. `available(target?)`는 대상이 주어지면 할당 여부도 확인합니다. `reset()`은 이 객체의 기록을 지웁니다.

조건에 맞는 관측된 사용량은 허용량 초과분까지 모두 계산됩니다. 추적기 자체는 페이지/앱을 차단하지 않습니다. 겹치는 표시 페이지 시간 구간은 한 번만 계산하며, 네이티브 앱은 관측된 전경 사용량을 계산합니다. 비활성화된 규칙은 사용량을 추가하지 않지만 기록은 정확한 구간 경계에서 계속 만료됩니다. 남은 기록이 제한보다 적어져야 다시 사용할 수 있습니다. 하트비트 표본은 최대 5초로 제한됩니다. 종료/비활성화 동안의 공백은 활동을 만들어 내지 않습니다. 사용자가 발생시킨 이벤트는 사용량을 추가하지 않습니다.

연결된 사용자 지정 그룹의 같은 객체 ID는 하나의 로컬 네이티브 허브를 권한 주체로 공유합니다. 연결하면 추적기 기록과 할당을 합치고 연결을 시작한 쪽의 타이머 상태를 유지합니다. 호환되지 않는 구성은 연결을 거부합니다. 각 구성원은 자신의 완료 이벤트를 받습니다. 접속이 끊어지면 공유 추적기를 사용할 수 없고 최신 권한 주체가 돌아올 때까지 타이머 제어가 거부됩니다. 연결을 해제하면 각 구성원은 최종 공유 사용량과 타이머 상태를 유지하고, 자신의 대상을 복원하며, 이전 연결의 명령을 버립니다. 허브는 돌아온 구성원이 최종 스냅샷을 저장하고 확인 응답할 때까지 보관합니다. 새 연결을 사용할 수 있게 되기 전에 대기 중인 인계를 완료합니다.

이름 있는 객체는 예약된 `v.state.$vaultTime`에 보관되어 Run과 재시작 후에도 유지됩니다. 이 필드를 직접 수정하지 마세요. 명시적으로 제거하려면 `v.removeTime(id)`를 사용합니다. ID는 1~80자의 ASCII 영문자, 숫자, `_` 또는 `-`이며 예약된 속성 이름은 거부됩니다. 최대 32개 객체가 규칙의 64 KiB UTF-8 상태 제한을 공유합니다. 기간은 최대 365일의 정수 밀리초입니다. 이동 구간 기록은 1024개 분 단위 버킷과 2048개 병합 구간으로 제한됩니다. 기록 용량 오류가 나면 명시적으로 초기화할 때까지 추적기를 사용할 수 없습니다. 잘못된 구성과 초과 크기 저장은 오류를 보고하며 저장된 데이터를 지우지 않습니다.

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

- `on(type, handler)` → boolean. `handler(ev)`를 등록합니다. 여러 핸들러는 등록 순서대로 실행됩니다. false는 인수 오류 또는 핸들러 한도 초과를 뜻합니다. `ev = { type: string, now: number, data }`; `now`는 Unix 밀리초입니다.
- `v.state`: 이벤트 dispatch 후 저장되는 변경 가능한 JSON 객체입니다. 기존 state를 덮어쓰지 말고 없는 필드를 초기화하세요. 객체가 아닌 값/배열을 지정하면 `{}`로 초기화됩니다. 직렬화 불가/과도한 업데이트는 저장되지 않습니다.
- `v.log(...values)`: 이 그룹의 Log에 추가합니다. 실행 및 전달 실패는 같은 피드에 명시적인 오류 항목으로 표시됩니다. Logs/Clear는 그룹별로 독립적입니다. 로드 오류는 Run 상태에도 표시됩니다. 일부 실행된 이벤트는 자동으로 다시 실행되지 않습니다.
- `v.emit(type, data)`: 현재 이벤트 후 `data` JSON 사본을 새 `now`와 함께을 그룹 핸들러에 대기시킵니다. 동기 호출이 아닙니다.
- `v.panel(id, spec)`: 그룹의 이름 있는 부동 패널을 바꿉니다. null `spec`은 제거합니다. Panels를 참조하세요.
- `v.file(op, path, payload?)` → 요청 ID 문자열. Files를 참조하세요.
- `v.block(appId, on)`: true는 앱 차단을 유지하고 false는 이 그룹의 차단을 제거합니다. 활성 그룹 사이에 차단은 결합되며 다른 그룹의 대상은 해제할 수 없습니다. 차단은 일반 종료를 요청하고 설정 간격으로 다시 시도합니다. 프로세스 시작을 막거나 앱이 Quit을 수락한다고 보장하지 않습니다.
- `v.quit(appId)`: 동일한 보호/재시도 정책을 따르는 일반 종료 요청 한 번이며 지속 차단은 아닙니다.
- `v.open(appId)`: macOS에 설치된 앱을 열도록 요청합니다. 성공 callback은 없습니다.

다른 호출은 `undefined`를 반환합니다. 앱 ID는 이벤트에서 확인할 수 있는 bundle identifier(예: `com.valvesoftware.steam`)입니다. Block/Quit은 Apple 앱과 브라우저 전체를 대상으로 지정할 수 있습니다. Mac Vault의 bundle identifier와 도우미, 같은 ID를 공유하는 다른 앱, 빈 ID는 무시합니다. 패널 ID/state는 표시 이름이 아니라 하나의 그룹에 속합니다.

## 이벤트

아래 payload 표기법은 유형을 설명하며 실행 가능한 코드가 아닙니다. `?`는 선택적 필드를 나타냅니다.

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

- `tick`은 근사값입니다. tick 수가 아니라 타임스탬프를 쓰세요. Running에는 bundle ID가 있는 foreground, 메뉴 막대, background `.app` 프로세스가 포함되며 모든 Unix 프로세스가 포함되는 것은 아닙니다. Frontmost는 null 또는 빈 앱 ID일 수 있습니다.
- `app`은 해당 tick의 `tick` 이벤트 전 관찰된 수명 주기 변경을 보고합니다. focus만 `previousAppId`를 포함합니다(알 수 없으면 null). 이름은 표시 이름이며 안정 ID가 아닙니다.
- `snooze`는 그룹의 Snooze 버튼을 눌렀다는 뜻입니다. 자체적으로 일시 중지하지 않습니다.
- 파일 응답은 요청한 그룹에 돌아갑니다. `requestId`를 맞추고 `ok`를 확인하며 tick으로 기한을 설정하세요. 규칙을 다시 불러오거나 비활성화하면 응답이 사라질 수 있습니다. Run 후 ID가 반복될 수 있으며 대기 요청은 영구 작업이 아닙니다.

## 패널

```text
spec = { title?: string, description?: string, controls?: Control[],
         position?: "top-left" | "top-right" | "bottom-left" | "bottom-right" | "center",
         width?: "small" | "medium" | "large" | number }
Control = { id?: string, type?: string, label?: string, value?, disabled?: boolean,
            ...type-specific fields below }
```

기본값: 오른쪽 아래, 너비 300px. small/medium/large는 220/280/360px이며 숫자 너비는 180–520px로 제한되고 pixel 문자열을 받습니다. Native 패널/섹션은 컨트롤을 세로로 쌓습니다. 브라우저 layout, alignment, role, autofocus, 컨트롤 크기 필드는 native renderer에 영향을 주지 않습니다.

ID는 ASCII 영문/숫자/`_`/`-`로 정규화됩니다(최대 80). 고유하고 안정적인 ID를 고르세요. 생략된 컨트롤 ID는 `control-N`, 생략/알 수 없는 유형은 text입니다. 생략 텍스트/목록은 비어 있고 disabled는 false입니다. 각 호출은 전체 spec을 바꿉니다. 명시한 `value`는 저장된 입력을 덮어쓰며 생략한 값은 마지막 이벤트 값을 사용한 뒤 유형에 맞게 정규화합니다. Native 이벤트 값은 문자열이므로 업데이트 패널을 렌더링하기 전에 선언된 유형으로 파싱하세요. 알 수 없는 필드는 버리고 패널 색/글꼴/CSS는 Vault가 관리합니다.

컨트롤 필드와 초기값:

- `text`: `text` 문자열, 기본값은 label입니다. `html`: `html` 문자열을 정리해 Mac에서 일반 텍스트로 표시합니다.
- `button`: `label`, 선택적 `action: "submit" | "cancel" | "close"`. 클릭 값은 action 문자열 또는 빈 값입니다. 자동 전송/닫기를 하지 않습니다.
- `checkbox`, `toggle`: 불리언 `value`(기본 false); 이벤트 값은 `"true"`/`"false"`입니다.
- `select`, `radio`: `options: (string | { value: string, label?: string })[]`; 문자열 value(기본 빈 값). 빈 옵션 값은 제거되고 label 기본값은 value입니다. 선택 후 타입이 지정된 패널 값을 업데이트하세요.
- `textInput`, `textarea`: 문자열 value(기본 빈 값), textInput의 `placeholder`, textarea `rows` 1–12(기본 3). Native textarea는 placeholder를 무시합니다.
- `numberInput`, `range`: 숫자 value(기본 0), `min`, `max`, 양수 `step`. 패널 업데이트 시 범위 안으로 제한됩니다. 지정하지 않은 정규화 범위는 −1000000…1000000입니다. Native numberInput은 텍스트 입력이므로 `Number(event.value)`를 직접 검증하세요. min/max/step은 입력을 제한하지 않습니다. Native range 기본값은 0…100, step 1입니다.
- `date`, `time`: 텍스트 입력; 초기값 형식은 `YYYY-MM-DD`, `HH:MM`/`HH:MM:SS`(잘못되면 빈 값). 수정값은 직접 검증하세요. `color`: `#RRGGBB`(기본 `#000000`).
- `pin`: 숫자 문자열; `length` 3–12(기본 6), `masked` 기본 true, `autoSubmit` false. `section`: `text`, `controls`; depth 3의 자식 section에는 자식이 없습니다(root control depth 0).

패널 이벤트: 일반 입력은 `change`, 버튼은 `click`만 보내며 PIN은 `change`와 autoSubmit 입력 완료 시 `submit`을 보냅니다. Native mount/unmount/focus/key 이벤트는 없습니다. 숫자/불리언을 포함해 값은 문자열입니다. `values`에는 렌더된 snapshot의 입력값이 있으며 트리거한 편집보다 늦을 수 있습니다. `value`는 해당 편집 값입니다. 안정적인 폼을 위해 `v.state`에 저장하고 타입이 지정된 값을 렌더링하세요. 클릭 이외 이벤트는 컨트롤마다 100ms 안에 합쳐집니다. 이벤트 수를 키 입력 수로 세지 마세요.

텍스트 한도: title/label 240, description/text 1000, HTML 20000, placeholder 500, 입력 텍스트 2000, 기타 value 문자열 512, option value/label 256자. 초과분은 잘립니다.

## 파일

`op`: `"read"`, `"write"`, `"append"`, `"list"`, `"exists"`. 설정의 **사용자 지정 규칙 폴더**와 권한이 필요합니다.

- `path`는 상대 경로이며 `/`가 디렉터리를 구분합니다. ASCII 영문/숫자, 공백, `_.,@()-`를 허용합니다. 선행 점, `.`/`..`, 절대 경로, URL은 안 됩니다. 파일 접미사는 `.txt`, `.csv`, `.json`(대소문자 무관)입니다. List 경로는 디렉터리이며 `""`는 선택한 루트입니다. 심볼릭 링크 경유를 포함해 선택 폴더 밖 경로는 거부됩니다.
- Read는 UTF-8 텍스트를 반환합니다. Write는 교체/생성, append는 자동 개행 없이 추가/생성합니다. 쓸 때 상위 디렉터리가 만들어집니다. 문자열 payload는 그대로 쓰고 다른 JSON payload는 직렬화합니다. null/생략은 빈 텍스트입니다. JSON/CSV 파싱은 규칙에서 해야 합니다. 최대 크기 1048576 UTF-8바이트.
- List는 바로 아래 보이는 하위 디렉터리와 지원 파일을 반환합니다. 항목: `{ name: string, path: string, kind: "directory" | "file", extension?: string }`; 파일의 extension에는 점이 있습니다. Exists는 지원되는 파일 경로의 불리언을 반환합니다.

```text
file.data = { requestId: string, op: string, path: string, ok: boolean,
              text: string | null, entries: Entry[] | null,
              exists: boolean | null, error: string }
```

사용하지 않은 결과 필드는 null이며 성공 시 error는 빈 값입니다. 실패에는 invalid-path, unsupported-file-type, 폴더 사용 불가, 파일 없음, file-too-large가 포함됩니다. error는 고정된 전체 enum이 아니라 문자열입니다. 트랜잭션 API가 없으므로 경로별 read-modify-write를 직렬화하세요.

## 그룹 레코드

`v.store(request)`는 handler 안에서 비동기 JSON 레코드 작업을 시작합니다. 레코드는 그룹 전용이며 Run 및 재시작 후에도 유지되고 그룹을 삭제하면 제거됩니다. 연결된 그룹은 별도 store를 사용합니다. 키, 값, 버전, 캐시 무효화, 피드백 우선순위는 규칙이 결정합니다. Mac과 브라우저 규칙은 같은 API를 쓰지만 앱/브라우저별 저장소는 분리됩니다.

| Request | Result |
|---|---|
| `{op:"get", key}` | `record` 또는 `null` |
| `{op:"put", key, value, version?, ifRevision?}` | 저장된 `record` |
| `{op:"delete", key, ifRevision?}` | `record: null` |
| `{op:"list", prefix?, after?, limit?}` | 정렬된 `entries`와 `next` |
| `{op:"clear", prefix?}` | `deleted` 개수 |

레코드는 `{value, revision, version, updatedAt}`입니다. 불투명한 `revision`은 실제 쓰기 시 바뀌며 `version`은 호출자가 관리하는 메타데이터입니다. `list`는 값 없는 헤더를 돌려줍니다. 하나를 읽으려면 `get`, 다음 페이지는 `after: next`를 사용하세요. `ifRevision` 생략 시 put/delete는 무조건 실행됩니다. `null`은 키가 없어야 하고 revision 문자열은 정확히 일치해야 합니다. 불일치 시 `ok:false`, `error:"store-conflict"`, 현재 `record`가 반환됩니다. 지연된 자동 응답이 사용자 피드백을 덮어쓰지 않게 합니다. `v.context.revision`은 규칙 버전에 포함할 수 있는 불투명한 설정 마커입니다. 프레임워크는 캐시 정책을 강제하지 않습니다.

제한: 키 1–2048자, version ≤128, JSON 값 ≤64KiB, depth ≤32, 그룹당 10000개 키, 전체 문서16MiB. `list`는 페이지당 최대100개 헤더와96KiB를 반환합니다. 그룹당 최대32개 요청, 전체 초당128개 시작입니다. 과부하 시 그룹별 초당 하나의 `store-busy` 오류를 알리고 나머지는 버립니다. 저장 오류는 `ok:false`를 반환합니다. 미래 형식/손상 문서는 보존하고 `store-unavailable`을 알립니다. 자동 재시도나 제거는 없습니다. deadline에는 ticks를 사용하세요.

## 한도

이벤트/그룹별로 대기 작업 256개, log 호출 200회, emit 64회이며 초과분은 버립니다. 규칙별로 핸들러 1000개, 패널 24개이며 각 컨트롤 목록은 항목 32개, 각 선택 컨트롤은 선택지 64개까지 지원합니다. 초과분은 무시하거나 잘라냅니다. emit 체인은 16세대 후 중단됩니다. 직렬화된 상태 제한은 UTF-8 65536바이트입니다. 등록과 각 이벤트의 전체 핸들러 실행 시간을 1초 미만으로 유지하세요. 반복 초과나 강제 시간 초과가 발생하면 Run을 누를 때까지 규칙을 중지합니다. Log는 그룹별로 항목 200개를 보관합니다. 시간 처리/응답은 최선의 노력으로 처리되며 실시간을 보장하지 않습니다.

## 완성된 규칙

Snooze 또는 패널 버튼으로 시작되는 5분 일시 중지 중에만 Steam이 차단 해제됩니다:

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

## 실행 중인 규칙의 AI 호출

각 custom group은 **AI calls**에서 connection/model과 reasoning effort를 선택합니다. Mac과 브라우저 규칙은 같은 API를 사용합니다. 브라우저 요청은 Mac Vault 연결이 필요하며 provider 자격 증명은 그곳에 유지됩니다. 연결된 그룹은 선택 및 선택적 일일 요청 한도를 공유합니다. 빈 값은 그룹 한도 없음이며 계정 제한은 계속 적용됩니다. 한도는 UTC 날짜 기준이고 재시작 후 유지되며 실패를 포함한 제출 시도를 셉니다. Link는 기존 사용량을 합치고 Unlink 후에도 이전 사용량을 유지합니다.

`v.ai({ prompt, input? })`는 즉시 request ID를 반환합니다. 규칙 등록이 아니라 handler 안에서 호출하세요. `input`은 모든 JSON 값이며 prompt/input 각각 최대20KB입니다. 응답은 `ai` 이벤트 `{requestId, ok, text, citations, error}`로 옵니다. 성공 텍스트 최대48KB, citation은 `{url,title}`입니다. 웹 검색 답변을 표시할 때 출처 링크를 보이고 클릭 가능하게 유지하세요. 검색은 모델에 항상 제공됩니다. 앱의 고정 deadline은 없고 동시성은 제한됩니다. provider 대체나 자동 재시도는 없습니다. 응답은 데이터이며 JavaScript로 실행되지 않습니다. 기존 동작을 할지는 규칙이 결정합니다.

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

대기 중 호출은 재시작 후 재생되지 않습니다. Run, 비활성화/재활성화, 삭제는 오래된 응답을 버립니다. 연결이 끊긴 브라우저는 `ai-unavailable`을 보고합니다. 다른 오류: `ai-not-configured`, `ai-invalid-input`, `ai-busy`, `ai-daily-limit`, `ai-request-failed`, `ai-usage-storage-unavailable`. 실패 호출은 규칙이 유지하기로 한 이전 결과를 덮어쓰지 않습니다. 규칙 state 한도는64KB입니다.

자격 증명 없는 선택지는 Mac의 `rule_ai_models` 또는 브라우저의 `settings-rule-ai-models`로 확인하고 기존 set-group 경로에서 `ruleAI`를 설정합니다. 필드: `providerModel`, `accountID`, `reasoningEffort` (`default`, `low`, `medium`, `high`), `dailyRequestLimit` (null 또는1–100000). 반환된 선택지를 사용하고 규칙 소스에 키나 provider URL을 넣지 마세요.
