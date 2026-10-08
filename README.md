# Power Spikes — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

1991 년 Video System 이 만든 배구 게임 *Power Spikes* 의 아케이드 기판을 FPGA 로
다시 만든 MiSTer 코어입니다.  에뮬레이터처럼 소프트웨어로 흉내 내는 것이 아니라,
원래 기판에 있던 CPU·비디오 칩·사운드 칩을 하드웨어 기술 언어로 하나씩 옮겨
DE10-Nano 위에서 그대로 돌립니다.

원래 기판의 구성은 다음과 같습니다.

- **메인 CPU** — Motorola 68000, 10 MHz
- **사운드 CPU** — Zilog Z80, 5 MHz (사운드 명령 래치 + NMI 로 68000 과 통신)
- **사운드 칩** — Yamaha YM2610, 8 MHz (FM 4채널 + SSG + ADPCM-A 6채널 + ADPCM-B)
- **비디오** — Video System C7-01 GGA (타이밍), 8x8 4bpp 타일맵 한 장(라인 단위 스크롤),
  VS8904/VS8905 스프라이트 칩(확대·축소 포함), 2048 색 xRGB555 팔레트
- **화면** — 352 x 240, 61.31 Hz, 가로 화면

MiSTer 에서 게임을 처음부터 끝까지 플레이할 수 있고, 2인 플레이와 사운드까지
실기에서 확인했습니다.  어트랙트 화면은 MAME 가 그린 프레임과 픽셀 단위로 비교했고,
일치하는 장면 14 장 중 5 장은 84,480 픽셀 전부가 MAME 와 같았습니다.

## 지원 게임

정상 구동용 `.mra` 는 `SD/_Arcade/_Kaze's Cores/` 에 있습니다. 개발용 계측 `.mra` 는 배포본에 넣지 않았습니다.

| MAME 세트 | 공식 명칭 | 상태 |
|---|---|---|
| `pspikes` | Power Spikes (World) | **실기에서 플레이 확인.** 1인·2인 플레이, 사운드, 화면 반전, MAME 픽셀 대조까지 확인 |
| `pspikesk` | Power Spikes (Korea) | ROM 구성이 MAME 의 CRC 와 일치함을 확인. 부모 세트와 68000 프로그램 ROM 만 다르며, 실기 플레이는 별도로 기록되지 않음 |
| `pspikesu` | Power Spikes (US) | 위와 같음 |
| `svolly91` | Super Volley '91 (Japan) | `.mra` 는 포함되어 있으나 ROM 을 확보하지 못해 **아직 시험하지 못함** |

부트렉 세트(`pspikesb`, `pspikesba`, `pspikesc`, `spikes91` 등)는 기판 구성이 달라
지원 대상이 아닙니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/PowerSpikes.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.

## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

명령줄에서 빌드하려면:

```sh
cd projects/vsystem/power_spikes/targets/mister
quartus_sh --flow compile PowerSpikes
```

