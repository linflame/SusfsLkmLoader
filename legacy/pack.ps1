# SUSFS LKM Loader (legacy) repack script
# 更新源: 首选 Gitee (解析 releases 页面, 不用 API 避免限流), 失败回退 GitHub (API 限流时解析 release 页面, 可设 GH_TOKEN 提额)
# 公共文件 (kos / susfs_insmod / upstream_version / 脚本) 在 ../shared, 本地版本 = shared/upstream_version
# 产物: modules/SUSFS_LKM_legacy.zip + modules/update.json + modules/changelog.md (nightly 模式, 地址恒定, 管理器凭 versionCode 判断升级)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'inforcqb/susfs4ksu-lkm'
$sources = @('gitee', 'github')
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$shared = Join-Path (Split-Path -Parent $root) 'shared'

$headers = @{ 'User-Agent' = 'susfs-lkm-pack' }
if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }

# update.json / changelog.md 经 jsDelivr 镜像读取 (raw 国内不可直连), zip 在 nightly release; 默认值可用环境变量覆盖 (CI 按实际分支注入)
$UpdateJsonUrl = if ($env:SUSFS_UPDATE_JSON_URL) { $env:SUSFS_UPDATE_JSON_URL } else { 'https://cdn.jsdelivr.net/gh/linflame/SusfsLkmLoader@main/modules/update.json' }
$ChangelogUrl  = if ($env:SUSFS_CHANGELOG_URL)  { $env:SUSFS_CHANGELOG_URL }  elseif ($UpdateJsonUrl) { $UpdateJsonUrl -replace '[^/]+$', 'changelog.md' } else { '' }
$ZipUrlBase    = if ($env:SUSFS_ZIP_URL_BASE)    { $env:SUSFS_ZIP_URL_BASE }    else { 'https://github.com/linflame/SusfsLkmLoader/releases/download/nightly/' }
$ZipOut        = 'SUSFS_LKM_legacy.zip'
$modDir        = Join-Path (Split-Path -Parent $root) 'modules'
New-Item -ItemType Directory -Path $modDir -Force | Out-Null

function Write-ModuleProp([string]$tag, [int]$code) {
    $lines = @(
        'id=SUSFS_LKM',
        'name=SUSFS LKM Loader',
        "version=$tag",
        "versionCode=$code",
        'author=linflame & 酷安@只是不够强',
        "description=Auto load susfs kernel module on boot (KernelSU via ksud, other root via bundled susfs_insmod). Upstream: $repo $tag"
    )
    if ($UpdateJsonUrl) { $lines += "updateJson=$UpdateJsonUrl" }
    # [IO.File] 相对路径按进程 cwd 解析, 必须用绝对路径
    [IO.File]::WriteAllText((Join-Path $root 'build\module.prop'), ($lines -join "`n") + "`n")
}

# 管理器更新: changelog 字段指向 markdown 地址, 更新内容写入 modules/changelog.md
function Write-UpdateJson([string]$tag, [int]$code, [string]$zipName) {
    if (-not $UpdateJsonUrl) { return }
    $md = "# 更新日志`n`n## $tag`n`n- 同步上游更新，susfs 版本号：$tag`n"
    [IO.File]::WriteAllText((Join-Path $modDir 'changelog.md'), $md)
    $j = [ordered]@{
        version     = $tag
        versionCode = $code
        zipUrl      = "$ZipUrlBase$zipName"
    }
    if ($ChangelogUrl) { $j.changelog = $ChangelogUrl }
    [IO.File]::WriteAllText((Join-Path $modDir 'update.json'), ($j | ConvertTo-Json) + "`n")
    Write-Host "      已生成 update.json + changelog.md (versionCode $code)"
}

$upfile = Join-Path $shared 'upstream_version'
if (-not (Test-Path $upfile)) { throw "本地 upstream_version 不存在: $upfile" }
$localTag = (Get-Content $upfile -Raw).Trim()
if (-not $localTag) { throw "upstream_version 文件为空" }
$vc = 1
$m2 = Select-String -Path 'build\module.prop' -Pattern '^versionCode=(\d+)' -ErrorAction SilentlyContinue
if ($m2) { $vc = [int]$m2.Matches[0].Groups[1].Value }
Write-Host "本地版本: $localTag (versionCode $vc)"

