& {
# 출근 설치 키트 - 업무 앱 6종을 공식 배포처에서 최신 버전으로 자동 설치
# 관리자 권한 PowerShell(터미널)에 붙여넣어 실행
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host ''
  Write-Host '[!] 관리자 권한이 아닙니다. 시작 버튼 우클릭 > 터미널(관리자)에서 다시 붙여넣어 주세요.' -ForegroundColor Yellow
  return
}

$work = Join-Path $env:TEMP 'office-setup'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$results = New-Object System.Collections.Generic.List[object]

function Install-Direct([string]$url, [string]$file, [string]$silentArgs) {
  try {
    $path = Join-Path $work $file
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 100000) { return $false }
    $p = Start-Process -FilePath $path -ArgumentList $silentArgs -Wait -PassThru
    return ($p.ExitCode -eq 0)
  } catch { return $false }
}

function Install-Winget([string]$id, [string]$source) {
  if (-not $hasWinget) { return $false }
  $a = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
  if ($source) { $a += @('--source', $source) }
  & winget @a | Out-Null
  # 0 = 설치 완료, -1978335189 = 이미 최신 버전 설치됨
  return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
}

function Step([string]$name, [scriptblock[]]$tries, [string]$fallbackUrl) {
  Write-Host ("  - {0} 설치 중..." -f $name) -NoNewline
  foreach ($t in $tries) {
    if (& $t) {
      Write-Host ' 완료' -ForegroundColor Green
      $results.Add([pscustomobject]@{ 앱 = $name; 결과 = '완료' })
      return
    }
  }
  Write-Host ' 실패' -ForegroundColor Red
  $results.Add([pscustomobject]@{ 앱 = $name; 결과 = '실패 - 다운로드 페이지를 열었어요' })
  if ($fallbackUrl) { Start-Process $fallbackUrl }
}

Write-Host ''
Write-Host '출근 설치 키트 - 6개 앱을 차례로 설치합니다. 창을 닫지 말고 기다려 주세요.' -ForegroundColor Cyan
Write-Host ''

Step '카카오톡' @(
  { Install-Direct 'https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe' 'KakaoTalk_Setup.exe' '/S' },
  { Install-Winget 'Kakao.KakaoTalk' }
) 'https://www.kakaocorp.com/page/service/service/KakaoTalk'

Step '네이버웍스' @(
  { Install-Direct 'https://download.worksmobile.com/k/wminst/r/naverworks/message_win64_install' 'NAVERWORKS_Setup.exe' '/S' },
  { Install-Winget 'WorksMobile.NAVERWORKS' }
) 'https://naver.worksmobile.com/download/'

Step '시놀로지 드라이브' @(
  { Install-Winget 'SynoLogy.DriveClient' }
) 'https://www.synology.com/ko-kr/support/download'

Step '말랑메모' @(
  {
    try {
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/woori-001/Mallang/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'office-setup' }
      $asset = $rel.assets | Where-Object { $_.name -like '*.exe' -and $_.name -notlike '*.blockmap' } | Select-Object -First 1
      if (-not $asset) { return $false }
      Install-Direct $asset.browser_download_url $asset.name '/S'
    } catch { $false }
  }
) 'https://github.com/woori-001/Mallang/releases/latest'

Step '클로드' @(
  { Install-Winget 'Anthropic.Claude' },
  { Install-Direct 'https://claude.ai/api/desktop/win32/x64/exe/latest/redirect' 'Claude_Setup.exe' '--silent' }
) 'https://claude.ai/download'

Step '챗GPT' @(
  { Install-Winget '9NT1R1C2HH7J' 'msstore' }
) 'https://apps.microsoft.com/detail/9NT1R1C2HH7J'

Write-Host ''
$results | Format-Table -AutoSize | Out-Host
$failed = @($results | Where-Object { $_.결과 -ne '완료' }).Count
if ($failed -eq 0) {
  Write-Host '모두 설치됐어요. 이 창은 닫아도 됩니다.' -ForegroundColor Green
} else {
  Write-Host ("{0}개 앱은 자동 설치가 안 됐어요. 열린 페이지나 설치 페이지의 개별 버튼으로 받아 주세요." -f $failed) -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
