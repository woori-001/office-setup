& {
# 출근 설치 키트 - 업무 앱을 공식 배포처에서 최신 버전으로 동시에 설치
# 필수: 카카오톡, 네이버웍스, 말랑메모 / 선택: 클로드, 챗GPT, CTI통계, 시놀로지 드라이브
# 선택 앱은 맨 위의 $Pick 으로 정해요. 예: $Pick = @('claude','chatgpt','cti','synology')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-Variable -Name Pick -Scope Global -ErrorAction SilentlyContinue)) { $global:Pick = @() }
$picked = @($global:Pick | ForEach-Object { "$_".ToLower() })

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host ''
  Write-Host '[!] 관리자 권한이 아닙니다. 시작 버튼 우클릭 > 터미널(관리자)에서 다시 실행해 주세요.' -ForegroundColor Yellow
  return
}

$work = Join-Path $env:TEMP 'office-setup'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$desktop = [Environment]::GetFolderPath('Desktop')

# 앱 목록 (설치 순서 = 표시 순서)
$apps = @(
  @{ key = 'kakao'; name = '카카오톡'; required = $true
     tries = @(
       @{ kind = 'direct'; url = 'https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe'; file = 'KakaoTalk_Setup.exe'; args = '/S' },
       @{ kind = 'winget'; id = 'Kakao.KakaoTalk' })
     shortcut = @{ name = '카카오톡'; paths = @('%ProgramFiles(x86)%\Kakao\KakaoTalk\KakaoTalk.exe', '%ProgramFiles%\Kakao\KakaoTalk\KakaoTalk.exe', '%LOCALAPPDATA%\Kakao\KakaoTalk\KakaoTalk.exe') }
     page = 'https://www.kakaocorp.com/page/service/service/KakaoTalk' },
  @{ key = 'works'; name = '네이버웍스'; required = $true
     tries = @(
       @{ kind = 'direct'; url = 'https://download.worksmobile.com/k/wminst/r/naverworks/message_win64_install'; file = 'NAVERWORKS_Setup.exe'; args = '/S' },
       @{ kind = 'winget'; id = 'WorksMobile.NAVERWORKS' })
     page = 'https://naver.worksmobile.com/download/' },
  @{ key = 'mallang'; name = '말랑메모'; required = $true
     tries = @(@{ kind = 'github'; repo = 'woori-001/Mallang'; args = '/S' })
     page = 'https://github.com/woori-001/Mallang/releases/latest' },
  @{ key = 'claude'; name = '클로드'; required = $false
     tries = @(
       @{ kind = 'winget'; id = 'Anthropic.Claude' },
       @{ kind = 'direct'; url = 'https://claude.ai/api/desktop/win32/x64/exe/latest/redirect'; file = 'Claude_Setup.exe'; args = '--silent' })
     page = 'https://claude.ai/download' },
  @{ key = 'chatgpt'; name = '챗GPT'; required = $false
     tries = @(@{ kind = 'winget'; id = '9NT1R1C2HH7J'; source = 'msstore' })
     page = 'https://apps.microsoft.com/detail/9NT1R1C2HH7J' },
  @{ key = 'cti'; name = 'CTI통계'; required = $false
     tries = @(@{ kind = 'auto'; url = 'http://otosolution.com/solution/CTIadmin/CTIadmin_Setup.exe'; file = 'CTIadmin_Setup.exe' })
     page = 'http://7123.kr/CRM4DownLoad.aspx' },
  @{ key = 'synology'; name = '시놀로지 드라이브'; required = $false
     tries = @(
       @{ kind = 'synology' },
       @{ kind = 'winget'; id = 'SynoLogy.DriveClient' })
     page = 'https://www.synology.com/ko-kr/support/download/DS925+?version=7.4#utilities' }
)

