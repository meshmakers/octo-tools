<#
    Feature environments (AB#8700): small, isolated lane folders at <rootPath>/wt-<env>/. An environment IS an
    octo-claude-pm lane: <env> is the lane name, wt-<env> its lane folder (agent-operating-rules §4, the worktree sweep
    knows <lane-root>/wt-*/ folders), and environments are discovered by <rootPath>/wt-*/.octo/environment.json.

    An environment holds git worktrees of the repositories a feature changes (role feature, on the feature branch)
    and of the repositories that must be rebuilt against them (role consumer, detached at the base checkout's
    upstream commit, origin/main; -localBase: the local checkout's commit), plus its own feed (nuget/), package cache (.nuget-packages/), CK and blueprint catalogs (.octo/), logs
    (logFiles/) and an Octo.User.props that declares RestorePackagesPath. The folders keep the plain repository names,
    so ../nuget, ../.octo/local-catalog, Find-OctoLaneRoot and Get-OctoBuildOrder resolve inside the environment and
    plain dotnet builds, Rider and Invoke-Build are isolated without extra properties.

    octo-tools owns everything on disk and every build; octo-devstack reads .octo/environment.json (schemaVersion 1,
    written only here) and runs the services. Main's packages and catalogs are copied as a snapshot (Sync-OctoEnvironment),
    never added as a second NuGet source.
#>

$script:ManifestSchemaVersion = 1
$script:DefaultBase = 'branches/main'
$script:CatalogFolders = @('local-catalog', 'local-blueprint-catalog')
$script:IgnoredSyncFiles = @('.catalog-index.lock', '.DS_Store')
# Developer tools that live next to the lanes (<rootPath>/<repo>), not in the base lane; never built here.
$script:ToolRepos = @('octo-tools', 'octo-devstack')

# ---------------------------------------------------------------------------------------------------------------
# Paths, names, manifest
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoEnvironmentRootPath {
    # The workspace root ($rootPath of profile.ps1). Environments live in <root>/wt-<env>.
    $root = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        throw "`$rootPath is not set - load modules/profile.ps1 first."
    }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$root))
}

function Test-OctoEnvironmentName {
    param([string]$env)
    return ($env -cmatch '^[a-z0-9][a-z0-9-]{1,62}$')
}

function Get-OctoEnvironmentPath {
    # Absolute folder of an environment; throws for an invalid name.
    param([Parameter(Mandatory = $true)] [string]$env)
    if (-not (Test-OctoEnvironmentName -env $env)) {
        throw "Invalid environment name '$env': use a lower-case slug or octo-claude-pm lane name (a-z, 0-9, '-'), 2-63 characters, e.g. ab8625-enum-null or odysseus-kind."
    }
    return Join-Path (Get-OctoEnvironmentRootPath) "wt-$env"
}

function Get-OctoEnvironmentBasePath {
    param([Parameter(Mandatory = $true)] [string]$base)
    if ([IO.Path]::IsPathRooted($base)) { return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($base)) }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path (Get-OctoEnvironmentRootPath) $base)))
}

function Test-OctoPathInside {
    # $true when $path is $parent or lies below it (separator-aware, case-insensitive).
    param([string]$path, [string]$parent)
    $p = ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path)) -replace '\\', '/') + '/'
    $q = ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($parent)) -replace '\\', '/') + '/'
    return $p.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)
}

function Get-OctoEnvironmentManifestPath {
    param([Parameter(Mandatory = $true)] [string]$environmentPath)
    return Join-Path $environmentPath '.octo/environment.json'
}

function Read-OctoEnvironmentManifest {
    # The manifest as an ordered hashtable, or $null when the environment does not exist.
    param([Parameter(Mandatory = $true)] [string]$env)
    $path = Get-OctoEnvironmentManifestPath -environmentPath (Get-OctoEnvironmentPath -env $env)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $manifest['repos'] = @($manifest['repos'] | Where-Object { $null -ne $_ })
    return $manifest
}

function Write-OctoEnvironmentManifest {
    param(
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest
    )
    $path = Get-OctoEnvironmentManifestPath -environmentPath $environmentPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $ordered = [ordered]@{
        schemaVersion = $script:ManifestSchemaVersion
        name          = $manifest['name']
        workItem      = $manifest['workItem']
        base          = $manifest['base']
        created       = $manifest['created']
        owner         = $manifest['owner']
        repos         = @($manifest['repos'] | ForEach-Object {
                [ordered]@{ name = $_['name']; role = $_['role']; path = $_['path']; branch = $_['branch']; baseCommit = $_['baseCommit']; baseRef = $_['baseRef'] }
            })
        slot          = $manifest['slot']
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 6
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-OctoEnvironmentUserPropsContent {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string]$base,
        [Parameter(Mandatory = $true)] [string]$basePath
    )
    $baseProps = (Join-Path $basePath 'Octo.User.props') -replace '\\', '/'
    return @"
<Project>
    <!-- Feature environment $env (generated by New-OctoEnvironment, octo-tools). Do not edit by hand.
         The base lane's Octo.User.props is imported for its settings; the environment's package cache
         below overrides any RestorePackagesPath it declares. -->
    <PropertyGroup>
        <OctoEnvironment>$env</OctoEnvironment>
        <OctoEnvironmentBase>$base</OctoEnvironmentBase>
    </PropertyGroup>
    <Import Project="$baseProps" Condition="Exists('$baseProps')" />
    <PropertyGroup>
        <RestorePackagesPath>`$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>
    </PropertyGroup>
</Project>
"@
}

function ConvertTo-OctoWorkItem {
    param([string]$workItem)
    if ([string]::IsNullOrWhiteSpace($workItem)) { return $null }
    if ($workItem -match '^(?i:AB#)?(\d+)$') { return "AB#$($Matches[1])" }
    throw "Invalid work item '$workItem': use AB#<id> or <id>."
}

function Get-OctoEnvironmentDefaultBranchName {
    # <user>/AB#<id>_<desc> (agent-operating-rules), <user>/<desc> without a work item. <desc> is the
    # environment name without a leading ab<id>- prefix.
    param([string]$env, [string]$workItem)
    $user = ([Environment]::UserName).ToLowerInvariant() -replace '[^a-z0-9._-]', ''
    if ([string]::IsNullOrWhiteSpace($user)) { $user = 'dev' }
    $desc = $env -replace '^ab\d+-', ''
    if ([string]::IsNullOrWhiteSpace($desc)) { $desc = $env }
    if ($workItem) { return "$user/$($workItem)_$desc" }
    return "$user/$desc"
}

# ---------------------------------------------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------------------------------------------

function Invoke-OctoEnvironmentGit {
    # Runs git in a folder; returns { ExitCode; Output (string[]) }. Never throws on a non-zero exit.
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [string[]]$arguments,
        # Network calls (ls-remote, fetch): git must fail instead of asking for credentials on the terminal - an
        # agent or octo-devstack run would hang on the prompt. Configured credential helpers keep working.
        [switch]$noPrompt
    )
    if (-not $noPrompt) {
        $output = @(& git -C $path @arguments 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    $previous = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $output = @(& git -C $path @arguments 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    finally { $env:GIT_TERMINAL_PROMPT = $previous }
}

function Get-OctoEnvironmentRepoSource {
    # The main checkout an environment worktree of $repo is added from: <base>/<repo>, or for a developer tool
    # (octo-tools, octo-devstack) the checkout next to the lanes, <rootPath>/<repo>. $null when neither is a git checkout.
    param([Parameter(Mandatory = $true)] [string]$repo, [Parameter(Mandatory = $true)] [string]$basePath)
    $folder = Join-Path $basePath $repo
    if (Test-Path -LiteralPath (Join-Path $folder '.git')) { return $folder }
    if ($script:ToolRepos -contains $repo) {
        $folder = Join-Path (Get-OctoEnvironmentRootPath) $repo
        if (Test-Path -LiteralPath (Join-Path $folder '.git')) { return $folder }
    }
    return $null
}

function Test-OctoEnvironmentToolRepo {
    # octo-tools / octo-devstack: developer tools, never built by Invoke-BuildEnvironment (Get-OctoBuildOrder skips them).
    param([string]$repo)
    return ($script:ToolRepos -contains $repo)
}

function Resolve-OctoEnvironmentRepoName {
    # Exact folder name in the base lane, or the name with "octo-" prepended; the developer tools octo-tools and
    # octo-devstack also resolve next to the lanes (<rootPath>/<repo>). Throws when neither exists.
    param([Parameter(Mandatory = $true)] [string]$repo, [Parameter(Mandatory = $true)] [string]$basePath)
    foreach ($candidate in @($repo, "octo-$repo")) {
        if (Get-OctoEnvironmentRepoSource -repo $candidate -basePath $basePath) { return $candidate }
    }
    throw "Repository '$repo' is not a git checkout in $basePath$(if (($script:ToolRepos -contains $repo) -or ($script:ToolRepos -contains "octo-$repo")) { " or $(Get-OctoEnvironmentRootPath)" })."
}

function Resolve-OctoEnvironmentBase {
    <#
        The commit a new environment worktree starts from, for one main checkout.
        Default: the upstream of the checkout's current branch (branches/main: origin/main), fetched first; a checkout
        without an upstream (detached HEAD, local-only branch) uses origin's default branch (asked from origin; when
        origin is unreachable the local origin/HEAD, else origin/main, origin/master). -localBase, or no usable remote ref: the checkout's HEAD.
        Returns { Commit; Ref ('origin/main' | 'HEAD'); LocalCommit; Ahead; Behind (local HEAD against Commit);
        Fetched; Warnings }.
    #>
    param([Parameter(Mandatory = $true)] [string]$source, [switch]$localBase)
    $head = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0) { throw "git rev-parse HEAD failed in ${source}: $($head.Output -join ' ')" }
    $local = [string]($head.Output | Select-Object -Last 1)
    $result = [ordered]@{ Commit = $local; Ref = 'HEAD'; LocalCommit = $local; Ahead = 0; Behind = 0; Fetched = $false; Warnings = @() }
    if ($localBase) { return [pscustomobject]$result }

    $repo = Split-Path -Leaf $source
    $remoteRef = $null
    $upstream = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ($upstream.ExitCode -eq 0) { $remoteRef = [string]($upstream.Output | Select-Object -Last 1) }
    if (-not $remoteRef -or $remoteRef -notmatch '^[^/]+/.+') {
        $remoteRef = $null
        # Ask origin for its default branch: the local origin/HEAD is set at clone time and goes stale when the
        # default branch is renamed. The tracking ref may not exist yet - the fetch below creates it.
        $symref = Invoke-OctoEnvironmentGit -path $source -arguments @('ls-remote', '--symref', 'origin', 'HEAD') -noPrompt
        $current = @($symref.Output | ForEach-Object { if ($_ -match '^ref:\s+refs/heads/(\S+)\s+HEAD$') { $Matches[1] } }) | Select-Object -First 1
        if ($symref.ExitCode -eq 0 -and $current) { $remoteRef = "origin/$current" }
        else {
            # origin unreachable: what the checkout last knew (the failed fetch below warns).
            $originHead = Invoke-OctoEnvironmentGit -path $source -arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
            $candidates = @()
            if ($originHead.ExitCode -eq 0) { $candidates += [string]($originHead.Output | Select-Object -Last 1) }
            $candidates += 'origin/main', 'origin/master'
            foreach ($candidate in $candidates) {
                if ((Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/$candidate")).ExitCode -eq 0) { $remoteRef = $candidate; break }
            }
        }
    }
    if (-not $remoteRef) {
        $result.Warnings = @("${repo}: no upstream branch and no origin default branch - based on the local checkout's HEAD.")
        return [pscustomobject]$result
    }
    $remote, $branch = $remoteRef -split '/', 2
    # Explicit destination: a single-branch clone has no fetch refspec for another branch, and a plain
    # `git fetch <remote> <branch>` would then leave no remote-tracking ref behind.
    $fetch = Invoke-OctoEnvironmentGit -path $source -arguments @('fetch', '--quiet', $remote, "+refs/heads/${branch}:refs/remotes/$remote/$branch") -noPrompt
    $result.Fetched = $fetch.ExitCode -eq 0
    if (-not $result.Fetched) { $result.Warnings += "${repo}: git fetch $remote $branch failed - $remoteRef is used as last fetched." }
    $commit = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/$remoteRef^{commit}")
    if ($commit.ExitCode -ne 0) {
        $result.Warnings += "${repo}: $remoteRef does not exist - based on the local checkout's HEAD."
        return [pscustomobject]$result
    }
    $result.Commit = [string]($commit.Output | Select-Object -Last 1)
    $result.Ref = $remoteRef
    if ($result.Commit -ne $local) {
        $count = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-list', '--left-right', '--count', "$local...$($result.Commit)")
        if ($count.ExitCode -eq 0 -and ([string]($count.Output | Select-Object -Last 1)) -match '^(\d+)\s+(\d+)$') {
            $result.Ahead = [int]$Matches[1]
            $result.Behind = [int]$Matches[2]
        }
        $result.Warnings += "${repo}: the local checkout $source is $($result.Behind) commit(s) behind and $($result.Ahead) ahead of $remoteRef - the worktree starts from $remoteRef ($($result.Commit.Substring(0, [Math]::Min(10, $result.Commit.Length)))); pass -localBase to start from the local checkout instead."
    }
    return [pscustomobject]$result
}

function Get-OctoEnvironmentRepoState {
    <#
        Dirty / unpushed state of an environment worktree (Remove-OctoEnvironment refuses either).
        unpushed: commits on top of the base commit that are on no remote branch; unpushedCommits names them
        ('<short sha> <subject>'). -checkMerged (Remove-OctoEnvironment, AB#8953): when there are unpushed commits,
        also asks whether their changes are already on origin's default branch - after a squash or rebase merge
        GitHub deletes the branch, so the commits are on no remote although nothing would be lost
        (Test-OctoEnvironmentWorkMerged). merged / mergedVia / mergedInto / pullRequest report the answer;
        unmergedCommits names the commits that are not on the base branch; mergeCheck says why the check could not
        decide (base branch unknown, ...).
    #>
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$repo, [switch]$checkMerged)
    $path = [string]$repo['path']
    $state = [ordered]@{
        name = $repo['name']; role = $repo['role']; path = $path; exists = $false; dirty = $false; unpushed = 0
        unpushedCommits = @(); merged = $false; mergedVia = $null; mergedInto = $null; pullRequest = $null
        unmergedCommits = @(); mergeCheck = $null; problem = $null
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return [pscustomobject]$state }
    $state.exists = $true
    $status = Invoke-OctoEnvironmentGit -path $path -arguments @('status', '--porcelain')
    if ($status.ExitCode -ne 0) {
        $state.problem = "git status failed: $($status.Output -join ' ')"
        return [pscustomobject]$state
    }
    $state.dirty = @($status.Output | Where-Object { $_ }).Count -gt 0
    # Work done in the environment that no remote has: commits on top of the base commit that are on no remote
    # branch (the base commit itself may be an unpushed commit of the base checkout - not this environment's work).
    $exclude = @('--not', '--remotes')
    if ($repo['baseCommit']) { $exclude += [string]$repo['baseCommit'] }
    $unpushed = Invoke-OctoEnvironmentGit -path $path -arguments (@('rev-list', '--format=%h %s', '--no-commit-header', 'HEAD') + $exclude)
    if ($unpushed.ExitCode -ne 0) {
        $state.problem = "git rev-list failed: $($unpushed.Output -join ' ')"
        return [pscustomobject]$state
    }
    $state.unpushedCommits = @($unpushed.Output | Where-Object { $_ })
    $state.unpushed = $state.unpushedCommits.Count
    if ($checkMerged -and $state.unpushed -gt 0) {
        $merge = Test-OctoEnvironmentWorkMerged -path $path -branch ([string]$repo['branch']) -unpushedCommits $state.unpushedCommits
        $state.merged = $merge.Merged
        $state.mergedVia = $merge.Via
        $state.mergedInto = $merge.Into
        $state.pullRequest = $merge.PullRequest
        $state.unmergedCommits = @($merge.Unmerged)
        $state.mergeCheck = $merge.Note
    }
    return [pscustomobject]$state
}

function Resolve-OctoEnvironmentDefaultBranch {
    <#
        origin's default branch for a worktree, fetched first, as a remote-tracking ref ('origin/main'); $null when
        there is none. Returns { Ref; Fetched; Note }. The name is asked from origin (ls-remote --symref), else the
        local origin/HEAD, origin/main, origin/master; a failed fetch keeps the last fetched state (Note says so).
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    $result = [ordered]@{ Ref = $null; Fetched = $false; Note = $null }
    $branch = $null
    $symref = Invoke-OctoEnvironmentGit -path $path -arguments @('ls-remote', '--symref', 'origin', 'HEAD') -noPrompt
    if ($symref.ExitCode -eq 0) {
        $branch = @($symref.Output | ForEach-Object { if ($_ -match '^ref:\s+refs/heads/(\S+)\s+HEAD$') { $Matches[1] } }) | Select-Object -First 1
    }
    if (-not $branch) {
        $originHead = Invoke-OctoEnvironmentGit -path $path -arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
        $candidates = @()
        if ($originHead.ExitCode -eq 0) { $candidates += [string]($originHead.Output | Select-Object -Last 1) }
        $candidates += 'origin/main', 'origin/master'
        foreach ($candidate in $candidates) {
            if ((Invoke-OctoEnvironmentGit -path $path -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/$candidate")).ExitCode -eq 0) { $branch = ($candidate -split '/', 2)[1]; break }
        }
    }
    if (-not $branch) { $result.Note = 'origin has no default branch'; return [pscustomobject]$result }
    $fetch = Invoke-OctoEnvironmentGit -path $path -arguments @('fetch', '--quiet', 'origin', "+refs/heads/${branch}:refs/remotes/origin/$branch") -noPrompt
    $result.Fetched = $fetch.ExitCode -eq 0
    if ((Invoke-OctoEnvironmentGit -path $path -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$branch^{commit}")).ExitCode -ne 0) {
        $result.Note = "origin/$branch does not exist (fetch failed)"
        return [pscustomobject]$result
    }
    $result.Ref = "origin/$branch"
    if (-not $result.Fetched) { $result.Note = "git fetch origin $branch failed - checked against origin/$branch as last fetched" }
    return [pscustomobject]$result
}

function Invoke-OctoEnvironmentGh {
    # Runs gh in a folder; returns { ExitCode; Output (string[]) }, ExitCode -1 when gh is not installed. Never throws.
    param([Parameter(Mandatory = $true)] [string]$path, [Parameter(Mandatory = $true)] [string[]]$arguments)
    if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ ExitCode = -1; Output = @('gh is not installed') } }
    $previous = $env:GH_PROMPT_DISABLED
    $env:GH_PROMPT_DISABLED = '1'
    Push-Location -LiteralPath $path
    try {
        $output = @(& gh @arguments 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    catch { return [pscustomobject]@{ ExitCode = 1; Output = @($_.Exception.Message) } }
    finally { Pop-Location; $env:GH_PROMPT_DISABLED = $previous }
}

function Test-OctoEnvironmentWorkMerged {
    <#
        Whether the unpushed commits of a worktree are already on origin's default branch (AB#8953), so removing the
        worktree loses nothing. Checked in this order, the first that holds wins (Via):
          patch       every unpushed commit has a patch-equivalent commit on the base branch (rebase merge, cherry-pick;
                      git cherry);
          tree        every file the branch changed since its merge base is identical on the base branch (squash
                      merge; also when the branch's net change is empty);
          squash      the branch's whole change as one patch equals a commit on the base branch (squash merge whose
                      files the base branch changed again later; git cherry of a temporary squash commit - an
                      unreferenced object, removed by git gc);
          pullRequest a merged GitHub pull request of the branch into the default branch whose head is exactly HEAD
                      (gh, when installed and logged in; nothing committed after the merge).
        Returns { Merged; Via; Into ('origin/main'); PullRequest ({ number; url } | $null); Unmerged (the unpushed
        commits not on the base branch, '<short sha> <subject>'); Note }.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [string]$branch,
        [Parameter(Mandatory = $true)] [string[]]$unpushedCommits
    )
    $result = [ordered]@{ Merged = $false; Via = $null; Into = $null; PullRequest = $null; Unmerged = @($unpushedCommits); Note = $null }
    $base = Resolve-OctoEnvironmentDefaultBranch -path $path
    $result.Note = $base.Note
    if (-not $base.Ref) { return [pscustomobject]$result }
    $result.Into = $base.Ref
    $head = [string]((Invoke-OctoEnvironmentGit -path $path -arguments @('rev-parse', 'HEAD')).Output | Select-Object -Last 1)
    $mergeBase = Invoke-OctoEnvironmentGit -path $path -arguments @('merge-base', 'HEAD', $base.Ref)
    if ($mergeBase.ExitCode -ne 0) {
        $result.Note = (@($result.Note, "HEAD has no merge base with $($base.Ref)") | Where-Object { $_ }) -join '; '
        return [pscustomobject]$result
    }
    $fork = [string]($mergeBase.Output | Select-Object -Last 1)

    # patch: git cherry marks the commits of fork..HEAD with '-' when the base branch has an equivalent change. An
    # unpushed commit at or before the fork is on the base branch itself (fast-forward merge); a commit after the fork
    # that git cherry does not mark '-' (also a merge commit, which it does not list) is not.
    $cherry = Invoke-OctoEnvironmentGit -path $path -arguments @('cherry', '--abbrev=40', $base.Ref, 'HEAD', $fork)
    $afterFork = Invoke-OctoEnvironmentGit -path $path -arguments @('rev-list', "$fork..HEAD")
    if ($cherry.ExitCode -eq 0 -and $afterFork.ExitCode -eq 0) {
        $equivalent = @{}
        foreach ($line in $cherry.Output) { if ($line -match '^-\s+([0-9a-f]+)') { $equivalent[$Matches[1]] = $true } }
        $pending = @{}
        foreach ($commit in $afterFork.Output) { if ($commit) { $pending[[string]$commit] = $true } }
        $result.Unmerged = @($unpushedCommits | Where-Object {
                $full = [string]((Invoke-OctoEnvironmentGit -path $path -arguments @('rev-parse', "$(($_ -split ' ', 2)[0])^{commit}")).Output | Select-Object -Last 1)
                $pending.ContainsKey($full) -and -not $equivalent.ContainsKey($full)
            })
        if ($result.Unmerged.Count -eq 0) { $result.Merged = $true; $result.Via = 'patch'; return [pscustomobject]$result }
    }

    # tree: no file the branch changed differs from the base branch (renames as delete + add, so both paths count).
    $changed = Invoke-OctoEnvironmentGit -path $path -arguments @('diff', '--no-renames', '--name-only', '-z', $fork, 'HEAD')
    $differs = Invoke-OctoEnvironmentGit -path $path -arguments @('diff', '--no-renames', '--name-only', '-z', $base.Ref, 'HEAD')
    if ($changed.ExitCode -eq 0 -and $differs.ExitCode -eq 0) {
        $split = { param($output) @(($output -join "`n") -split "`0" | Where-Object { $_ }) }
        $differing = @{}
        foreach ($file in (& $split $differs.Output)) { $differing[$file] = $true }
        if (@((& $split $changed.Output) | Where-Object { $differing.ContainsKey($_) }).Count -eq 0) {
            $result.Merged = $true; $result.Via = 'tree'; $result.Unmerged = @(); return [pscustomobject]$result
        }
    }

    # squash: the branch's whole change as one commit on the merge base, compared by patch id with the base branch.
    $squash = Invoke-OctoEnvironmentGit -path $path -arguments @('-c', 'user.name=octo-tools', '-c', 'user.email=octo-tools@localhost', 'commit-tree', 'HEAD^{tree}', '-p', $fork, '-m', 'octo-tools merge check')
    if ($squash.ExitCode -eq 0) {
        $squashCommit = [string]($squash.Output | Select-Object -Last 1)
        $squashCherry = Invoke-OctoEnvironmentGit -path $path -arguments @('cherry', $base.Ref, $squashCommit, $fork)
        if ($squashCherry.ExitCode -eq 0 -and @($squashCherry.Output | Where-Object { $_ -match '^-\s' }).Count -eq 1 -and @($squashCherry.Output | Where-Object { $_ -match '^\+\s' }).Count -eq 0) {
            $result.Merged = $true; $result.Via = 'squash'; $result.Unmerged = @(); return [pscustomobject]$result
        }
    }

    # pullRequest: a merged PR of this branch whose head is exactly HEAD.
    if ($branch) {
        # The configured URL, not get-url: url.<base>.insteadOf may rewrite it to a mirror.
        $remoteUrl = [string]((Invoke-OctoEnvironmentGit -path $path -arguments @('config', '--get', 'remote.origin.url')).Output | Select-Object -Last 1)
        if ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?/?$') {
            # Only a PR into the default branch: one merged into release/x leaves main without the change.
            $defaultBranch = $base.Ref -replace '^origin/', ''
            $gh = Invoke-OctoEnvironmentGh -path $path -arguments @('pr', 'list', '--repo', "$($Matches[1])/$($Matches[2])", '--head', $branch, '--state', 'merged', '--base', $defaultBranch, '--json', 'number,url,headRefOid')
            if ($gh.ExitCode -eq 0) {
                try {
                    $pr = @(($gh.Output -join "`n") | ConvertFrom-Json) | Where-Object { $_.headRefOid -eq $head } | Select-Object -First 1
                    if ($pr) {
                        $result.Merged = $true; $result.Via = 'pullRequest'; $result.Unmerged = @()
                        $result.PullRequest = [ordered]@{ number = $pr.number; url = $pr.url }
                        return [pscustomobject]$result
                    }
                }
                catch { }
            }
        }
    }
    return [pscustomobject]$result
}