결과물은 `projects/vsystem/power_spikes/targets/mister/output_files/PowerSpikes.rbf` 입니다. Quartus GUI 로
`PowerSpikes.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/vsystem/power_spikes/
  rtl/                               기판 하드웨어 RTL (68000·Z80 버스, 스프라이트·타일맵·비디오, SDRAM·ROM 캐시, 사운드 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호(예: `D18`, `MEASUREMENTS 158`, `docs/...`)와
측정 기록이 그대로 남아 있습니다. 해당 개발 문서와 측정·분석 도구는 이 배포본에 포함하지
않았습니다. 주석은 설계 근거를 남기려는 것이고, 빌드에는 영향이 없습니다.

## 작업 내역

### 2026-10-08 — v0.9.1

- **OSD 설정 저장 유지.** 이전에는 `Save settings` 로 저장해도 다음 실행 때 코어가 `.mra` 기본값을 다시 올려 저장값을 덮어썼습니다(MiSTer 는 저장 파일을 ROM 로드 전에 읽고, 코어가 보낸 status 로 128비트 전체를 교체합니다). 이제 저장된 설정이 있으면 기본값을 올리지 않습니다. 실기에서 저장 파일 값이 화면에 반영되는 것을 확인했습니다.

### 블록별 구현

- **68000** — fx68k 를 그대로 사용합니다.  주소 디코드와 메모리 맵은 MAME 의 `pspikes_map`
  을 그대로 옮기고 FBNeo 로 교차확인했습니다.  수직 귀선 인터럽트는 MAME 의
  `irq1_line_hold` 와 같이 **CPU 가 응답(IACK)할 때까지 유지**되며, 응답은 fx68k 의
  FC=111 버스 사이클에서 직접 끌어냅니다.
- **Z80** — T80(`T80pa`)을 5 MHz 로 돌립니다.  128 KB 프로그램 ROM 은 블록 RAM 에 두어
  대기 없이 읽히게 했고, 사운드 래치는 MAME 처럼 응답을 분리한 양방향 래치 + NMI 입니다.
  포트 맵은 같은 드라이버 안의 비슷한 맵이 아니라 `spinlbrk_sound_portmap` 이 맞다는 것을
  MAME 와 FBNeo 양쪽에서 확인했습니다.
- **YM2610** — jotego 의 jt10(jt12 패키지)을 8 MHz 로 사용합니다.  ADPCM-A/B 샘플 ROM 은
  SDRAM 에 있고, 칩이 내보내는 주소를 따라가는 6 엔트리 워드 캐시를 거쳐 공급합니다.
- **스프라이트** — VS8904/VS8905 동작을 라인 버퍼 방식으로 구현했습니다.  다음 줄을
  미리 그리는 블리터를 페치와 분리해 한 줄 안에 일을 끝내고, 확대·축소와 화면 반전 시의
  원점 미러링, 겹침 순서는 MAME 의 `vsystem_spr2` 와 `drawgfx` 규칙을 따릅니다.
- **타일맵** — 8x8 4bpp 타일을 스캔라인마다 SDRAM 에서 가져와 그립니다.  라인 단위 스크롤의
  부호 규칙은 MAME 의 `tilemap.cpp` 에서 확인했습니다.
- **팔레트** — 2048 엔트리 xRGB555 를 듀얼포트 블록 RAM 으로 구현했습니다.
- **SDRAM / ROM 캐시** — 단일 40 MHz 클럭 도메인에서 동작하는 SDRAM 컨트롤러와 중재기를
  직접 만들었습니다.  중재 우선순위는 "마감이 짧은 쪽이 먼저" 원칙으로 정했고
  (타일맵 39 클럭, 스프라이트 약 2,550 클럭), 68000 프로그램 ROM 앞에는 작은 캐시를 두어
  명령어 페치 대기를 평균 7.19 클럭에서 4.76 클럭으로 줄였습니다.
- **비디오 타이밍** — GGA(C7-01) 에 게임이 쓰는 레지스터 값으로 타이밍을 만듭니다(2026-10-06).
  해독은 H = (n+1)×4, V = (n+1)×2 이고, 게임이 쓰는 값이 456 x 256 총 주사·352 x 240 표시·61.31 Hz 와
  정확히 맞습니다. 레지스터 트래픽에서 얻은 해독이며 데이터시트로 확인한 것은 아닙니다.
- **OSD / DIP** — 화면비, 스캔더블러 효과, DIP 스위치, OSD 를 열면 자동 일시정지,
  패드 R 버튼 일시정지, 리셋을 제공합니다.  DIP 표 12 항목은 MAME 와 자동으로 대조하는
  검사기로 확인했습니다.  버튼은 기판대로 A/B/C 세 개이며, 게임 플레이에는 A 하나만 쓰입니다
  (프로그램 역어셈블로 확인).

### 시간순 기록

- **2026-08 말** — 68000 부팅, 타일맵·스프라이트·팔레트, SDRAM, Z80·YM2610 을 차례로 올렸습니다.
  이 시기에 해결한 것들:
  - fx68k 가 버스 사이클을 멈추던 문제 — 데이터 입력(`din`)을 사이클 끝까지 유지하지 않았던 것.
  - PLL VCO 가 400 MHz 로 잡혀 Cyclone V 최소값(600 MHz)을 밑돌던 문제 — 쓰지 않는 세 번째
    출력을 추가해 합법적인 VCO 를 강제했습니다.
  - YM2610 레지스터 쓰기 한 번이 다섯 번 실행되던 문제 — jt12 는 원시 클럭마다 쓰기 스트로브를
    샘플링하므로, 스트로브 폭을 정확히 원시 클럭 1 개로 줄였습니다.  ADPCM-A 가 계속 처음부터
    재시작되고 FM 엔벨로프가 어택에서 빠져나오지 못하던 두 증상이 한 원인이었습니다.
  - 어트랙트가 무음이었던 것은 결함이 아니라 `.mra` 의 Demo Sounds DIP 기본값이 MAME(On)와
    달랐기 때문이었습니다.
- **2026-09-01** — 실기에서 게임이 돌기 시작했습니다.
  - **스프라이트 깜박임** — 수직 귀선 인터럽트를 CPU 응답이 아니라 귀선 끝에서 내렸기 때문에,
    게임의 인터럽트 핸들러가 한 프레임에 **두 번** 돌고 두 번째 실행이 화면 표시 중에 스프라이트
    RAM 을 쓰고 있었습니다.  IACK 에서 내리도록 고친 뒤 프레임당 스프라이트 쓰기가 절반이 되고
    쓰기 구간이 귀선 안으로 돌아왔습니다.
  - **배경 지글거림** — 중재기 우선순위가 뒤집혀 있어, 마감이 39 클럭인 타일맵이 2,550 클럭
    여유가 있는 스프라이트 엔진을 기다리고 있었습니다.  순서를 바꾸자 프레임당 타일맵 마감 실패가
    43 회 이상에서 0 회가 됐습니다.
  - **ADPCM 지직거림** — ADPCM-A 바이트가 jt10 이 다음 주소로 넘어간 뒤에 도착했고, 잘못된
    니블이 믹서에서 7.25 배 증폭되어 잡음이 됐습니다.  긴급 마스크와 주소 추종 캐시로 지연 페치를
    0 으로 만들었습니다.
  - 각 줄의 첫 타일을 가져오지 않던 문제와, 줄 왼쪽 끝이 이전 줄의 스크롤 값을 쓰던 문제를 고쳐
    MAME 와의 차이를 3,333 픽셀에서 0 으로 줄였습니다.
  - 스프라이트 라인 버퍼가 블록 RAM 으로 추론되지 못해 11,264 개의 플립플롭이 되어 있던 것을
    바로잡아 로직 사용량을 24,330 ALM 에서 15,361 ALM 으로 줄였습니다.
  - 화면 반전이 절반만 구현되어 있었던 것(타일맵만 뒤집히고 스프라이트 원점은 그대로)을 고치고,
    클론 세트 세 개를 추가했습니다.
- **2026-09-02** — 스프라이트 한 줄이 1 클럭 모자라 글자 세 개가 깜박이던 문제를 블리터를 페치와
  분리해 해결했습니다.  스프라이트 우선순위 오버라이드가 배경 지글거림을 줄 반대편 끝에서 다시
  만들던 것을 고쳤고(프레임당 마감 실패 0~383 회 → 0~1 회), 타일맵이 수평 귀선 중에 줄마다
  SDRAM 워드 24 개를 버리던 것을 없애 마지막 남은 스프라이트 라벨 깜박임(초당 약 880 회의 라인
  초과)을 0 으로 만들었습니다.
- **2026-09-03** — 버튼 이름을 기판 그대로 A/B/C 로 바로잡고, OSD 에 빠져 있던 DIP 메뉴를
  추가했습니다.  이 시점의 MiSTer 코어를 검증 기준판으로 표시했습니다.
- **2026-09-06** — 2인 플레이(P1/P2 입력이 바뀌어 배선된 기판 특성 포함)와 사운드를 실기에서
  확인했습니다.
- **2026-09-09** — OSD 를 표준 배치로 정리했습니다.  보드 프레임 20 장을 MAME 와 대조해
  14 장이 같은 장면으로 매칭됐고 그 중 5 장은 픽셀 차이 0 이었습니다.
- **2026-09-15** — 로드 직후 약 50 초 동안 일시정지가 듣지 않던 문제와, "Pause when OSD open: Off"
  를 고르면 진단용 자동 코인이 켜지던 OSD 상태 비트 충돌을 고치고 실기에서 확인했습니다.

- **2026-10-06** — 화면 타이밍을 GGA 레지스터에서 만들도록 바꿨습니다(이전에는 주사율에서
  역산한 상수). 실기에서 수직 귀선 인터럽트 응답(IACK)이 매 프레임 정확히 한 번임을 확인한 뒤,
  응답이 없을 때 인터럽트를 강제로 내리던 안전 경로를 없앴습니다. 같은 정지 화면 6 장이 이전
  RBF 와 84,480 픽셀 전부 같았습니다.

## 감사의 말과 사용한 코드

이 코어는 많은 분들이 먼저 쌓아 둔 작업 위에 서 있습니다.

무엇보다 **MAME 팀**에 깊이 감사드립니다.  수십 년에 걸쳐 아케이드 기판을 분석하고 기록해 온
MAME 가 없었다면 이 기판의 메모리 맵, 클럭, ROM 구성, 그래픽 형식, 스프라이트 규칙을 알아낼
방법이 없었을 것입니다.  이 코어의 동작이 맞는지 판단하는 기준도 언제나 MAME 였습니다.
— https://www.mamedev.org/ , https://github.com/mamedev/mame

### 사용한 외부 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| fx68k | 메인 CPU (68000) | Jorge Cwik | GPL-3.0 | [ijor/fx68k](https://github.com/ijor/fx68k) @ `0602ee4627b10f301298f2673d826cdd6baa9327` | `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | **있음** — `fx68k.sv` 에 내부 레지스터를 읽기 위한 디버그 출력 포트 `dbg_d7` 를 추가 (동작 변경 없음, `// LOCAL:` 표시) |
| T80 | 사운드 CPU (Z80) | Daniel Wallner, MikeJ, TobiFlex, Sean Riddle, Sorgelig (MiSTer-devel) | BSD-3-Clause 계열 | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) @ `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538` | `T80_Pack.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Reg.vhd`, `T80.vhd`, `T80pa.vhd` | 없음 |
| JT12 (jt10) | 사운드 칩 (YM2610) | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt12](https://github.com/jotego/jt12) @ `4cf1c5b1426cbed74591ca344f96b769fb027269` | upstream `jt10.qip` 가 지정하는 `jt10*.v`, `jt12*.v` 일체 + `jt03_acc.v` | **있음** — `jt10.v`, `jt10_adpcm_drvA.v`, `jt12_top.v`, `jt12_reg.v`, `jt12_kon.v`, `jt12_mmr.v` 에 디버그 관측용 출력 포트만 추가 (기존 논리 줄은 삭제·변경 없음, 추가된 모든 줄에 `// LOCAL:` 표시) |
| JT49 | YM2610 의 SSG 부분 | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt49](https://github.com/jotego/jt49) @ `47301ed51374d6d41db4db846b7643fecf75e417` (jt12 의 서브모듈) | `jt49*.v` | 없음 |
| MiSTer framework | DE10-Nano 입출력, OSD, 스케일러, HDMI, 오디오 출력 | MiSTer-devel (Sorgelig 외) | 파일별 (대부분 GPLv2+ / GPLv3+) | [MiSTer-devel/Template_MiSTer @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별)](https://github.com/MiSTer-devel/Template_MiSTer) | `sys/` 전체 | **있음** — `sys.tcl` 의 경로 해석 두 줄을 스크립트 자신의 위치 기준으로 변경 (동작 변경 없음) |

- **Jorge Cwik** 님께 — 사이클 정확한 68000 코어 fx68k 덕분에 이 기판의 메인 CPU 를 믿고 쓸 수 있었습니다.
- **Daniel Wallner 님과 MiSTer-devel 기여자들**께 — 오랜 세월 다듬어진 T80 이 사운드 CPU 를 맡고 있습니다.
- **jotego** 님께 — YM2610 의 FM·SSG·ADPCM 전부를 담은 jt12/jt49 없이는 이 게임의 소리를 낼 수 없었습니다.
- **MiSTer-devel 과 Sorgelig** 님께 — MiSTer 프레임워크가 이 모든 것을 DE10-Nano 위에 올려 줍니다.

### 참고한 MAME 소스

MAME 소스는 하드웨어 사실(메모리 맵, 클럭, ROM 구성, 비트 배치, 동작 규칙)을 확인하는 데 읽었으며,
MAME 의 C++ 코드를 RTL 로 옮겨 적지는 않았습니다.  MAME 는 프레임 단위로 그리는 구조라
이 코어의 스캔라인 페치·라인 버퍼·중재기 구조는 MAME 에 대응하는 부분이 없습니다.
참고한 MAME 커밋: `446356f29ee59b4f2dad4f93408b1aaa33fae926`.

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/vsystem/pspikes.cpp` | BSD-3-Clause | Nicola Salmoria | 드라이버 전체: 68000·Z80 메모리 맵(`pspikes_map`, `spinlbrk_sound_portmap`), 클럭, `irq1_line_hold` 인터럽트 방식, 사운드 래치 설정, 화면 설정, ROM 구성, DIP 기본값 |
| `src/mame/vsystem/vsystem_spr2.cpp` | BSD-3-Clause | Nicola Salmoria, David Haywood | 스프라이트 속성 디코드, 순회 순서, 확대·축소, 화면 반전 시 원점 미러링 |
| `src/emu/drawgfx.cpp`, `src/emu/drawgfxt.ipp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 스프라이트 확대·축소 시 픽셀 샘플링 규칙과 겹침 처리 |
| `src/emu/tilemap.cpp` | BSD-3-Clause | Aaron Giles | 타일맵 스크롤 값의 부호 규칙 |
| `src/emu/video/generic.cpp` | BSD-3-Clause | Nicola Salmoria | `gfx_8x8x4_packed_lsb` 타일 그래픽 비트 배치 |
| `src/emu/emupal.h` | BSD-3-Clause | Aaron Giles | xRGB555 팔레트 형식 |

**FBNeo** (`src/burn/drv/pst90s/d_aerofgt.cpp`, 커밋 `da70e8799370ad64a44f9e79e0c5114b4f6dda92`) 는
MAME 에서 확인한 사실을 독립적으로 교차확인하는 용도로만 읽었습니다 (예: Z80 포트 맵).
FBNeo 의 코드는 한 줄도 가져오지 않았습니다.

## 라이선스

이 코어는 전체로서 **GPL-3.0** 입니다.  GPL-3.0 인 fx68k 가 함께 합성되기 때문입니다.
`LICENSE` 파일은 GPL-3.0 전문입니다.

외부에서 가져온 파일들(fx68k, T80, jt12/jt49, MiSTer framework)은 각 파일 머리말에 적힌 원래의
저작권 표시와 라이선스를 그대로 유지합니다.  T80 의 BSD 계열 라이선스는 GPL-3.0 과 호환됩니다.

ROM 데이터는 포함되어 있지 않습니다.  게임 ROM 은 정당하게 소유한 것을 직접 준비해야 합니다.
*Power Spikes* 와 *Super Volley '91* 은 각 권리자의 상표입니다.

## 알려진 제한사항

- **MiSTer 전용입니다.**  Analogue Pocket 타깃은 아직 만들어지지 않았습니다.
- **이 배포본의 `.mra` 와 RBF 를 함께 쓰세요.**  개발용 디버그 오버레이와 테스트 패턴은 기본이 꺼짐이고
  (OSD 의 Debug 페이지에서 켤 수 있습니다), 배포본의 `.mra` 도 같은 기준(`00 00 00`)으로 맞춰져 있습니다.
  2026-10-05 이전에 배포된 `.mra`(OSD 기본값 `00 0C 00`)를 이 RBF 와 함께 쓰면 두 기능이 켜진 채로 시작합니다.
- 클론 세트 `pspikesk` / `pspikesu` 는 ROM 구성만 검증했고, `svolly91` 은 아직 시험하지 못했습니다.
- OSD 의 DIP 메뉴는 표시되는 것까지 확인했지만, 항목을 하나씩 바꿔 게임의 변화를 확인하지는 않았습니다.
- 사운드는 귀와 출력 레벨(MAME 대비 약 94 %)로 확인했으며, YM2610 레지스터 쓰기를 MAME 와
  하나하나 대조하지는 않았습니다.
- 경기 중 심판의 호루라기 소리가 재시작할 때까지 계속 울리는 현상이 한 번 보고됐습니다.  재현되지
  않았고 원인은 아직 찾지 못했습니다.
- GGA 레지스터 해독은 레지스터 값의 산술 일치에서 얻은 것입니다(데이터시트·스코프 미확인). 레지스터 04/05·0c/0d 는 아직 모릅니다.
  이 변경으로 수평 동기 위치가 400–424 로 옮겨졌습니다. 화면 내용은 이전과 픽셀 단위로 같지만, CRT·아날로그 출력에서의 위치는 확인하지 않았습니다.
- MAME 자체도 어트랙트의 확대 글자 표현이 완벽하지 않다고 적고 있어, 그 장면은 MAME 와 정확히
  일치하지 않을 수 있습니다.
- 수직 귀선 중 게임의 비디오 갱신이 MAME 보다 약 한 줄 늦게 끝나는 경우가 있습니다(16 줄 귀선 대비
  최대 17 번째 줄).  눈에 보이는 결함으로는 확인되지 않았습니다.
