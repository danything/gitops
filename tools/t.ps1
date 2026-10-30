# 運用のコマンドを wslc (WSL コンテナ) で動かす。中身は compose.yaml の tools を wslc-compose run する。例:
#   tools/t.ps1 infisical login --domain https://il.doany.io/api
#   tools/t.ps1 sops -d bootstrap/infisical-secrets.sops.yaml
#   tools/t.ps1 kubectl get pods -A          # クラスタは読み取り用で繋ぐ
#   tools/t.ps1 --admin kubectl apply -f x   # 書くときだけ管理者 (tools/README.md「クラスタの資格情報」)
# 引数が無ければシェルに入る。Dockerfile を変えたら次の実行で作り直す (変わっていなければキャッシュで一瞬)。
#
# wslc はネットワークを host にできないので、infisical login のときだけブラウザの戻りを中継する (Start-LoginRelay)。
# cf auth login は未対応。uid は指定しない (Windows のファイルに持ち主の uid は無い)。
# 5.1 でも読めるように BOM 付きの UTF-8 にする (無いと Shift_JIS と読まれ構文が壊れる)。文字列は ASCII だけ
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$image = 'gitops-tools:latest'

# ログインと鍵の置き場 (コンテナの中の HOME)。git には入らない。自分だけが読める権限にする (chmod 700 相当)
$home_ = Join-Path $root '.home'
if (-not (Test-Path $home_)) {
    New-Item -ItemType Directory $home_ | Out-Null
    icacls $home_ /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
}

$build = wslc image build --tag $image --progress quiet (Join-Path $root 'tools') 2>&1
if ($LASTEXITCODE -ne 0) { $build | Write-Host; throw "tools: image build failed ($LASTEXITCODE)" }