function Add-OctoEnvironmentWorktree {
    <#
        Creates one worktree. Returns { Entry (manifest entry); Source (main checkout); CreatedBranch (the branch this
        call created, $null when it existed or for a consumer); Base (Resolve-OctoEnvironmentBase) }. Throws on failure.
        baseCommit in the manifest is the commit the worktree started from: the base commit (origin's, or the local
        HEAD with -localBase) for a consumer and a new feature branch; for an existing feature branch its merge base
        with the base commit. Commits on top of it that no remote has are the environment's unpushed work.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$basePath,
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$repo,
        [Parameter(Mandatory = $true)] [ValidateSet('feature', 'consumer')] [string]$role,
        [string]$branchName = '',
        [switch]$localBase
    )
    $source = Get-OctoEnvironmentRepoSource -repo $repo -basePath $basePath
    if (-not $source) { throw "Repository '$repo' is not a git checkout in $basePath." }
    $target = Join-Path $environmentPath $repo
    if (Test-Path -LiteralPath $target) { throw "$target already exists." }
    $base = Resolve-OctoEnvironmentBase -source $source -localBase:$localBase
    $baseCommit = $base.Commit
    $createdBranch = $null

    if ($role -eq 'consumer') {
        $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', '--detach', $target, $baseCommit)
        $branch = $null
    }
    else {
        $local = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$branchName")
        $remote = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$branchName")
        if ($local.ExitCode -eq 0 -or $remote.ExitCode -eq 0) {
            # Existing branch (resumed work): check it out; git creates the tracking branch from origin when needed.
            $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', $target, $branchName)
            if ($local.ExitCode -ne 0 -and $add.ExitCode -eq 0) { $createdBranch = $branchName }   # local tracking branch made by this call
            $existing = if ($local.ExitCode -eq 0) { "refs/heads/$branchName" } else { "refs/remotes/origin/$branchName" }
            $mergeBase = Invoke-OctoEnvironmentGit -path $source -arguments @('merge-base', $existing, $baseCommit)
            if ($mergeBase.ExitCode -eq 0 -and $mergeBase.Output) { $baseCommit = [string]($mergeBase.Output | Select-Object -Last 1) }
            # The branch decides where the worktree stands, not the base: no drift to report.
            $base = [pscustomobject]@{ Commit = $baseCommit; Ref = $branchName; LocalCommit = $baseCommit; Ahead = 0; Behind = 0; Fetched = $base.Fetched; Warnings = @() }
        }
        else {
            # --no-track: the feature branch must not get origin/main as its upstream (a plain push would target it).
            $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', '--no-track', '-b', $branchName, $target, $baseCommit)
            if ($add.ExitCode -eq 0) { $createdBranch = $branchName }
        }
        $branch = $branchName
    }
    if ($add.ExitCode -ne 0) { throw "git worktree add failed for ${repo}: $($add.Output -join ' ')" }
    return [pscustomobject]@{
        Entry         = [ordered]@{ name = $repo; role = $role; path = [IO.Path]::GetFullPath($target); branch = $branch; baseCommit = $baseCommit; baseRef = $base.Ref }
        Source        = $source
        CreatedBranch = $createdBranch
        Base          = $base
    }
}

function ConvertTo-OctoBaseDriftRow {
    # One -Json row of baseDrift: a worktree that does not start from the base lane checkout's commit.
    param([Parameter(Mandatory = $true)] $added)
    return [ordered]@{
        repo = $added.Entry['name']; role = $added.Entry['role']; baseRef = $added.Base.Ref; baseCommit = $added.Base.Commit
        localCommit = $added.Base.LocalCommit; behind = $added.Base.Behind; ahead = $added.Base.Ahead
    }
}

function Get-OctoEnvironmentFeedSnapshotReport {
    <#
        The environment's feed is a snapshot of the base lane's packages, built there from the LOCAL checkouts. With
        worktrees based on origin (the default) two things can be out of step:
          - rebuildInEnvironment: environment repositories whose worktree is newer than the base lane checkout. Their seeded packages are older than their sources; Invoke-BuildEnvironment
            rebuilds them into the environment feed.
          - staleProducers: libraries OUTSIDE the environment that an environment repository consumes (transitively)
            and whose base lane checkout is behind its upstream (fetched here; a failed fetch uses the ref as last fetched). Their
            seeded packages can lack what the newer consumers need (CS0246); nothing in the environment rebuilds them.
        Both are derived from the manifest (every repository of the environment, not only the ones a call added):
        a worktree is newer when its baseCommit has commits the base lane checkout's HEAD lacks.
        Returns { rebuildInEnvironment; staleProducers = @({ repo; behind; upstream; consumedBy }); hints }.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest,
        [Parameter(Mandatory = $true)] [string]$basePath
    )
    $rebuild = @()
    foreach ($repo in $manifest['repos']) {
        if (-not $repo['baseCommit'] -or (Test-OctoEnvironmentToolRepo -repo $repo['name'])) { continue }
        $source = Get-OctoEnvironmentRepoSource -repo ([string]$repo['name']) -basePath $basePath
        if (-not $source) { continue }
        $newer = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-list', '--count', "HEAD..$($repo['baseCommit'])")
        if ($newer.ExitCode -eq 0 -and [int]($newer.Output | Select-Object -Last 1) -gt 0) { $rebuild += [string]$repo['name'] }
    }
    $stale = @()
    if ($rebuild.Count -gt 0) {
        $inEnvironment = @($manifest['repos'] | ForEach-Object { $_['name'] })
        $set = @(Get-OctoEnvironmentRepoSet -manifest $manifest -basePath $basePath)
        $graph = Get-OctoAffectedRepoGraph -repos $set -features @()
        # producersOf[consumer] = producers it references
        $producersOf = @{}
        foreach ($producer in $graph.Consumers.Keys) {
            foreach ($edge in $graph.Consumers[$producer]) {
                if (-not $producersOf.ContainsKey($edge.Consumer)) { $producersOf[$edge.Consumer] = [System.Collections.Generic.List[string]]::new() }
                if (-not $producersOf[$edge.Consumer].Contains($producer)) { $producersOf[$edge.Consumer].Add($producer) }
            }
        }
        $consumedBy = @{}
        foreach ($name in $rebuild) {
            $seen = @{ $name = $true }
            $queue = [System.Collections.Generic.Queue[string]]::new()
            $queue.Enqueue($name)
            while ($queue.Count -gt 0) {
                $current = $queue.Dequeue()
                if (-not $producersOf.ContainsKey($current)) { continue }
                foreach ($producer in $producersOf[$current]) {
                    if ($seen.ContainsKey($producer)) { continue }
                    $seen[$producer] = $true
                    $queue.Enqueue($producer)
                    if ($inEnvironment -contains $producer) { continue }
                    if (-not $consumedBy.ContainsKey($producer)) { $consumedBy[$producer] = [System.Collections.Generic.List[string]]::new() }
                    if (-not $consumedBy[$producer].Contains($name)) { $consumedBy[$producer].Add($name) }
                }
            }
        }
        foreach ($entry in $set) {
            if (-not $consumedBy.ContainsKey($entry.Name)) { continue }
            $upstream = Invoke-OctoEnvironmentGit -path $entry.Path -arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
            $ref = if ($upstream.ExitCode -eq 0) { [string]($upstream.Output | Select-Object -Last 1) } else { 'origin/main' }
            if ($ref -match '^([^/]+)/(.+)$') { [void](Invoke-OctoEnvironmentGit -path $entry.Path -arguments @('fetch', '--quiet', $Matches[1], $Matches[2]) -noPrompt) }
            $count = Invoke-OctoEnvironmentGit -path $entry.Path -arguments @('rev-list', '--count', "HEAD..refs/remotes/$ref")
            if ($count.ExitCode -ne 0) { continue }
            $behind = [int]($count.Output | Select-Object -Last 1)
            if ($behind -gt 0) { $stale += [ordered]@{ repo = $entry.Name; behind = $behind; upstream = $ref; consumedBy = @($consumedBy[$entry.Name]) } }
        }
    }
    $hints = @()
    if ($rebuild.Count -gt 0) {
        $hints += "The feed was seeded with the packages $basePath built from its local checkouts; $($rebuild -join ', ') start from a newer commit than those packages. Invoke-BuildEnvironment -env $env rebuilds them into the environment feed."
    }
    if ($stale.Count -gt 0) {
        $first = $stale[0]['repo']
        $hints += "Libraries outside the environment are behind their upstream in ${basePath}: $(@($stale | ForEach-Object { "$($_['repo']) ($($_['behind']) behind $($_['upstream']), consumed by $($_['consumedBy'] -join ', '))" }) -join '; '). Their seeded packages may lack what the newer consumers need (CS0246). Either add them (Add-OctoEnvironmentRepo -env $env -repo $first -role consumer, then Invoke-BuildEnvironment), or update and rebuild them in the base lane and run Sync-OctoEnvironment -env $env."
    }
    return [ordered]@{ rebuildInEnvironment = $rebuild; staleProducers = $stale; hints = $hints }
}

# ---------------------------------------------------------------------------------------------------------------
# Existing worktrees (octo-claude-pm flat wt-<lane>-<repo>, Claude Code <repo>/.claude/worktrees/<name>)
# ---------------------------------------------------------------------------------------------------------------

function Test-OctoEnvironmentRepoInPlace {
    # An adopted worktree recorded with -inPlace: its folder is not <env>/<repo>.
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$repo, [Parameter(Mandatory = $true)] [string]$environmentPath)
    $expected = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path $environmentPath $repo['name'])))
    $actual = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$repo['path']))
    return -not ($expected -ieq $actual)
}

function Get-OctoWorktreeInfo {
    <#
        Facts about a linked git worktree: repository name (folder of the main checkout that owns it), common git dir,
        main checkout, branch (null when detached), HEAD and whether git has it locked. Throws for a folder that is no
        linked worktree (a main checkout or a plain folder is never adopted).
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    $full = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path))
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "$full does not exist." }
    if (-not (Test-Path -LiteralPath (Join-Path $full '.git') -PathType Leaf)) {
        throw "$full is no linked git worktree (.git is not a file) - only worktrees are adopted, never a main checkout."
    }
    $common = Invoke-OctoEnvironmentGit -path $full -arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($common.ExitCode -ne 0) { throw "git rev-parse --git-common-dir failed in ${full}: $($common.Output -join ' ')" }
    $commonDir = [IO.Path]::TrimEndingDirectorySeparator([string]($common.Output | Select-Object -Last 1))
    if ((Split-Path -Leaf $commonDir) -ne '.git') { throw "$full belongs to the bare repository $commonDir - not supported." }
    $mainCheckout = Split-Path -Parent $commonDir
    $branch = Invoke-OctoEnvironmentGit -path $full -arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $head = Invoke-OctoEnvironmentGit -path $full -arguments @('rev-parse', 'HEAD')
    # git lists worktrees in its own path form (symlinks resolved, e.g. /private/tmp); compare against that form.
    $topLevel = Invoke-OctoEnvironmentGit -path $full -arguments @('rev-parse', '--show-toplevel')
    $gitForm = ([string]($topLevel.Output | Select-Object -Last 1)) -replace '\\', '/'
    $list = Invoke-OctoEnvironmentGit -path $mainCheckout -arguments @('worktree', 'list', '--porcelain')
    $locked = $false
    $current = $null
    foreach ($line in $list.Output) {
        if ($line -like 'worktree *') { $current = $line.Substring(9).TrimEnd('/') -replace '\\', '/' }
        elseif (($line -eq 'locked' -or $line -like 'locked *') -and $current -and ($current -ieq $gitForm -or $current -ieq ($full -replace '\\', '/'))) { $locked = $true }
    }
    return [pscustomobject]@{
        Path         = $full
        Repo         = Split-Path -Leaf $mainCheckout
        CommonDir    = $commonDir
        MainCheckout = $mainCheckout
        Branch       = if ($branch.ExitCode -eq 0) { [string]($branch.Output | Select-Object -Last 1) } else { $null }
        Head         = [string]($head.Output | Select-Object -Last 1)
        Locked       = $locked
    }
}