# versionCode 由上游 tag 推导: v2.3.0-r18.1 -> 230181 (每段固定占位, 位数恒定、严格单调; 上限: 主/次/修订 <10, r<100, 子修订 <10)
function Get-VersionCode([string]$tag) {
    if ($tag -match '^v?(\d+)\.(\d+)\.(\d+)(?:-r(\d+)(?:\.(\d+))?)?$') {
        $R = 0; $s = 0
        if ($Matches[4]) { $R = [int]$Matches[4] }
        if ($Matches[5]) { $s = [int]$Matches[5] }
        return [int]$Matches[1] * 100000 + [int]$Matches[2] * 10000 + [int]$Matches[3] * 1000 + $R * 10 + $s
    }
    throw "无法从上游 tag 推导 versionCode: $tag"
}

function Get-LatestRelease([string]$src) {
    if ($src -eq 'gitee') {
        try {
            $html = (Invoke-WebRequest -Uri "https://gitee.com/$repo/releases" -Headers $headers -UseBasicParsing).Content
            $tm = [regex]::Match($html, [regex]::Escape($repo) + '/releases/tag/([^"?#<"]+)')
            if (-not $tm.Success) { throw "页面中未找到 release tag" }
            $tag = $tm.Groups[1].Value
            $assets = @()
            foreach ($am in [regex]::Matches($html, [regex]::Escape("$repo/releases/download/$tag/") + '([^"?#<"]+)')) {
                $assets += [PSCustomObject]@{
                    name = [Uri]::UnescapeDataString($am.Groups[1].Value)
                    size = 0
                    url  = "https://gitee.com/$repo/releases/download/$tag/" + $am.Groups[1].Value
                }
            }
            $assets = @($assets | Group-Object name | ForEach-Object { $_.Group[0] })
            if ($assets.Count -eq 0) { throw "页面解析未找到 $tag 的附件" }
            return [PSCustomObject]@{ source = 'gitee'; tag = $tag; assets = $assets }
        } catch {
            Write-Host "      gitee 查询失败: $($_.Exception.Message)"
            return $null
        }
    }
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
        $assets = @($rel.assets | ForEach-Object {
            [PSCustomObject]@{ name = $_.name; size = [long]$_.size; url = $_.browser_download_url }
        })
        return [PSCustomObject]@{ source = 'github'; tag = [string]$rel.tag_name; assets = $assets }
    } catch {
        Write-Host "      github API 不可用 ($($_.Exception.Message)), 改用 release 页面解析 ..."
        try {
            $resp = Invoke-WebRequest -Uri "https://github.com/$repo/releases/latest" -Headers $headers -UseBasicParsing
            $tag = ($resp.BaseResponse.ResponseUri.AbsolutePath -split '/')[-1]
            $html = (Invoke-WebRequest -Uri "https://github.com/$repo/releases/expanded_assets/$tag" -Headers $headers -UseBasicParsing).Content
            $assets = @()
            foreach ($mm in [regex]::Matches($html, 'href="(/' + [regex]::Escape($repo) + '/releases/download/[^"]+)"')) {
                $u = $mm.Groups[1].Value
                $assets += [PSCustomObject]@{
                    name = [Uri]::UnescapeDataString(($u -split '/')[-1])
                    size = 0
                    url  = 'https://github.com' + $u
                }
            }
            if ($assets.Count -eq 0) { throw "页面解析未找到 $tag 的附件" }
            return [PSCustomObject]@{ source = 'github'; tag = $tag; assets = $assets }
        } catch {
            Write-Host "      github 页面解析失败: $($_.Exception.Message)"
            return $null
        }
    }
}

# 拼接 shared/ (公共) + build/ (线专有) 到临时目录后打包; $files 中 shared 没有的从 build 取
function Pack-Module([string]$out, [string[]]$files) {
    $koCount = (Get-ChildItem (Join-Path $shared 'kos') -Filter 'susfs_guard_lkm-*.ko' -ErrorAction SilentlyContinue).Count
    if ($koCount -eq 0) { throw "shared\kos 下没有 ko 文件, 无法打包" }
    if (-not (Test-Path (Join-Path $shared 'susfs_insmod'))) { throw "shared\susfs_insmod 缺失, 无法打包" }
    $stage = Join-Path $root '.pack_tmp'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($f in $files) {
        $src = Join-Path $shared $f
        if (-not (Test-Path $src)) { $src = Join-Path 'build' $f }
        if (-not (Test-Path $src)) { Remove-Item $stage -Recurse -Force; throw "缺少打包文件: $f" }
        Copy-Item $src (Join-Path $stage $f) -Recurse
    }
    if (Test-Path $out) { Remove-Item $out -Force }
    # 不能用 Compress-Archive: zip 条目名会写成反斜杠, Android 端解压后 ko 提取失败. 用 Windows 自带 bsdtar.
    $tar = "$env:SystemRoot\System32\tar.exe"
    if (-not (Test-Path $tar)) { throw "bsdtar not found at $tar (Windows 10 1803+ is required)" }
    & $tar -acf $out -C $stage $files
    Remove-Item $stage -Recurse -Force
    if ($LASTEXITCODE -ne 0) { throw "tar pack failed (exit $LASTEXITCODE)" }
    return $koCount
}

