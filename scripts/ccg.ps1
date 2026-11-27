<#
.SYNOPSIS
  CCG (Claude-Codex-Gemini) Windows PowerShell - Zero-dependency multi-model orchestrator.
  Calls Magpie Gateway (/v1/chat/completions) for debate, review, and consult modes.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("debate", "review", "consult")]
    [string]$Mode,

    [string]$Prompt = "",
    [string[]]$ContextFile = @(),
    [string]$RepoPath = "",
    [ValidateSet(1, 2)]
    [int]$Rounds = 2,
    [string]$BaseUrl = "",
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-CouncilConfig {
    $cfg = @{
        baseUrl    = "http://10.89.10.199:3425/v1"
        apiKey     = ""
        planModel  = "group/plan-review"
        codeModel  = "group/code-pro"
        timeoutSec = 120
    }
    $cfgPath = Join-Path $env:USERPROFILE ".ccg.json"
    if (-not (Test-Path $cfgPath)) {
        $cfgPath = Join-Path $env:USERPROFILE ".magpie-council.json"
    }
    if (Test-Path $cfgPath) {
        $raw = [System.IO.File]::ReadAllText($cfgPath, $utf8NoBom) | ConvertFrom-Json
        foreach ($k in @("baseUrl", "apiKey", "planModel", "codeModel", "timeoutSec")) {
            if ($null -ne $raw.$k -and "$($raw.$k)" -ne "") { $cfg[$k] = $raw.$k }
        }
    }
    if ($env:MAGPIE_BASE_URL) { $cfg.baseUrl = $env:MAGPIE_BASE_URL }
    if ($env:MAGPIE_API_KEY)  { $cfg.apiKey  = $env:MAGPIE_API_KEY }
    if ($BaseUrl) { $cfg.baseUrl = $BaseUrl }
    if ($ApiKey)  { $cfg.apiKey  = $ApiKey }

    if (-not $cfg.apiKey) {
        throw "Missing Magpie API key. Set MAGPIE_API_KEY or create ~/.ccg.json."
    }
    $cfg.baseUrl = $cfg.baseUrl.TrimEnd("/")
    return $cfg
}

function Expand-ContextPaths {
    param([string[]]$RawPaths)
    $expanded = @()
    foreach ($item in $RawPaths) {
        if (-not $item) { continue }
        if (-not (Test-Path -LiteralPath $item) -and $item.Contains(",")) {
            foreach ($part in ($item -split ",")) {
                $trimmed = $part.Trim()
                if ($trimmed) { $expanded += $trimmed }
            }
        } else {
            $expanded += $item
        }
    }
    return ,$expanded
}

function Read-BoundedFile {
    param([string]$Path, [int]$Limit)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $probeLen = [Math]::Min(4096, [int]$fs.Length)
        if ($probeLen -gt 0) {
            $probe = New-Object byte[] $probeLen
            $readBytes = $fs.Read($probe, 0, $probeLen)
            for ($i = 0; $i -lt $readBytes; $i++) {
                if ($probe[$i] -eq 0) { return @{ IsBinary = $true; Text = "" } }
            }
            $fs.Position = 0
        }
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        $buf = New-Object char[] ($Limit + 1)
        $total = 0
        while ($total -lt ($Limit + 1)) {
            $n = $sr.Read($buf, $total, ($Limit + 1 - $total))
            if ($n -le 0) { break }
            $total += $n
        }
        $txt = New-Object string($buf, 0, $total)
        return @{ IsBinary = $false; Text = $txt }
    } finally {
        $fs.Dispose()
    }
}

function Read-ContextFiles {
    param([string[]]$Paths, [int]$MaxChars = 24000)
    $norm = Expand-ContextPaths -RawPaths $Paths
    if (-not $norm -or $norm.Count -eq 0) { return "" }
    $chunks = @()
    $used = 0
    foreach ($p in $norm) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            $chunks += "### File: $p (not found)"
            continue
        }
        $rem = $MaxChars - $used
        if ($rem -le 0) {
            $chunks += "### File: $p (omitted due to budget)"
            continue
        }
        try {
            $res = Read-BoundedFile -Path (Resolve-Path -LiteralPath $p).Path -Limit $rem
        } catch {
            $chunks += "### File: $p (read error: $($_.Exception.Message))"
            continue
        }
        if ($res.IsBinary) {
            $chunks += "### File: $p (binary file skipped)"
            continue
        }
        $txt = $res.Text
        if ($txt.Length -gt $rem) {
            $txt = $txt.Substring(0, $rem) + "`n...[truncated]..."
        }
        $used += $txt.Length
        $chunks += "### File: $p`n``````n$txt`n``````"
    }
    return ($chunks -join "`n`n")
}

