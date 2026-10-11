# このPC (10.10.0.2) に mado を入れる / 版や設定を当て直す。README.md の「入れ方」。
#   pwsh -File mado/setup.ps1
# 普段のユーザーで流す。Infisical から Entra の client secret を取り出し、リリースの exe を落としてチェックサムを
# 照らしたあと (tools/t.ps1 は普段のユーザーの WSL コンテナで動く)、残りを UAC で昇格して流す。何度流してもよい
param([string]$Stage)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$pwsh = (Get-Command pwsh).Source

# renovate: datasource=github-releases depName=danything/mado
$version = 'v0.2.1'
$dir = 'C:\mado'
# AAAA (pulumi/dns.ts) に書いた固定のアドレス。JCOM のプレフィックスの中で、DHCPv6 が配る範囲の外
$ipv6 = '2405:1201:5201:3a00::2'
$task = 'mado'

if (-not $Stage) {
    # --- 普段のユーザー: 秘密と exe を用意して、昇格して続きを流す ---------------------------------
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

    # 受け渡しのフォルダ。本人だけが読める
    $tmp = Join-Path $env:TEMP "mado-setup-$PID"
    New-Item -ItemType Directory $tmp | Out-Null
    icacls $tmp /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
    try {
        # リリースの exe と SHA-256。照らして合わなければ止める
        gh release download $version --repo danything/mado --dir $tmp --pattern 'mado.exe' --pattern 'mado.exe.sha256'
        if ($LASTEXITCODE) { throw "gh release download $version ($LASTEXITCODE)" }
        $want = ((Get-Content "$tmp\mado.exe.sha256") -split '\s+')[0].ToLower()
        $got = (Get-FileHash "$tmp\mado.exe" -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $got) { throw "mado.exe の SHA-256 が合わない ($got / $want)" }
        # 作ったのが danything/mado の release.yml であること (attest-build-provenance)。SHA-256 は exe と同じリリースに載っているので、改ざんへの備えはこちら
        gh attestation verify "$tmp\mado.exe" --repo danything/mado --signer-workflow danything/mado/.github/workflows/release.yml | Out-Null
        if ($LASTEXITCODE) { throw "mado.exe の出どころを確かめられない ($LASTEXITCODE)" }

        [IO.File]::WriteAllText("$tmp\client-secret.txt", $secret)
        Copy-Item "$PSScriptRoot\mado.json" $tmp
        $p = Start-Process $pwsh -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Stage', "`"$tmp`""
        if ($p.ExitCode -ne 0) { throw "昇格した側が失敗した ($($p.ExitCode))" }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
    return
}

# --- 管理者 ------------------------------------------------------------------------------------------
# 前の回のウィンドウが開いたままでも書けるように、ログは回ごとに分ける
Start-Transcript (Join-Path $env:TEMP "mado-setup-$(Get-Date -Format yyyyMMdd-HHmmss).log") | Out-Null
try {
    # 置き場。client secret とセッションの鍵が入るので SYSTEM (タスク) と Administrators だけが読める
    New-Item -ItemType Directory -Force $dir | Out-Null
    icacls $dir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

    # 動いていれば止めてから差し替える (exe は動いている間は書き換えられない)
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $task
        # タスクを止めても止まるのは cmd.exe だけで、mado.exe は残る。止めて、本当に消えるまで待つ
        # (消えたあとも exe がしばらく掴まれていることがあるので、下の Copy-Item は何度か試す。2026-10-11)
        Get-Process mado -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 30 -and (Get-Process mado -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    }
    foreach ($f in 'mado.exe', 'mado.json', 'client-secret.txt') {
        for ($i = 0; ; $i++) {
            try { Copy-Item (Join-Path $Stage $f) (Join-Path $dir $f) -Force; break }
            catch { if ($i -ge 20) { throw }; Start-Sleep -Milliseconds 500 }
        }
        icacls (Join-Path $dir $f) /reset | Out-Null
    }
    # v0.1 の設定 (v0.2 から JSON)
    Remove-Item "$dir\mado.toml" -ErrorAction SilentlyContinue

    # AAAA に書いたアドレスを Ethernet (既定経路が JCOM の 10.10.0.1 の口) に足す。出ていく通信の送り元には使わない
    # (外から来た接続の返事はこのアドレスから返る)
    $if = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Where-Object NextHop -EQ '10.10.0.1' | Select-Object -First 1).InterfaceIndex
    if (-not $if) { throw '10.10.0.1 への既定経路が無い (JCOM の LAN につながっていない)' }
    if (-not (Get-NetIPAddress -IPAddress $ipv6 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $if -AddressFamily IPv6 -IPAddress $ipv6 -PrefixLength 64 -SkipAsSource $true | Out-Null
    }

    # 80 (Let's Encrypt と https への案内) と 443 だけ
    if (-not (Get-NetFirewallRule -Name 'mado-In' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'mado-In' -DisplayName 'mado (TCP 80, 443)' -Direction Inbound -Protocol TCP `
            -LocalPort 80, 443 -Action Allow -Profile Any | Out-Null
    }

    # RDP を 60fps に (既定は 30fps)。DWM のフレーム間隔で、15 が 60fps の目安 (Microsoft のサポート記事の値)。
    # 次の RDP の接続から効く。Windows App で直接つなぐときも mado から入るときも同じ
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'
    New-ItemProperty -Path $ts -Name DWMFRAMEINTERVAL -PropertyType DWord -Value 15 -Force | Out-Null

    # 寝ると入口ごと消える。電源につないでいるときはスリープも休止もしない
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    # 起動時に SYSTEM で動かす (サインインしなくても動く)。落ちたら 1 分ごとに起こし直す。出力は mado.log に足していく
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -WorkingDirectory $dir `
        -Argument "/c `"`"$dir\mado.exe`" --config `"$dir\mado.json`" >> `"$dir\mado.log`" 2>&1`""
    $settings = New-ScheduledTaskSettingsSet -RestartCount 9999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $task -Force -Action $action -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null
    Start-ScheduledTask -TaskName $task
    Start-Sleep -Seconds 3
    Get-ScheduledTask -TaskName $task | Select-Object TaskName, State | Format-Table -AutoSize
    Get-Content "$dir\mado.log" -Tail 5 -ErrorAction SilentlyContinue
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Enter で閉じる'
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