function Get-OctoUserPropsProperties {
    # Unconditional properties of Octo.User.props files, in order (a later file wins): the base lane's, then the
    # environment's. $(MSBuildThisFileDirectory) and properties defined earlier are expanded.
    param([string[]]$paths = @())
    $properties = @{}
    foreach ($path in $paths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { [xml]$xml = Get-Content -LiteralPath $path -Raw } catch { Write-Warning "Cannot parse $path - its properties are not used for in-place RestoreSources: $($_.Exception.Message)"; continue }
        $directory = (Split-Path -Parent ([IO.Path]::GetFullPath($path))) + [IO.Path]::DirectorySeparatorChar
        foreach ($group in @($xml.SelectNodes("//*[local-name()='PropertyGroup']"))) {
            if ($group.GetAttribute('Condition')) { continue }
            foreach ($node in @($group.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                if ($node.GetAttribute('Condition')) { continue }
                $value = ([string]$node.InnerText).Trim().Replace('$(MSBuildThisFileDirectory)', $directory)
                $value = [regex]::Replace($value, '\$\((\w+)\)', { param($m) if ($properties.ContainsKey($m.Groups[1].Value)) { $properties[$m.Groups[1].Value] } else { $m.Value } })
                $properties[$node.LocalName] = $value
            }
        }
    }
    return $properties
}

function Get-OctoInPlaceRestoreSources {
    <#
        RestoreSources for an in-place worktree, evaluated like MSBuild would for its Directory.Build.props in DebugL: the
        RestoreSources elements in order, with the simple conditions '$(X)'=='..' / '$(X)'!='..' ($(RestoreSources) =
        the value so far, $(Configuration) = DebugL, other properties from the base lane's and the environment's
        Octo.User.props). $(OctoRepoRootPath)../nuget is replaced by the environment feed. Macros are substituted (a
        global property is not macro-expanded), e.g. $(OctoNugetPrivateServer); an entry with a macro that cannot be
        resolved is dropped with a warning that names the macro. So octo-report-services keeps Telerik and a private
        feed stays. Without own sources: environment feed + nuget.org. Credentials in feed URLs are never printed.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$repositoryPath,
        [Parameter(Mandatory = $true)] [string]$environmentFeed,
        [string[]]$userPropsPaths = @()
    )
    $nugetOrg = 'https://api.nuget.org/v3/index.json'
    $props = Join-Path $repositoryPath 'Directory.Build.props'
    $elements = @()
    if (Test-Path -LiteralPath $props -PathType Leaf) {
        try {
            [xml]$xml = Get-Content -LiteralPath $props -Raw
            $elements = @($xml.SelectNodes("//*[local-name()='RestoreSources']"))
        }
        catch { Write-Warning "Cannot parse $props - in-place RestoreSources fall back to the environment feed and nuget.org: $($_.Exception.Message)" }
    }
    if ($elements.Count -eq 0) { return "$environmentFeed;$nugetOrg" }

    $properties = Get-OctoUserPropsProperties -paths $userPropsPaths
    $properties['Configuration'] = 'DebugL'
    $current = [System.Collections.Generic.List[string]]::new()
    $propertyValue = { param([string]$name) if ($name -eq 'RestoreSources') { $current -join ';' } elseif ($properties.ContainsKey($name)) { [string]$properties[$name] } else { '' } }
    foreach ($element in $elements) {
        $condition = ([string]$element.GetAttribute('Condition')).Trim()
        if ($condition) {
            if ($condition -notmatch "^'\`$\((\w+)\)'\s*(==|!=)\s*'([^']*)'$") {
                Write-Warning "In-place RestoreSources of ${props}: condition $condition is not evaluated - element skipped."
                continue
            }
            $equal = (& $propertyValue $Matches[1]) -ieq $Matches[3]
            if (($Matches[2] -eq '==') -ne $equal) { continue }
        }
        $next = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in (([string]$element.InnerText).Trim() -split ';')) {
            $entry = $entry.Trim()
            if ($entry -eq '') { continue }
            if ($entry -eq '$(RestoreSources)') { foreach ($own in $current) { $next.Add($own) }; continue }
            if ($entry -match '^\$\(OctoRepoRootPath\)(\.\./)?nuget/?$') { $next.Add($environmentFeed); continue }
            $expanded = [regex]::Replace($entry, '\$\((\w+)\)', { param($m) if ($properties.ContainsKey($m.Groups[1].Value)) { $properties[$m.Groups[1].Value] } else { $m.Value } })
            $unresolved = @([regex]::Matches($expanded, '\$\((\w+)\)') | ForEach-Object { $_.Value } | Select-Object -Unique)
            if ($unresolved.Count -gt 0) {
                Write-Warning "In-place RestoreSources of ${props}: $($unresolved -join ', ') is defined neither in Octo.User.props nor the environment - the source '$(Hide-OctoUrlCredentials $entry)' is dropped."
                continue
            }
            foreach ($part in ($expanded -split ';')) { if ($part.Trim()) { $next.Add($part.Trim()) } }
        }
        $current = $next
    }
    $sources = [System.Collections.Generic.List[string]]::new([string[]]@($current | Select-Object -Unique))
    if (-not $sources.Contains($environmentFeed)) { $sources.Insert(0, $environmentFeed) }
    if ($sources.Count -eq 1) { $sources.Add($nugetOrg) }
    return ($sources -join ';')
}

function Split-OctoSourceCredentials {
    # Splits "scheme://user:password@host/..." sources into the source without credentials and its credentials.
    # Returns { Sources = [string[]] (same order, no userinfo); Credentials = @{ <source without userinfo> = @{ User; Password } } }.
    param([string]$restoreSources)
    $sources = [System.Collections.Generic.List[string]]::new()
    $credentials = @{}
    foreach ($source in ($restoreSources -split ';')) {
        if (-not $source) { continue }
        if ($source -match '^(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]*://)(?<user>[^:/@]*)(:(?<password>[^/@]*))?@(?<rest>.*)$') {
            $plain = "$($Matches['scheme'])$($Matches['rest'])"
            $credentials[$plain] = @{ User = [Uri]::UnescapeDataString($Matches['user']); Password = [Uri]::UnescapeDataString([string]$Matches['password']) }
            $sources.Add($plain)
        }
        else { $sources.Add($source) }
    }
    return [pscustomobject]@{ Sources = @($sources); Credentials = $credentials }
}

function Get-OctoUserNuGetConfigFile {
    # The user-level NuGet.Config (a wrapper so tests never read the developer's real file).
    if ($IsWindows) { return Join-Path $env:APPDATA 'NuGet/NuGet.Config' }
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.nuget/NuGet/NuGet.Config'
}

function Set-OctoOwnerOnlyAccess {
    # Restricts a file or folder to the current user: mode 600/700 on macOS/Linux, an ACL with only the current user
    # (no inheritance) on Windows.
    param([Parameter(Mandatory = $true)] [string]$path, [switch]$directory)
    if ($IsWindows) {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($directory) {
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path), $acl)
        }
        else {
            $acl = [System.Security.AccessControl.FileSecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'Allow'))
            [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $acl)
        }
        return
    }
    $mode = if ($directory) { [IO.UnixFileMode]'UserRead, UserWrite, UserExecute' } else { [IO.UnixFileMode]'UserRead, UserWrite' }
    [IO.File]::SetUnixFileMode($path, $mode)
}

