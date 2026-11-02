# 運用のコマンドを wslc (WSL コンテナ) で動かす。中身は compose.yaml の tools を wslc-compose run する。例:
#   tools/t.ps1 sops edit deploy/matrix/secrets.sops.yaml
#   tools/t.ps1 sops -d bootstrap/cert-manager-values.sops.yaml
#   tools/t.ps1 kubectl get pods -A          # クラスタは読み取り用で繋ぐ
#   tools/t.ps1 --admin kubectl apply -f x   # 書くときだけ管理者 (tools/README.md「クラスタの資格情報」)
# 引数が無ければシェルに入る。Dockerfile を変えたら次の実行で作り直す (変わっていなければキャッシュで一瞬)。
#
# wslc はネットワークを host にできないので、ブラウザから戻ってくる方式のログイン (cf auth login など) は使えない。
# uid は指定しない (Windows のファイルに持ち主の uid は無い)。
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
exit $LASTEXITCODE