$packFiles = @('customize.sh', 'module.prop', 'post-fs-data.sh', 'service.sh', 'uninstall.sh', 'susfs_insmod', 'kos')

Write-Host "[1/3] Querying latest release of $repo (首选 gitee) ..."
$rel = $null
foreach ($s in $sources) {
    $rel = Get-LatestRelease $s
    if ($rel -and $rel.tag) { break }
}
if ($rel) {
    Write-Host "      上游最新: $($rel.tag) [来源: $($rel.source)]"
} else {
    Write-Host "      !! 所有更新源均不可用, 按本地版本处理"
}

# 无更新: 本地已有 zip 则停止, 否则打包本地版本 (versionCode 不递增)
if (-not $rel -or $rel.tag -eq $localTag) {
    $out = Join-Path $modDir $ZipOut
    if (Test-Path $out) {
        Write-Host ""
        Write-Host "无更新 ($localTag), 且本地构建 $out 已存在, 停止打包."
        exit 0
    }
    Write-Host "[2/3] 无更新, 本地无构建 -> 打包本地版本 $localTag (versionCode 保持 $vc) ..."
    Write-ModuleProp $localTag $vc
    $kc = Pack-Module $out $packFiles
    Write-UpdateJson $localTag $vc $ZipOut
    Write-Host ""
    Write-Host "Done: $out  (本地版本 $localTag, versionCode $vc 未变, $kc kernels + susfs_insmod)"
    exit 0
}

# 有更新: 拉取 ko + loader 到 shared, version = 上游 tag, versionCode 由 tag 推导
$tag = $rel.tag
$assets = @($rel.assets | Where-Object { $_.name -like 'susfs_guard_lkm-*.ko' -or $_.name -eq 'susfs_insmod' })
$koCount = ($assets | Where-Object { $_.name -like '*.ko' }).Count
if ($koCount -eq 0) { throw "No susfs_guard_lkm-*.ko assets found in release $tag" }
if (-not ($assets | Where-Object { $_.name -eq 'susfs_insmod' })) { throw "No susfs_insmod loader found in release $tag" }
Write-Host "[2/3] 发现更新 $localTag -> $tag, 下载 $koCount kernels + susfs_insmod [$($rel.source)] ..."
$kosDir = Join-Path $shared 'kos'
if (Test-Path $kosDir) {
    Remove-Item "$kosDir\*.ko" -Force
} else {
    New-Item -ItemType Directory -Path $kosDir | Out-Null
}
foreach ($a in $assets) {
    if ($a.name -eq 'susfs_insmod') {
        $dst = Join-Path $shared $a.name
    } else {
        $dst = Join-Path $kosDir $a.name
    }
    Write-Host "      $($a.name)"
    $ok = $false
    for ($try = 1; $try -le 3 -and -not $ok; $try++) {
        try {
            Invoke-WebRequest -Uri $a.url -OutFile $dst -Headers $headers
            $ok = $true
        } catch {
            Write-Host "      download attempt $try failed: $($_.Exception.Message)"
            if ($try -lt 3) { Start-Sleep -Seconds (3 * $try) }
        }
    }
    if (-not $ok) { throw "Download failed after 3 attempts: $($a.name)" }
    $len = (Get-Item $dst).Length
    if ($a.size -gt 0 -and $len -ne $a.size) { throw "Size mismatch after download: $($a.name)" }
    if ($len -lt 10000) { throw "Downloaded file suspiciously small: $($a.name)" }
}

$vc = Get-VersionCode $tag
Write-Host "[3/3] 更新 module.prop 并打包 (versionCode=$vc) ..."
Write-ModuleProp $tag $vc
[IO.File]::WriteAllText($upfile, "$tag`n")

$out = Join-Path $modDir $ZipOut
$kc = Pack-Module $out $packFiles
Write-UpdateJson $tag $vc $ZipOut

Write-Host ""
Write-Host "Done: $out  (upstream $tag [$($rel.source)], versionCode $vc, $kc kernels + susfs_insmod)"