# 앱 하나를 설치하는 작업 (각 앱이 별도 프로세스에서 동시에 실행됨)
$installJob = {
  param($app, $work, $hasWinget, $desktop)
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

  function Get-File([string]$url, [string]$file) {
    $path = Join-Path $work $file
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -UserAgent $ua
    if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 100000) { throw 'download failed' }
    return $path
  }
  function Run-Installer([string]$path, [string]$silentArgs) {
    if ($path -like '*.msi') {
      # 다른 설치가 Windows Installer를 쓰는 중이면(1618) 잠시 기다렸다 다시 시도
      for ($i = 0; $i -lt 12; $i++) {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn /norestart' -f $path) -Wait -PassThru
        if ($p.ExitCode -ne 1618) { break }
        Start-Sleep -Seconds 10
      }
      return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
    }
    if ($silentArgs) { $p = Start-Process -FilePath $path -ArgumentList $silentArgs -Wait -PassThru }
    else { $p = Start-Process -FilePath $path -Wait -PassThru }
    return ($p.ExitCode -eq 0)
  }
  function Try-One($t) {
    try {
      switch ($t.kind) {
        'direct' { return (Run-Installer (Get-File $t.url $t.file) $t.args) }
        'winget' {
          if (-not $hasWinget) { return $false }
          $a = @('install', '--id', $t.id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
          if ($t.source) { $a += @('--source', $t.source) }
          & winget @a | Out-Null
          return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
        }
        'github' {
          $rel = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $t.repo) -UseBasicParsing -Headers @{ 'User-Agent' = 'office-setup' }
          $asset = $rel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
          if (-not $asset) { return $false }
          return (Run-Installer (Get-File $asset.browser_download_url $asset.name) $t.args)
        }
        'synology' {
          # 시놀로지 공식 아카이브에서 가장 최신 Drive Client 버전을 찾아 MSI로 설치
          $html = (Invoke-WebRequest -Uri 'https://archive.synology.com/download/Utility/SynologyDriveClient' -UseBasicParsing -UserAgent $ua).Content
          $vers = [regex]::Matches($html, 'SynologyDriveClient/(\d+\.\d+\.\d+-(\d+))') | ForEach-Object { [pscustomobject]@{ v = $_.Groups[1].Value; b = [int]$_.Groups[2].Value } }
          $latest = $vers | Sort-Object b -Descending | Select-Object -First 1
          if (-not $latest) { return $false }
          $url = 'https://global.synologydownload.com/download/Utility/SynologyDriveClient/{0}/Windows/Installer/x86_64/Synology%20Drive%20Client-{0}-x64.msi' -f $latest.v
          return (Run-Installer (Get-File $url 'SynologyDriveClient.msi') $null)
        }
        'auto' {
          # 설치 방식이 공개되지 않은 프로그램: 설치 파일 종류를 보고 무인 설치 옵션을 고름
          $path = Get-File $t.url $t.file
          $bytes = [IO.File]::ReadAllBytes($path)
          $text = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min($bytes.Length, 4000000))
          if ($text -match 'Nullsoft') { $sa = '/S' }
          elseif ($text -match 'Inno Setup') { $sa = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
          else { $sa = $null }  # 알 수 없는 형식은 설치 화면을 띄워서 직접 진행
          return (Run-Installer $path $sa)
        }
      }
    } catch { return $false }
    return $false
  }

  $ok = $false
  foreach ($t in $app.tries) { if (Try-One $t) { $ok = $true; break } }

  if ($ok -and $app.shortcut) {
    try {
      $target = $app.shortcut.paths | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($target) {
        $lnk = Join-Path $desktop ($app.shortcut.name + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = $target
        $s.WorkingDirectory = Split-Path $target
        $s.Save()
      }
    } catch { }
  }
  return $ok
}

$targets = @($apps | Where-Object { $_.required -or ($picked -contains $_.key) })

Write-Host ''
Write-Host '출근 설치 키트' -ForegroundColor Cyan
Write-Host ('설치할 앱: ' + (($targets | ForEach-Object { $_.name }) -join ', '))
Write-Host '모든 앱을 동시에 설치합니다. 창을 닫지 말고 기다려 주세요.'
Write-Host ''

$started = Get-Date
$jobs = @()
foreach ($a in $targets) {
  $j = Start-Job -Name $a.key -ScriptBlock $installJob -ArgumentList $a, $work, $hasWinget, $desktop
  $jobs += [pscustomobject]@{ job = $j; app = $a; done = $false; ok = $false }
}

while (@($jobs | Where-Object { -not $_.done }).Count -gt 0) {
  foreach ($r in ($jobs | Where-Object { -not $_.done })) {
    if ($r.job.State -ne 'Running' -and $r.job.State -ne 'NotStarted') {
      $out = Receive-Job $r.job -ErrorAction SilentlyContinue
      $r.ok = [bool](@($out) | Select-Object -Last 1)
      $r.done = $true
      $sec = [int]((Get-Date) - $started).TotalSeconds
      if ($r.ok) { Write-Host ('  [완료] {0}  ({1}초)' -f $r.app.name, $sec) -ForegroundColor Green }
      else { Write-Host ('  [실패] {0}  - 다운로드 페이지를 열어요' -f $r.app.name) -ForegroundColor Red; Start-Process $r.app.page }
      Remove-Job $r.job -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 700
}

$failed = @($jobs | Where-Object { -not $_.ok }).Count
$total = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
if ($failed -eq 0) {
  Write-Host ('모두 설치됐어요. ({0}초) 이 창은 닫아도 됩니다.' -f $total) -ForegroundColor Green
} else {
  Write-Host ('{0}개 앱은 자동 설치가 안 됐어요. 열린 페이지에서 받아 주세요.' -f $failed) -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
