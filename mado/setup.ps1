# このPC (10.10.0.2) に mado を入れる / 版や設定を当て直す。README.md の「入れ方」。
#   pwsh -File mado/setup.ps1
# 普段のユーザーで流す。Infisical から Entra の client secret を取り出し、リリースの MSI を落として SHA-256 と出どころを
# 確かめたあと (tools/t.ps1 は普段のユーザーの WSL コンテナで動く)、残りを UAC で昇格して流す。何度流してもよい
param([string]$Stage)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$pwsh = (Get-Command pwsh).Source

# 入れる版 (MSI)。上げるときはここを変えて流し直す (Renovate が上げる)
# renovate: datasource=github-releases depName=danything/mado
$version = 'v0.4.0'
# 設定・client secret・証明書・ログの置き場。MSI が SYSTEM と Administrators だけが読めるように作る
$data = Join-Path $env:ProgramData 'mado'
# AAAA (pulumi/dns.ts) に書いた固定のアドレス。JCOM のプレフィックスの中で、DHCPv6 が配る範囲の外
$ipv6 = '2405:1201:5201:3a00::2'

if (-not $Stage) {
    # --- 普段のユーザー: 秘密と MSI を用意して、昇格して続きを流す ---------------------------------
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
        # リリースの MSI と SHA-256。照らして合わなければ止める
        gh release download $version --repo danything/mado --dir $tmp --pattern 'mado.msi' --pattern 'mado.msi.sha256'
        if ($LASTEXITCODE) { throw "gh release download $version ($LASTEXITCODE)" }
        $want = ((Get-Content "$tmp\mado.msi.sha256" | Select-String 'mado\.msi$') -split '\s+')[0].ToLower()
        $got = (Get-FileHash "$tmp\mado.msi" -Algorithm SHA256).Hash.ToLower()
        if ($want -ne $got) { throw "mado.msi の SHA-256 が合わない ($got / $want)" }
        # 作ったのが danything/mado の release.yml であること (attest-build-provenance)。SHA-256 は MSI と同じリリースに載っているので、改ざんへの備えはこちら
        gh attestation verify "$tmp\mado.msi" --repo danything/mado --signer-workflow danything/mado/.github/workflows/release.yml | Out-Null
        if ($LASTEXITCODE) { throw "mado.msi の出どころを確かめられない ($LASTEXITCODE)" }

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
    # --- v0.3 まで (bun。C:\mado に置いてタスク スケジューラで動かしていた) からの引っ越し ---
    if (Get-ScheduledTask -TaskName 'mado' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'mado'
        Unregister-ScheduledTask -TaskName 'mado' -Confirm:$false
    }
    # タスクを止めても止まるのは cmd.exe だけで、mado.exe は残る (サービスの mado.exe は MSI が止める)
    $old = { Get-Process mado -ErrorAction SilentlyContinue | Where-Object Path -Like 'C:\mado\*' }
    & $old | Stop-Process -Force -ErrorAction SilentlyContinue
    # 止まるまで待つ (掴まれたままだと下の Move-Item が落ちる)
    for ($i = 0; $i -lt 30 -and (& $old); $i++) { Start-Sleep -Milliseconds 500 }
    New-Item -ItemType Directory -Force $data | Out-Null
    icacls $data /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
    # 証明書・ACME のアカウント・セッションの鍵は同じ形なので、そのまま持ってくる (取り直さずに済む)
    if ((Test-Path 'C:\mado\data') -and -not (Test-Path "$data\data")) {
        Move-Item -LiteralPath 'C:\mado\data' -Destination "$data\data"
    }
    # v0.3 までの setup.ps1 が足した規則。MSI が入れる規則は「mado (TCP 80)」「mado (TCP 443)」で、名前が違うので消さない
    Get-NetFirewallRule -Name 'mado-In' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    # --- 設定と client secret (MSI には入れない。サービスが起動したときに読めるよう、MSI より先に置く) ---
    foreach ($f in 'mado.json', 'client-secret.txt') {
        Copy-Item (Join-Path $Stage $f) (Join-Path $data $f) -Force
        icacls (Join-Path $data $f) /reset | Out-Null
    }

    # --- MSI (サービス・ファイアウォール・ProgramData の権限)。新しい版なら古い版を外して入れ替える。同じ版ならそのまま ---
    # 受け渡しのフォルダは本人だけが読めるので、MSI を読む Windows Installer (SYSTEM) には読めない (1619 になる)。
    # SYSTEM と Administrators が読める ProgramData\mado に写してから入れる
    $msi = Join-Path $data 'mado.msi'
    Copy-Item (Join-Path $Stage 'mado.msi') $msi -Force
    $msilog = Join-Path $env:TEMP "mado-msi-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msilog`""
    Remove-Item -LiteralPath $msi -Force
    # 3010 は「再起動が要る」で、mado には関係ない (ファイルの置き換えだけ)
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec ($($p.ExitCode))。ログ: $msilog" }

    # 設定を読み直させる (MSI が起動したとき、設定がまだ古いこともある)
    Restart-Service mado
    for ($i = 0; $i -lt 30 -and (Get-Service mado).Status -ne 'Running'; $i++) { Start-Sleep -Milliseconds 500 }
    if ((Get-Service mado).Status -ne 'Running') { throw "サービス mado が起動しない。ログ: $data\logs\mado.log" }

    # 引っ越しが終わったら古い置き場を消す (古い exe・ログ・平文の client secret が残っている)
    if (Test-Path 'C:\mado') { Remove-Item -LiteralPath 'C:\mado' -Recurse -Force }

    # AAAA に書いたアドレスを Ethernet (既定経路が JCOM の 10.10.0.1 の口) に足す。出ていく通信の送り元には使わない
    # (外から来た接続の返事はこのアドレスから返る)
    $if = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Where-Object NextHop -EQ '10.10.0.1' | Select-Object -First 1).InterfaceIndex
    if (-not $if) { throw '10.10.0.1 への既定経路が無い (JCOM の LAN につながっていない)' }
    if (-not (Get-NetIPAddress -IPAddress $ipv6 -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $if -AddressFamily IPv6 -IPAddress $ipv6 -PrefixLength 64 -SkipAsSource $true | Out-Null
    }

    # RDP を 60fps に (既定は 30fps)。DWM のフレーム間隔で、15 が 60fps の目安 (Microsoft のサポート記事の値)。
    # 次の RDP の接続から効く。Windows App で直接つなぐときも mado から入るときも同じ
    $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'
    New-ItemProperty -Path $ts -Name DWMFRAMEINTERVAL -PropertyType DWord -Value 15 -Force | Out-Null

    # 寝ると入口ごと消える。電源につないでいるときはスリープも休止もしない
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    Start-Sleep -Seconds 2
    Get-Service mado | Format-Table Name, Status, StartType -AutoSize
    Get-Content "$data\logs\mado.log" -Tail 5 -ErrorAction SilentlyContinue
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Enter で閉じる'
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
