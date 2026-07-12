# Mac Vault Xcode 프로젝트

`project.yml`은 공유 Swift 패키지를 사용하는 macOS 및 iOS 대상에 대해 체크인된 XcodeGen 사양입니다.

## 프로젝트 생성

```bash
cd XcodeProject
./generate.sh
open macosBlocker.xcodeproj
```

`project.yml`, 대상, 자격 또는 소스 멤버십을 변경한 후 다시 생성합니다. 생성된 프로젝트 파일을 표준 구성으로 사용하지 마십시오.

## 현재 대상 가족

- `AdamanciaVaultMac`은 `MacBlockerAppFeature`이 지원하는 macOS 애플리케이션 대상입니다.
- `macosBlocker`은 iOS 애플리케이션 대상입니다.
- iOS 프로젝트에는 장치 활동, Shield 구성 및 Shield Action 확장이 포함됩니다.

현재 식별자, 배포 대상, 버전 필드 및 기능은 `project.yml` 및 참조된 자격 파일에 정의되어 있습니다. 배포하기 전에 서명 환경에서 검토하세요.

## 서명 및 기능

배포 계정에 속하는 팀 및 번들 식별자를 사용합니다. 구축 중인 대상에 필요한 기능을 확인하세요. 이 저장소에 서명 비밀, 프로비저닝 프로필 또는 계정 자격 증명을 추가하지 마십시오.

## 먼저 테스트해 보세요

아카이브를 생성하기 전에 공유 패키지 테스트를 실행하십시오.

```bash
cd ..
swift test
```