function Write-OctoRestoreConfigText {
    # A wrapper so tests can force a write failure.
    param([Parameter(Mandatory = $true)] [string]$path, [AllowEmptyString()] [string]$text)
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

function New-OctoRestoreConfigFile {
    <#
        Writes an owner-only NuGet.Config in a new temporary folder that carries the credentials of the given sources, so
        they never reach dotnet as command-line arguments (visible in ps). The sources themselves stay in RestoreSources
        (a global property, it decides the list); NuGet takes the credentials of a restore source from the config's
        source with the same URL. RestoreConfigFile replaces the user-level NuGet.Config, so credentials it holds for
        these sources (e.g. Telerik) are copied over. Returns the file; the caller deletes its folder in finally.
    #>
    param(
        [Parameter(Mandatory = $true)] [string[]]$sources,
        [Parameter(Mandatory = $true)] [hashtable]$credentials,
        [string]$userConfigPath = (Get-OctoUserNuGetConfigFile)
    )
    $escape = { param([string]$v) [System.Security.SecurityElement]::Escape($v) }
    # Credentials of the user-level config, keyed by source URL.
    $userCredentials = @{}
    if ($userConfigPath -and (Test-Path -LiteralPath $userConfigPath -PathType Leaf)) {
        try {
            [xml]$user = Get-Content -LiteralPath $userConfigPath -Raw
            $urlOfKey = @{}
            foreach ($add in @($user.SelectNodes("/configuration/packageSources/add"))) { $urlOfKey[[string]$add.GetAttribute('key')] = [string]$add.GetAttribute('value') }
            foreach ($node in @($user.SelectNodes("/configuration/packageSourceCredentials/*"))) {
                $key = [System.Xml.XmlConvert]::DecodeName($node.LocalName)
                if ($urlOfKey.ContainsKey($key)) { $userCredentials[$urlOfKey[$key]] = @($node.SelectNodes('add')) }
            }
        }
        catch { Write-Warning "Cannot read the user-level NuGet.Config ($userConfigPath) - its feed credentials are not carried over: $($_.Exception.Message)" }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>')
    $lines.Add('<configuration>')
    $lines.Add('  <packageSources>')
    $lines.Add('    <clear />')
    for ($i = 0; $i -lt $sources.Count; $i++) { $lines.Add("    <add key=""octo-source-$($i + 1)"" value=""$(& $escape $sources[$i])"" />") }
    $lines.Add('  </packageSources>')
    $lines.Add('  <packageSourceCredentials>')
    for ($i = 0; $i -lt $sources.Count; $i++) {
        $key = "octo-source-$($i + 1)"
        if ($credentials.ContainsKey($sources[$i])) {
            $credential = $credentials[$sources[$i]]
            $lines.Add("    <$key>")
            $lines.Add("      <add key=""Username"" value=""$(& $escape $credential.User)"" />")
            $lines.Add("      <add key=""ClearTextPassword"" value=""$(& $escape $credential.Password)"" />")
            $lines.Add("    </$key>")
        }
        elseif ($userCredentials.ContainsKey($sources[$i])) {
            $lines.Add("    <$key>")
            foreach ($add in $userCredentials[$sources[$i]]) { $lines.Add("      <add key=""$(& $escape $add.GetAttribute('key'))"" value=""$(& $escape $add.GetAttribute('value'))"" />") }
            $lines.Add("    </$key>")
        }
    }
    $lines.Add('  </packageSourceCredentials>')
    $lines.Add('</configuration>')

    $folder = Join-Path ([IO.Path]::GetTempPath()) ("octo-restore-" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    try {
        Set-OctoOwnerOnlyAccess -path $folder -directory
        $file = Join-Path $folder 'NuGet.Config'
        # Create empty and restrict it before any credential is written.
        Write-OctoRestoreConfigText -path $file -text ''
        Set-OctoOwnerOnlyAccess -path $file
        Write-OctoRestoreConfigText -path $file -text (($lines -join "`n") + "`n")
    }
    catch {
        # Never leave a (partial) credentials file behind: the caller gets no path to clean up.
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return $file
}

function Get-OctoAdoptedWorktreeEntry {
    # Manifest entry of an adopted worktree at $path (after the move, or in place).
    param([Parameter(Mandatory = $true)] $info, [Parameter(Mandatory = $true)] [string]$path, [Parameter(Mandatory = $true)] [string]$role)
    # baseCommit: where the work in this worktree started - the unpushed count (Remove-OctoEnvironment) ignores the
    # commits up to it. Never the adopted worktree's own HEAD: that would hide its unpushed commits.
    #   1. merge base of the worktree's HEAD and the main checkout's HEAD;
    #   2. the main checkout's HEAD when there is no merge base (or the lookup fails);
    #   3. origin's default branch (refs/remotes/origin/HEAD) when the main checkout's HEAD cannot be read;
    #   4. none ($null): only commits that a remote has are excluded - everything else counts as unpushed.
    $baseCommit = $null
    $mainHead = Invoke-OctoEnvironmentGit -path $info.MainCheckout -arguments @('rev-parse', 'HEAD')
    if ($mainHead.ExitCode -eq 0) {
        $mainHeadCommit = [string]($mainHead.Output | Select-Object -Last 1)
        $mergeBase = Invoke-OctoEnvironmentGit -path $path -arguments @('merge-base', 'HEAD', $mainHeadCommit)
        $baseCommit = if ($mergeBase.ExitCode -eq 0) { [string]($mergeBase.Output | Select-Object -Last 1) } else { $mainHeadCommit }
    }
    else {
        $originHead = Invoke-OctoEnvironmentGit -path $path -arguments @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/HEAD^{commit}')
        if ($originHead.ExitCode -eq 0) { $baseCommit = [string]($originHead.Output | Select-Object -Last 1) }
    }
    return [ordered]@{ name = $info.Repo; role = $role; path = [IO.Path]::GetFullPath($path); branch = $info.Branch; baseCommit = $baseCommit }
}

# ---------------------------------------------------------------------------------------------------------------
# Snapshot sync (port of octo-devstack Builds/PrivateFeed.cs, extended to the catalogs)
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoFileHash256 {
    param([Parameter(Mandatory = $true)] [string]$path)
    $stream = [IO.File]::OpenRead($path)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Read-OctoSyncManifest {
    param([string]$path)
    $files = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($doc -and $doc['files']) { foreach ($key in $doc['files'].Keys) { $files[$key] = $doc['files'][$key] } }
        }
        catch { Write-Warning "Unreadable sync manifest $path - every differing file counts as environment-built: $_" }
    }
    return $files
}

function Write-OctoSyncManifest {
    param([string]$path, [hashtable]$files)
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $sorted = [ordered]@{}
    foreach ($key in ($files.Keys | Sort-Object)) { $sorted[$key] = $files[$key] }
    $json = ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 1; files = $sorted }) -Depth 5
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Compare-OctoSemVer {
    # -1 / 0 / 1; non-SemVer strings compare ordinally.
    param([string]$a, [string]$b)
    $va = $null; $vb = $null
    $ca = ($a -split '[-+]')[0]; $cb = ($b -split '[-+]')[0]
    if ([version]::TryParse($ca, [ref]$va) -and [version]::TryParse($cb, [ref]$vb)) {
        $c = $va.CompareTo($vb)
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return [Math]::Sign([string]::CompareOrdinal($a, $b))
}

function Merge-OctoCatalogIndex {
    <#
        Merges a catalog index (catalog.json) of the environment with the base lane's: the union of the entries, the
        environment's entry wins on a key collision.
          - "models": [{ modelName, (majorVersion), catalogPath }]  -> key modelName (+ majorVersion)
          - "versions": [{ version, ... }]                           -> key version, sorted descending; latestVersion
        Any other content keeps the environment's value. Returns the merged JSON text.
    #>
    param([Parameter(Mandatory = $true)] [string]$environmentJson, [Parameter(Mandatory = $true)] [string]$baseJson)
    $environment = $environmentJson | ConvertFrom-Json -AsHashtable
    $base = $baseJson | ConvertFrom-Json -AsHashtable
    $keyOf = {
        param($entry, [string]$kind)
        if ($kind -eq 'models') { return "$($entry['modelName'])|$($entry['majorVersion'])" }
        return [string]$entry['version']
    }
    foreach ($kind in @('models', 'versions')) {
        if (-not ($environment.Contains($kind) -and $base.Contains($kind))) { continue }
        $merged = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        foreach ($entry in @($environment[$kind])) { $seen[(& $keyOf $entry $kind)] = $true; $merged.Add($entry) }
        foreach ($entry in @($base[$kind])) { if (-not $seen.ContainsKey((& $keyOf $entry $kind))) { $merged.Add($entry) } }
        if ($kind -eq 'models') {
            $environment[$kind] = @($merged | Sort-Object -Property { [string]$_['modelName'] }, { [string]$_['majorVersion'] })
        }
        else {
            $list = [System.Collections.Generic.List[object]]::new($merged)
            $list.Sort([Comparison[object]] { param($x, $y) Compare-OctoSemVer ([string]$y['version']) ([string]$x['version']) })
            $environment[$kind] = @($list)
            if ($environment.Contains('latestVersion') -and $list.Count -gt 0) { $environment['latestVersion'] = [string]$list[0]['version'] }
        }
    }
    if ($environment.Contains('updatedAt')) { $environment['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o') }
    return (ConvertTo-Json -InputObject $environment -Depth 20)
}

function Sync-OctoEnvironmentFolder {
    <#
        Mirrors $source into $target with the PrivateFeed rules. The manifest records per relative path the hash of
        the file the sync wrote (target, $null when the environment owns it) and of the base file it last saw (source).
          - missing in the environment                     -> copied
          - unchanged since the sync wrote it, base changed -> refreshed
          - changed or built in the environment             -> kept (the environment's file wins), except:
              * a catalog index (catalog.json) whose base copy changed -> JSON-merged (Merge-OctoCatalogIndex)
              * a catalog cache file (cache/*-cache.json) whose base copy changed -> dropped (the tools rebuild it)
        $kind 'nuget' looks at *.nupkg in the top folder only; 'catalog' at every file below the folder.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$source,
        [Parameter(Mandatory = $true)] [string]$target,
        [Parameter(Mandatory = $true)] [string]$manifestPath,
        [Parameter(Mandatory = $true)] [ValidateSet('nuget', 'catalog')] [string]$kind,
        [switch]$dryRun
    )
    $result = [ordered]@{ source = $source; target = $target; copied = @(); refreshed = @(); kept = @(); merged = @(); dropped = @() }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { return $result }
    $files = Read-OctoSyncManifest -path $manifestPath
    if (-not $dryRun -and -not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }

    $sourceFiles = if ($kind -eq 'nuget') {
        @(Get-ChildItem -LiteralPath $source -File -Filter '*.nupkg')
    }
    else {
        @(Get-ChildItem -LiteralPath $source -File -Recurse | Where-Object { $_.Name -notin $script:IgnoredSyncFiles })
    }
    $sourceRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($source))
    foreach ($file in $sourceFiles) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName) -replace '\\', '/'
        $destination = Join-Path $target $relative
        $sourceHash = Get-OctoFileHash256 -path $file.FullName
        $entry = $files[$relative]
        $isCache = $kind -eq 'catalog' -and $relative -match '(^|/)cache/[^/]*-cache\.json$'
        $isIndex = $kind -eq 'catalog' -and $file.Name -eq 'catalog.json'

        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            if ($null -ne $entry -and $entry['dropped']) {
                # A cache file the sync dropped earlier: the tools own it now.
                $files[$relative] = @{ target = $null; source = $sourceHash; dropped = $true }
                continue
            }
            if (-not $dryRun) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
            $files[$relative] = @{ target = $sourceHash; source = $sourceHash }
            $result.copied += $relative
            continue
        }

        $targetHash = Get-OctoFileHash256 -path $destination
        $baseChanged = ($null -eq $entry) -or ([string]$entry['source'] -ne $sourceHash)
        if ($null -ne $entry -and [string]$entry['target'] -eq $targetHash) {
            if ($targetHash -ne $sourceHash) {
                if (-not $dryRun) { Copy-Item -LiteralPath $file.FullName -Destination $destination -Force }
                $files[$relative] = @{ target = $sourceHash; source = $sourceHash }
                $result.refreshed += $relative
            }
            else { $files[$relative] = @{ target = $targetHash; source = $sourceHash } }
            continue
        }
        if ($targetHash -eq $sourceHash) {
            # Same content as the base (e.g. built from the same commit): mirrored from now on.
            $files[$relative] = @{ target = $targetHash; source = $sourceHash }
            continue
        }
        if ($isIndex -and $baseChanged) {
            try {
                $mergedJson = Merge-OctoCatalogIndex -environmentJson (Get-Content -LiteralPath $destination -Raw) -baseJson (Get-Content -LiteralPath $file.FullName -Raw)
                if (-not $dryRun) { [IO.File]::WriteAllText($destination, $mergedJson + "`n", [Text.UTF8Encoding]::new($false)) }
                $files[$relative] = @{ target = $null; source = $sourceHash }
                $result.merged += $relative
            }
            catch {
                Write-Warning "Cannot merge catalog index $relative - the environment's copy is kept: $_"
                $files[$relative] = @{ target = $null; source = $sourceHash }
                $result.kept += $relative
            }
            continue
        }
        if ($isCache -and $baseChanged) {
            if (-not $dryRun) { Remove-Item -LiteralPath $destination -Force }
            $files[$relative] = @{ target = $null; source = $sourceHash; dropped = $true }
            $result.dropped += $relative
            continue
        }
        # Built or changed in the environment: it wins over the base's file.
        $files[$relative] = @{ target = $null; source = $sourceHash }
        $result.kept += $relative
    }
    if (-not $dryRun) { Write-OctoSyncManifest -path $manifestPath -files $files }
    return $result
}

function Clear-OctoEnvironmentStalePackageCache {
    # Port of PrivateFeed.PurgeStaleCache: deletes <cache>/<id>/<version> whose nupkg differs from the feed's copy
    # (NuGet never re-extracts a version it already has, and every local build is 999.0.0).
    param([Parameter(Mandatory = $true)] [string]$feed, [Parameter(Mandatory = $true)] [string]$cache, [switch]$dryRun)
    $purged = @()
    if (-not (Test-Path -LiteralPath $feed) -or -not (Test-Path -LiteralPath $cache)) { return $purged }
    foreach ($file in @(Get-ChildItem -LiteralPath $feed -File -Filter '*.nupkg')) {
        if ($file.Name -notmatch '^(?<id>.+?)\.(?<version>\d+\.\d+\.\d+(?:[-+][^/]*)?)\.nupkg$') { continue }
        $id = $Matches['id'].ToLowerInvariant()
        $version = $Matches['version'].ToLowerInvariant()
        $folder = Join-Path (Join-Path $cache $id) $version
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $cached = Join-Path $folder "$id.$version.nupkg"
        if (-not (Test-Path -LiteralPath $cached -PathType Leaf) -or (Get-OctoFileHash256 -path $cached) -ne (Get-OctoFileHash256 -path $file.FullName)) {
            if (-not $dryRun) { Remove-Item -LiteralPath $folder -Recurse -Force }
            $purged += "$id/$version"
        }
    }
    return $purged
}

function Invoke-OctoEnvironmentSync {
    # Feed + catalogs + cache purge of one environment; returns the result object (Sync-OctoEnvironment's data).
    param(
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$basePath,
        [switch]$dryRun
    )
    $syncState = Join-Path $environmentPath '.octo/sync'
    $nuget = Sync-OctoEnvironmentFolder -source (Join-Path $basePath 'nuget') -target (Join-Path $environmentPath 'nuget') -manifestPath (Join-Path $syncState 'nuget.json') -kind nuget -dryRun:$dryRun
    $catalogs = [ordered]@{}
    foreach ($folder in $script:CatalogFolders) {
        $catalogs[$folder] = Sync-OctoEnvironmentFolder -source (Join-Path $basePath ".octo/$folder") -target (Join-Path $environmentPath ".octo/$folder") -manifestPath (Join-Path $syncState "$folder.json") -kind catalog -dryRun:$dryRun
    }
    $purged = @(Clear-OctoEnvironmentStalePackageCache -feed (Join-Path $environmentPath 'nuget') -cache (Join-Path $environmentPath '.nuget-packages') -dryRun:$dryRun)
    return [ordered]@{
        dryRun          = [bool]$dryRun
        base            = $basePath
        nuget           = $nuget
        catalogs        = $catalogs
        purgedFromCache = $purged
    }
}

$script:SyncListLimit = 20

function ConvertTo-OctoSyncReport {
    <#
        The sync result for -Json: per feed/catalog the counts (copied, refreshed, kept, merged, dropped) and at most
        $script:SyncListLimit names per list (truncated = $true when a list was cut); -Detailed keeps every name. A fresh
        environment copies thousands of catalog files - listing them all made New-OctoEnvironment -Json ~40 KB.
    #>
    param([Parameter(Mandatory = $true)] $sync, [switch]$detailed)
    $limit = if ($detailed) { [int]::MaxValue } else { $script:SyncListLimit }
    $folder = {
        param($result)
        $report = [ordered]@{ source = $result.source; target = $result.target; counts = [ordered]@{}; truncated = $false }
        foreach ($list in @('copied', 'refreshed', 'kept', 'merged', 'dropped')) {
            $all = @($result[$list])
            $report.counts[$list] = $all.Count
            $report[$list] = @($all | Select-Object -First $limit)
            if ($all.Count -gt $limit) { $report.truncated = $true }
        }
        return $report
    }
    $catalogs = [ordered]@{}
    foreach ($name in $sync.catalogs.Keys) { $catalogs[$name] = & $folder $sync.catalogs[$name] }
    $purged = @($sync.purgedFromCache)
    return [ordered]@{
        dryRun               = $sync.dryRun
        base                 = $sync.base
        detailed             = [bool]$detailed
        nuget                = & $folder $sync.nuget
        catalogs             = $catalogs
        purgedFromCacheCount = $purged.Count
        purgedFromCache      = @($purged | Select-Object -First $limit)
    }
}

function Write-OctoEnvironmentSyncSummary {
    param($sync)
    $n = $sync.nuget
    Write-Host ("  feed: {0} copied, {1} refreshed, {2} built in the environment (kept)" -f @($n.copied).Count, @($n.refreshed).Count, @($n.kept).Count)
    foreach ($name in $sync.catalogs.Keys) {
        $c = $sync.catalogs[$name]
        Write-Host ("  {0}: {1} copied, {2} refreshed, {3} kept, {4} index merged, {5} cache dropped" -f $name, @($c.copied).Count, @($c.refreshed).Count, @($c.kept).Count, @($c.merged).Count, @($c.dropped).Count)
    }
    Write-Host ("  package cache: {0} stale folder(s) purged" -f @($sync.purgedFromCache).Count)
}

# ---------------------------------------------------------------------------------------------------------------
# Package graph
# ---------------------------------------------------------------------------------------------------------------

$script:PackageScanSkippedFolders = [System.Collections.Generic.HashSet[string]]::new([string[]]@('node_modules', 'bin', 'obj', '.git', '.vs', '.idea', 'TestResults', 'packages', '.nuget-packages', 'dist', '.angular', 'artifacts', 'coverage', '.nx', '.cache'), [StringComparer]::OrdinalIgnoreCase)

function Get-OctoPackageScanFiles {
    <#
        The files the package graph reads for one repository: every *.csproj and *.props below the repository root
        (src/, tests/, tools, samples - projects outside src/ count too). The walk never enters node_modules, bin, obj,
        .git, generated output (dist, .angular, artifacts, coverage, .nx, .cache, TestResults, packages) or symbolic
        links: a plain recursive Get-ChildItem enumerates node_modules completely before any filter applies (90 s for
        branches/main), this walk about half a second.
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    $files = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                if ($file.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase) -or $file.EndsWith('.props', [StringComparison]::OrdinalIgnoreCase)) { $files.Add($file) }
            }
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                if ($script:PackageScanSkippedFolders.Contains([IO.Path]::GetFileName($child))) { continue }
                if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($child)
            }
        }
        catch [System.UnauthorizedAccessException] { continue }
        catch [System.IO.IOException] { continue }
    }
    return @($files)
}

function Get-OctoRepoPackageInfo {
    # Produced package ids and Meshmakers.* references of one repository, from its csproj (and props) files
    # (Get-OctoPackageScanFiles: the whole repository, never node_modules/bin/obj/.git or generated output).
    param([Parameter(Mandatory = $true)] [string]$path)
    $produces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $references = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($filePath in @(Get-OctoPackageScanFiles -path $path)) {
        $file = [IO.FileInfo]::new($filePath)
        $text = [IO.File]::ReadAllText($filePath)
        if ([string]::IsNullOrEmpty($text)) { continue }
        foreach ($match in [regex]::Matches($text, '<PackageReference\s+[^>]*?Include\s*=\s*"(Meshmakers\.[^"]+)"', 'IgnoreCase')) {
            [void]$references.Add($match.Groups[1].Value)
        }
        if ($file.Extension -ne '.csproj') { continue }
        if ($text -match '<IsPackable>\s*false\s*</IsPackable>') { continue }
        $id = if ($text -match '<PackageId>\s*([^<$]+?)\s*</PackageId>') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($file.Name) }
        [void]$produces.Add($id)
    }
    foreach ($id in $produces) { [void]$references.Remove($id) }   # a repository does not consume itself
    return [pscustomobject]@{ Produces = @($produces | Sort-Object); References = @($references | Sort-Object) }
}

function Get-OctoAffectedRepoGraph {
    <#
        Pure graph computation. $repos: ordered list of { Name; Path } in build order. $features: names of the changed
        repositories. Returns one row per affected repository (transitive consumer of a feature repository), in build
        order: { repo; depth; via = @("<package> (<producer>)") }.
    #>
    param([object[]]$repos = @(), [string[]]$features = @())
    $info = [ordered]@{}
    $producerOf = @{}
    foreach ($repo in $repos) {
        $info[$repo.Name] = Get-OctoRepoPackageInfo -path $repo.Path
        foreach ($id in $info[$repo.Name].Produces) { if (-not $producerOf.ContainsKey($id.ToLowerInvariant())) { $producerOf[$id.ToLowerInvariant()] = $repo.Name } }
    }
    # consumers[producer] = list of { consumer; package }
    $consumers = @{}
    foreach ($name in $info.Keys) {
        foreach ($id in $info[$name].References) {
            $producer = $producerOf[$id.ToLowerInvariant()]
            if (-not $producer -or $producer -eq $name) { continue }
            if (-not $consumers.ContainsKey($producer)) { $consumers[$producer] = [System.Collections.Generic.List[object]]::new() }
            $consumers[$producer].Add([pscustomobject]@{ Consumer = $name; Package = $id })
        }
    }
    $depth = @{}
    $via = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($feature in $features) { $depth[$feature] = 0; $queue.Enqueue($feature) }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $consumers.ContainsKey($current)) { continue }
        foreach ($edge in $consumers[$current]) {
            if ($features -contains $edge.Consumer) { continue }
            if (-not $via.ContainsKey($edge.Consumer)) { $via[$edge.Consumer] = [System.Collections.Generic.List[string]]::new() }
            $label = "$($edge.Package) ($current)"
            if (-not $via[$edge.Consumer].Contains($label)) { $via[$edge.Consumer].Add($label) }
            if (-not $depth.ContainsKey($edge.Consumer)) {
                $depth[$edge.Consumer] = $depth[$current] + 1
                $queue.Enqueue($edge.Consumer)
            }
        }
    }
    $rows = @()
    foreach ($repo in $repos) {
        if ($features -contains $repo.Name -or -not $depth.ContainsKey($repo.Name)) { continue }
        $rows += [pscustomobject][ordered]@{ repo = $repo.Name; depth = $depth[$repo.Name]; via = @($via[$repo.Name]) }
    }
    return [pscustomobject]@{ Affected = $rows; Consumers = $consumers; Info = $info }
}

function Get-OctoUpstreamRepoMap {
    # repository -> every repository it depends on through Meshmakers.* packages, transitively (from the Consumers
    # edges of Get-OctoAffectedRepoGraph, which cover the whole lane - also repositories outside an environment).
    param([Parameter(Mandatory = $true)] $graph)
    $producersOf = @{}
    foreach ($producer in $graph.Consumers.Keys) {
        foreach ($edge in $graph.Consumers[$producer]) {
            if (-not $producersOf.ContainsKey($edge.Consumer)) { $producersOf[$edge.Consumer] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            [void]$producersOf[$edge.Consumer].Add($producer)
        }
    }
    $map = @{}
    foreach ($name in @($graph.Info.Keys)) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($name)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            if (-not $producersOf.ContainsKey($current)) { continue }
            foreach ($producer in $producersOf[$current]) { if ($producer -ine $name -and $seen.Add($producer)) { $queue.Enqueue($producer) } }
        }
        $map[$name] = @($seen | Sort-Object)
    }
    return $map
}

function Get-OctoEnvironmentBuildSelection {
    <#
        Invoke-BuildEnvironment -repos / -skip (AB#8814). $order: the environment's repositories in build order.
        Returns { Build (names, build order); Skipped (name -> { reason = notSelected|excluded; detail }) }.
        Throws for a name that is no repository of the environment's build order (a developer tool included) and
        when nothing is left to build.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string[]]$order,
        [string[]]$repos = @(),
        [string[]]$skip = @(),
        [string[]]$toolRepos = @()
    )
    $resolve = {
        param([string]$name, [string]$parameter)
        foreach ($candidate in @($name, "octo-$name")) {
            $hit = @($order | Where-Object { $_ -ieq $candidate })
            if ($hit.Count -gt 0) { return $hit[0] }
        }
        foreach ($candidate in @($name, "octo-$name")) {
            if ($toolRepos -contains $candidate) { throw "-${parameter}: $candidate is a developer tool - Invoke-BuildEnvironment never builds it." }
        }
        throw "-${parameter}: '$name' is no repository of environment $env. Its repositories: $($order -join ', ')."
    }
    $split = { param($values) @($values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $selected = @(& $split $repos | ForEach-Object { & $resolve $_ 'repos' })
    $excluded = @(& $split $skip | ForEach-Object { & $resolve $_ 'skip' })
    $build = @()
    $skipped = [ordered]@{}
    foreach ($name in $order) {
        if ($excluded -contains $name) { $skipped[$name] = @{ reason = 'excluded'; detail = 'named in -skip' } }
        elseif ($selected.Count -gt 0 -and $selected -notcontains $name) { $skipped[$name] = @{ reason = 'notSelected'; detail = 'not named in -repos' } }
        else { $build += $name }
    }
    if ($build.Count -eq 0) { throw "-repos / -skip leave no repository of environment $env to build." }
    return [pscustomobject]@{ Build = $build; Skipped = $skipped }
}

function Get-OctoEnvironmentStaleWarnings {
    <#
        Stale packages through repositories that are left out of a build (-repos / -skip): a left-out repository M
        with a built consumer C is a problem when a repository M depends on is built in this run (M's packages are
        not rebuilt against it, C binds to both: MissingMethodException at runtime), or when M itself changed
        since its last build here (C is built against M's old packages).
        $changed: name -> { Unchanged; Reason; Detail } (Compare-OctoBuildStamp) for every repository of the order.
        Returns @({ repo; skipReason; changed; changeReason; upstreamBuilt; consumers; message }).
    #>
    param(
        [Parameter(Mandatory = $true)] [string[]]$order,
        [Parameter(Mandatory = $true)] $selection,
        [Parameter(Mandatory = $true)] [hashtable]$upstream,
        [Parameter(Mandatory = $true)] [hashtable]$changed,
        [switch]$buildUnchanged
    )
    # Which of the selected repositories will be built: changed, or downstream of one that is built.
    $predicted = @()
    foreach ($name in $order) {
        if ($selection.Build -notcontains $name) { continue }
        $dependsOn = @($upstream[$name])
        if ($buildUnchanged -or -not $changed[$name].Unchanged -or @($predicted | Where-Object { $dependsOn -contains $_ }).Count -gt 0) { $predicted += $name }
    }
    $warnings = @()
    foreach ($name in @($selection.Skipped.Keys)) {
        $consumers = @($predicted | Where-Object { @($upstream[$_]) -contains $name })
        if ($consumers.Count -eq 0) { continue }
        $upstreamBuilt = @($predicted | Where-Object { @($upstream[$name]) -contains $_ })
        $isChanged = -not $changed[$name].Unchanged -and $changed[$name].Reason -ne 'neverBuilt'
        if ($upstreamBuilt.Count -eq 0 -and -not $isChanged) { continue }
        $parts = @()
        if ($upstreamBuilt.Count -gt 0) { $parts += "lies between $($upstreamBuilt -join ', ') (built) and $($consumers -join ', ') (built): its packages are not rebuilt against the new $($upstreamBuilt -join ', '), so $($consumers -join ', ') binds to a stale $name (MissingMethodException at runtime)" }
        if ($isChanged) { $parts += "changed since its last build here ($($changed[$name].Reason)): $($consumers -join ', ') is built against its old packages" }
        $warnings += [ordered]@{
            repo = $name; skipReason = $selection.Skipped[$name]['reason']; changed = $isChanged; changeReason = $(if ($isChanged) { $changed[$name].Reason } else { $null })
            upstreamBuilt = $upstreamBuilt; consumers = $consumers
            message = "$name is not built in this run ($($selection.Skipped[$name]['reason'])) but $($parts -join '; and it '). Build it too (add it to -repos / drop it from -skip)."
        }
    }
    return $warnings
}

function Get-OctoReposOnPath {
    # The affected repositories from which $target can be reached (they lie between a feature repository and the
    # target), plus the target itself when it is affected.
    param([Parameter(Mandatory = $true)] $graph, [Parameter(Mandatory = $true)] [string]$target)
    $affected = @($graph.Affected | ForEach-Object repo)
    $onPath = @()
    foreach ($name in $affected) {
        if ($name -eq $target) { $onPath += $name; continue }
        # BFS from $name along consumer edges; does it reach $target?
        $seen = @{ $name = $true }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($name)
        $reached = $false
        while ($queue.Count -gt 0 -and -not $reached) {
            $current = $queue.Dequeue()
            if (-not $graph.Consumers.ContainsKey($current)) { continue }
            foreach ($edge in $graph.Consumers[$current]) {
                if ($edge.Consumer -eq $target) { $reached = $true; break }
                if (-not $seen.ContainsKey($edge.Consumer)) { $seen[$edge.Consumer] = $true; $queue.Enqueue($edge.Consumer) }
            }
        }
        if ($reached) { $onPath += $name }
    }
    return $onPath
}

function Get-OctoEnvironmentRepoSet {
    # Build-order list { Name; Path } of the base lane, with the environment's worktrees replacing the base folders.
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest, [Parameter(Mandatory = $true)] [string]$basePath)
    $environmentRepos = @{}
    foreach ($repo in $manifest['repos']) { $environmentRepos[$repo['name']] = $repo['path'] }
    $set = @()
    foreach ($entry in @(Get-OctoBuildOrder -branchRootPath $basePath -excludeFrontend $false -excludeAdditional $false)) {
        $path = if ($environmentRepos.ContainsKey($entry.Name) -and (Test-Path -LiteralPath $environmentRepos[$entry.Name])) { $environmentRepos[$entry.Name] } else { $entry.Path }
        $set += [pscustomobject]@{ Name = $entry.Name; Path = $path }
    }
    return $set
}

function Get-OctoEnvironmentAffected {
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest, [Parameter(Mandatory = $true)] [string]$basePath)
    $features = @($manifest['repos'] | Where-Object { $_['role'] -eq 'feature' } | ForEach-Object { $_['name'] })
    $graph = Get-OctoAffectedRepoGraph -repos (Get-OctoEnvironmentRepoSet -manifest $manifest -basePath $basePath) -features $features
    return [pscustomobject]@{ Features = $features; Graph = $graph }
}

# ---------------------------------------------------------------------------------------------------------------
# Package cache of a new environment (AB#8831)
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoGlobalPackageCachePath {
    # The user-level NuGet package cache (mocked in the tests; the real one is only ever read).
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/packages'
}

function Get-OctoPackageCacheSeedSource {
    # Where an environment's package cache is filled from: the base lane's cache when it has one, else the
    # user-level cache. $null when neither exists.
    param([Parameter(Mandatory = $true)] [string]$basePath)
    # A cache counts when it holds at least one version that would be copied: a base lane cache with nothing but
    # local builds (or unfinished extractions) must not hide the user-level cache.
    foreach ($candidate in @((Join-Path $basePath '.nuget-packages'), (Get-OctoGlobalPackageCachePath))) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        foreach ($idFolder in [IO.Directory]::EnumerateDirectories($candidate)) {
            $id = [IO.Path]::GetFileName($idFolder)
            foreach ($versionFolder in [IO.Directory]::EnumerateDirectories($idFolder)) {
                if (Test-OctoPackageVersionEligible -id $id -versionFolder $versionFolder) { return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($candidate)) }
            }
        }
    }
    return $null
}

function Test-OctoPackageVersionEligible {
    # A version folder a cache may hand to another: not a local build (meshmakers.*/999.0.0), and completely
    # extracted (NuGet writes .nupkg.metadata last).
    param([Parameter(Mandatory = $true)] [string]$id, [Parameter(Mandatory = $true)] [string]$versionFolder)
    if ($id -like 'meshmakers.*' -and [IO.Path]::GetFileName($versionFolder) -eq '999.0.0') { return $false }
    return (Test-Path -LiteralPath (Join-Path $versionFolder '.nupkg.metadata') -PathType Leaf)
}

function Get-OctoPackageCopyMethod {
    <#
        How package folders get from one cache into another:
          clone  macOS, both folders on the same APFS volume: `cp -c` (clonefile). The copy has its own files that
                 share the data blocks until one side is written (copy-on-write) - nothing an environment does to its
                 cache can reach another cache, deleting included, and it costs neither time nor disk space.
          copy   everything else: a plain copy.
        Hardlinks are never used: a hardlink is the same file under two names, so a write through one cache (a tool
        patching a file, a re-extraction over an existing folder) would change the other environment's package.
    #>
    param([Parameter(Mandatory = $true)] [string]$source, [Parameter(Mandatory = $true)] [string]$target)
    if (-not $IsMacOS) { return 'copy' }
    try {
        $devices = @(& /usr/bin/stat -f '%d' $source $target 2>$null)
        if ($LASTEXITCODE -eq 0 -and $devices.Count -eq 2 -and $devices[0] -eq $devices[1]) { return 'clone' }
    }
    catch { }
    return 'copy'
}

function Copy-OctoPackageFolder {
    # Copies one folder (a package id or one version of it) to a target that does not exist yet. Throws on failure.
    # All or nothing: the bytes go to a temporary sibling that is renamed into place; a copy that fails halfway
    # leaves no folder a later run would take for a complete package.
    param([Parameter(Mandatory = $true)] [string]$source, [Parameter(Mandatory = $true)] [string]$target, [Parameter(Mandatory = $true)] [string]$method)
    $temporary = Join-Path (Split-Path -Parent $target) (".seeding-{0}-{1}" -f $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Copy-OctoPackageFolderRaw -source $source -target $temporary -method $method
        [IO.Directory]::Move($temporary, $target)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-OctoPackageFolderRaw {
    # The copy itself (clone or plain) to a target that does not exist. Throws on failure; may leave a partial target.
    param([Parameter(Mandatory = $true)] [string]$source, [Parameter(Mandatory = $true)] [string]$target, [Parameter(Mandatory = $true)] [string]$method)
    if ($method -eq 'clone') {
        $output = @(& /bin/cp -Rc $source $target 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "cp -Rc $source $target failed: $($output -join ' ')" }
        return
    }
    Copy-Item -LiteralPath $source -Destination $target -Recurse -Force -ErrorAction Stop
}

function Invoke-OctoPackageCacheSeed {
    <#
        Fills a package cache from another local one instead of the network (AB#8831): every <id>/<version> folder
        of $source that $target lacks - third-party packages only. Never copied:
          - meshmakers.*/999.0.0, the local builds: an environment gets them from its own feed, another lane's build
            of the same version must not slip in;
          - a version folder without .nupkg.metadata (NuGet writes it last): an extraction that did not finish.
        Existing folders of the target are left alone. Returns { source; target; method; packages; alreadyPresent;
        skippedLocalBuilds; skippedIncomplete; sizeBytes; seconds; errors; dryRun }.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$source,
        [Parameter(Mandatory = $true)] [string]$target,
        [switch]$dryRun
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $report = [ordered]@{ source = $source; target = $target; method = $null; packages = 0; alreadyPresent = 0; skippedLocalBuilds = 0; skippedIncomplete = 0; sizeBytes = [long]0; seconds = 0.0; errors = @(); dryRun = [bool]$dryRun }
    if (-not $dryRun -and -not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
    $report.method = Get-OctoPackageCopyMethod -source $source -target $(if (Test-Path -LiteralPath $target) { $target } else { Split-Path -Parent $target })
    $sizeOf = {
        param([string]$folder)
        $total = [long]0
        foreach ($file in [IO.Directory]::EnumerateFiles($folder, '*', [IO.SearchOption]::AllDirectories)) { $total += ([IO.FileInfo]::new($file)).Length }
        return $total
    }
    foreach ($idFolder in @([IO.Directory]::EnumerateDirectories($source) | Sort-Object)) {
        $id = [IO.Path]::GetFileName($idFolder)
        $targetId = Join-Path $target $id
        $versions = @([IO.Directory]::EnumerateDirectories($idFolder))
        $wanted = @()
        foreach ($versionFolder in $versions) {
            $version = [IO.Path]::GetFileName($versionFolder)
            if ($id -like 'meshmakers.*' -and $version -eq '999.0.0') { $report.skippedLocalBuilds++; continue }
            if (-not (Test-Path -LiteralPath (Join-Path $versionFolder '.nupkg.metadata') -PathType Leaf)) { $report.skippedIncomplete++; continue }
            if (Test-Path -LiteralPath (Join-Path $targetId $version)) { $report.alreadyPresent++; continue }
            $wanted += $versionFolder
        }
        if ($wanted.Count -eq 0) { continue }
        try {
            if ($dryRun) { foreach ($versionFolder in $wanted) { $report.sizeBytes += & $sizeOf $versionFolder } }
            elseif ($wanted.Count -eq $versions.Count -and -not (Test-Path -LiteralPath $targetId)) {
                # The whole id in one call (one process instead of one per version).
                Copy-OctoPackageFolder -source $idFolder -target $targetId -method $report.method
                $report.sizeBytes += & $sizeOf $idFolder
            }
            else {
                if (-not (Test-Path -LiteralPath $targetId)) { New-Item -ItemType Directory -Force -Path $targetId | Out-Null }
                foreach ($versionFolder in $wanted) {
                    Copy-OctoPackageFolder -source $versionFolder -target (Join-Path $targetId ([IO.Path]::GetFileName($versionFolder))) -method $report.method
                    $report.sizeBytes += & $sizeOf $versionFolder
                }
            }
            $report.packages += $wanted.Count
        }
        catch {
            $report.errors += "${id}: $($_.Exception.Message)"
            # No empty id folder stays behind either.
            if ((Test-Path -LiteralPath $targetId -PathType Container) -and @([IO.Directory]::EnumerateFileSystemEntries($targetId) | Select-Object -First 1).Count -eq 0) { Remove-Item -LiteralPath $targetId -Force -ErrorAction SilentlyContinue }
        }
    }
    $report.seconds = $watch.Elapsed.TotalSeconds
    return $report
}

function Invoke-OctoEnvironmentPackageCacheSeed {
    # The seeding of one environment: source selection and the rule when it happens without being asked for.
    # $automatic (New-OctoEnvironment): only where it is cheap - a clone, or a copy of the base lane's own cache;
    # copying the whole user-level cache (tens of GB) is left to an explicit Initialize-OctoEnvironmentPackageCache.
    param(
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$basePath,
        [string]$source = '',
        [switch]$automatic,
        [switch]$dryRun
    )
    $target = Join-Path $environmentPath '.nuget-packages'
    if ([string]::IsNullOrWhiteSpace($source)) { $source = Get-OctoPackageCacheSeedSource -basePath $basePath }
    else { $source = [IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($source)) }
    $skipped = { param([string]$why) [ordered]@{ source = $source; target = $target; method = $null; packages = 0; alreadyPresent = 0; skippedLocalBuilds = 0; skippedIncomplete = 0; sizeBytes = [long]0; seconds = 0.0; errors = @(); dryRun = [bool]$dryRun; skipped = $why } }
    if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Container)) { return & $skipped 'no local package cache to copy from (base lane cache, user-level cache)' }
    if (Test-OctoPathInside -path $source -parent $target) { return & $skipped 'the source is the environment cache itself' }
    if ($automatic) {
        $method = Get-OctoPackageCopyMethod -source $source -target $(if (Test-Path -LiteralPath $target) { $target } else { $environmentPath })
        $isBaseCache = (Test-OctoPathInside -path $source -parent $basePath)
        if ($method -ne 'clone' -and -not $isBaseCache) {
            return & $skipped "cloning is not available here and $source is the user-level cache - a full copy is only made on request: Initialize-OctoEnvironmentPackageCache -env $(Split-Path -Leaf $environmentPath | ForEach-Object { $_ -replace '^wt-', '' })"
        }
    }
    return Invoke-OctoPackageCacheSeed -source $source -target $target -dryRun:$dryRun
}

# ---------------------------------------------------------------------------------------------------------------
# Cmdlets
# ---------------------------------------------------------------------------------------------------------------

<#
.SYNOPSIS
    Creates a feature environment at <rootPath>/wt-<env> (the octo-claude-pm lane folder of lane <env>): feature
    worktrees, Octo.User.props, manifest, and a
    snapshot of the base lane's feed and catalogs.

.DESCRIPTION
    For every repository in -repos a git worktree <env>/<repo> is added from <base>/<repo> on the feature branch
    (-branchName, default <user>/AB#<id>_<desc>; an existing local or origin branch is checked out instead of
    created). The developer tools octo-tools and octo-devstack live next to the lanes (<rootPath>/<repo>) and can be
    named too; Invoke-BuildEnvironment does not build them.

    Base: a new feature branch and every consumer worktree start from the upstream of the base checkout's current
    branch (branches/main: origin/main), fetched first - not from the local checkout, which may be stale. A checkout
    without an upstream uses origin's default branch. When the local checkout's HEAD differs, a warning names the
    repository and how far it is behind/ahead (-Json: baseDrift). -localBase keeps the old behaviour (the local
    checkout's HEAD). The manifest records baseCommit (the commit the worktree started from; for an existing branch
    its merge base with the base) and baseRef (the remote ref it started from, e.g. origin/main; HEAD; or the
    existing branch).
    The feed is seeded from the base lane's packages, which were built from the LOCAL checkouts: the output says which
    environment repositories are newer than those packages (Invoke-BuildEnvironment rebuilds them) and which
    libraries outside the environment are behind their upstream in the base lane, with what to do (-Json: feedSnapshot).

    Package cache (AB#8831): <env>/.nuget-packages is filled from a local cache - the base lane's .nuget-packages,
    else ~/.nuget/packages - instead of downloading 2-5 GB on the first restore: third-party packages only, never
    meshmakers.*/999.0.0 (those come from the environment's feed). On macOS the folders are APFS clones (`cp -c`):
    no time, no disk space, and copy-on-write, so two environments cannot change each other's packages; hardlinks
    are not used for that reason. Elsewhere it is a plain copy, made automatically only from the base lane's cache
    (Initialize-OctoEnvironmentPackageCache copies from the user-level cache on request). -skipPackageCacheSeed
    turns it off. -Json: packageCache { source, method, packages, sizeBytes, seconds, ... }.

    Atomic: when anything fails (a worktree, the seeding, -addAffected), everything this call created is rolled back -
    its worktrees, the environment folder and the branches it created, never a branch that existed before - and the
    same call can be repeated after the cause is fixed (-Json: rolledBack). The environment gets nuget/, .nuget-packages/, .octo/local-catalog, .octo/local-blueprint-catalog
    (copied from the base lane by Sync-OctoEnvironment rules), logFiles/, an Octo.User.props declaring
    RestorePackagesPath=<env>/.nuget-packages plus OctoEnvironment/OctoEnvironmentBase (the base lane's own
    Octo.User.props is imported for its other settings), and .octo/environment.json (schemaVersion 1).

    Refuses an existing environment, an invalid name, a name whose wt-<name> already exists without a manifest (an
    octo-claude-pm lane folder or a flat worktree wt-<lane>-<repo>), a base lane that does not exist, and an
    environment folder inside the base lane (the kill scope and cache logic of the base would match it). Existing
    worktrees are adopted with Add-OctoEnvironmentRepo -path. -addAffected adds every
    transitive consumer of the feature repositories as a consumer worktree (Get-OctoAffectedRepos); for a single
    service use Add-OctoEnvironmentRepo -role consumer -addAffected instead.

.EXAMPLE
    New-OctoEnvironment -env ab8625-enum-null -repos octo-construction-kit-engine -workItem AB#8625
#>
function New-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string[]]$repos,
        [string]$workItem = '',
        [string]$branchName = '',
        [string]$owner = '',
        [string]$base = $script:DefaultBase,
        [switch]$addAffected,
        [switch]$localBase,
        [switch]$skipPackageCacheSeed,
        [switch]$Detailed,
        [switch]$Json
    )

    $fail = {
        param([string]$message)
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'New-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $message }) }
        else { Write-Error $message }
    }

    try {
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $normalizedWorkItem = ConvertTo-OctoWorkItem -workItem $workItem
        $basePath = Get-OctoEnvironmentBasePath -base $base
    }
    catch { & $fail $_.Exception.Message; return }
    if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { & $fail "Base lane $basePath does not exist."; return }
    if (Test-OctoPathInside -path $environmentPath -parent $basePath) {
        & $fail "Environment folder $environmentPath lies inside the base lane $basePath (`$rootPath points into the lane - load the profile from the octo-tools next to the lanes). Refused: the base lane's kill scope and package caches would include it."
        return
    }
    if (Test-Path -LiteralPath (Get-OctoEnvironmentManifestPath -environmentPath $environmentPath) -PathType Leaf) { & $fail "Environment $env already exists ($environmentPath). Use Add-OctoEnvironmentRepo, or Remove-OctoEnvironment first."; return }
    # wt-<env> without a manifest is an octo-claude-pm lane folder or a flat worktree wt-<lane>-<repo>: not ours.
    if (Test-Path -LiteralPath $environmentPath) {
        & $fail "$environmentPath already exists and is no feature environment (an octo-claude-pm lane folder or a flat worktree wt-<lane>-<repo>). Choose another name; adopt existing worktrees with Add-OctoEnvironmentRepo -path."
        return
    }
    try { $repoNames = @($repos | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Resolve-OctoEnvironmentRepoName -repo $_.Trim() -basePath $basePath } | Select-Object -Unique) }
    catch { & $fail $_.Exception.Message; return }
    if ($repoNames.Count -eq 0) { & $fail "-repos names no repository."; return }
    if ([string]::IsNullOrWhiteSpace($branchName)) { $branchName = Get-OctoEnvironmentDefaultBranchName -env $env -workItem $normalizedWorkItem }
    $relativeBase = if ([IO.Path]::IsPathRooted($base)) { [IO.Path]::GetRelativePath((Get-OctoEnvironmentRootPath), $basePath) -replace '\\', '/' } else { $base -replace '\\', '/' }

    $manifest = [ordered]@{
        name     = $env
        workItem = $normalizedWorkItem
        base     = $relativeBase
        created  = (Get-Date).ToUniversalTime().ToString('o')
        owner    = if ($owner) { $owner } else { $branchName }
        repos    = @()
        slot     = $env
    }

    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Create environment with feature worktree(s) $($repoNames -join ', ') on $branchName")) {
        $plan = [ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; path = $environmentPath; base = $basePath; branch = $branchName; repos = $repoNames; localBase = [bool]$localBase }
        if ($Json) { Write-OctoJson -Command 'New-OctoEnvironment' -Data $plan }
        return
    }

    # Atomic: everything below is rolled back when the call does not complete (failure, exception, Ctrl+C best-effort).
    # The folder did not exist before (checked above), so all of it is this call's; only branches this call created
    # are deleted, never one that existed before.
    $created = [System.Collections.Generic.List[object]]::new()
    $errors = @()
    $warnings = @()
    $drift = @()
    $addedConsumers = @()
    $sync = $null
    $feedSnapshot = $null
    $completed = $false
    $rolledBack = $null
    try {
        foreach ($folder in @('nuget', '.nuget-packages', '.octo', 'logFiles')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $environmentPath $folder) | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $environmentPath 'Octo.User.props') -Value (Get-OctoEnvironmentUserPropsContent -env $env -base $relativeBase -basePath $basePath)
        Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest

        $addWorktree = {
            param([string]$repo, [string]$role)
            $added = Add-OctoEnvironmentWorktree -basePath $basePath -environmentPath $environmentPath -repo $repo -role $role -branchName $branchName -localBase:$localBase
            $created.Add($added)
            $manifest['repos'] = @($manifest['repos']) + @($added.Entry)
            Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
            return $added
        }
        foreach ($repo in $repoNames) {
            $added = & $addWorktree $repo 'feature'
            $warnings += @($added.Base.Warnings)
            if ($added.Base.Commit -ne $added.Base.LocalCommit) { $drift += ConvertTo-OctoBaseDriftRow -added $added }
        }
        $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath
        if ($addAffected) {
            $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
            foreach ($row in $affected.Graph.Affected) {
                $added = & $addWorktree $row.repo 'consumer'
                $addedConsumers += $row.repo
                $warnings += @($added.Base.Warnings)
                if ($added.Base.Commit -ne $added.Base.LocalCommit) { $drift += ConvertTo-OctoBaseDriftRow -added $added }
            }
        }
        # Part of the transaction: it reads project files and runs git; a failure here rolls back like any other.
        $feedSnapshot = Get-OctoEnvironmentFeedSnapshotReport -env $env -manifest $manifest -basePath $basePath
        $completed = $true
    }
    catch { $errors += $_.Exception.Message }
    finally {
        if (-not $completed) { $rolledBack = Undo-OctoEnvironmentCreation -environmentPath $environmentPath -created @($created) }
    }

    if (-not $completed) {
        $global:LASTEXITCODE = 1
        $errors += @($rolledBack.errors)
        $message = "New-OctoEnvironment failed and was rolled back ($($rolledBack.worktrees.Count) worktree(s), $($rolledBack.branches.Count) branch(es) created by this call$(if ($rolledBack.folder) { ', the environment folder' }) removed); fix the cause and run the same call again: $($errors -join ' | ')"
        if ($Json) {
            Write-OctoJson -Command 'New-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{
                    environment = $env; path = $environmentPath; branch = $branchName; error = $message; errors = $errors; rolledBack = $rolledBack
                })
        }
        else { Write-Error $message }
        return
    }

    $toolRepos = @($manifest['repos'] | Where-Object { Test-OctoEnvironmentToolRepo -repo $_['name'] } | ForEach-Object { $_['name'] })
    # AB#8831: third-party packages from a local cache instead of the network. After the transaction: an environment
    # without a filled cache is complete, its first restore just downloads them.
    $packageCache = $null
    if (-not $skipPackageCacheSeed) {
        try { $packageCache = Invoke-OctoEnvironmentPackageCacheSeed -environmentPath $environmentPath -basePath $basePath -automatic }
        catch { $warnings += "The package cache was not filled from a local cache: $($_.Exception.Message)" }
        if ($packageCache -and @($packageCache.errors).Count -gt 0) { $warnings += "The package cache was filled with errors ($(@($packageCache.errors).Count)): $(@($packageCache.errors | Select-Object -First 3) -join '; ')" }
    }
    $global:LASTEXITCODE = 0
    if ($Json) {
        Write-OctoJson -Command 'New-OctoEnvironment' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{
                packageCache = $packageCache
                environment = $env; path = $environmentPath; branch = $branchName; manifest = $manifest
                consumersAdded = $addedConsumers; sync = (ConvertTo-OctoSyncReport -sync $sync -detailed:$Detailed); errors = @()
                localBase = [bool]$localBase; baseDrift = $drift; feedSnapshot = $feedSnapshot; toolRepos = $toolRepos; warnings = $warnings
            })
        return
    }
    Write-Host "Environment $env at $environmentPath (base $basePath)" -ForegroundColor Green
    foreach ($repo in $manifest['repos']) {
        $short = $repo['baseCommit'].Substring(0, [Math]::Min(10, $repo['baseCommit'].Length))
        Write-Host ("  {0,-9} {1}  {2}" -f $repo['role'], $repo['name'], $(if ($repo['branch']) { "$($repo['branch']) (from $($repo['baseRef']) $short)" } else { "detached at $($repo['baseRef']) $short" }))
    }
    Write-OctoEnvironmentSyncSummary -sync $sync
    if ($packageCache) { Write-OctoPackageCacheSeedSummary -report $packageCache }
    foreach ($message in $warnings) { Write-Warning $message }
    foreach ($message in $feedSnapshot.hints) { Write-Warning $message }
    if ($toolRepos.Count -gt 0) { Write-Host "  $($toolRepos -join ', '): developer tool(s), not built by Invoke-BuildEnvironment" -ForegroundColor DarkGray }
    Write-Host "Next: Invoke-BuildEnvironment -env $env -verifyTests" -ForegroundColor Cyan
}

