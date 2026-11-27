$ErrorActionPreference = "Stop"

$RepoUrl = if ($env:CCG_REPO_URL) { $env:CCG_REPO_URL } else { "https://github.com/sglinhome/ccg.git" }
$BaseDir = Join-Path $env:USERPROFILE ".agents\skills"
$TargetDir = Join-Path $BaseDir "ccg"

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null

if (Test-Path (Join-Path $TargetDir ".git")) {
    Write-Output "[ccg] Updating existing installation in $TargetDir..."
    git -C $TargetDir pull --ff-only
} else {
    if (Test-Path $TargetDir) { Remove-Item $TargetDir -Recurse -Force }
    Write-Output "[ccg] Cloning $RepoUrl to $TargetDir..."
    git clone --depth 1 $RepoUrl $TargetDir
}

$GeminiSkills = Join-Path $env:USERPROFILE ".gemini\config\skills\ccg"
New-Item -ItemType Directory -Force -Path $GeminiSkills | Out-Null
Copy-Item "$TargetDir\*" $GeminiSkills -Recurse -Force

$CfgPath = Join-Path $env:USERPROFILE ".ccg.json"
if (-not (Test-Path $CfgPath)) {
    Write-Output ""
    Write-Output "[ccg] Next step: create $CfgPath with your Magpie Gateway key:"
    Write-Output '{"baseUrl":"http://10.89.10.199:3425/v1","apiKey":"YOUR_GATEWAY_KEY","planModel":"group/plan-review","codeModel":"group/code-pro","timeoutSec":120}'
} else {
    Write-Output "[ccg] Found existing $CfgPath"
}

Write-Output "[ccg] Installed successfully!"
