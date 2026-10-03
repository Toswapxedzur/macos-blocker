# Mac Vault 코드 설명서

[사용자 설명서](../manual/ko.md)

## 규칙 계약

소스는 함수 표현식 `(on, v) => { ... }` 하나입니다. 동기 JavaScript와 아래 API만 지원합니다. 타이머, 네트워크, native system API, 브라우저 페이지 접근은 허용되지 않습니다. 시간 기반 규칙은 `ev.now`와 이벤트를 사용합니다. 브라우저 규칙은 브라우저 확장 프로그램 코드 설명서를 사용합니다.

- 편집하면 초안이 저장됩니다. **Run**은 규칙을 활성화하고 그룹을 켭니다. 동결된 그룹은 Run할 수 없습니다. 빈 소스는 규칙을 언로드합니다.
- Run에 성공하면 핸들러/패널을 바꾸고 이 그룹의 앱 차단 집합을 지우면서 `v.state`를 보존합니다. 컴파일/등록 실패 시 이전 규칙이 남고 timeout으로 중지될 수 있습니다. 재시작하면 마지막 활성 소스를 등록하고 클로저 변수 및 앱 차단 집합을 초기화합니다.
- 등록 시 state 초기화, 핸들러 등록, 패널 표시, 로그 기록을 할 수 있습니다. 앱/파일 작업과 emit은 핸들러 안에 둡니다. 등록 중 대기열은 폐기됩니다.
- Disable은 핸들러를 억제하고 패널/앱 차단을 해제합니다. Enable은 로드된 규칙과 유지된 패널/차단을 재개합니다. Delete는 핸들러/state/효과를 제거합니다. 종료된 앱을 다시 열지 않으며 파일 쓰기도 되돌리지 않습니다.
- 이벤트는 일반 그룹 대상에 제한되지 않습니다. 규칙에서 앱을 선택하세요. 작업은 대기열에 들어간 뒤 dispatch 후 적용됩니다. 예외는 해당 핸들러를 중지하지만 state/작업은 롤백되지 않고 다음 핸들러는 실행될 수 있습니다. 결과 이벤트가 있는 것은 파일 작업뿐입니다.

## API

- `on(type, handler)` → boolean. `handler(ev)`를 등록합니다. 여러 핸들러는 등록 순서대로 실행됩니다. false는 인수 오류 또는 핸들러 한도 초과를 뜻합니다. `ev = { type: string, now: number, data }`; `now`는 Unix 밀리초입니다.
- `v.state`: 이벤트 dispatch 후 저장되는 변경 가능한 JSON 객체입니다. 기존 state를 덮어쓰지 말고 없는 필드를 초기화하세요. 객체가 아닌 값/배열을 지정하면 `{}`로 초기화됩니다. 직렬화 불가/과도한 업데이트는 저장되지 않습니다.
- `v.log(...values)`: 이 그룹 Log의 유일한 생성자입니다. Logs/Clear는 그룹별로 독립적입니다. 로드 오류는 Run 상태에 나타나고 핸들러 진단은 Log를 채우지 않습니다.
- `v.emit(type, data)`: 현재 이벤트 후 `data` JSON 사본을 새 `now`와 함께을 그룹 핸들러에 대기시킵니다. 동기 호출이 아닙니다.
- `v.panel(id, spec)`: 그룹의 이름 있는 부동 패널을 바꿉니다. null `spec`은 제거합니다. Panels를 참조하세요.
- `v.file(op, path, payload?)` → 요청 ID 문자열. Files를 참조하세요.
- `v.block(appId, on)`: true는 앱 차단을 유지하고 false는 이 그룹의 차단을 제거합니다. 활성 그룹 사이에 차단은 결합되며 다른 그룹의 대상은 해제할 수 없습니다. 차단은 일반 종료를 요청하고 설정 간격으로 다시 시도합니다. 프로세스 시작을 막거나 앱이 Quit을 수락한다고 보장하지 않습니다.
- `v.quit(appId)`: 동일한 보호/재시도 정책을 따르는 일반 종료 요청 한 번이며 지속 차단은 아닙니다.
- `v.open(appId)`: macOS에 설치된 앱을 열도록 요청합니다. 성공 callback은 없습니다.

다른 호출은 `undefined`를 반환합니다. 앱 ID는 bundle identifier(예: `com.valvesoftware.steam`)이며 이벤트에서 제공됩니다. Block/Quit은 `com.apple.*`, 브라우저, Vault와 도우미, 빈 ID를 무시합니다. 패널 ID/state는 표시 이름이 아니라 그룹에 속합니다.

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

## 한도

이벤트/그룹별 대기 작업 256개, log 호출 200회, emit 64회이며 초과분은 버립니다. 규칙당 handler 1000개, panel 24개, 컨트롤 목록당 32개 항목, 선택지당 64개 옵션까지입니다. 초과분은 무시/잘립니다. Emit 연결은 16세대에서 멈춥니다. 직렬화 state 한도는 JavaScript 문자열 65536자입니다. 등록과 각 이벤트의 전체 handler를 1초 미만으로 유지하세요. 반복 초과나 강제 timeout은 Run할 때까지 규칙을 멈춥니다. Log는 그룹당 200개를 보관합니다. 시간/응답은 최선 노력이며 실시간 보장은 아닙니다.

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
