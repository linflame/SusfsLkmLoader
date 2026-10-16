# SUSFS LKM Loader (next) pack script
# next 线已冻结: 模块 version 固定 1.0 / versionCode 1, 不查上游、不带更新配置
# 公共文件 (kos / susfs_insmod / upstream_version / 脚本) 在 ../shared
# 产物: ../modules/SUSFS_LKM_next.zip
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$shared = Join-Path (Split-Path -Parent $root) 'shared'

$modDir = Join-Path (Split-Path -Parent $root) 'modules'
New-Item -ItemType Directory -Path $modDir -Force | Out-Null
$out = Join-Path $modDir 'SUSFS_LKM_next.zip'

$tag = ((Get-Content (Join-Path $shared 'upstream_version') -Raw).Trim())
if (-not $tag) { throw "shared\upstream_version 为空" }

$lines = @(
    'id=SUSFS_LKM',
    'name=SUSFS LKM Loader',
    'version=1.0',
    'versionCode=1',
    'author=linflame & 酷安@只是不够强',
    "description=Auto load susfs kernel module on boot. Current version = $tag. 加载状态读 /data/adb/susfs_lkm.log: OK loaded=😋加载成功, ERROR=😭加载失败"
)
[IO.File]::WriteAllText((Join-Path $root 'build\module.prop'), ($lines -join "`n") + "`n")

# 拼接 shared/ (公共) + build/ (线专有) 到临时目录后打包
$files = @('customize.sh', 'module.prop', 'post-fs-data.sh', 'service.sh', 'uninstall.sh',
           'action.sh', 'updater.sh', 'webui.sh', 'kmi.sh', 'load.sh', 'susfs_insmod', 'upstream_version', 'kos', 'webroot')
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
& $tar -acf $out -C $stage $files
Remove-Item $stage -Recurse -Force
if ($LASTEXITCODE -ne 0) { throw "tar pack failed (exit $LASTEXITCODE)" }

$koCount = (Get-ChildItem (Join-Path $shared 'kos') -Filter 'susfs_guard_lkm-*.ko').Count
Write-Host "Done: $out  (模块 1.0 / susfs $tag, $koCount kernels + susfs_insmod)"
