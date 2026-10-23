@echo off
rem Office setup kit - installs work apps with admin rights
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#PS1'+'START#'; $t=Get-Content -LiteralPath '%~f0' -Encoding UTF8 -Raw; iex ($t.Substring($t.IndexOf($m)+$m.Length))"
echo.
pause
exit /b
#PS1START#
$Pick = @()
& {
# 출근 설치 키트 - 업무 앱을 공식 배포처에서 최신 버전으로 동시에 설치
# 기본: 카카오톡, 네이버웍스, 말랑메모 / 선택: 샌드박스, 클로드, 챗GPT, CTI통계, 시놀로지 드라이브
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
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
$desktop = [Environment]::GetFolderPath('Desktop')

# 앱 목록 (표시 순서). est = 보통 걸리는 설치 시간(초), 진행률 추정에 사용
$apps = @(
  @{ key = 'kakao'; name = '카카오톡'; required = $true; est = 25
     tries = @(
       @{ kind = 'direct'; url = 'https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe'; file = 'KakaoTalk_Setup.exe'; args = '/S' },
       @{ kind = 'direct'; url = 'https://app-pc.kakaocdn.net/talk/win32/x64/KakaoTalk_Setup.exe'; file = 'KakaoTalk_Setup_x64.exe'; args = '/S' },
       @{ kind = 'winget'; id = 'Kakao.KakaoTalk' })
     shortcut = @{ name = '카카오톡'; paths = @('%ProgramFiles(x86)%\Kakao\KakaoTalk\KakaoTalk.exe', '%ProgramFiles%\Kakao\KakaoTalk\KakaoTalk.exe', '%LOCALAPPDATA%\Kakao\KakaoTalk\KakaoTalk.exe'); start = '^KakaoTalk|카카오톡' }
     page = 'https://www.kakaocorp.com/page/service/service/KakaoTalk' },
  @{ key = 'works'; name = '네이버웍스'; required = $true; est = 30
     tries = @(
       @{ kind = 'direct'; url = 'https://download.worksmobile.com/k/wminst/r/naverworks/message_win64_install'; file = 'NAVERWORKS_Setup.exe'; args = '/S' },
       @{ kind = 'winget'; id = 'WorksMobile.NAVERWORKS' })
     page = 'https://naver.worksmobile.com/download/' },
  @{ key = 'mallang'; name = '말랑메모'; required = $true; est = 30
     tries = @(@{ kind = 'github'; repo = 'woori-001/Mallang'; args = '/S' })
     page = 'https://github.com/woori-001/Mallang/releases/latest' },
  @{ key = 'claude'; name = '클로드'; required = $false; est = 45
     tries = @(
       @{ kind = 'winget'; id = 'Anthropic.Claude' },
       @{ kind = 'direct'; url = 'https://claude.ai/api/desktop/win32/x64/exe/latest/redirect'; file = 'Claude_Setup.exe'; args = '--silent' })
     shortcut = @{ name = '클로드'; paths = @('%LOCALAPPDATA%\AnthropicClaude\claude.exe'); start = '^Claude$'; pkg = 'Claude' }
     verify = $true
     page = 'https://claude.ai/download' },
  @{ key = 'chatgpt'; name = '챗GPT'; required = $false; est = 45
     tries = @(@{ kind = 'winget'; id = '9NT1R1C2HH7J'; source = 'msstore' })
     shortcut = @{ name = '챗GPT'; paths = @(); start = '^ChatGPT'; pkg = '*ChatGPT*' }
     verify = $true
     page = 'ms-windows-store://pdp/?ProductId=9NT1R1C2HH7J' },
  @{ key = 'cti'; name = 'CTI통계'; required = $false; est = 20
     tries = @(@{ kind = 'auto'; url = 'http://otosolution.com/solution/CTIadmin/CTIadmin_Setup.exe'; file = 'CTIadmin_Setup.exe' })
     page = 'http://7123.kr/CRM4DownLoad.aspx' },
  @{ key = 'synology'; name = '시놀로지 드라이브'; required = $false; est = 40
     tries = @(
       @{ kind = 'synology' },
       @{ kind = 'winget'; id = 'SynoLogy.DriveClient' })
     page = 'https://www.synology.com/ko-kr/support/download/DS925+?version=7.4#utilities' },
  @{ key = 'sandboxie'; name = '샌드박스'; required = $false; est = 40
     tries = @(@{ kind = 'github'; repo = 'sandboxie-plus/Sandboxie'; pattern = 'Sandboxie-Plus-x64-v*.exe'; args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' })
     page = 'https://sandboxie-plus.com/downloads/' }
)

# 앱 하나를 설치하는 작업 (앱마다 별도 프로세스에서 동시에 실행)
# 진행 상황은 상태 파일(st-앱.txt)에 적어서 메인 화면이 읽어 가요: dl:퍼센트 / inst / wg
$installJob = {
  param($app, $work, $hasWinget)
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
  $statusFile = Join-Path $work ('st-' + $app.key + '.txt')

  function Set-Status([string]$s) { try { [IO.File]::WriteAllText($statusFile, $s) } catch { } }

  function Get-File([string]$url, [string]$file) {
    # 멈춤 감지(20초 동안 데이터가 안 오면 중단) + 받다 끊기면 최대 3번 다시 받기
    $path = Join-Path $work $file
    $lastErr = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      Set-Status 'dl:0:0'
      try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = $ua
        $req.AllowAutoRedirect = $true
        $req.Timeout = 20000
        $req.ReadWriteTimeout = 20000
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($path)
        $done = 0
        try {
          $buf = New-Object byte[] 262144
          $last = -1
          $sw = [Diagnostics.Stopwatch]::StartNew()
          while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $done += $n
            $pct = 0
            if ($total -gt 0) { $pct = [int][Math]::Floor($done * 100 / $total) }
            if ($pct -ne $last -or ($sw.ElapsedMilliseconds % 1000) -lt 50) {
              $kbs = 0
              if ($sw.Elapsed.TotalSeconds -gt 0.5) { $kbs = [int]($done / 1024 / $sw.Elapsed.TotalSeconds) }
              Set-Status ('dl:{0}:{1}' -f $pct, $kbs); $last = $pct
            }
          }
        } finally { $out.Close(); $in.Close(); $resp.Close() }
        if ($total -gt 0 -and $done -lt $total) { throw ('받다가 끊김 ({0}/{1}MB)' -f [int]($done / 1MB), [int]($total / 1MB)) }
        if ((Get-Item $path).Length -lt 100000) { throw '파일이 비정상적으로 작음' }
        return $path
      } catch {
        $lastErr = $_.Exception.Message
        Set-Status ('retry:{0}' -f $attempt)
        Start-Sleep -Seconds 2
      }
    }
    throw ('다운로드 실패: ' + $lastErr)
  }
  function Run-Installer([string]$path, [string]$silentArgs) {
    Set-Status 'inst'
    if ($path -like '*.msi') {
      # 다른 설치가 Windows Installer를 쓰는 중이면(1618) 잠시 기다렸다 다시 시도
      for ($i = 0; $i -lt 12; $i++) {
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn /norestart' -f $path) -Wait -PassThru
        if ($p.ExitCode -ne 1618) { break }
        Start-Sleep -Seconds 10
      }
      return ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
    }
    # 같은 설치 파일이 이미 돌고 있으면(이전 시도가 멈춘 경우) 정리
    $exeName = [IO.Path]::GetFileNameWithoutExtension($path)
    Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($silentArgs) { $p = Start-Process -FilePath $path -ArgumentList $silentArgs -PassThru }
    else { $p = Start-Process -FilePath $path -PassThru }
    # 설치 프로그램이 5분 넘게 끝나지 않으면 멈춘 것으로 보고 중단
    $limit = 300
    if (-not $silentArgs) { $limit = 900 }
    if (-not $p.WaitForExit($limit * 1000)) {
      try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch { }
      throw '설치 프로그램이 응답 없음'
    }
    return ($p.ExitCode -eq 0)
  }
  function Try-One($t) {
    try {
      switch ($t.kind) {
        'direct' { return (Run-Installer (Get-File $t.url $t.file) $t.args) }
        'winget' {
          if (-not $hasWinget) { return $false }
          Set-Status 'wg'
          $a = @('install', '--id', $t.id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
          if ($t.source) { $a += @('--source', $t.source) }
          & winget @a | Out-Null
          return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
        }
        'github' {
          $rel = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $t.repo) -UseBasicParsing -Headers @{ 'User-Agent' = 'office-setup' }
          $pat = '*.exe'; if ($t.pattern) { $pat = $t.pattern }
          $asset = $rel.assets | Where-Object { $_.name -like $pat } | Select-Object -First 1
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
    } catch { $script:why = $_.Exception.Message; return $false }
    return $false
  }

  $script:why = $null
  $ok = $false
  foreach ($t in $app.tries) { if (Try-One $t) { $ok = $true; break } }
  if (-not $ok -and $script:why) { Set-Status ('err:' + $script:why) }
  return $ok
}

# 시작 메뉴에서 앱을 찾아요 (스토어 앱 확인용)
function Find-StartApp([string]$pattern) {
  try { return (Get-StartApps | Where-Object { $_.Name -match $pattern } | Select-Object -First 1) } catch { return $null }
}

# 바탕화면 바로가기 만들기. 실행 파일이 있으면 그걸로, 스토어 앱이면 시작 메뉴 항목으로 연결
function New-DesktopShortcut($sc) {
  $lnkPath = Join-Path $desktop ($sc.name + '.lnk')
  $ws = New-Object -ComObject WScript.Shell
  $exe = @($sc.paths) | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if ($exe) {
    $s = $ws.CreateShortcut($lnkPath)
    $s.TargetPath = $exe
    $s.WorkingDirectory = Split-Path $exe
    $s.Save()
    return $true
  }
  $sa = Find-StartApp $sc.start
  if (-not $sa) { return $false }
  $s = $ws.CreateShortcut($lnkPath)
  $s.TargetPath = Join-Path $env:WINDIR 'explorer.exe'
  $s.Arguments = 'shell:AppsFolder\' + $sa.AppID
  $icon = $null
  if ($sc.pkg) {
    $pkg = Get-AppxPackage -Name $sc.pkg -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
      $icon = Get-ChildItem -Path $pkg.InstallLocation -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'helper|crash|update|squirrel|elevat' } | Select-Object -First 1
    }
  }
  if ($icon) { $s.IconLocation = $icon.FullName + ',0' }
  $s.Save()
  return $true
}

