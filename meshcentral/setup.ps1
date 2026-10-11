# このPC (10.10.0.2) に MeshCentral を Windows サービスとして入れる / 設定を当て直す。README.md の「入れ方」。
#   pwsh -File meshcentral/setup.ps1
# 管理者でなく普段のユーザーで流す。Infisical から Entra の client secret を取り出したあと (tools/t.ps1 は
# 普段のユーザーの WSL コンテナで動く)、残りを UAC で昇格して流す。何度流してもよい (入っているものは飛ばす)
param([string]$Config)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$pwsh = (Get-Command pwsh).Source

# 入れる最初の版。あとは MeshCentral が自分で上げる (config.json の selfUpdate)。npm の版を書く (GitHub のタグが
# 先に出ることがある。1.2.6 はタグだけで npm に無かった。2026-10-11)
$version = '1.2.5'
$dir = 'C:\meshcentral'
# AAAA (pulumi/dns.ts) に書いた固定のアドレス。JCOM のプレフィックスの中で、DHCPv6 が配る範囲の外
$ipv6 = '2405:1201:5201:3a00::2'

if (-not $Config) {
    # --- 普段のユーザー: 秘密を取り出して設定を作り、昇格して続きを流す --------------------------
    # 未ログインだと export がログインの入力を待つので、標準入力を閉じてすぐ失敗させる (dotfiles の init.ps1 と同じ)
    function Export-Entra {
        $psi = New-Object Diagnostics.ProcessStartInfo $pwsh, ("-NoProfile -ExecutionPolicy Bypass -File `"$root\tools\t.ps1`" " +
            'infisical export --domain https://il.doany.io/api --projectId b3ee533f-5b9e-4fdf-8c44-109926b78f20 ' +
            '--env prod --path /shared/entra --silent --format json')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) { $out }
    }
    $exported = Export-Entra
    if (-not $exported) {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\tools\t.ps1" infisical login --domain https://il.doany.io/api
        $exported = Export-Entra
        if (-not $exported) { throw 'infisical: /shared/entra を取り出せない' }
    }
    $secret = ($exported | Out-String | ConvertFrom-Json | Where-Object key -EQ 'client-secret').value
    if (-not $secret) { throw 'infisical: /shared/entra に client-secret がない' }

    # 値は JSON の文字列としてエスケープして埋める。画面には出さない
    $json = (Get-Content -Raw "$PSScriptRoot\config.json").Replace('"__ENTRA_CLIENT_SECRET__"', ($secret | ConvertTo-Json))
    $tmp = Join-Path $env:TEMP "meshcentral-config-$PID.json"
    New-Item -ItemType File $tmp | Out-Null
    icacls $tmp /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
    try {
        [IO.File]::WriteAllText($tmp, $json)
        $p = Start-Process $pwsh -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Config', "`"$tmp`""
        if ($p.ExitCode -ne 0) { throw "昇格した側が失敗した ($($p.ExitCode))" }
    } finally {
        Remove-Item $tmp -Force
    }
    return
}

# --- 管理者 ------------------------------------------------------------------------------------------
# 前の回のウィンドウが開いたままでも書けるように、ログは回ごとに分ける
Start-Transcript (Join-Path $env:TEMP "meshcentral-setup-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null
try {
    # Node.js (LTS)。入れたら PATH を読み直す
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        winget install --id OpenJS.NodeJS.LTS --exact --silent --accept-source-agreements --accept-package-agreements
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH', 'User')
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    if (-not (Test-Path "$dir\node_modules\meshcentral")) {
        Push-Location $dir
        try { npm install --no-fund --no-audit "meshcentral@$version"; if ($LASTEXITCODE) { throw "npm install ($LASTEXITCODE)" } }
        finally { Pop-Location }
    }

    # 設定。client secret が入るので SYSTEM (サービス) と Administrators だけが読める
    $data = "$dir\meshcentral-data"
    New-Item -ItemType Directory -Force $data | Out-Null
    icacls $data /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
    Copy-Item $Config "$data\config.json" -Force
    icacls "$data\config.json" /reset | Out-Null

    # AAAA に書いたアドレスを Ethernet (既定経路が JCOM の 10.10.0.1 の口) に足す。出ていく通信の送り元には使わない
    # (外から来た接続の返事はこのアドレスから返る)
    $if = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Where-Object NextHop -EQ '10.10.0.1' | Select-Object -First 1).InterfaceIndex
    if (-not $if) { throw '10.10.0.1 への既定経路が無い (JCOM の LAN につながっていない)' }
    if (-not (Get-NetIPAddress -IPAddress $ipv6 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $if -AddressFamily IPv6 -IPAddress $ipv6 -PrefixLength 64 -SkipAsSource $true | Out-Null
    }

    # 80 (Let's Encrypt と https への転送) と 443 だけ
    if (-not (Get-NetFirewallRule -Name 'MeshCentral-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'MeshCentral-In' -DisplayName 'MeshCentral (TCP 80, 443)' -Direction Inbound -Protocol TCP `
            -LocalPort 80, 443 -Action Allow -Profile Any | Out-Null
    }

    # 寝ると入口ごと消える。電源につないでいるときはスリープも休止もしない
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    # サービス (MeshCentral が node-windows で登録する)。入っていれば設定を読み直させる
    if (Get-Service MeshCentral -ErrorAction SilentlyContinue) {
        Restart-Service MeshCentral
    } else {
        Push-Location $dir
        try { node node_modules/meshcentral --install; if ($LASTEXITCODE) { throw "meshcentral --install ($LASTEXITCODE)" } }
        finally { Pop-Location }
    }
    Get-Service MeshCentral | Format-Table -AutoSize
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Enter で閉じる'
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
