# 한글 뷰어 (HWP Viewer)

Claude 채팅 등에서 받은 **한글 문서(`.hwp`, `.hwpx`)를 iPhone · iPad · Mac에서 바로 열어 보는** 읽기 전용 뷰어입니다.

- **HWP 5.x**(바이너리) / **HWPX**(OWPML) 모두 지원. 확장자가 아니라 파일 내용으로 형식을 판별합니다.
- 문단 서식(정렬·여백·들여쓰기·줄 간격), 글자 서식(글꼴·크기·굵게·기울임·밑줄·취소선·색·형광펜), **표**(셀 병합·테두리·배경색), **그림**, 글상자 표시
- **쪽 보기**(원본 용지 모양) / **읽기 모드**(화면 폭에 맞춰 재배치) 전환
- **PDF로 저장**, **인쇄**, 확대/축소, 텍스트 선택·복사, iPhone/iPad에서는 문서 내 검색
- 외부 라이브러리 없음, 네트워크 사용 없음 — 문서는 기기 밖으로 나가지 않습니다.

설치 방법은 **[docs/설치가이드.md](docs/설치가이드.md)** 를 보세요.

## 구조

```
App/                      SwiftUI 앱 (iOS 16+ / macOS 13+ 단일 타깃)
  HWPViewerApp.swift        DocumentGroup(viewing:) 문서 앱
  HWPFileDocument.swift     파일 → HWPKit 파싱
  DocumentView.swift        WKWebView 표시, 보기 전환, PDF/인쇄 메뉴
  Info.plist                .hwp/.hwpx 형식 등록 (파일 앱 · 공유 시트 연동)
Packages/HWPKit/          파서 + 렌더러 (순수 Swift, Linux에서도 테스트 가능)
  Container/                DEFLATE 해제, ZIP, OLE 복합 문서 리더
  HWP/                      HWP 5.x 레코드 파서
  HWPX/                     HWPX XML 파서
  Model/                    공통 문서 모델
  Render/HTMLRenderer.swift 문서 → 자체 완결 HTML
project.yml               XcodeGen 프로젝트 정의
.github/workflows/        macOS 러너에서 테스트 + iOS/macOS 빌드, 설치 파일 생성
```

## 개발

```sh
# 파서 테스트 (macOS 또는 Linux)
cd Packages/HWPKit && swift test

# 여러 문서를 한꺼번에 검사하고 HTML 결과 저장
HWP_CORPUS=~/hwp-samples HWP_HTML_OUT=/tmp/out swift test --filter testCorpus

# Xcode 프로젝트 생성 (Mac)
brew install xcodegen && xcodegen generate && open HWPViewer.xcodeproj
```

## 알려진 한계

정확한 쪽 나눔 재현, 머리말/꼬리말, 각주/미주, 도형·수식·차트, 세로쓰기, 글자처럼 취급하지 않는 개체의 절대 위치는 표시하지 않거나 본문 흐름 안에 배치합니다. 암호·배포용 문서는 열 수 없다는 안내를 표시합니다.