function Undo-OctoEnvironmentCreation {
    # Rollback of a New-OctoEnvironment call that did not complete: the worktrees it added, the branches it created
    # (never a branch that existed before) and the environment folder (it did not exist before the call).
    param([Parameter(Mandatory = $true)] [string]$environmentPath, [object[]]$created = @())
    $report = [ordered]@{ worktrees = @(); branches = @(); folder = $false; errors = @() }
    foreach ($added in $created) {
        $path = [string]$added.Entry['path']
        if (Test-Path -LiteralPath $path) {
            $remove = Invoke-OctoEnvironmentGit -path $added.Source -arguments @('worktree', 'remove', '--force', $path)
            if ($remove.ExitCode -ne 0) { $report.errors += "rollback: git worktree remove failed for $($added.Entry['name']): $($remove.Output -join ' ')"; continue }
        }
        [void](Invoke-OctoEnvironmentGit -path $added.Source -arguments @('worktree', 'prune'))
        $report.worktrees += $path
        if ($added.CreatedBranch) {
            $delete = Invoke-OctoEnvironmentGit -path $added.Source -arguments @('branch', '-D', $added.CreatedBranch)
            if ($delete.ExitCode -eq 0) { $report.branches += "$($added.Entry['name']): $($added.CreatedBranch)" }
            else { $report.errors += "rollback: git branch -D $($added.CreatedBranch) failed in $($added.Entry['name']): $($delete.Output -join ' ')" }
        }
    }
    if ($report.errors.Count -eq 0 -and (Test-Path -LiteralPath $environmentPath)) {
        try { Remove-Item -LiteralPath $environmentPath -Recurse -Force -ErrorAction Stop; $report.folder = $true }
        catch { $report.errors += "rollback: $environmentPath could not be removed: $($_.Exception.Message)" }
    }
    return $report
}

