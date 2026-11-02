# このPC (10.10.0.2) に mado を入れる / 版や設定を当て直す。README.md の「入れ方」。
#   pwsh -File mado/setup.ps1
# 普段のユーザーで流す。gitops の SOPS から Entra の client secret を取り出し、リリースの MSI を落として SHA-256 と出どころを
# 確かめたあと (tools/t.ps1 は普段のユーザーの WSL コンテナで動く)、残りを UAC で昇格して流す。何度流してもよい。
# Talos のダッシュボードと電源の操作の talosconfig (os:operator、90 日) も作り直して置く。期限が近い (mado の画面に出る) ときも流す
param([string]$Stage)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$pwsh = (Get-Command pwsh).Source

# 入れる版 (MSI) は、流したときの最新のリリース (版は固定しない)。あとは mado が自分で上げる (署名を確かめた MSI を入れる。v0.5.0 から)。
# 動いているほうが新しければ MSI は入れない (古い版で上書きしない。MSI もそれを拒む)
$version = $null
# 設定・client secret・証明書・ログの置き場。MSI が SYSTEM と Administrators だけが読めるように作る
$data = Join-Path $env:ProgramData 'mado'
# AAAA (pulumi/dns.ts) に書いた固定のアドレス。JCOM のプレフィックスの中で、DHCPv6 が配る範囲の外
$ipv6 = '2405:1201:5201:3a00::2'

