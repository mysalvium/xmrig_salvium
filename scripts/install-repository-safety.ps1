$ErrorActionPreference = "Stop"

$expectedOrigin = "git@github-salvium:mysalvium/xmrig_salvium.git"
$disabledUpstreamPush = "disabled://xmrig/xmrig"
$longLivedBranches = @("stock", "salvium", "donation", "combined")

$repositoryRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $repositoryRoot) {
    throw "Run this script from a worktree of the xmrig_salvium repository."
}

Push-Location $repositoryRoot
try {
    $originUrl = (& git remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or $originUrl -ne $expectedOrigin) {
        throw "Unexpected origin '$originUrl'; expected '$expectedOrigin'."
    }

    & git config core.hooksPath .githooks
    & git config remote.pushDefault origin
    & git config push.default current
    & git config alias.check-upstream-pr "!sh scripts/check-upstream-pr.sh"

    foreach ($branch in $longLivedBranches) {
        & git config "branch.$branch.pushRemote" origin

        if ($branch -ne "combined") {
            & git config "branch.$branch.gh-merge-base" combined
        }
    }

    & git remote get-url upstream *> $null
    if ($LASTEXITCODE -eq 0) {
        & git remote set-url --push upstream $disabledUpstreamPush
    }

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh repo set-default mysalvium/xmrig_salvium
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to set the GitHub CLI default repository."
        }
    }

    Write-Host "Repository safety settings installed."
    Write-Host "  Git push default: origin"
    Write-Host "  GitHub CLI default: mysalvium/xmrig_salvium"
    Write-Host "  Upstream fetch: https://github.com/xmrig/xmrig.git"
    Write-Host "  Upstream push: disabled"
    Write-Host "  Hooks: .githooks"
}
finally {
    Pop-Location
}
