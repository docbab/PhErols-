<!--
`./build.sh dist <version>` 이 이 파일의 {{VERSION}} 을 치환해 release-notes.md 로 내보낸다.
아래 "바뀐 것" 목록만 손으로 채운 뒤 publish 하면 된다.

  ./build.sh dist 1.4
  $EDITOR release-notes.md          # 바뀐 것 채우기
  gh release create v1.4 UsageBar.zip -R docbab/PhErols- -t v1.4 --latest --notes-file release-notes.md
-->

## 바뀐 것

- TODO

## 설치

아래 `Assets`에서 **`UsageBar.zip`** 을 받고, 터미널에서 아래를 통째로 붙여넣으세요.

```bash
cd ~/Downloads
rm -rf UsageBar.app
ditto -x -k UsageBar.zip .
xattr -dr com.apple.quarantine UsageBar.app
rm -rf /Applications/UsageBar.app
mv UsageBar.app /Applications/
open /Applications/UsageBar.app
```

Apple Silicon / Intel 모두 동작합니다 (universal binary). macOS 14 이상.

실행 중이던 이전 버전은 알아서 종료되니 따로 끄지 않아도 됩니다.

### 왜 이 명령이 필요한가

이 앱은 Apple Developer ID 서명 / notarization이 없어서(ad-hoc 서명), 다운로드하면 Gatekeeper가 실행을 막습니다. `xattr` 줄이 다운로드 격리 속성을 지웁니다. **`/Applications`로 옮기기 전에** 지우는 것이 중요합니다.

Finder로 압축을 풀면 격리 속성이 하위 파일에 다시 붙는 경우가 있어 `ditto`로 풉니다.

### 이미 차단 메시지를 봤다면

**"확인할 수 없습니다" / "악성 소프트웨어가 없는지 확인할 수 없습니다"**
→ 앱을 한 번 실행 시도한 뒤 `시스템 설정 > 개인정보 보호 및 보안` 에서 아래로 스크롤 → **"그래도 열기"**

**"손상되었기 때문에 열 수 없습니다"**
→ 설정에 버튼이 나오지 않습니다. 위 설치 명령을 처음부터 다시 실행하세요.

## 확인

메뉴바에 `C 52%  X 31%` 같은 표시가 뜨면 정상입니다. 메뉴를 열면 하단에 현재 버전(`v{{VERSION}}`)이 보입니다.

로그인 안 된 도구는 표시되지 않습니다. Claude는 `claude` 로그인, Codex는 `codex`를 한 번 이상 실행한 기록이 있어야 합니다. 둘 다 없으면 표시가 `—` 입니다.

터미널로 확인:

```bash
pgrep -fl UsageBar                                               # 실행 중인지
/Applications/UsageBar.app/Contents/MacOS/UsageBar --checkupdate  # 버전 확인
```

**실행은 되는데 메뉴바에 안 보이는 경우**: 메뉴바가 꽉 찼을 가능성이 높습니다. 노치가 있는 MacBook은 공간이 부족하면 macOS가 아이콘을 조용히 숨깁니다. 다른 메뉴바 앱을 몇 개 끄거나 Ice / Bartender 같은 정리 도구를 쓰세요.

**로그인 시 자동 실행**을 쓰던 분은 교체 후 메뉴에서 체크를 껐다 켜주세요. macOS가 앱 경로로 등록하기 때문에 번들을 교체하면 재등록이 필요합니다.