if (-not $Stage) {
    # talosconfig の期限を読む X509CertificateLoader は .NET 9 (pwsh 7.5) から。DPAPI の ProtectedData は pwsh 7 に入っている
    if ($PSVersionTable.PSVersion -lt [version]'7.5') { throw "pwsh 7.5 以上で流す (今は $($PSVersionTable.PSVersion))" }
    # --- 普段のユーザー: 秘密と MSI を用意して、昇格して続きを流す ---------------------------------
    # client secret は Entra の共用のアプリ登録の値。gitops の SOPS (deploy/auth/secrets.sops.yaml の auth-secrets の
    # oidc-client-secret) から取る。管理者の age の鍵が .home に無ければ recovery/sops-age.key.age をパスフレーズで開いて置き、
    # 取り出したら消す (置いてあった鍵は残す)。復号した中身はメモリで受け取り、ファイルに書かない
    $key = Join-Path $root '.home\.config\sops\age\keys.txt'
    $placed = -not (Test-Path $key)
    # 鍵を置くところから try に入れる (開けずに途中で止まったときも、書きかけの鍵を残さない)
    try {
        if ($placed) {
            & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\tools\t.ps1" sh -c 'mkdir -p ~/.config/sops/age && age -d -o ~/.config/sops/age/keys.txt recovery/sops-age.key.age'
            if ($LASTEXITCODE -ne 0) { throw 'age: recovery/sops-age.key.age を開けない' }
        }
        $decrypted = & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\tools\t.ps1" sops -d --output-type json deploy/auth/secrets.sops.yaml
        if ($LASTEXITCODE -ne 0) { throw 'sops: deploy/auth/secrets.sops.yaml を開けない' }
        # Talos のダッシュボードとシャットダウン・再起動 (mado の docs/talos.md) の talosconfig。役割は os:operator (設定の書き換え・
        # リセット・アップグレードはできない) で、90 日で切れる。AMT で既に強制の電源操作ができるので、安全な止め方を足すほうが安全側 (docs/decisions.md)。
        # 管理者の talosconfig (tools/creds.sh が SOPS の Talos の CA からコンテナの /dev/shm に作る) で Talos API に作らせ、
        # 平文は標準出力で受け取る (手元のディスクには書かない)。コンテナの中の書き出しも /dev/shm で、すぐ消す。クラスタは変えない
        $talosconfig = & $pwsh -NoProfile -ExecutionPolicy Bypass -File "$root\tools\t.ps1" --admin sh -c 'd=$(mktemp -d /dev/shm/operator.XXXXXX) && talosctl config new $d/talosconfig --roles os:operator --crt-ttl 2160h >&2 && cat $d/talosconfig; r=$?; rm -rf $d; exit $r'
        if ($LASTEXITCODE -ne 0) { throw 'talosctl config new: os:operator の talosconfig を作れない (ノードに届くか、age の鍵で開けるか)' }
    } finally {
        if ($placed) { Remove-Item $key -ErrorAction SilentlyContinue }
    }
    $secret = (($decrypted | Out-String | ConvertFrom-Json).spec.secretTemplates |
        Where-Object name -EQ 'auth-secrets').stringData.'oidc-client-secret'
    $decrypted = $null
    if (-not $secret) { throw 'sops: deploy/auth/secrets.sops.yaml の auth-secrets に oidc-client-secret がない' }

    # talosconfig は DPAPI の LocalMachine の範囲で保護してから書く (サービスは LocalSystem なので、普段のユーザーの範囲では開けない)。
    # 誰が読めるかは置き場の ACL (SYSTEM と Administrators) で絞る。中身は画面にもログにも出さない (期限だけ出す)
    $plain = [Text.Encoding]::UTF8.GetBytes((@($talosconfig) -join "`n") + "`n")
    $talosconfig = $null
    $text = [Text.Encoding]::UTF8.GetString($plain)
    $crt = [regex]::Match($text, '(?m)^\s*crt:\s*(\S+)\s*$').Groups[1].Value
    $text = $null
    if (-not $crt) { [Array]::Clear($plain); throw 'talosctl config new: 出てきたものに crt が無い (talosconfig の形でない)' }
    $pem = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($crt))
    $notAfter = [Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificate(
        [Convert]::FromBase64String(($pem -replace '-----[^-]+-----', '' -replace '\s', ''))).NotAfter
    $talosBlob = [Security.Cryptography.ProtectedData]::Protect($plain, $null, 'LocalMachine')
    [Array]::Clear($plain)
    Write-Host "Talos の talosconfig (os:operator): $($notAfter.ToString('yyyy-MM-dd')) まで"

    # talosctl.exe (mado が ConPTY で動かす)。版は tools/Dockerfile の talosctl と同じ (Renovate が上げる)。公式の sha256sum.txt と照らす
    $talosVersion = [regex]::Match((Get-Content -Raw "$root\tools\Dockerfile"), '(?m)^ARG TALOSCTL_VERSION=(\S+)').Groups[1].Value
    if (-not $talosVersion) { throw 'tools/Dockerfile に TALOSCTL_VERSION が無い' }

    # 受け渡しのフォルダ。本人だけが読める
    $tmp = Join-Path $env:TEMP "mado-setup-$PID"
    New-Item -ItemType Directory $tmp | Out-Null
    icacls $tmp /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
    try {
        # 動いている mado の版 (状態の口)。自分で上げてこちら以上なら MSI は入れない (設定と秘密だけ置き直す)。
        # 同じ版の MSI を入れると Windows Installer は修復として扱い、自動更新が入れたときの MSI (もう無い) を探して 1603 で落ちる
        function ConvertTo-Version([string]$v) {
            try { [version](($v -replace '^v', '') -replace '[-+].*$', '') } catch { $null }
        }
        $version = gh release view --repo danything/mado --json tagName --jq .tagName
        if ($LASTEXITCODE -or -not $version) { throw "gh release view: danything/mado の最新のリリースが分からない ($LASTEXITCODE)" }
        Write-Host "最新のリリース: $version"
        $running = $null
        try { $running = (Invoke-RestMethod http://127.0.0.1:8788/status -TimeoutSec 3).version } catch {}
        $a = ConvertTo-Version $running
        $b = ConvertTo-Version $version
        if ($a -and $b -and $a -ge $b) {
            Write-Host "動いている mado ($running) が $version 以上なので、MSI はそのまま (設定と秘密だけ置き直す)"
        } else {
            # リリースの MSI と SHA-256。照らして合わなければ止める
            gh release download $version --repo danything/mado --dir $tmp --pattern 'mado.msi' --pattern 'mado.msi.sha256'
            if ($LASTEXITCODE) { throw "gh release download $version ($LASTEXITCODE)" }
            $want = ((Get-Content "$tmp\mado.msi.sha256" | Select-String 'mado\.msi$') -split '\s+')[0].ToLower()
            $got = (Get-FileHash "$tmp\mado.msi" -Algorithm SHA256).Hash.ToLower()
            if ($want -ne $got) { throw "mado.msi の SHA-256 が合わない ($got / $want)" }
            # 作ったのが danything/mado の release.yml であること (attest-build-provenance)。SHA-256 は MSI と同じリリースに載っているので、改ざんへの備えはこちら
            gh attestation verify "$tmp\mado.msi" --repo danything/mado --signer-workflow danything/mado/.github/workflows/release.yml | Out-Null
            if ($LASTEXITCODE) { throw "mado.msi の出どころを確かめられない ($LASTEXITCODE)" }
        }

        gh release download $talosVersion --repo siderolabs/talos --dir $tmp --pattern 'talosctl-windows-amd64.exe' --pattern 'sha256sum.txt'
        if ($LASTEXITCODE) { throw "gh release download: talosctl $talosVersion ($LASTEXITCODE)" }
        $want = ((Get-Content "$tmp\sha256sum.txt" | Select-String 'talosctl-windows-amd64\.exe$') -split '\s+')[0]
        $got = (Get-FileHash "$tmp\talosctl-windows-amd64.exe" -Algorithm SHA256).Hash
        if (-not $want -or $want.ToLower() -ne $got.ToLower()) { throw "talosctl-windows-amd64.exe の SHA-256 が合わない ($got / $want)" }
        Move-Item "$tmp\talosctl-windows-amd64.exe" "$tmp\talosctl.exe"
        [IO.File]::WriteAllBytes("$tmp\talosconfig.dpapi", $talosBlob)

        [IO.File]::WriteAllText("$tmp\client-secret.txt", $secret)
        Copy-Item "$PSScriptRoot\mado.json" $tmp
        $p = Start-Process $pwsh -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"", '-Stage', "`"$tmp`""
        if ($p.ExitCode -ne 0) { throw "昇格した側が失敗した ($($p.ExitCode))" }
        # タスクトレイ (サインイン時にも起動する。MSI が HKLM の Run に登録する)。今のサインインでも出しておく
        $tray = Join-Path $env:ProgramFiles 'mado\mado-tray.exe'
        if ((Test-Path $tray) -and -not (Get-Process mado-tray -ErrorAction SilentlyContinue)) { Start-Process $tray }
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
    # talosconfig.dpapi は Talos のダッシュボードの鍵 (DPAPI で保護したもの)。mado は開くたびに読むので、置き直せば再起動は要らない
    foreach ($f in 'mado.json', 'client-secret.txt', 'talosconfig.dpapi') {
        Copy-Item (Join-Path $Stage $f) (Join-Path $data $f) -Force
        icacls (Join-Path $data $f) /reset | Out-Null
    }
    # talosctl.exe (mado.json の talos の先の talosctl)。ダッシュボードを開いている間は掴まれていて置き換えられない
    New-Item -ItemType Directory -Force "$data\bin" | Out-Null
    try { Copy-Item (Join-Path $Stage 'talosctl.exe') "$data\bin\talosctl.exe" -Force }
    catch { throw "talosctl.exe を置き換えられない (mado でダッシュボードを開いていれば閉じてから流し直す): $_" }
    icacls "$data\bin" /reset /T | Out-Null

    # --- MSI (サービス・ファイアウォール・ProgramData の権限)。新しい版なら古い版を外して入れ替える。同じ版ならそのまま ---
    # 受け渡しのフォルダは本人だけが読めるので、MSI を読む Windows Installer (SYSTEM) には読めない (1619 になる)。
    # SYSTEM と Administrators が読める ProgramData\mado に写してから入れる
    # 動いているほうが新しくて落としていなければ、MSI は飛ばす
    if (Test-Path (Join-Path $Stage 'mado.msi')) {
        $msi = Join-Path $data 'mado.msi'
        Copy-Item (Join-Path $Stage 'mado.msi') $msi -Force
        $msilog = Join-Path $env:TEMP "mado-msi-$(Get-Date -Format yyyyMMdd-HHmmss).log"
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msilog`""
        Remove-Item -LiteralPath $msi -Force
        # 3010 は「再起動が要る」で、mado には関係ない (ファイルの置き換えだけ)
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec ($($p.ExitCode))。ログ: $msilog" }
    }

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
