# UsageBar

Claude Code + Codex 사용량을 맥 상태바에서 추적하는 앱. 단기(5h) / 장기(주간) 한도를
남은 사용량 기준으로 보여주고, 그래프와 알림을 띄운다.

상태바 표시: `C 52%  X 0%🐢` — Claude 남은 52%, Codex 0% + 아껴쓰기 권고.

## 설치 (다운로드한 경우)

`UsageBar.zip` 하나만 받으면 된다. Apple Silicon / Intel 둘 다 동작 (universal binary).

```bash
unzip UsageBar.zip
mv UsageBar.app /Applications/
xattr -dr com.apple.quarantine /Applications/UsageBar.app   # 아래 설명 참고
open /Applications/UsageBar.app
```

**`xattr` 줄이 왜 필요한가**: 이 앱은 Apple Developer ID 서명/notarization이 없다
(ad-hoc 서명). 그래서 다운로드하면 Gatekeeper가 실행을 막는다 (`spctl: rejected`).
위 명령이 다운로드 격리 속성을 지운다. 명령줄을 쓰기 싫으면 앱을 한 번 실행 시도한 뒤
시스템 설정 > 개인정보 보호 및 보안 > **"확인 없이 열기"** 를 눌러도 된다.

첫 알림 발송 시 macOS가 알림 권한을 물어볼 수 있다.

## 무엇을 읽는가

| 대상 | 방법 |
|---|---|
| Claude 사용량 | 로그인 키체인의 `Claude Code-credentials` 토큰으로 `api.anthropic.com/api/oauth/usage` 호출 |
| Codex 사용량 | `~/.codex/sessions/**/*.jsonl` 최신 `rate_limits` 이벤트 읽기 (로컬 파일만) |

Claude 토큰은 `/usr/bin/security`로 읽고 Anthropic 사용량 API 호출에만 쓴다. 다른 곳으로
전송하지 않는다. Codex는 네트워크 호출 없음 — `chatgpt.com/backend-api`가 비브라우저
클라이언트를 차단하므로 codex가 마지막으로 실행된 시점의 파일 기록을 쓴다.

로그인 안 된 도구는 그냥 표시되지 않는다.

## 기능

- 60초 주기 갱신 (Codex는 로컬 파일이라 매번, Claude는 API 부하 때문에 5분 주기)
- Claude usage API는 자체 rate limit이 있음. 429가 나면 5분 → 10분 → ... 최대 1시간까지
  지수 백오프하고, 그동안 마지막 측정값을 계속 보여준다. `새로고침` 버튼은 백오프를 무시하고
  즉시 재시도
- **단기/장기 한도** 별도 표시 (남은 % + 리셋까지 남은 시간), 30% 이하 주황 / 10% 이하 빨강
- **남은 사용량 추이 그래프** — 값이 바뀔 때만 기록, 최대 2880개 샘플
  (`~/Library/Application Support/UsageBar/history.json`)
- **⚡ 팍팍 쓰기**: 단기 한도 50% 이상 남았는데 1시간 내 리셋 → 지금 쓰라고 알림
- **🐢 아껴 쓰기**: 장기 한도 25% 이하 남았고 48시간 넘게 리셋 안 됨 → 아끼라고 알림
  (장기 부족이 단기 여유보다 우선)
- **로그인 시 자동 실행** 토글 (`SMAppService`). 앱을 옮기면 다시 켜야 한다

임계값은 `UsageBar.swift`의 `enum Thresholds`에서 조정.

## 업데이트

앱이 1시간마다 GitHub 최신 릴리스를 확인한다. 새 버전이 있으면 메뉴 맨 위에
`⬆ 새 버전 x.y 있음 · 받기` 줄이 뜨고, 누르면 릴리스 페이지가 열린다. 현재 버전은
메뉴 하단 `갱신 시각 · vX.Y` 에 있다.

받은 사람은 zip 을 내려받아 기존 앱을 교체한다 (앱 종료 → unzip → `/Applications` 덮어쓰기
→ `xattr -dr com.apple.quarantine` → 실행). 자동 설치는 하지 않는다 — ad-hoc 서명이라
서명 검증 없이 자기 번들을 덮어쓰는 구조가 되기 때문.

배포하는 쪽:

```bash
./build.sh dist 1.1
gh release create v1.1 UsageBar.zip -R docbab/PhErols- -t v1.1 --generate-notes
```

버전은 `CFBundleShortVersionString` 에 그대로 박히고, 태그의 `v` 접두사는 비교 시 벗겨진다.
릴리스 확인은 토큰 없이 호출하므로 **레포가 public 이어야 한다**. 레포 슬러그는
`UsageBar.swift` 의 `releasesRepo` 상수.

## 직접 빌드

```bash
./build.sh              # UsageBar.app 생성 + 셀프테스트 (버전 0.0)
./build.sh dist 1.1     # 위 + 버전 박아서 UsageBar.zip 생성
```

Xcode 프로젝트 없음. 소스는 `UsageBar.swift` 한 파일. `mkicon.swift`는 아이콘
(`AppIcon.icns`) 생성용이며 빌드에 관여하지 않는다.

CLI 옵션: `--selftest`, `--login on|off|status`.
