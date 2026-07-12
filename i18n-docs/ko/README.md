# 맥 볼트

Mac Vault는 Vault 제품군의 기본 macOS 구성원입니다. Swift 정책 엔진, WebView 편집기, 기본 애플리케이션 인벤토리 및 적용 어댑터, 사용자 정의 규칙 지원 및 로컬 웹 앱 브리지 허브를 결합합니다.

현재 코드가 진실의 원천입니다. 영어 인앱 참조는 [Sources/MacBlockerWebUI/WebAssets/manual/en.md](Sources/MacBlockerWebUI/WebAssets/manual/en.md)입니다.

## 구현된 내용

- 선택된 macOS 애플리케이션에 대한 기본 그룹 및 고급 정책 규칙에 대한 사용자 정의 그룹.
- 즉시, 허용, 카운트다운 차단 모드.
- 일정, 고정 모드, 흐름 일시 중지, 가져오기/내보내기 및 영구 그룹 상태.
- 애플리케이션 인벤토리, 장치 제어 권한 상태, 기본 적용 어댑터 및 부동 상태 표면.
- 로깅 및 구문 검사 기능을 갖춘 제어된 JavaScript 정책 런타임입니다.
- 명시적으로 연결된 호환 그룹을 위한 루프백 WebSocket 브리지 허브입니다.
- Vault 제품군과 동일한 핵심 그룹 모델을 사용하는 WebView 편집기입니다.

## 개발

Swift 패키지 테스트를 실행합니다.

```bash
swift test
```

패키지에는 핵심 정책, 일정, 사용자 지정 규칙, 브리지, 가져오기 및 macOS 제어 테스트가 포함되어 있습니다.

## Xcode 프로젝트

선택적 Xcode 프로젝트는 [XcodeProject/project.yml](XcodeProject/project.yml)에서 생성됩니다.

```bash
cd XcodeProject
./generate.sh
```

서명 또는 배포 대상을 구성하기 전에 [XcodeProject/README.md](XcodeProject/README.md)를 읽어보세요.

## 문서화 정책

영어 문서는 표준으로 남아 있습니다. 편집기 UI에는 완전한 로케일 카탈로그가 있고 번역된 매뉴얼은 `WebAssets/manual/en.md` 옆에 있으며 나머지 유지 관리 문서의 번역된 사본은 `i18n-docs/<locale>/` 아래에 있습니다.

법적 조건과 개인정보 보호정책은 별도의 법적 문서로 유지됩니다. 이 README는 이를 대체하지 않습니다.