# infisical login (ブラウザ方式) の中継。コンテナの中の CLI が待ち受けるポートを手元でも受け、wslc exec の curl で渡す。
# 受け付けるのはログイン先 ($origin) からの POST / OPTIONS だけ。リクエストの値はコマンドに埋め込まない
function Start-LoginRelay($name, $origin) {
    Start-Job -ArgumentList $name, $origin -ScriptBlock {
        param($name, $origin)
        $port = $null
        for ($i = 0; $i -lt 240 -and -not $port; $i++) {
            Start-Sleep -Milliseconds 500
            # /proc/net/tcp: 127.0.0.1 (0100007F) で LISTEN (0A) しているポート
            foreach ($l in (wslc exec $name cat /proc/net/tcp 2>$null)) {
                $f = -split $l
                if ($f.Count -gt 3 -and $f[1] -like '0100007F:*' -and $f[3] -eq '0A') { $port = [Convert]::ToInt32($f[1].Split(':')[1], 16) }
            }
        }
        if (-not $port) { 'relay: the login callback port was not found in the container'; return }
        try {
            $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
            $listener.Start()
        } catch { "relay: cannot listen on 127.0.0.1:${port}: $_"; return }
        while ($true) {
            $client = $listener.AcceptTcpClient()
            # 投機的な空の接続で止まらないように
            $client.ReceiveTimeout = 10000
            try {
                $s = $client.GetStream()
                $buf = New-Object byte[] 65536
                $data = New-Object IO.MemoryStream
                $headerEnd = -1
                while ($headerEnd -lt 0) {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $data.Write($buf, 0, $n)
                    $headerEnd = [Text.Encoding]::ASCII.GetString($data.ToArray()).IndexOf("`r`n`r`n")
                }
                if ($headerEnd -lt 0) { continue }
                $head = [Text.Encoding]::ASCII.GetString($data.ToArray(), 0, $headerEnd)
                $lines = $head -split "`r`n"
                $method = ($lines[0] -split ' ')[0]
                $h = @{}
                foreach ($l in $lines[1..($lines.Count - 1)]) { $k, $v = $l -split ':\s*', 2; $h[$k.ToLower()] = $v }
                $len = if ($h['content-length']) { [int]$h['content-length'] } else { 0 }
                while ($data.Length - $headerEnd - 4 -lt $len) {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $data.Write($buf, 0, $n)
                }
                $body = New-Object byte[] $len
                [Array]::Copy($data.ToArray(), $headerEnd + 4, $body, 0, $len)
                $cors = "Access-Control-Allow-Origin: $origin`r`nAccess-Control-Allow-Credentials: true`r`n" +
                    "Access-Control-Allow-Methods: POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`n" +
                    "Access-Control-Allow-Private-Network: true`r`nVary: Origin`r`n"
                if ($h['origin'] -ne $origin) {
                    $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 403 Forbidden`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                } elseif ($method -eq 'OPTIONS') {
                    $resp = "HTTP/1.1 204 No Content`r`n$cors" + "Content-Length: 0`r`nConnection: close`r`n`r`n"
                    $out = [Text.Encoding]::ASCII.GetBytes($resp)
                } elseif ($method -ne 'POST') {
                    $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 405 Method Not Allowed`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                } else {
                    # 埋め込むのは自分で決めた $name / $origin / $port だけ
                    $psi = New-Object Diagnostics.ProcessStartInfo 'wslc', ("exec --interactive $name curl -s -o /dev/null -w %{http_code} " +
                        "-X POST -H `"Content-Type: application/json`" -H `"Origin: $origin`" --data-binary @- http://127.0.0.1:$port/")
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardInput = $true
                    $psi.RedirectStandardOutput = $true
                    $p = [Diagnostics.Process]::Start($psi)
                    $p.StandardInput.BaseStream.Write($body, 0, $body.Length)
                    $p.StandardInput.Close()
                    $code = $p.StandardOutput.ReadToEnd().Trim()
                    $p.WaitForExit()
                    if ($code -notmatch '^\d{3}$') { $code = '502' }
                    $resp = "HTTP/1.1 $code Relayed`r`n$cors" + "Content-Length: 0`r`nConnection: close`r`n`r`n"
                    $out = [Text.Encoding]::ASCII.GetBytes($resp)
                }
                $s.Write($out, 0, $out.Length)
            } catch {
            } finally {
                $client.Close()
            }
        }
    }
}

# 設定は compose.yaml の tools。パイプやリダイレクトのときは TTY を付けない (-T)。
# パイプしたものは標準入力でなく $input に来るので下で流し直す。
# Test-NulStdin: 標準入力が NUL (FILE_TYPE_CHAR) か。ファイルやパイプからの入力は NUL と扱わない
function Test-NulStdin {
    if (-not [Console]::IsInputRedirected) { return $false }
    if (-not ('GitopsTools.Kernel32' -as [type])) {
        Add-Type -Namespace GitopsTools -Name Kernel32 -MemberDefinition (
            '[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);' +
            '[DllImport("kernel32.dll")] public static extern int GetFileType(System.IntPtr h);')
    }
    return [GitopsTools.Kernel32]::GetFileType([GitopsTools.Kernel32]::GetStdHandle(-10)) -eq 2
}
$piped = $MyInvocation.ExpectingInput
$opts = @('--rm')
if ($piped -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $opts += '-T' }
# 先頭の --admin は t.ps1 が受け取る。コンテナの中の kubectl / talosctl / helm が管理者の資格情報を使う (tools/creds.sh)
$rest = @($args)
if ($rest.Count -and $rest[0] -eq '--admin') {
    $opts += '-e', 'GITOPS_ADMIN=1'
    $rest = @($rest | Select-Object -Skip 1)
}
# 1 つのときも配列にする (でないと $cmd[0] が 1 文字目になる)
$cmd = @(if ($rest.Count) { $rest } else { 'bash' })

$relay = $null
$browserLogin = $cmd.Count -ge 2 -and $cmd[0] -eq 'infisical' -and $cmd[1] -eq 'login' -and
    -not ($cmd | Where-Object { $_ -match '^(-i|--interactive|--method)' })
if ($browserLogin) {
    # ブラウザのリクエストの Origin はログイン先 (--domain から /api を除いたもの)
    $domain = 'https://app.infisical.com'
    for ($i = 0; $i -lt $cmd.Count; $i++) {
        if ($cmd[$i] -eq '--domain' -and $i + 1 -lt $cmd.Count) { $domain = $cmd[$i + 1] }
        elseif ($cmd[$i] -like '--domain=*') { $domain = $cmd[$i].Substring(9) }
    }
    $origin = ([Uri]$domain).GetLeftPart([UriPartial]::Authority)
    $name = "gitops-tools-login-$PID"
    $opts += '--name', $name
    $relay = Start-LoginRelay $name $origin
}
try {
    $compose = Join-Path $root 'compose.yaml'
    if ($piped) {
        # ネイティブに流すと CRLF になり 5.1 では日本語が化けるので、LF の UTF-8 を base64 で渡す
        $text = (@($input) -join "`n") + "`n"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        # 7.3 より前 (5.1 も) は引数の中の " をネイティブのコマンドに渡すときにエスケープしないので、自分でする
        $wrap = 'base64 -d -i | "$@"'
        if ($PSVersionTable.PSVersion -lt [version]'7.3') { $wrap = $wrap.Replace('"', '\"') }
        $b64 | wslc-compose --file $compose run @opts tools sh -c $wrap sh @cmd
    } elseif (Test-NulStdin) {
        # 標準入力が NUL だと wslc-compose run の出力が落ちて ERROR_INVALID_HANDLE で終わる。空のパイプに置き換える
        @() | wslc-compose --file $compose run @opts tools @cmd
    } else {
        wslc-compose --file $compose run @opts tools @cmd
    }
    $code = $LASTEXITCODE
} finally {
    if ($relay) {
        Stop-Job $relay
        Receive-Job $relay -ErrorAction SilentlyContinue | ForEach-Object { Write-Warning $_ }
        Remove-Job $relay -Force
    }
}
exit $code