# 화면 표시 도우미 (한글은 두 칸 너비)
function Get-Width([string]$s) {
  $w = 0
  foreach ($ch in $s.ToCharArray()) { if ([int]$ch -ge 0x1100) { $w += 2 } else { $w += 1 } }
  return $w
}
function Pad([string]$s, [int]$n) { $g = $n - (Get-Width $s); if ($g -gt 0) { return $s + (' ' * $g) } else { return $s } }

$targets = @($apps | Where-Object { $_.required -or ($picked -contains $_.key) })

Write-Host ''
Write-Host '  출근 설치 키트' -ForegroundColor Cyan
Write-Host ('  {0}개 앱을 동시에 설치합니다. 창을 닫지 말고 기다려 주세요.' -f $targets.Count)
Write-Host ''

$started = Get-Date
$rows = @()
foreach ($a in $targets) {
  $j = Start-Job -Name $a.key -ScriptBlock $installJob -ArgumentList $a, $work, $hasWinget
  $rows += [pscustomobject]@{ job = $j; app = $a; state = 'run'; ok = $false; pct = 0; note = '준비 중'; instAt = $null; secs = 0 }
}

# 진행 화면을 그릴 자리를 확보
$canRedraw = $true
try {
  foreach ($r in $rows) { Write-Host '' }
  $top = [Console]::CursorTop - $rows.Count
} catch { $canRedraw = $false }

