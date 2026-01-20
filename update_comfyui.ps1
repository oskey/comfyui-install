$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# ===================== 前置：检查 Git 是否存在 =====================
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "❌ 未检测到 Git，请先安装 Git" -ForegroundColor Red
    exit 1
}

# ===================== 新增：修复 Git 可疑所有权问题 =====================
Write-Host "🔧 预处理 Git 目录权限问题..." -ForegroundColor Cyan
$currentDir = (Get-Location).Path

# 避免重复写入 safe.directory
$existingSafe = @()
try {
    $existingSafe = git config --global --get-all safe.directory 2>$null
} catch { }

if (-not ($existingSafe -contains $currentDir)) {
    git config --global --add safe.directory "$currentDir" | Out-Null
    if ($?) {
        Write-Host "✅ 已将 $currentDir 加入 Git 安全目录" -ForegroundColor Green
    } else {
        Write-Host "⚠️ 添加 Git 安全目录失败（可手动执行：git config --global --add safe.directory `"$currentDir`"）" -ForegroundColor Yellow
    }
} else {
    Write-Host "✅ Git 安全目录已包含：$currentDir" -ForegroundColor Green
}

# ===================== 检查 Git 仓库合法性 =====================
if (-not (Test-Path ".git" -PathType Container)) {
    Write-Host "❌ 当前目录不是 Git 仓库（未找到 .git 目录）" -ForegroundColor Red
    Write-Host "   请确认：1) 该目录是通过 git clone 下载的 ComfyUI；2) .git 目录未被删除" -ForegroundColor Yellow
    exit 1
}

# ===================== 检查远程仓库配置 =====================
Write-Host "🔍 检查远程仓库配置..." -ForegroundColor Cyan
$remoteList = @(git remote)

$targetRemote = $null
if (-not $remoteList -or $remoteList.Count -eq 0) {
    Write-Host "⚠️ 未配置任何远程仓库，常见的 ComfyUI 官方仓库地址：" -ForegroundColor Yellow
    Write-Host "   https://github.com/comfyanonymous/ComfyUI.git" -ForegroundColor Cyan
    $addRemote = Read-Host "是否自动添加官方远程仓库（命名为 origin）？(Y/N)"
    if ($addRemote -match '^[Yy]$') {
        git remote add origin https://github.com/comfyanonymous/ComfyUI.git
        if (-not $?) {
            Write-Host "❌ 添加远程仓库失败，请手动执行：git remote add origin https://github.com/comfyanonymous/ComfyUI.git" -ForegroundColor Red
            exit 1
        }
        $targetRemote = "origin"
        Write-Host "✅ 已添加官方远程仓库：origin" -ForegroundColor Green
    } else {
        Write-Host "❌ 未配置远程仓库，无法同步代码" -ForegroundColor Red
        exit 1
    }
} elseif ($remoteList -contains "origin") {
    $targetRemote = "origin"
    Write-Host "✅ 检测到远程仓库：origin" -ForegroundColor Green
} else {
    Write-Host "⚠️ 存在远程仓库，但没有名为 origin 的仓库，当前远程仓库列表：" -ForegroundColor Yellow
    $remoteList | ForEach-Object { Write-Host "  - $_" }
    $targetRemote = Read-Host "请输入要使用的远程仓库名称（从上面列表选择）"
    if (-not ($remoteList -contains $targetRemote)) {
        Write-Host "❌ 输入的远程仓库名称不存在" -ForegroundColor Red
        exit 1
    }
}

# ===================== 显示未跟踪文件（会保留） =====================
$untrackedFiles = @(git ls-files --others --exclude-standard)
if ($untrackedFiles -and $untrackedFiles.Count -gt 0) {
    Write-Host "ℹ️ 检测到本地新增的未跟踪文件（将被保留）：" -ForegroundColor Cyan
    $untrackedFiles | ForEach-Object { Write-Host "  - $_" }
    Write-Host ""
}

# ===================== 检测远程主分支（优先 main/master） =====================
Write-Host "🔍 正在检测远程仓库的分支..." -ForegroundColor Cyan
try {
    $remoteBranches = @(git ls-remote --heads $targetRemote | ForEach-Object { $_ -replace '^.*refs/heads/', '' })
} catch {
    Write-Host "❌ 获取远程分支失败，请检查网络或远程仓库地址（git remote -v）" -ForegroundColor Red
    exit 1
}

if (-not $remoteBranches -or $remoteBranches.Count -eq 0) {
    Write-Host "❌ 无法获取远程分支信息，请检查网络或仓库地址" -ForegroundColor Red
    exit 1
}

$possibleBranches = @("main", "master", "dev")
$defaultBranch = $null
foreach ($b in $possibleBranches) {
    if ($remoteBranches -contains $b) { $defaultBranch = $b; break }
}

if (-not $defaultBranch) {
    Write-Host "⚠️ 未找到常见主分支（main/master/dev），远程分支列表：" -ForegroundColor Yellow
    $remoteBranches | ForEach-Object { Write-Host "  - $_" }
    $defaultBranch = Read-Host "请输入要同步的远程分支名称（从上面列表选择）"
    if (-not ($remoteBranches -contains $defaultBranch)) {
        Write-Host "❌ 输入的分支不存在" -ForegroundColor Red
        exit 1
    }
}

Write-Host "✅ 将以远程分支为准：$defaultBranch" -ForegroundColor Green

# ===================== 处理分离头指针 / 切换到目标分支 =====================
$currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
$isDetached = ($currentBranch -eq "HEAD")

Write-Host "🔎 当前本地分支状态：$currentBranch" -ForegroundColor Cyan

# 先 fetch，保证本地 refs 更新
Write-Host "🔄 git fetch $targetRemote ..." -ForegroundColor Cyan
git fetch $targetRemote
if (-not $?) {
    Write-Host "❌ git fetch 失败，请检查网络或权限" -ForegroundColor Red
    exit 1
}

if ($isDetached) {
    Write-Host "⚠️ 处于「分离头指针」状态，准备切换到 $defaultBranch ..." -ForegroundColor Yellow

    # 如果本地已有该分支，直接 checkout；没有则创建并跟踪远程
    $localHas = @(git branch --list $defaultBranch)
    if ($localHas -and $localHas.Count -gt 0) {
        git checkout $defaultBranch | Out-Null
    } else {
        git checkout -b $defaultBranch "$targetRemote/$defaultBranch" | Out-Null
    }

    if (-not $?) {
        Write-Host "❌ 切换到 $defaultBranch 分支失败" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ 已切换到 $defaultBranch 分支" -ForegroundColor Green
} else {
    # 非 detached：如果当前分支不等于默认分支，仍然建议同步默认分支（避免把“你当前分支”当成主分支）
    if ($currentBranch -ne $defaultBranch) {
        Write-Host "⚠️ 当前在本地分支 $currentBranch，但远程默认分支是 $defaultBranch。" -ForegroundColor Yellow
        $useDefault = Read-Host "是否切换到 $defaultBranch 进行同步？(Y/N)"
        if ($useDefault -match '^[Yy]$') {
            $localHas = @(git branch --list $defaultBranch)
            if ($localHas -and $localHas.Count -gt 0) {
                git checkout $defaultBranch | Out-Null
            } else {
                git checkout -b $defaultBranch "$targetRemote/$defaultBranch" | Out-Null
            }
            if (-not $?) {
                Write-Host "❌ 切换到 $defaultBranch 失败" -ForegroundColor Red
                exit 1
            }
            Write-Host "✅ 已切换到 $defaultBranch 分支" -ForegroundColor Green
        } else {
            Write-Host "⏭️ 将在当前分支 $currentBranch 上同步（请确认这是你想更新的分支）" -ForegroundColor Gray
            $defaultBranch = $currentBranch
        }
    }
}

# ===================== 同步最新代码（保留未跟踪文件） =====================
Write-Host "🔄 正在同步远程 $targetRemote/$defaultBranch 的最新代码..." -ForegroundColor Cyan
git pull $targetRemote $defaultBranch
if (-not $?) {
    Write-Host "❌ 拉取代码失败，可能需要手动解决冲突（git status 查看）" -ForegroundColor Red
    exit 1
}

# ===================== 激活虚拟环境（强制使用 comfyui_venv） =====================
$venvPython = ".\comfyui_venv\Scripts\python.exe"
$venvActivate = ".\comfyui_venv\Scripts\Activate.ps1"

if (-not (Test-Path $venvPython)) {
    Write-Host "❌ 未检测到虚拟环境 python：$venvPython" -ForegroundColor Red
    Write-Host "   请先运行安装脚本创建 comfyui_venv" -ForegroundColor Yellow
    exit 1
}

# 校验 venv 版本必须是 3.13（避免被 3.10 的 venv 混淆）
$venvVer = (& $venvPython -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')").Trim()
if ($venvVer -ne "3.13") {
    Write-Host "❌ comfyui_venv 的 Python 版本不是 3.13（实际：$venvVer）。请重建 comfyui_venv。" -ForegroundColor Red
    exit 1
}

Write-Host "✅ 检测到 comfyui_venv (Python $venvVer)" -ForegroundColor Green

if (Test-Path $venvActivate) {
    Write-Host "✅ 激活虚拟环境 comfyui_venv" -ForegroundColor Cyan
    & $venvActivate
} else {
    Write-Host "⚠️ 找不到 Activate.ps1，但不影响使用 venv python 更新依赖" -ForegroundColor Yellow
}

# ===================== 更新依赖（强制走 venv python -m pip） =====================
if (Test-Path "requirements.txt") {
    Write-Host "📦 更新 Python 依赖 (requirements.txt)..." -ForegroundColor Green

    # 优先用 uv（更快），但仍强制使用 venv 的解释器来执行 pip（最稳）
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        # 让 uv 在当前已激活 venv 下工作
        uv pip install -r requirements.txt
    } else {
        & $venvPython -m pip install -U pip setuptools wheel
        & $venvPython -m pip install -r requirements.txt --upgrade
    }
} else {
    Write-Host "⚠️ 未找到 requirements.txt，跳过依赖更新" -ForegroundColor Yellow
}

# ===================== 显示当前版本信息 =====================
Write-Host "`n🔹 当前 ComfyUI 版本信息:" -ForegroundColor Cyan
git log -1 --pretty=format:"Commit: %H%nAuthor: %an%nDate: %ad%nMessage: %s"
Write-Host "`n"

Write-Host "✅ 同步完成！本地新增文件已保留" -ForegroundColor Green
pause