<#
.SYNOPSIS
    Lists the feature environments, or shows one with the git state of its worktrees.
.EXAMPLE
    Get-OctoEnvironment -Json
.EXAMPLE
    Get-OctoEnvironment -env ab8625-enum-null
#>
function Get-OctoEnvironment {
    param(
        [string]$env = '',
        [switch]$Json
    )

    # Discovery: <rootPath>/wt-*/.octo/environment.json (flat octo-claude-pm worktrees wt-<lane>-<repo> have none).
    $environmentsRoot = Get-OctoEnvironmentRootPath
    $names = if ($env) { @($env) } else {
        @(Get-ChildItem -LiteralPath $environmentsRoot -Directory -Filter 'wt-*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Get-OctoEnvironmentManifestPath -environmentPath $_.FullName) -PathType Leaf } |
            ForEach-Object { $_.Name.Substring(3) } | Where-Object { Test-OctoEnvironmentName -env $_ } | Sort-Object)
    }
    $rows = @()
    $missing = $null
    foreach ($name in $names) {
        try { $manifest = Read-OctoEnvironmentManifest -env $name }
        catch { $manifest = $null; if ($env) { $missing = $_.Exception.Message } }
        if ($null -eq $manifest) {
            if ($env -and -not $missing) { $missing = "Environment $name does not exist." }
            continue
        }
        $row = [ordered]@{
            name     = $manifest['name']
            path     = Get-OctoEnvironmentPath -env $name
            workItem = $manifest['workItem']
            base     = $manifest['base']
            owner    = $manifest['owner']
            created  = $manifest['created']
            slot     = $manifest['slot']
            repos    = @($manifest['repos'] | ForEach-Object { [ordered]@{ name = $_['name']; role = $_['role']; branch = $_['branch']; path = $_['path']; baseCommit = $_['baseCommit']; baseRef = $_['baseRef']; inPlace = (Test-OctoEnvironmentRepoInPlace -repo $_ -environmentPath (Get-OctoEnvironmentPath -env $name)) } })
        }
        if ($env) {
            $row['repos'] = @($manifest['repos'] | ForEach-Object {
                    $state = Get-OctoEnvironmentRepoState -repo $_
                    [ordered]@{ name = $_['name']; role = $_['role']; branch = $_['branch']; path = $_['path']; baseCommit = $_['baseCommit']; baseRef = $_['baseRef']; inPlace = (Test-OctoEnvironmentRepoInPlace -repo $_ -environmentPath (Get-OctoEnvironmentPath -env $name)); exists = $state.exists; dirty = $state.dirty; unpushed = $state.unpushed }
                })
        }
        $rows += [pscustomobject]$row
    }
    if ($missing) {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Get-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ error = $missing }) }
        else { Write-Error $missing }
        return
    }
    if ($Json) {
        $data = if ($env) { $rows[0] } else { [ordered]@{ environments = @($rows) } }
        Write-OctoJson -Command 'Get-OctoEnvironment' -Data $data
        return
    }
    if ($rows.Count -eq 0) { Write-Host "No feature environments in $environmentsRoot"; return }
    foreach ($row in $rows) {
        Write-Host ("{0}  {1}  base {2}  {3}" -f $row.name, $(if ($row.workItem) { $row.workItem } else { '-' }), $row.base, $row.path) -ForegroundColor Cyan
        foreach ($repo in $row.repos) {
            $flags = @()
            if ($repo['inPlace']) { $flags += "in place: $($repo['path']) (not isolated outside octo-tools builds)" }
            if ($repo.Contains('exists') -and -not $repo['exists']) { $flags += 'MISSING' }
            if ($repo.Contains('dirty') -and $repo['dirty']) { $flags += 'dirty' }
            if ($repo.Contains('unpushed') -and $repo['unpushed'] -gt 0) { $flags += "$($repo['unpushed']) unpushed" }
            Write-Host ("  {0,-9} {1,-40} {2} {3}" -f $repo['role'], $repo['name'], $(if ($repo['branch']) { $repo['branch'] } else { 'detached' }), ($flags -join ', '))
        }
    }
}

<#
.SYNOPSIS
    Adds a repository to an environment: a new feature or consumer worktree, or an existing worktree (-path).
.DESCRIPTION
    -repo <name>: -role feature (default) creates <env>/<repo> on the branch of the environment's feature repositories
    (or the default <user>/AB#<id>_<desc>); -role consumer creates a clean detached worktree, rebuilt against the
    environment's packages (read-only by convention). Both start from the upstream of the base checkout's branch
    (origin/main, fetched), -localBase from the local checkout's HEAD - see New-OctoEnvironment (baseDrift,
    feedSnapshot). octo-tools and octo-devstack (next to the lanes) can be added; they are not built.
    Repeatable: worktrees added before a failure stay in the manifest, the same call adds what is missing. -addAffected also adds, as
    consumers, every affected repository on the path from a feature repository to -repo (Get-OctoAffectedRepos -target).

    -path <worktree>: adopts an existing linked worktree - an octo-claude-pm flat worktree <checkout>/wt-<lane>-<repo>
    or a Claude Code worktree <repo>/.claude/worktrees/<name>. The repository is the main checkout that owns it, the
    branch its current branch, baseCommit the merge base with the main checkout's HEAD. By default it is moved with
    `git worktree move` to <env>/<repo>, so plain dotnet builds and Rider there are isolated like any environment repo;
    the move is refused when git has the worktree locked or a process runs from it (Get-OctoProcessesUnderFolder:
    Invoke-KillDotnet's lane matching - working directory, entry assembly, modules - list-only over every process, e.g.
    a shell, an IDE or a Claude Code session; Windows cannot see working directories, stop them there first). Uncommitted changes move with it. The old and the new path are reported.
    -inPlace only records the worktree in the manifest. Invoke-BuildEnvironment then builds it from where it is and
    passes the environment's feed, package cache and CK catalog as global properties (RestoreSources,
    RestorePackagesPath, OctoLocalCatalogRootPath); a plain dotnet build or Rider in that folder is NOT isolated (it
    restores from the ../nuget next to it). Remove-OctoEnvironment only unregisters an in-place worktree, it never
    deletes it (it belongs to its original owner). The manifest's path is authoritative for every repository.
.EXAMPLE
    Add-OctoEnvironmentRepo -env ab8625-enum-null -repo octo-asset-repo-services -role consumer -addAffected
.EXAMPLE
    Add-OctoEnvironmentRepo -env odysseus-kind -path ~/dev/meshmakers/wt-odysseus-kind-octo-helm-core
.EXAMPLE
    Add-OctoEnvironmentRepo -env ab8700-envs -path ~/dev/meshmakers/octo-tools/.claude/worktrees/feature-environments -inPlace
#>
function Add-OctoEnvironmentRepo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [string]$repo = '',
        [string]$path = '',
        [switch]$inPlace,
        [ValidateSet('feature', 'consumer')] [string]$role = 'feature',
        [switch]$addAffected,
        [switch]$localBase,
        [switch]$Json
    )

    $fail = {
        param([string]$message, $extra = $null)
        $global:LASTEXITCODE = 1
        $data = @{ environment = $env; error = $message }
        if ($extra) { foreach ($key in $extra.Keys) { $data[$key] = $extra[$key] } }
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra $data) }
        else { Write-Error $message }
    }
    if ([string]::IsNullOrWhiteSpace($repo) -eq [string]::IsNullOrWhiteSpace($path)) { & $fail "Pass either -repo (new worktree) or -path (adopt an existing worktree)."; return }
    if ($inPlace -and [string]::IsNullOrWhiteSpace($path)) { & $fail "-inPlace needs -path."; return }
    if ($addAffected -and -not [string]::IsNullOrWhiteSpace($path)) { & $fail "-addAffected works with -repo only; run it for the adopted repository afterwards."; return }
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
    }
    catch { & $fail $_.Exception.Message; return }
    $present = @($manifest['repos'] | ForEach-Object { $_['name'] })

    if (-not [string]::IsNullOrWhiteSpace($path)) {
        Add-OctoEnvironmentExistingWorktree -env $env -manifest $manifest -environmentPath $environmentPath -path $path -inPlace:$inPlace -role $role -present $present -fail $fail -Json:$Json -WhatIf:$WhatIfPreference
        return
    }

    try { $name = Resolve-OctoEnvironmentRepoName -repo $repo -basePath $basePath }
    catch { & $fail $_.Exception.Message; return }
    $toAdd = [System.Collections.Generic.List[object]]::new()
    if ($present -notcontains $name) { $toAdd.Add([pscustomobject]@{ Name = $name; Role = $role }) }
    if ($addAffected) {
        $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
        if ($affected.Features.Count -eq 0) { & $fail "-addAffected needs at least one feature repository in $env."; return }
        foreach ($onPath in @(Get-OctoReposOnPath -graph $affected.Graph -target $name)) {
            if ($onPath -ne $name -and $present -notcontains $onPath) { $toAdd.Add([pscustomobject]@{ Name = $onPath; Role = 'consumer' }) }
        }
    }
    if ($toAdd.Count -eq 0) {
        $global:LASTEXITCODE = 0
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ environment = $env; added = @(); note = "$name is already in $env" }) }
        else { Write-Host "$name is already in $env - nothing to add." }
        return
    }
    $branchName = @($manifest['repos'] | Where-Object { $_['role'] -eq 'feature' -and $_['branch'] } | ForEach-Object { $_['branch'] } | Select-Object -First 1)
    $branchName = if ($branchName) { [string]$branchName[0] } else { Get-OctoEnvironmentDefaultBranchName -env $env -workItem $manifest['workItem'] }

    $plan = @($toAdd | ForEach-Object { "$($_.Role) $($_.Name)" })
    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Add worktree(s): $($plan -join ', ')")) {
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; added = $plan }) }
        return
    }
    # Repeatable, not atomic: every worktree that was added is in the manifest; after a failure the same call adds
    # only what is still missing.
    $added = @()
    $errors = @()
    $warnings = @()
    $drift = @()
    foreach ($item in $toAdd) {
        try {
            $new = Add-OctoEnvironmentWorktree -basePath $basePath -environmentPath $environmentPath -repo $item.Name -role $item.Role -branchName $branchName -localBase:$localBase
            $manifest['repos'] = @($manifest['repos']) + @($new.Entry)
            Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
            $added += [ordered]@{ name = $item.Name; role = $item.Role; baseRef = $new.Entry['baseRef']; baseCommit = $new.Entry['baseCommit'] }
            $warnings += @($new.Base.Warnings)
            if ($new.Base.Commit -ne $new.Base.LocalCommit) { $drift += ConvertTo-OctoBaseDriftRow -added $new }
        }
        catch { $errors += $_.Exception.Message }
    }
    # The worktrees are added and recorded by now; a report that cannot be made is a warning, not a failed add.
    try { $feedSnapshot = Get-OctoEnvironmentFeedSnapshotReport -env $env -manifest $manifest -basePath $basePath }
    catch {
        $warnings += "The feed snapshot report is not available: $($_.Exception.Message)"
        $feedSnapshot = [ordered]@{ rebuildInEnvironment = @(); staleProducers = @(); hints = @() }
    }
    $toolRepos = @($added | Where-Object { Test-OctoEnvironmentToolRepo -repo $_['name'] } | ForEach-Object { $_['name'] })
    $success = $errors.Count -eq 0
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{
                environment = $env; added = $added; errors = $errors; localBase = [bool]$localBase; baseDrift = $drift; feedSnapshot = $feedSnapshot; toolRepos = $toolRepos; warnings = $warnings
            })
        return
    }
    foreach ($item in $added) { Write-Host ("Added {0} {1} to {2} (from {3})" -f $item.role, $item.name, $env, $item.baseRef) -ForegroundColor Green }
    foreach ($message in $warnings) { Write-Warning $message }
    foreach ($message in $feedSnapshot.hints) { Write-Warning $message }
    if ($toolRepos.Count -gt 0) { Write-Host "$($toolRepos -join ', '): developer tool(s), not built by Invoke-BuildEnvironment" -ForegroundColor DarkGray }
    foreach ($message in $errors) { Write-Warning $message }
}