$spin = @('|', '/', '-', '\')
$tick = 0
$doneCount = 0
while ($doneCount -lt $rows.Count) {
  $tick++
  foreach ($r in $rows) {
    if ($r.state -ne 'run') { continue }
    $el = ((Get-Date) - $started).TotalSeconds
    $stFile = Join-Path $work ('st-' + $r.app.key + '.txt')
    # 한 앱이 15분을 넘기면 멈춘 것으로 보고 중단 (다른 앱은 계속 진행)
    $timedOut = $false
    if ($el -gt 900 -and $r.job.State -eq 'Running') {
      Stop-Job $r.job -ErrorAction SilentlyContinue
      $timedOut = $true
    }
    if ($timedOut -or ($r.job.State -ne 'Running' -and $r.job.State -ne 'NotStarted')) {
      $out = $null
      if (-not $timedOut) { $out = Receive-Job $r.job -ErrorAction SilentlyContinue }
      $r.ok = [bool](@($out) | Select-Object -Last 1)
      $why = ''
      if ($timedOut) { $why = '15분 넘게 끝나지 않음' }
      else { try { $last = [IO.File]::ReadAllText($stFile); if ($last -like 'err:*') { $why = $last.Substring(4) } } catch { } }
      Remove-Job $r.job -Force -ErrorAction SilentlyContinue
      $r.secs = [int]$el
      if ($r.ok -and $r.app.verify) {
        # 스토어 앱은 실제로 시작 메뉴에 나타날 때까지 확인 (최대 30초)
        $r.note = '설치 확인 중'
        $found = $false
        for ($i = 0; $i -lt 15 -and -not $found; $i++) {
          if (Find-StartApp $r.app.shortcut.start) { $found = $true } else { Start-Sleep -Seconds 2 }
        }
        $r.ok = $found
      }
      if ($r.ok -and $r.app.shortcut) { try { [void](New-DesktopShortcut $r.app.shortcut) } catch { } }
      $r.state = 'done'
      $doneCount++
      if ($r.ok) { $r.pct = 100; $r.note = ('완료 ({0}초)' -f $r.secs) }
      else {
        $r.note = '실패 - 설치 페이지를 열었어요'
        if ($why) { $r.note = '실패 (' + $why + ')' }
        if ($r.note.Length -gt 40) { $r.note = $r.note.Substring(0, 39) + '…)' }
        try { Start-Process $r.app.page } catch { }
      }
      continue
    }
    $st = ''
    try { $st = [IO.File]::ReadAllText($stFile) } catch { }
    $est = [double]$r.app.est
    if ($st -like 'dl:*') {
      $parts = $st.Split(':')
      $d = [int]$parts[1]
      $kbs = 0; if ($parts.Count -gt 2) { $kbs = [int]$parts[2] }
      $r.pct = [int]($d * 0.6)
      if ($kbs -ge 1024) { $spd = '{0:0.0}MB/s' -f ($kbs / 1024) } elseif ($kbs -gt 0) { $spd = '{0}KB/s' -f $kbs } else { $spd = '연결 중' }
      $r.note = ('다운로드 중 {0}% · {1}' -f $d, $spd)
    } elseif ($st -like 'retry:*') {
      $r.note = ('연결이 끊겨 다시 받는 중 ({0}/3)' -f $st.Substring(6))
    } elseif ($st -eq 'inst' -or $st -eq 'wg') {
      if (-not $r.instAt) { $r.instAt = Get-Date }
      $ie = ((Get-Date) - $r.instAt).TotalSeconds
      if ($st -eq 'inst') { $base = 60; $span = 38 } else { $base = 0; $span = 98 }
      $r.pct = [int][Math]::Min($base + $span, $base + $span * (1 - [Math]::Exp(-2 * $ie / $est)))
      $r.note = '설치 중 ' + $spin[$tick % 4]
    }
  }

  if ($canRedraw) {
    try {
      [Console]::SetCursorPosition(0, $top)
      foreach ($r in $rows) {
        $filled = [int][Math]::Floor($r.pct / 10)
        $bar = ('■' * $filled) + ('□' * (10 - $filled))
        $line = '  ' + (Pad $r.app.name 18) + $bar + ('{0,5}%  ' -f $r.pct) + $r.note
        $color = 'Gray'
        if ($r.state -eq 'done') { if ($r.ok) { $color = 'Green' } else { $color = 'Red' } }
        Write-Host (Pad $line 76) -ForegroundColor $color
      }
    } catch { $canRedraw = $false }
  } elseif ($tick % 10 -eq 0) {
    Write-Host ('  진행 중... {0}/{1}개 끝남' -f $doneCount, $rows.Count)
  }
  Start-Sleep -Milliseconds 400
}

if (-not $canRedraw) { foreach ($r in $rows) { Write-Host ('  {0}  {1}' -f $r.app.name, $r.note) } }

$failed = @($rows | Where-Object { -not $_.ok }).Count
$total = [int]((Get-Date) - $started).TotalSeconds
Write-Host ''
if ($failed -eq 0) {
  Write-Host ('  모두 설치됐어요. 총 {0}초. 이 창은 닫아도 됩니다.' -f $total) -ForegroundColor Green
} else {
  Write-Host ('  {0}개 앱은 자동 설치가 안 됐어요. 열린 페이지에서 받아 주세요. (총 {1}초)' -f $failed, $total) -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
