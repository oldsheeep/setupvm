# sheep への SSH 接続環境（Cloudflare Access + 短命証明書）をセットアップする（Windows 用）
#
#   irm https://raw.githubusercontent.com/<org>/<repo>/main/setup.ps1 | iex
#
# やること（setup.sh と同じ）:
#   1. cloudflared をインストール（無ければ。空白を含まないパスに置く）
#   2. ~/.ssh/config に sheep 用の設定を書き込む（再実行しても重複しない）
#   3. ブラウザで GitHub ログインして短命証明書を発行
#   4. ssh sheep で接続テスト
#
# 環境変数で上書き可能: SHEEP_HOSTNAME / SHEEP_ALIAS / SHEEP_USER

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $SheepHostname = if ($env:SHEEP_HOSTNAME) { $env:SHEEP_HOSTNAME } else { 'sheep-ssh.sheeplab.net' }
    $SheepAlias    = if ($env:SHEEP_ALIAS)    { $env:SHEEP_ALIAS }    else { 'sheep' }
    $SheepUser     = if ($env:SHEEP_USER)     { $env:SHEEP_USER }     else { 'sshu' }

    $SshDir     = Join-Path $env:USERPROFILE '.ssh'
    $SshConfig  = Join-Path $SshDir 'config'
    $CertFile   = Join-Path $env:USERPROFILE ".cloudflared\$SheepHostname-cf_key-cert.pub"
    $BeginMark  = "# >>> $SheepAlias (managed by sheep setup) >>>"
    $EndMark    = "# <<< $SheepAlias (managed by sheep setup) <<<"
    $ReleaseUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

    function Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
    function Warn([string]$Message) { Write-Host "[warn] $Message" -ForegroundColor Yellow }

    # ssh_config にそのまま書けるパスか（空白・日本語などを含まない）
    function Test-SafePath([string]$Path) { return $Path -match '^[\x21-\x7E]+$' }

    function Assert-OpenSsh {
        if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
            throw 'OpenSSH クライアントが見つかりません。設定 → システム → オプション機能 → 「OpenSSH クライアント」を追加してから再実行してください'
        }
        $version = (cmd /c 'ssh -V 2>&1' | Out-String).Trim()
        Info "OpenSSH: $version"
        if ($version -match 'OpenSSH_for_Windows_(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if ($major -lt 8 -or ($major -eq 8 -and $minor -lt 1)) {
                Warn 'OpenSSH が古く、ssh config の "Match exec" が動かない可能性があります。失敗したら winget install Microsoft.OpenSSH.Preview で更新してください'
            }
        }
    }

    function Install-Cloudflared {
        $existing = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
        if ($existing -and (Test-SafePath $existing.Source)) {
            Info "cloudflared はインストール済みです: $($existing.Source)"
            return $existing.Source
        }

        # winget 版は Program Files (x86) に入り空白を含むので、別途空白のない場所に置く
        $dir = @((Join-Path $env:LOCALAPPDATA 'cloudflared'), 'C:\tools\cloudflared') |
            Where-Object { Test-SafePath $_ } | Select-Object -First 1
        $exe = Join-Path $dir 'cloudflared.exe'
        if (Test-Path $exe) {
            Info "cloudflared はダウンロード済みです: $exe"
            return $exe
        }

        Info "cloudflared を $exe にダウンロードします"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri $ReleaseUrl -OutFile $exe
        return $exe
    }

    function Update-SshConfig([string]$Cloudflared) {
        New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

        $old = ''
        if (Test-Path $SshConfig) {
            $old = [IO.File]::ReadAllText($SshConfig)
            if ($old.Length -gt 0) {
                $backup = "$SshConfig.bak.$(Get-Date -Format yyyyMMddHHmmss)"
                Copy-Item $SshConfig $backup
                Info "既存の ssh config をバックアップしました: $backup"
            }
        }

        # 既存の管理ブロック（と直後の空行 1 つ）を取り除く
        $kept = New-Object System.Collections.Generic.List[string]
        $skip = $false; $eat = $false
        foreach ($line in ($old -split "\r?\n")) {
            if ($line -eq $BeginMark) { $skip = $true; continue }
            if ($line -eq $EndMark) { $skip = $false; $eat = $true; continue }
            if ($eat -and $line -eq '') { $eat = $false; continue }
            $eat = $false
            if (-not $skip) { $kept.Add($line) }
        }
        $rest = ($kept -join "`n").TrimEnd("`n")

        $block = @"
$BeginMark
Host $SheepAlias
  HostName $SheepHostname
  User $SheepUser

Match host $SheepHostname exec "$Cloudflared access ssh-gen --hostname %h"
  ProxyCommand $Cloudflared access ssh --hostname %h
  IdentityFile ~/.cloudflared/$SheepHostname-cf_key
  CertificateFile ~/.cloudflared/$SheepHostname-cf_key-cert.pub
  IdentitiesOnly yes
  ServerAliveInterval 30

# reset scope so the rest of this file applies to all hosts
Host *
$EndMark


"@ -replace "`r`n", "`n"

        # ブロックはファイル先頭に置く（ssh_config は先に書いた値が優先されるため）
        $content = $block
        if ($rest) { $content += $rest + "`n" }
        # BOM 付き UTF-8 だと ssh が読めないので BOM なしで書く
        [IO.File]::WriteAllText($SshConfig, $content, (New-Object System.Text.UTF8Encoding($false)))
        Info "~/.ssh/config に '$SheepAlias' の設定を書き込みました"

        $aliasPattern = '(?im)^\s*host(\s+\S+)*\s+' + [regex]::Escape($SheepAlias) + '(\s|$)'
        if ($rest -match $aliasPattern -or $rest.Contains($SheepHostname)) {
            Warn "~/.ssh/config に以前の '$SheepAlias' / $SheepHostname の設定が残っています。今回の設定が優先されますが、不要なら削除してください"
        }
    }

    function New-SheepCert([string]$Cloudflared) {
        Info 'ブラウザが開くので GitHub でログインしてください（開かない場合は表示される URL を開く）'
        Remove-Item $CertFile -ErrorAction SilentlyContinue
        & $Cloudflared access ssh-gen --hostname $SheepHostname
        if (-not (Test-Path $CertFile)) {
            Warn '短命証明書を発行できませんでした。次を確認してください:'
            Warn '  - GitHub の team への招待を Accept しているか'
            Warn '  - GitHub の Authorize 画面で組織へのアクセスを Grant / Request したか'
            throw '証明書の発行に失敗しました'
        }
        Info '短命証明書を発行しました'
    }

    function Test-SheepConnection {
        Info "接続テスト: ssh $SheepAlias"
        & ssh.exe -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 $SheepAlias 'echo OK: $(whoami)@$(hostname)'
        if ($LASTEXITCODE -ne 0) {
            throw "接続テストに失敗しました。'ssh -v $SheepAlias' の出力を管理者に送ってください"
        }
        Info "完了！ これからは 'ssh $SheepAlias' で接続できます"
    }

    try {
        Assert-OpenSsh
        $cloudflared = Install-Cloudflared
        if (-not (Test-SafePath $cloudflared)) {
            throw "cloudflared のパスに空白や日本語が含まれていて ssh の設定に使えません: $cloudflared"
        }
        Update-SshConfig $cloudflared
        New-SheepCert $cloudflared
        Test-SheepConnection
    } catch {
        Write-Host "[error] $($_.Exception.Message)" -ForegroundColor Red
    }
}