function Add-OctoEnvironmentExistingWorktree {
    # Add-OctoEnvironmentRepo -path: adopt an existing linked worktree (move it into the environment, or record it in place).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$env, [System.Collections.IDictionary]$manifest, [string]$environmentPath, [string]$path,
        [switch]$inPlace, [string]$role, [string[]]$present, [scriptblock]$fail, [switch]$Json
    )
    try { $info = Get-OctoWorktreeInfo -path $path }
    catch { & $fail $_.Exception.Message; return }
    if ($present -contains $info.Repo) { & $fail "$($info.Repo) is already in $env."; return }
    if (Test-OctoPathInside -path $info.Path -parent $environmentPath) { & $fail "$($info.Path) already lies inside the environment folder $environmentPath."; return }
    if (Test-OctoEnvironmentToolRepo -repo $info.Repo) {
        Write-Warning "$($info.Repo) is a developer tool, not built by Invoke-BuildEnvironment - it is only recorded."
    }
    $target = Join-Path $environmentPath $info.Repo
    $oldPath = $info.Path

    if ($inPlace) {
        if (-not $PSCmdlet.ShouldProcess($oldPath, "Record in environment $env (in place)")) {
            if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; repo = $info.Repo; oldPath = $oldPath; newPath = $oldPath; inPlace = $true }) }
            return
        }
        $entry = Get-OctoAdoptedWorktreeEntry -info $info -path $oldPath -role $role
    }
    else {
        if (Test-Path -LiteralPath $target) { & $fail "$target already exists."; return }
        if ($info.Locked) { & $fail "git has the worktree $oldPath locked - unlock it (git worktree unlock) or use -inPlace." @{ oldPath = $oldPath }; return }
        # Invoke-KillDotnet's lane matching, list-only, over every process (shells, IDEs, Claude Code sessions too).
        $processes = @(Get-OctoProcessesUnderFolder -path $oldPath)
        if ($processes.Count -gt 0) {
            $list = @($processes | ForEach-Object { "pid $($_.pid) $($_.name) ($($_.reason))" })
            & $fail "Processes run from $oldPath - stop them (or leave the folder) before moving it, or use -inPlace: $($list -join '; ')." @{ oldPath = $oldPath; processes = $processes }
            return
        }
        if (-not $PSCmdlet.ShouldProcess($oldPath, "git worktree move to $target")) {
            if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; repo = $info.Repo; oldPath = $oldPath; newPath = $target; inPlace = $false }) }
            return
        }
        if (-not (Test-Path -LiteralPath $environmentPath)) { New-Item -ItemType Directory -Force -Path $environmentPath | Out-Null }
        $move = Invoke-OctoEnvironmentGit -path $info.MainCheckout -arguments @('worktree', 'move', $oldPath, $target)
        if ($move.ExitCode -ne 0) { & $fail "git worktree move $oldPath $target failed: $($move.Output -join ' ')" @{ oldPath = $oldPath }; return }
        $entry = Get-OctoAdoptedWorktreeEntry -info $info -path $target -role $role
    }
    $manifest['repos'] = @($manifest['repos']) + @($entry)
    Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
    $global:LASTEXITCODE = 0
    $newPath = [string]$entry['path']
    if ($Json) {
        Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{
                environment = $env; added = @([ordered]@{ name = $info.Repo; role = $role }); repo = $info.Repo
                oldPath = $oldPath; newPath = $newPath; inPlace = [bool]$inPlace; branch = $entry['branch']; errors = @()
            })
        return
    }
    if ($inPlace) {
        Write-Host "Recorded $($info.Repo) in $env in place: $oldPath" -ForegroundColor Green
        Write-Warning "Invoke-BuildEnvironment builds it with the environment's feed and cache; a plain dotnet build or Rider in $oldPath is not isolated."
    }
    else {
        Write-Host "Moved $($info.Repo) into $env" -ForegroundColor Green
        Write-Host "  old path: $oldPath"
        Write-Host "  new path: $newPath"
    }
}

function Write-OctoPackageCacheSeedSummary {
    param([Parameter(Mandatory = $true)] $report)
    if ($report['skipped']) { Write-Host "  package cache: not filled - $($report['skipped'])" -ForegroundColor DarkGray; return }
    Write-Host ("  package cache: {0} package version(s), {1:N1} GB from {2} ({3}, {4:N1} s){5}" -f $report['packages'], ($report['sizeBytes'] / 1GB), $report['source'], $report['method'], $report['seconds'], $(if ($report['dryRun']) { ' - dry run' })) -ForegroundColor DarkGray
}

<#
.SYNOPSIS
    Fills an environment's package cache from a local cache instead of the network (AB#8831).
.DESCRIPTION
    Copies every third-party package version the environment's <env>/.nuget-packages lacks from -source (default:
    the base lane's .nuget-packages when it has one, else ~/.nuget/packages). Never meshmakers.*/999.0.0 - the local
    builds come from the environment's own feed - and never a half-extracted version folder. Folders the environment
    already has are left alone, so the call is repeatable.
    macOS, same APFS volume: clones (`cp -c`, copy-on-write: no time, no space, and nothing one environment does to
    its cache reaches another). Everywhere else a plain copy. Never hardlinks.
    New-OctoEnvironment does this on its own; use this cmdlet for an environment created before, or to top it up.
.EXAMPLE
    Initialize-OctoEnvironmentPackageCache -env ab8625-enum-null -Json
#>
function Initialize-OctoEnvironmentPackageCache {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [string]$source = '',
        [switch]$Json
    )
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        if (-not [string]::IsNullOrWhiteSpace($source) -and -not (Test-Path -LiteralPath $source -PathType Container)) { throw "Package cache $source does not exist." }
        # -Json is for callers without a terminal: never wait for a confirmation there (-Confirm, or a
        # $ConfirmPreference that makes this cmdlet ask).
        if ($Json -and -not $WhatIfPreference -and "$ConfirmPreference" -in @('Low', 'Medium')) { throw "Initialize-OctoEnvironmentPackageCache -Json does not prompt: drop -Confirm (or `$ConfirmPreference = '$ConfirmPreference')." }
        $dryRun = -not $PSCmdlet.ShouldProcess((Join-Path $environmentPath '.nuget-packages'), 'Fill the package cache from a local cache')
        $report = Invoke-OctoEnvironmentPackageCacheSeed -environmentPath $environmentPath -basePath $basePath -source $source -dryRun:$dryRun
    }
    catch {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Initialize-OctoEnvironmentPackageCache' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $_.Exception.Message }) }
        else { Write-Error $_.Exception.Message }
        return
    }
    $success = @($report.errors).Count -eq 0 -and -not $report['skipped']
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        $data = New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{ environment = $env }
        foreach ($key in $report.Keys) { $data[$key] = $report[$key] }
        if ($report['skipped']) { $data['error'] = $report['skipped'] }
        Write-OctoJson -Command 'Initialize-OctoEnvironmentPackageCache' -Data $data
        return
    }
    Write-Host "Package cache of $env" -ForegroundColor Green
    Write-OctoPackageCacheSeedSummary -report $report
    Write-Host ("  left alone: {0} already there, {1} local build(s) (meshmakers.*/999.0.0), {2} incomplete" -f $report['alreadyPresent'], $report['skippedLocalBuilds'], $report['skippedIncomplete']) -ForegroundColor DarkGray
    foreach ($message in @($report.errors)) { Write-Warning $message }
}

<#
.SYNOPSIS
    Refreshes an environment's snapshot of the base lane: feed, CK catalog and blueprint catalog.