function Get-GitDiffText {
    param([string]$Repo, [int]$MaxChars = 30000)
    $stagedLines = & git -C $Repo diff --cached 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git diff --cached failed in $Repo`: $($stagedLines -join ' ')" }
    $unstagedLines = & git -C $Repo diff 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git diff failed in $Repo`: $($unstagedLines -join ' ')" }
    $untrackedLines = & git -C $Repo ls-files --others --exclude-standard 2>$null
    $untrackedFiles = if ($LASTEXITCODE -eq 0 -and $untrackedLines) {
        @($untrackedLines | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    } else { @() }

    $sections = @()
    $used = 0
    $staged   = ($stagedLines -join "`n").Trim()
    $unstaged = ($unstagedLines -join "`n").Trim()
    $trackedDiff = (@($staged, $unstaged) | Where-Object { $_ }) -join "`n"
    if ($trackedDiff) {
        if ($trackedDiff.Length -gt $MaxChars) {
            $trackedDiff = $trackedDiff.Substring(0, $MaxChars) + "`n...[diff truncated]..."
        }
        $sections += "### Tracked Git Diff`n``````diff`n$trackedDiff`n``````"
        $used += $trackedDiff.Length
    }

    foreach ($rel in $untrackedFiles) {
        $rem = $MaxChars - $used
        if ($rem -le 0) {
            $sections += "### Untracked New File: $rel (omitted due to budget)"
            continue
        }
        $fullPath = Join-Path $Repo $rel
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        try {
            $res = Read-BoundedFile -Path $fullPath -Limit $rem
            if ($res.IsBinary) {
                $sections += "### Untracked New File: $rel (binary skipped)"
                continue
            }
            $txt = $res.Text
            if ($txt.Length -gt $rem) {
                $txt = $txt.Substring(0, $rem) + "`n...[truncated]..."
            }
            $used += $txt.Length
            $sections += "### Untracked New File: $rel`n``````n$txt`n``````"
        } catch {
            $sections += "### Untracked New File: $rel (read error: $($_.Exception.Message))"
        }
    }

    if ($sections.Count -eq 0) {
        $st = (& git -C $Repo status --short 2>$null) -join "`n"
        return "(No tracked diff or untracked files; git status:`n$st)"
    }
    return ($sections -join "`n`n")
}

function Invoke-SingleChatWithRetry {
    param([System.Net.Http.HttpClient]$Client, [string]$Url, [hashtable]$Call, [int]$MaxRetries = 2)
    $retryCodes = @(408, 429, 500, 502, 503, 504)
    $bodyObj = @{
        model      = $Call.Model
        messages   = @(
            @{ role = "system"; content = $Call.System },
            @{ role = "user";   content = $Call.User }
        )
        max_tokens = 8192
    }
    $json = $bodyObj | ConvertTo-Json -Depth 5
    $lastErr = ""

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $content = New-Object System.Net.Http.StringContent($json, $utf8NoBom, "application/json")
        try {
            $resp  = $Client.PostAsync($Url, $content).GetAwaiter().GetResult()
            $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $raw   = [System.Text.Encoding]::UTF8.GetString($bytes)
            $code  = [int]$resp.StatusCode

            if (-not $resp.IsSuccessStatusCode) {
                $snip = if ($raw.Length -gt 300) { $raw.Substring(0, 300) } else { $raw }
                $lastErr = "HTTP $code`: $snip"
                if (($retryCodes -contains $code) -and ($attempt -lt $MaxRetries)) {
                    Start-Sleep -Milliseconds ([int](1500 * ($attempt + 1)))
                    continue
                }
                return @{ Label = $Call.Label; Ok = $false; Model = $Call.Model; Text = $lastErr }
            }

            $parsed = $raw | ConvertFrom-Json
            $choice = $parsed.choices[0]
            $msgObj = $choice.message
            $txt = if ($msgObj.content) { "$($msgObj.content)" } elseif ($msgObj.reasoning_content) { "$($msgObj.reasoning_content)" } else { "" }
            $txt = $txt.Trim()
            if ($choice.finish_reason -eq "length") {
                $txt += "`n`n[WARN: Output truncated due to max_tokens=8192 limit]"
            }
            $served = if ($parsed.model) { "$($parsed.model)" } else { $Call.Model }
            $upstream = $null
            foreach ($hk in @("x-magpie-model", "x-upstream-model", "x-magpie-provider", "openai-model")) {
                $vals = $null
                if ($resp.Headers.TryGetValues($hk, [ref]$vals)) {
                    $v = ($vals | Select-Object -First 1)
                    if ($v -and $v -ne $served) { $upstream = $v; break }
                }
            }
            if ($upstream) { $served = "$served [$upstream]" }
            return @{ Label = $Call.Label; Ok = $true; Model = $served; Text = $txt }
        } catch {
            $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            $lastErr = "Error: $msg"
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Milliseconds ([int](1500 * ($attempt + 1)))
                continue
            }
            return @{ Label = $Call.Label; Ok = $false; Model = $Call.Model; Text = $lastErr }
        }
    }
    return @{ Label = $Call.Label; Ok = $false; Model = $Call.Model; Text = $lastErr }
}