.DESCRIPTION
    Port of octo-devstack's PrivateFeed rules: packages missing in the environment are copied; packages whose base
    copy changed are refreshed when the environment did not change them; packages built in the environment always
    win. Afterwards <env>/.nuget-packages/<id>/<version> folders whose nupkg differs from the feed are purged (NuGet
    never re-extracts a version it has). The catalogs follow the same rules; a catalog index (catalog.json) changed
    on both sides is JSON-merged (union, the environment's entry wins), a catalog cache file changed on both sides
    is dropped. The per-file state lives in <env>/.octo/sync/*.json. The base lane's feed is never written.
    Snapshot, not live: run it only when main is not being rebuilt (octo-devstack refuses a sync while a main
    build is queued or running). -Json reports per feed and catalog the counts and at most 20 names per list
    (truncated = true when cut); -Detailed lists every file. Same for New-OctoEnvironment and Invoke-BuildEnvironment.
.EXAMPLE
    Sync-OctoEnvironment -env ab8625-enum-null -WhatIf -Json
#>
function Sync-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [switch]$Detailed,
        [switch]$Json
    )
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { throw "Base lane $basePath does not exist." }
    }
    catch {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Sync-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $_.Exception.Message }) }
        else { Write-Error $_.Exception.Message }
        return
    }
    $dryRun = -not $PSCmdlet.ShouldProcess($environmentPath, "Sync feed and catalogs from $basePath")
    $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath -dryRun:$dryRun
    $global:LASTEXITCODE = 0
    if ($Json) {
        $data = New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ environment = $env }
        $report = ConvertTo-OctoSyncReport -sync $sync -detailed:$Detailed
        foreach ($key in $report.Keys) { $data[$key] = $report[$key] }
        Write-OctoJson -Command 'Sync-OctoEnvironment' -Data $data
        return
    }
    Write-Host "Synced $env from $basePath$(if ($dryRun) { ' (dry run - nothing written)' })" -ForegroundColor Green
    Write-OctoEnvironmentSyncSummary -sync $sync
}

<#
.SYNOPSIS
    The repositories a feature environment's changes reach: transitive consumers of its feature repositories.
.DESCRIPTION
    Builds a package graph from every repository of the base lane (the environment's worktrees replace their base
    folders): produced package ids (packable csproj, <PackageId> or the project name; <IsPackable>false</IsPackable>
    produces nothing) and <PackageReference Include="Meshmakers.*"> entries of csproj and props files. A library change
    reaches a service only if every repository between them is rebuilt against the environment feed; prebuilt main
    packages of intermediate libraries would bind to the new library at runtime (MissingMethodException).
    -target limits the result to the repositories on the path from a feature repository to the given repositories.
.EXAMPLE
    Get-OctoAffectedRepos -env ab8625-enum-null -target octo-asset-repo-services -Json
#>
function Get-OctoAffectedRepos {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [string[]]$target = @(),
        [switch]$Json
    )
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        $targets = @($target | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Resolve-OctoEnvironmentRepoName -repo $_.Trim() -basePath $basePath })
    }
    catch {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Get-OctoAffectedRepos' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $_.Exception.Message }) }
        else { Write-Error $_.Exception.Message }
        return
    }
    $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
    $rows = @($affected.Graph.Affected)
    if ($targets.Count -gt 0) {
        $keep = @{}
        foreach ($t in $targets) { foreach ($name in @(Get-OctoReposOnPath -graph $affected.Graph -target $t)) { $keep[$name] = $true } }
        $rows = @($rows | Where-Object { $keep.ContainsKey($_.repo) })
    }
    $present = @{}
    foreach ($repo in $manifest['repos']) { $present[$repo['name']] = $repo['role'] }
    $result = @($rows | ForEach-Object {
            [pscustomobject][ordered]@{ repo = $_.repo; depth = $_.depth; via = $_.via; inEnvironment = $present.ContainsKey($_.repo); role = $present[$_.repo] }
        })
    $global:LASTEXITCODE = 0
    if ($Json) {
        Write-OctoJson -Command 'Get-OctoAffectedRepos' -Data ([ordered]@{ environment = $env; features = $affected.Features; targets = $targets; affected = $result })
        return
    }
    Write-Host "Feature repositories: $($affected.Features -join ', ')" -ForegroundColor Cyan
    if ($result.Count -eq 0) { Write-Host "  no affected repositories"; return }
    foreach ($row in $result) {
        $mark = if ($row.inEnvironment) { "[$($row.role)]" } else { '[not in env]' }
        Write-Host ("  {0,-45} depth {1} {2,-13} via {3}" -f $row.repo, $row.depth, $mark, ($row.via -join ', '))
    }
}

<#
.SYNOPSIS
    Removes a feature environment: its worktrees and its folder (feed, cache, catalogs, logs).
.DESCRIPTION
    Refuses - and removes nothing - when a worktree has uncommitted or untracked changes, or commits on top of its base
    commit that no remote has and whose changes are not on origin's default branch either; the refusal names those
    commits. Commits whose changes are already on the default branch do not block (AB#8953): after a squash or rebase
    merge GitHub deletes the branch, so its commits are on no remote, yet nothing is lost. The default branch is
    fetched first; a worktree counts as merged when every unpushed commit has a patch-equivalent commit there (rebase
    merge), when every file the branch changed is identical there, when the branch's whole change equals one commit
    there (squash merge), or when gh finds a pull request of the branch merged into the default branch whose head is
    HEAD; the dirty state is read again right before anything is removed. -Json: per repo
    unpushed, unpushedCommits, merged, mergedVia (patch | tree | squash | pullRequest), mergedInto, pullRequest,
    unmergedCommits, mergeCheck. There is no -force: commit and push, or discard, first. Feature branches are kept.
    In-place worktrees (Add-OctoEnvironmentRepo -inPlace) are neither checked nor removed. Only what the environment
    owns is deleted (worktrees, nuget/, .nuget-packages/, logFiles/, Octo.User.props, the catalogs, .octo/sync,
    .octo/build-stamps and the manifest); anything else in the folder is kept, the folder goes only when empty. Stop the environment's
    services first (octo-devstack env_remove does that and releases the lease).
.EXAMPLE
    Remove-OctoEnvironment -env ab8625-enum-null -WhatIf
#>
function Remove-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [switch]$Json
    )
    $fail = {
        param([string]$message, $states)
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Remove-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $message; repos = $states }) }
        else { Write-Error $message }
    }
    try {
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist (no $(Get-OctoEnvironmentManifestPath -environmentPath $environmentPath))." }
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
    }
    catch { & $fail $_.Exception.Message @(); return }

    # In-place worktrees (Add-OctoEnvironmentRepo -path -inPlace) are not the environment's: never checked, never removed.
    $owned = @($manifest['repos'] | Where-Object { -not (Test-OctoEnvironmentRepoInPlace -repo $_ -environmentPath $environmentPath) })
    $keptInPlace = @($manifest['repos'] | Where-Object { Test-OctoEnvironmentRepoInPlace -repo $_ -environmentPath $environmentPath } | ForEach-Object { [string]$_['path'] })
    # -checkMerged: unpushed commits whose changes are already on origin's default branch (squash or rebase merge,
    # GitHub deleted the branch) do not block (AB#8953).
    $states = @($owned | ForEach-Object { Get-OctoEnvironmentRepoState -repo $_ -checkMerged })
    $blocking = @($states | Where-Object { $_.dirty -or ($_.unpushed -gt 0 -and -not $_.merged) -or $_.problem })
    if ($blocking.Count -gt 0) {
        $reasons = @($blocking | ForEach-Object {
                $why = @()
                if ($_.dirty) { $why += 'uncommitted changes' }
                if ($_.unpushed -gt 0 -and -not $_.merged) {
                    $commits = if (@($_.unmergedCommits).Count -gt 0) { @($_.unmergedCommits) } else { @($_.unpushedCommits) }
                    $text = "$($_.unpushed) unpushed commit(s)"
                    if ($_.mergedInto) { $text += ", $($commits.Count) not on $($_.mergedInto)" }
                    $text += ": $($commits -join ' | ')"
                    if ($_.mergeCheck) { $text += " ($($_.mergeCheck))" }
                    $why += $text
                }
                if ($_.problem) { $why += $_.problem }
                "$($_.name): $($why -join ', ')"
            })
        & $fail "Remove-OctoEnvironment refused, nothing removed: $($reasons -join '; ')." $states
        return
    }

    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Remove $($owned.Count) worktree(s) and the environment's files")) {
        if ($Json) { Write-OctoJson -Command 'Remove-OctoEnvironment' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; path = $environmentPath; repos = $states; keptInPlace = $keptInPlace }) }
        return
    }
    # The merge checks above fetch and may ask gh, which takes a while: read the dirty state again right before
    # anything is removed, so edits made meanwhile are never deleted (git worktree remove --force below).
    $fresh = @($owned | ForEach-Object { Get-OctoEnvironmentRepoState -repo $_ } | Where-Object { $_.dirty -or $_.problem })
    if ($fresh.Count -gt 0) {
        $reasons = @($fresh | ForEach-Object { "$($_.name): $(if ($_.problem) { $_.problem } else { 'uncommitted changes' })" })
        & $fail "Remove-OctoEnvironment refused, nothing removed: $($reasons -join '; ')." $states
        return
    }
    $errors = @()
    foreach ($repo in $owned) {
        # The main checkout that owns the worktree (adopted worktrees may come from another checkout than the base lane).
        $owner = Get-OctoEnvironmentRepoSource -repo ([string]$repo['name']) -basePath $basePath
        if (-not $owner) { $owner = Join-Path $basePath $repo['name'] }
        if (Test-Path -LiteralPath $repo['path']) {
            try { $owner = (Get-OctoWorktreeInfo -path $repo['path']).MainCheckout } catch { }
            # Clean by the check above; --force only lets git remove a worktree with submodules or ignored build output.
            $remove = Invoke-OctoEnvironmentGit -path $owner -arguments @('worktree', 'remove', '--force', $repo['path'])
            if ($remove.ExitCode -ne 0) { $errors += "git worktree remove failed for $($repo['name']): $($remove.Output -join ' ')"; continue }
        }
        if (Test-Path -LiteralPath $owner) { [void](Invoke-OctoEnvironmentGit -path $owner -arguments @('worktree', 'prune')) }
    }
    $leftOver = @()
    if ($errors.Count -eq 0) {
        # Only what the environment owns; anything else somebody put there stays, the folder goes only when empty.
        # (Claims are not here: they live in the base lane, branches/main/.octo/claims/<repo>.md.)
        foreach ($item in @('nuget', '.nuget-packages', 'logFiles', 'Octo.User.props', '.octo/sync', '.octo/build-stamps', '.octo/local-catalog', '.octo/local-blueprint-catalog', '.octo/environment.json')) {
            $itemPath = Join-Path $environmentPath $item
            if (Test-Path -LiteralPath $itemPath) { Remove-Item -LiteralPath $itemPath -Recurse -Force }
        }
        foreach ($folder in @((Join-Path $environmentPath '.octo'), $environmentPath)) {
            if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) { Remove-Item -LiteralPath $folder -Force }
        }
        if (Test-Path -LiteralPath $environmentPath) { $leftOver = @(Get-ChildItem -LiteralPath $environmentPath -Force | ForEach-Object Name) }
    }
    $success = $errors.Count -eq 0
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'Remove-OctoEnvironment' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{ environment = $env; path = $environmentPath; repos = $states; keptInPlace = $keptInPlace; leftOver = $leftOver; errors = $errors })
        return
    }
    if ($success) { Write-Host "Removed environment $env ($environmentPath); feature branches are kept." -ForegroundColor Green }
    foreach ($state in @($states | Where-Object { $_.merged })) {
        $how = if ($state.pullRequest) { "pull request #$($state.pullRequest.number)" } else { "$($state.mergedVia)-equivalent" }
        Write-Host "  $($state.name): $($state.unpushed) local commit(s) already on $($state.mergedInto) ($how)"
    }
    foreach ($kept in $keptInPlace) { Write-Host "  kept in-place worktree $kept" }
    if ($leftOver.Count -gt 0) { Write-Host "  lane folder kept, it still holds: $($leftOver -join ', ')" }
    foreach ($message in $errors) { Write-Error $message }
}

<#
.SYNOPSIS
    Builds a feature environment incrementally: optional sync with the base lane, then Invoke-BuildRange over the
    environment's repositories.
.DESCRIPTION
    Runs Invoke-BuildRange -branch wt-<env> from the first to the last repository of the environment in the
    shared build order (OctoBuildOrder.psm1; frontends included when the environment holds one). Packages go to
    <env>/nuget, the per-package purge hits only <env>/.nuget-packages (the environment is an isolated lane).
    In-place worktrees (Add-OctoEnvironmentRepo -inPlace) are built from their own folder at their build-order
    position (Invoke-BuildRange -externalRepoPaths) with the environment's feed, cache and CK catalog as global
    properties: RestoreSources (Get-OctoInPlaceRestoreSources: the environment feed in place of ../nuget plus the
    repository's own DebugL sources, e.g. Telerik for octo-report-services; nuget.org when it declares none),
    RestorePackagesPath=<env>/.nuget-packages, OctoLocalCatalogRootPath=<env>/.octo/local-catalog. Credentials in a
    source never reach the dotnet command line: RestoreSources carries the source without them, an owner-only
    NuGet.Config in a temporary folder (mode 600 / current-user ACL, deleted after the build, also on failure) passed
    as RestoreConfigFile carries them, with the user-level NuGet.Config's credentials for the same sources
    (RestoreConfigFile replaces that file).
    Only what changed is built (AB#8814). After every successful repository a build stamp is written
    (<env>/.octo/build-stamps/<repo>.json, OctoBuildStamp.psm1): its git state - HEAD, the diff of the tracked
    files and the untracked files - and the SHA-256 of the environment-feed packages it consumes (the packages of
    every repository it depends on in the package graph). A repository whose stamp still matches when its turn comes
    is skipped (status "skipped", reason "unchanged"); a library rebuilt earlier in the run changes the feed, so its
    consumers are built. Also built: never built here, the last build did not compile the tests and this one asks
    for it, no bin/DebugL output. -buildUnchanged builds everything (needed for a change the stamp cannot see: a CK
    model taken only from the local catalog, npm packages of a frontend, Octo.User.props).
    -repos <names> builds only these repositories (still in build order), -skip <names> leaves repositories out;
    both take exact names or the name without "octo-", and refuse a name that is no repository of the environment.
    A left-out repository between a library that is built and a consumer that is built (or one that changed itself)
    means stale packages: a warning names it (-Json: staleWarnings).
    -Json reports per repository status (built | skipped | failed), reason (unchanged, notSelected, excluded,
    nothingToBuild, neverBuilt, sourcesChanged, packagesChanged, propertiesChanged, testsNotCompiled, noBuildOutput,
    noGitState, always)
    and detail, plus selection and builtCount / skippedCount; -DryRun reports the prediction as action (build | skip)
    and reason (also upstreamBuilt). The events file gets a repoSkipped event for a repository that is not built and
    status / reason on repoDone; the plan event carries the prediction.
    Repositories that do not depend on each other build at the same time, at most -maxParallel (default 2; 1 = one
    after the other, the run as it was before): a repository starts when every environment repository it depends
    on in the package graph is finished, each in its own child process with its own environment. Repositories with
    a CK model, and build.ps1 / frontend / zenon repositories, do not overlap (see Invoke-BuildRange -maxParallel).
    After a failure nothing new starts and the running repositories finish. -Json: parallel, maxParallel, failedRepos.
    The remote CK catalogs are read at most once per run (AB#8831): before the first repository that uses a
    construction kit - not at all while the caches are younger than 30 minutes - and the CK compiles of the run build
    with OctoRefreshRemoteCatalogs=false (OctoCkCatalogRefresh.psm1). -refreshCatalogs lets every CK compile refresh
    them itself, as before. -Json: catalogs { mode, usable, seconds, detail, repo }; per repository catalogSeconds,
    restoreSeconds, compileSeconds and testRestoreSeconds (also on the repoDone event).
    Developer tools in the environment (octo-tools, octo-devstack) are not built; -Json lists them in
    environment.toolRepos, and an environment that holds only tools succeeds with nothing to build.
    -syncMain runs Sync-OctoEnvironment first. Before every hand-off use -verifyTests or -includeTests.
    Before the build the kill scope of the environment is cleared: Invoke-KillDotnet -branchRootPath wt-<env>
    -additionalRoots <in-place worktrees> (Windows stops the matched dotnet processes, macOS/Linux list them);
    -skipKill turns it off. -DryRun prints the plan (Invoke-BuildRange -WhatIf) and changes nothing, also no sync and
    no kill. -EventsFile writes the
    build events with command "Invoke-BuildEnvironment".
.EXAMPLE
    Invoke-BuildEnvironment -env ab8625-enum-null -syncMain -verifyTests
.EXAMPLE
    Invoke-BuildEnvironment -env ab8625-enum-null -repos octo-construction-kit-engine,octo-sdk -DryRun -Json
.EXAMPLE
    Invoke-BuildEnvironment -env ab8625-enum-null -skip octo-docs -buildUnchanged
#>
function Invoke-BuildEnvironment {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [string[]]$repos = @(),
        [string[]]$skip = @(),
        [switch]$buildUnchanged,
        [ValidateRange(1, 16)] [int]$maxParallel = 2,
        [switch]$refreshCatalogs,
        [switch]$syncMain,
        [switch]$verifyTests,
        [switch]$includeTests,
        [string]$EventsFile = '',
        [switch]$skipKill,
        [switch]$Detailed,
        [switch]$DryRun,
        [switch]$Json
    )
    $fail = {
        param([string]$message)
        $global:LASTEXITCODE = 1
        if ($EventsFile -and -not $DryRun) {
            Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-BuildEnvironment' -Event 'done' -Data ([ordered]@{ success = $false; failedRepo = $null; failedStep = 'preflight'; elapsedSeconds = 0 })
        }
        if ($Json) { Write-OctoJson -Command 'Invoke-BuildEnvironment' -Data ([ordered]@{ success = $false; error = $message; environment = $env; synced = $false; repositories = @() }) }
        else { Write-Error $message }
    }
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
    }
    catch { & $fail $_.Exception.Message; return }
    $external = @{}
    $perRepo = @{}
    $credentialSources = [System.Collections.Generic.List[string]]::new()
    $credentials = @{}
    $credentialRepos = @()
    $environmentFeed = Join-Path $environmentPath 'nuget'
    # Developer tools (octo-tools, octo-devstack) are part of the environment but never built: not in the build
    # order, not passed to Invoke-BuildRange, and an in-place one is not in the kill scope (a daemon may run from it).
    $toolRepos = @($manifest['repos'] | Where-Object { Test-OctoEnvironmentToolRepo -repo $_['name'] } | ForEach-Object { [string]$_['name'] })
    foreach ($repo in @($manifest['repos'] | Where-Object { -not (Test-OctoEnvironmentToolRepo -repo $_['name']) -and (Test-OctoEnvironmentRepoInPlace -repo $_ -environmentPath $environmentPath) })) {
        if (-not (Test-Path -LiteralPath $repo['path'] -PathType Container)) { & $fail "In-place worktree $($repo['path']) of $($repo['name']) does not exist."; return }
        $external[[string]$repo['name']] = [string]$repo['path']
        # Credentials in a source (user:password@, e.g. a resolved OctoNugetPrivateServer) never go on the dotnet
        # command line: RestoreSources keeps the sources without them, an owner-only RestoreConfigFile carries them.
        $split = Split-OctoSourceCredentials -restoreSources (Get-OctoInPlaceRestoreSources -repositoryPath ([string]$repo['path']) -environmentFeed $environmentFeed -userPropsPaths @((Join-Path $basePath 'Octo.User.props'), (Join-Path $environmentPath 'Octo.User.props')))
        $perRepo[[string]$repo['name']] = @{
            RestoreSources           = ($split.Sources -join ';')
            RestorePackagesPath      = (Join-Path $environmentPath '.nuget-packages')
            OctoLocalCatalogRootPath = (Join-Path $environmentPath '.octo/local-catalog')
        }
        if ($split.Credentials.Count -gt 0) {
            foreach ($source in $split.Sources) { if (-not $credentialSources.Contains($source)) { $credentialSources.Add($source) } }
            foreach ($key in $split.Credentials.Keys) { $credentials[$key] = $split.Credentials[$key] }
            $credentialRepos += [string]$repo['name']
        }
    }
    try { $order = @(Get-OctoBuildOrder -branchRootPath $environmentPath -excludeFrontend $false -excludeAdditional $false -additionalRepos $external) }
    catch { & $fail $_.Exception.Message; return }
    if ($order.Count -eq 0) {
        # Nothing to build is a result only when the manifest names nothing but tools; a repository whose worktree is
        # gone (deleted, moved) must not turn into "only developer tools".
        $missing = @($manifest['repos'] | Where-Object { -not (Test-OctoEnvironmentToolRepo -repo $_['name']) } | ForEach-Object { [string]$_['name'] })
        if ($missing.Count -gt 0) { & $fail "Environment $env holds no repository to build: the worktree(s) of $($missing -join ', ') are missing in $environmentPath."; return }
        if ($toolRepos.Count -eq 0) { & $fail "Environment $env holds no repository."; return }
        # Only developer tools: nothing to build is a result, not a failure.
        $global:LASTEXITCODE = 0
        $note = "Environment $env holds only developer tools ($($toolRepos -join ', ')) - nothing to build."
        if ($EventsFile -and -not $DryRun) {
            Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-BuildEnvironment' -Event 'plan' -Data ([ordered]@{ repos = @(); count = 0 })
            Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-BuildEnvironment' -Event 'done' -Data ([ordered]@{ success = $true; failedRepo = $null; failedStep = $null; elapsedSeconds = 0 })
        }
        if ($Json) {
            $data = [ordered]@{ success = $true; repositories = @(); note = $note; synced = $false
                environment = [ordered]@{ name = $env; path = $environmentPath; base = $basePath; repos = @(); inPlace = @{}; toolRepos = $toolRepos } }
            if ($DryRun) { $data['whatIf'] = $true }
            Write-OctoJson -Command 'Invoke-BuildEnvironment' -Data $data
        }
        else { Write-Host $note -ForegroundColor Yellow }
        return
    }
    if ($toolRepos.Count -gt 0 -and -not $Json) { Write-Host "Not built (developer tools): $($toolRepos -join ', ')" -ForegroundColor DarkGray }

    # AB#8814: -repos / -skip narrow the build; unknown names are refused before anything runs.
    $orderNames = [string[]]@($order | ForEach-Object Name)
    try { $selection = Get-OctoEnvironmentBuildSelection -env $env -order $orderNames -repos $repos -skip $skip -toolRepos $toolRepos }
    catch { & $fail $_.Exception.Message; return }

    # Kill scope: the lane matching of Invoke-KillDotnet over wt-<env> AND every in-place worktree (Windows stops the
    # matched dotnet processes, which could lock build output; macOS/Linux only list them).
    $killRoots = @($environmentPath) + @($external.Values)
    $kill = [ordered]@{ roots = $killRoots; skipped = [bool]($skipKill -or $DryRun); processes = @(); killedCount = 0 }
    if (-not $kill.skipped) {
        $killDoc = (@(Invoke-KillDotnet -branchRootPath $environmentPath -additionalRoots @($external.Values) -Json) -join "`n") | ConvertFrom-Json
        if ($null -eq $killDoc -or -not $killDoc.data.success) {
            & $fail "Invoke-KillDotnet failed for the environment scope ($($killRoots -join ', ')): $(if ($killDoc.data.error) { $killDoc.data.error } else { 'dotnet processes could not be stopped' })"
            return
        }
        $kill.processes = @($killDoc.data.processes)
        $kill.killedCount = [int]$killDoc.data.killedCount
        if (-not $Json -and $kill.processes.Count -gt 0) {
            Write-Host "Kill scope $($killRoots -join ', '): $($kill.processes.Count) dotnet process(es), $($kill.killedCount) stopped" -ForegroundColor DarkGray
        }
    }

    $sync = $null
    if ($syncMain -and -not $DryRun) {
        if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { & $fail "Base lane $basePath does not exist."; return }
        $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath
        if (-not $Json) { Write-Host "Synced $env from $basePath" -ForegroundColor Green; Write-OctoEnvironmentSyncSummary -sync $sync }
    }

    # Dependencies from the package graph of the lane (environment worktrees in place of their base folders): the feed
    # packages each repository consumes go into its build stamp, the repositories it depends on into the prediction
    # and the stale-package warnings. Without a graph Invoke-BuildRange hashes the whole feed per repository.
    $repoInputs = @{}
    $upstream = @{}
    foreach ($name in $orderNames) { $upstream[$name] = @() }
    try {
        $graph = Get-OctoAffectedRepoGraph -repos (Get-OctoEnvironmentRepoSet -manifest $manifest -basePath $basePath) -features @()
        $upstreamAll = Get-OctoUpstreamRepoMap -graph $graph
        foreach ($name in $orderNames) {
            if (-not $upstreamAll.ContainsKey($name)) { continue }
            $upstream[$name] = @($upstreamAll[$name] | Where-Object { $orderNames -contains $_ })
            $repoInputs[$name] = @{
                packages  = @($upstreamAll[$name] | ForEach-Object { $graph.Info[$_].Produces } | Sort-Object -Unique)
                dependsOn = $upstream[$name]
            }
        }
    }
    catch { Write-Warning "Package graph of $basePath is not available ($($_.Exception.Message)) - every package of the environment feed counts as consumed by every repository." }

    # Stale packages through left-out repositories. Evaluated after the sync: its packages are in the feed by now.
    $staleWarnings = @()
    if ($selection.Skipped.Count -gt 0) {
        $stampRoot = Join-Path $environmentPath '.octo/build-stamps'
        $stampTests = if ($verifyTests -or $includeTests) { 'compiled' } else { 'none' }
        $changed = @{}
        foreach ($entry in $order) {
            $known = if ($repoInputs.ContainsKey($entry.Name)) { [string[]]@($repoInputs[$entry.Name]['packages']) } else { $null }
            $inputs = Get-OctoRepoBuildInputs -path $entry.Path -feedPath $environmentFeed -packageIds $known -msbuildProperties $perRepo[$entry.Name]
            $changed[$entry.Name] = Compare-OctoBuildStamp -stamp (Read-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name) -inputs $inputs -configuration 'DebugL' -tests $stampTests
        }
        $staleWarnings = @(Get-OctoEnvironmentStaleWarnings -order $orderNames -selection $selection -upstream $upstream -changed $changed -buildUnchanged:$buildUnchanged)
        if (-not $Json) { foreach ($warning in $staleWarnings) { Write-Warning $warning['message'] } }
    }

    $range = @{
        branch          = "wt-$env"
        from            = $order[0].Name
        to              = $order[-1].Name
        excludeFrontend = $false
        EventsCommand   = 'Invoke-BuildEnvironment'
        recordStamps    = $true
        maxParallel     = $maxParallel
        refreshCatalogs = [bool]$refreshCatalogs
        skipUnchanged   = -not $buildUnchanged
        repoInputs      = $repoInputs
    }
    if ($selection.Skipped.Count -gt 0) {
        $skipRepos = @{}
        foreach ($name in $selection.Skipped.Keys) { $skipRepos[$name] = $selection.Skipped[$name] }
        $range['skipRepos'] = $skipRepos
    }
    if ($external.Count -gt 0) {
        $range['externalRepoPaths'] = $external
        $range['msbuildPropertiesPerRepo'] = $perRepo
    }
    if ($verifyTests) { $range['verifyTests'] = $true }
    if ($includeTests) { $range['includeTests'] = $true }
    if ($EventsFile) { $range['EventsFile'] = $EventsFile }
    if ($DryRun) { $range['WhatIf'] = $true }

    # The credentials file exists only while the build runs; it is deleted in finally, also after a failure.
    $restoreConfig = $null
    try {
        if ($credentialRepos.Count -gt 0) {
            $restoreConfig = if ($DryRun) { '<owner-only NuGet.Config, generated at build time>' } else { New-OctoRestoreConfigFile -sources @($credentialSources) -credentials $credentials }
            foreach ($name in $credentialRepos) { $perRepo[$name]['RestoreConfigFile'] = $restoreConfig }
        }
        if (-not $Json) {
            Invoke-BuildRange @range
            return
        }
        $output = @(Invoke-BuildRange @range -Json)
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        if ($restoreConfig -and -not $DryRun) { Remove-Item -LiteralPath (Split-Path -Parent $restoreConfig) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $data = [ordered]@{}
    try {
        $inner = ($output -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($key in $inner['data'].Keys) { $data[$key] = $inner['data'][$key] }
    }
    catch {
        $data['success'] = $false
        $data['error'] = "Invoke-BuildRange returned no JSON document: $($_.Exception.Message)"
        $exitCode = 1
    }
    $data['environment'] = [ordered]@{ name = $env; path = $environmentPath; base = $basePath; repos = @($order | ForEach-Object Name); inPlace = $external; toolRepos = $toolRepos }
    $data['synced'] = $null -ne $sync
    $data['selection'] = [ordered]@{ repos = @($selection.Build); skipped = $selection.Skipped; buildUnchanged = [bool]$buildUnchanged }
    $data['staleWarnings'] = @($staleWarnings)
    $data['killDotnet'] = $kill
    if ($null -ne $sync) { $data['sync'] = ConvertTo-OctoSyncReport -sync $sync -detailed:$Detailed }
    $global:LASTEXITCODE = $exitCode
    Write-OctoJson -Command 'Invoke-BuildEnvironment' -Data $data
}

Export-ModuleMember -Function @(
    'New-OctoEnvironment',
    'Get-OctoEnvironment',
    'Add-OctoEnvironmentRepo',
    'Sync-OctoEnvironment',
    'Get-OctoAffectedRepos',
    'Remove-OctoEnvironment',
    'Initialize-OctoEnvironmentPackageCache',
    'Invoke-BuildEnvironment'
)