function Invoke-ParallelChats {
    param($Cfg, [array]$Calls)
    Add-Type -AssemblyName System.Net.Http
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $Calls.Count))
    $pool.Open()
    $workerScript = ${function:Invoke-SingleChatWithRetry}.ToString()

    $jobs = @()
    foreach ($c in $Calls) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript("
            param(`$Cfg, `$Call, `$WorkerDef)
            Add-Type -AssemblyName System.Net.Http
            `$utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
            Set-Item -Path Function:\Invoke-Worker -Value `$WorkerDef
            `$client = New-Object System.Net.Http.HttpClient
            `$client.Timeout = [TimeSpan]::FromSeconds([int]`$Cfg.timeoutSec)
            `$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', `$Cfg.apiKey)
            try {
                return (Invoke-Worker -Client `$client -Url (`$Cfg.baseUrl + '/chat/completions') -Call `$Call)
            } finally {
                `$client.Dispose()
            }
        ").AddArgument($Cfg).AddArgument($c).AddArgument($workerScript)
        $jobs += @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $results = @()
    foreach ($j in $jobs) {
        try {
            $out = $j.PS.EndInvoke($j.Handle)
            $results += $out[0]
        } finally {
            $j.PS.Dispose()
        }
    }
    $pool.Close()
    $pool.Dispose()
    return ,$results
}

try {
    $cfg = Get-CouncilConfig
    $ctx = Read-ContextFiles -Paths $ContextFile

    if ($Mode -eq "debate") {
        if (-not $Prompt) { throw "-Prompt is required for debate mode." }
        $archSys = "You are the Adversarial Architect (Pre-Mortem Reviewer) in the CCG council. Assume the naive solution will fail in production: uncover hidden assumptions, concurrency/state traps, security boundaries, and edge cases, then propose a resilient architecture & verification plan. Respond in Chinese."
        $engSys  = "You are the Pragmatic Staff Engineer in the CCG council. Optimize for simplicity, minimal code churn, zero unnecessary abstractions, and concrete step-by-step execution with exact file boundaries and failure handling. Respond in Chinese."
        $userMsg = "## Task`n$Prompt"
        if ($ctx) { $userMsg += "`n`n## Context`n$ctx" }

        $r1 = Invoke-ParallelChats -Cfg $cfg -Calls @(
            @{ Label = "Architect"; Model = $cfg.planModel; System = $archSys; User = $userMsg },
            @{ Label = "Engineer";  Model = $cfg.codeModel; System = $engSys;  User = $userMsg }
        )
        $arch1 = $r1[0]; $eng1 = $r1[1]
        Write-Output "=== [Round 1] Architect (Pre-Mortem & Architecture) ==="
        Write-Output "(model: $($arch1.Model))`n$($arch1.Text)`n"
        Write-Output "=== [Round 1] Engineer (Pragmatic Minimal Implementation) ==="
        Write-Output "(model: $($eng1.Model))`n$($eng1.Text)`n"

        if (-not $arch1.Ok -and -not $eng1.Ok) { exit 1 }

        if (-not ($arch1.Ok -and $eng1.Ok)) {
            $failedSide = if (-not $arch1.Ok) { "Architect" } else { "Engineer" }
            Write-Output "[WARN / DEGRADED] $failedSide failed after retries; Round 2 cross-critique skipped (single-model degraded mode)!`n"
            exit 0
        }

        if ($Rounds -ge 2) {
            $critSys = "You are reviewing a peer model's engineering proposal. Point out concrete flaws, missing edge cases, unnecessary complexity, or security risks, then state the optimal merged steps. Be concise and respond in Chinese."
            $a2User = "Original Task:`n$Prompt`n`nYour Proposal:`n$($arch1.Text)`n`nPeer Engineer Proposal:`n$($eng1.Text)`n`nCritique the peer proposal and merge into the best final plan."
            $e2User = "Original Task:`n$Prompt`n`nYour Proposal:`n$($eng1.Text)`n`nPeer Architect Proposal:`n$($arch1.Text)`n`nCritique the peer proposal and flag any over-engineering or feasibility issues."
            $r2 = Invoke-ParallelChats -Cfg $cfg -Calls @(
                @{ Label = "Architect"; Model = $cfg.planModel; System = $critSys; User = $a2User },
                @{ Label = "Engineer";  Model = $cfg.codeModel; System = $critSys; User = $e2User }
            )
            Write-Output "=== [Round 2] Architect Cross-Critique & Merged Plan ==="
            Write-Output "(model: $($r2[0].Model))`n$($r2[0].Text)`n"
            Write-Output "=== [Round 2] Engineer Cross-Critique ==="
            Write-Output "(model: $($r2[1].Model))`n$($r2[1].Text)`n"
        }
    }
    elseif ($Mode -eq "review") {
        $diffText = if ($RepoPath) { Get-GitDiffText -Repo $RepoPath } else { "" }
        $revSys = "You are a strict Senior Code Reviewer. Audit the changes (both tracked diffs and newly created files) for bugs, security issues, missing edge cases, encoding/concurrency traps, and regressions. Categorize every finding strictly as [Blocker], [Concern], or [Nit] with exact file/line references. If clean, state LGTM. Respond in Chinese."
        $parts = @()
        if ($Prompt)   { $parts += "## Review Goal`n$Prompt" }
        if ($diffText) { $parts += "## Repository Changes`n$diffText" }
        if ($ctx)      { $parts += "## Files Context`n$ctx" }
        if ($parts.Count -eq 0) { throw "Review requires -RepoPath, -ContextFile, or -Prompt." }

        $r = Invoke-ParallelChats -Cfg $cfg -Calls @(
            @{ Label = "Reviewer"; Model = $cfg.planModel; System = $revSys; User = ($parts -join "`n`n") }
        )
        Write-Output "=== Senior Diff Review ==="
        Write-Output "(model: $($r[0].Model))`n$($r[0].Text)`n"
        if (-not $r[0].Ok) { exit 1 }
    }
    elseif ($Mode -eq "consult") {
        if (-not $Prompt) { throw "-Prompt is required for consult mode." }
        $conSys = "You are a Senior Technical Advisor. Give a direct, grounded, pragmatic recommendation and point out pitfalls to avoid. Respond in Chinese."
        $userMsg = $Prompt + $(if ($ctx) { "`n`n## Context`n$ctx" } else { "" })
        $r = Invoke-ParallelChats -Cfg $cfg -Calls @(
            @{ Label = "Advisor"; Model = $cfg.planModel; System = $conSys; User = $userMsg }
        )
        Write-Output "=== Technical Advisor ==="
        Write-Output "(model: $($r[0].Model))`n$($r[0].Text)`n"
        if (-not $r[0].Ok) { exit 1 }
    }
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
