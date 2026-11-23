BeforeAll {
    $script:releaseWorkflow = Get-Content (Join-Path $PSScriptRoot '../.github/workflows/release-attestation.yml') -Raw
    $script:releasePolicy = Get-Content (Join-Path $PSScriptRoot '../docs/release-attestation.md') -Raw
}

Describe 'Release attestation output wiring' {
    It 'passes only the verified commit output to the archive step' {
        $verification = [regex]::Match($script:releaseWorkflow, '(?s)- name: Verify signed annotated tag.*?(?=\r?\n      - name:)').Value
        $bundle = [regex]::Match($script:releaseWorkflow, '(?s)- name: Create deterministic source release bundle.*?(?=\r?\n      - name:)').Value
        $verification | Should -Match 'id: verify_tag'
        $verification | Should -Match 'echo "commit=\$\{tag_commit\}" >> "\$\{GITHUB_OUTPUT\}"'
        $bundle | Should -Match 'VERIFIED_COMMIT: \$\{\{ steps\.verify_tag\.outputs\.commit \}\}'
        $bundle | Should -Match 'git archive .*"\$\{VERIFIED_COMMIT\}"'
        $bundle | Should -Not -Match 'git (rev-list|rev-parse)'
    }
    It 'requires a protected ref and documents the commit-only tag boundary' {
        $script:releaseWorkflow | Should -Match 'GITHUB_REF_PROTECTED'
        $script:releasePolicy | Should -Match 'does not bind the annotated-tag object'
        $script:releasePolicy | Should -Match 'Restrict updates'
        $script:releasePolicy | Should -Match 'Restrict deletions'
    }
}

# The producer runs on ubuntu-latest. Execute its actual Bash blocks there;
# Windows validation still checks the cross-step output wiring above.
Describe 'Release attestation producer offline execution' -Skip:(-not $IsLinux) {
    BeforeAll {
        $steps = @{}
        foreach ($step in @{
            'verify.sh' = 'Verify signed annotated tag'
            'bundle.sh' = 'Create deterministic source release bundle'
        }.GetEnumerator()) {
            $pattern = '(?s)- name: ' + [regex]::Escape($step.Value) + '.*?run: \|\r?\n(?<code>.*?)(?=\r?\n      - name:|\z)'
            $match = [regex]::Match($script:releaseWorkflow, $pattern)
            if (-not $match.Success) { throw "Missing workflow step: $($step.Value)" }
            $steps[$step.Key] = $match.Groups['code'].Value -replace '(?m)^          ', ''
        }

        function Invoke-ReleaseProducerFixture {
            param(
                [hashtable] $Ref = @{},
                [hashtable] $Tag = @{},
                [string] $Case = 'valid'
            )

            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $root | Out-Null
            foreach ($step in $steps.GetEnumerator()) {
                Set-Content (Join-Path $root $step.Key) -Value ($step.Value -replace "`r`n", "`n") -Encoding utf8NoBOM
            }
            @{ ref = $Ref; tag = $Tag } | ConvertTo-Json -Depth 10 |
                Set-Content (Join-Path $root 'overrides.json') -Encoding utf8NoBOM
            $fixture = @'
set -euo pipefail
export FIXTURE_ROOT="$PWD"
# Isolate Git configuration and prohibit every transport except local files.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file
export GIT_TERMINAL_PROMPT=0 GH_TOKEN='' GITHUB_TOKEN=''
export GIT_AUTHOR_NAME='release fixture' GIT_AUTHOR_EMAIL='release@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git init --quiet --initial-branch=main origin
cd origin
printf 'base\n' > payload.txt
git add payload.txt
git commit --quiet -m base
base_commit="$(git rev-parse HEAD)"
printf 'reviewed release\n' > payload.txt
git commit --quiet -am release
release_commit="$(git rev-parse HEAD)"
tag='v1.2.3'
git tag -a "$tag" -m 'release fixture'
tag_sha="$(git rev-parse "refs/tags/${tag}")"
printf 'later main\n' > payload.txt
git commit --quiet -am later
cd "$FIXTURE_ROOT"
git clone --quiet --no-local origin checkout
cd checkout
git checkout --quiet --detach "$release_commit"

export GITHUB_REF="refs/tags/${tag}" GITHUB_SHA="$release_commit" GITHUB_REF_PROTECTED=true
export GITHUB_REPOSITORY='example/azd-advanced-auditing' GITHUB_OUTPUT="$FIXTURE_ROOT/verify.outputs"
export RUNNER_TEMP="$FIXTURE_ROOT"
printf '%s\n' "$release_commit" > "$FIXTURE_ROOT/expected-commit.txt"
printf '%s\n' "$tag_sha" > "$FIXTURE_ROOT/expected-tag-object.txt"
printf '%s\n' "$tag_sha" > "$FIXTURE_ROOT/original-tag-object.txt"

jq -n --arg ref "$GITHUB_REF" --arg sha "$tag_sha" --slurpfile overrides "$FIXTURE_ROOT/overrides.json" \
    '{ref:$ref,object:{type:"tag",sha:$sha}} * $overrides[0].ref' > "$FIXTURE_ROOT/ref.json"
jq -n --arg tag "$tag" --arg sha "$tag_sha" --arg commit "$release_commit" --slurpfile overrides "$FIXTURE_ROOT/overrides.json" \
    '{sha:$sha,tag:$tag,object:{type:"commit",sha:$commit},verification:{verified:true}} * $overrides[0].tag' > "$FIXTURE_ROOT/tag.json"

# A shell function shadows gh completely; unexpected requests fail instead of
# falling through to an installed CLI or contacting a service.
gh() {
    printf '%s\n' "$*" >> "$FIXTURE_ROOT/api.calls"
    if [[ "$#" == 2 && "$1" == api && "$2" == repos/example/azd-advanced-auditing/git/ref/tags/v1.2.3 ]]; then
        cat "$FIXTURE_ROOT/ref.json"
    elif [[ "$#" == 2 && "$1" == api && "$2" == "repos/example/azd-advanced-auditing/git/tags/$(cat "$FIXTURE_ROOT/expected-tag-object.txt")" ]]; then
        cat "$FIXTURE_ROOT/tag.json"
    elif [[ "$#" == 4 && "$1" == api && "$2" == repos/example/azd-advanced-auditing && "$3" == --jq && "$4" == .default_branch ]]; then
        printf 'main\n'
    else
        echo "Unexpected fixture API request: $*" >&2
        return 97
    fi
}
export -f gh

case "$FIXTURE_CASE" in
    same-commit-tag-replaced-before-read)
        git tag --force -a "$tag" "$release_commit" -m 'replacement annotation'
        replacement_sha="$(git rev-parse "refs/tags/${tag}")"
        printf '%s\n' "$replacement_sha" > "$FIXTURE_ROOT/replacement-tag-object.txt"
        printf '%s\n' "$replacement_sha" > "$FIXTURE_ROOT/expected-tag-object.txt"
        export FIXTURE_TAG_SHA="$replacement_sha" GITHUB_REF_PROTECTED=false
        jq -n --arg ref "$GITHUB_REF" --arg sha "$replacement_sha" \
            '{ref:$ref,object:{type:"tag",sha:$sha}}' > "$FIXTURE_ROOT/ref.json"
        jq -n --arg tag "$tag" --arg sha "$replacement_sha" --arg commit "$release_commit" \
            '{sha:$sha,tag:$tag,object:{type:"commit",sha:$commit},verification:{verified:true}}' > "$FIXTURE_ROOT/tag.json"
        ;;
    branch-ref) export GITHUB_REF=refs/heads/main ;;
    local-tag-moved) git tag --force -a "$tag" "$base_commit" -m replacement ;;
    local-tag-object-changed) git tag --force -a "$tag" "$release_commit" -m replacement ;;
    local-tag-lightweight) git tag --force "$tag" "$release_commit" ;;
    event-commit-mismatch) export GITHUB_SHA="$base_commit" ;;
    event-commit-short) export GITHUB_SHA="${release_commit:0:7}" ;;
    head-commit-mismatch) git checkout --quiet --detach "$base_commit" ;;
    remote-commit-mismatch)
        jq --arg sha "$base_commit" '.object.sha=$sha' "$FIXTURE_ROOT/tag.json" > "$FIXTURE_ROOT/changed.json"
        mv "$FIXTURE_ROOT/changed.json" "$FIXTURE_ROOT/tag.json"
        ;;
    outside-default-branch)
        git -C "$FIXTURE_ROOT/origin" update-ref refs/heads/main "$base_commit"
        git update-ref refs/remotes/origin/main "$base_commit"
        ;;
    malformed-ref-json) printf 'not json\n' > "$FIXTURE_ROOT/ref.json" ;;
    malformed-tag-json) printf 'not json\n' > "$FIXTURE_ROOT/tag.json" ;;
esac

bash --noprofile --norc "$FIXTURE_ROOT/verify.sh"
export VERIFIED_COMMIT="$(sed -n 's/^commit=//p' "$GITHUB_OUTPUT")"
if [[ "$FIXTURE_CASE" == moved-after-verification ]]; then
    git tag --force -a "$tag" "$base_commit" -m replacement
    git checkout --quiet --detach "$base_commit"
elif [[ "$FIXTURE_CASE" == missing-verified-output ]]; then
    export VERIFIED_COMMIT=''
fi
git rev-parse "refs/tags/${tag}^{commit}" > "$FIXTURE_ROOT/tag-after.txt"
export GITHUB_OUTPUT="$FIXTURE_ROOT/bundle.outputs"
bash --noprofile --norc "$FIXTURE_ROOT/bundle.sh"
archive="$(sed -n 's/^path=//p' "$GITHUB_OUTPUT")"
gzip -dc "$archive" | git get-tar-commit-id > "$FIXTURE_ROOT/archived-commit.txt"
tar -xOf "$archive" azd-advanced-auditing-v1.2.3/payload.txt > "$FIXTURE_ROOT/bundled-payload.txt"
'@
            Set-Content (Join-Path $root 'fixture.sh') -Value ($fixture -replace "`r`n", "`n") -Encoding utf8NoBOM
            $start = [System.Diagnostics.ProcessStartInfo]::new('bash')
            $start.ArgumentList.Add('--noprofile')
            $start.ArgumentList.Add('--norc')
            $start.ArgumentList.Add('fixture.sh')
            $start.WorkingDirectory = $root
            $start.Environment['FIXTURE_CASE'] = $Case
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [System.Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                [pscustomobject]@{
                    ExitCode = $process.ExitCode
                    Output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
                    Root = $root
                }
            }
            finally { $process.Dispose() }
        }
    }

    It 'archives the exact verified commit after checking default-branch ancestry' {
        $result = Invoke-ReleaseProducerFixture
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $commit = Get-Content (Join-Path $result.Root 'expected-commit.txt')
        Get-Content (Join-Path $result.Root 'verify.outputs') | Should -Be "commit=$commit"
        Get-Content (Join-Path $result.Root 'archived-commit.txt') | Should -Be $commit
        Get-Content (Join-Path $result.Root 'bundled-payload.txt') | Should -Be 'reviewed release'
        $calls = @(Get-Content (Join-Path $result.Root 'api.calls'))
        $calls.Count | Should -Be 3
        @($calls | Where-Object { $_ -match '/git/tags/' }).Count | Should -Be 1
    }

    It 'rejects invalid GitHub ref metadata: <Name>' -ForEach @(
        @{ Name = 'different exact tag'; Ref = @{ ref = 'refs/tags/v1.2.30' } }
        @{ Name = 'branch ref'; Ref = @{ ref = 'refs/heads/v1.2.3' } }
        @{ Name = 'missing ref'; Ref = @{ ref = $null } }
        @{ Name = 'lightweight tag'; Ref = @{ object = @{ type = 'commit' } } }
        @{ Name = 'missing type'; Ref = @{ object = @{ type = $null } } }
        @{ Name = 'short object SHA'; Ref = @{ object = @{ sha = 'abcdef0' } } }
        @{ Name = 'nonhex object SHA'; Ref = @{ object = @{ sha = ('g' * 40) } } }
        @{ Name = 'numeric object SHA'; Ref = @{ object = @{ sha = 1 } } }
        @{ Name = 'missing object SHA'; Ref = @{ object = @{ sha = $null } } }
        @{ Name = 'newline object SHA'; Ref = @{ object = @{ sha = (('a' * 40) + "`n") } } }
    ) {
        $result = Invoke-ReleaseProducerFixture -Ref $Ref
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'not the exact annotated tag ref'
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
        @(Get-Content (Join-Path $result.Root 'api.calls')).Count | Should -Be 1
    }

    It 'rejects invalid GitHub annotated-tag metadata: <Name>' -ForEach @(
        @{ Name = 'different tag object'; Tag = @{ sha = ('a' * 40) } }
        @{ Name = 'different internal tag name'; Tag = @{ tag = 'v9.9.9' } }
        @{ Name = 'missing internal tag name'; Tag = @{ tag = $null } }
        @{ Name = 'nested tag'; Tag = @{ object = @{ type = 'tag' } } }
        @{ Name = 'tree target'; Tag = @{ object = @{ type = 'tree' } } }
        @{ Name = 'missing target type'; Tag = @{ object = @{ type = $null } } }
        @{ Name = 'unverified signature'; Tag = @{ verification = @{ verified = $false } } }
        @{ Name = 'string verified flag'; Tag = @{ verification = @{ verified = 'true' } } }
        @{ Name = 'numeric verified flag'; Tag = @{ verification = @{ verified = 1 } } }
        @{ Name = 'missing verified flag'; Tag = @{ verification = @{ verified = $null } } }
        @{ Name = 'short commit SHA'; Tag = @{ object = @{ sha = 'abcdef0' } } }
        @{ Name = 'nonhex commit SHA'; Tag = @{ object = @{ sha = ('g' * 40) } } }
        @{ Name = 'uppercase commit SHA'; Tag = @{ object = @{ sha = ('A' * 40) } } }
        @{ Name = 'numeric commit SHA'; Tag = @{ object = @{ sha = 1 } } }
        @{ Name = 'missing commit SHA'; Tag = @{ object = @{ sha = $null } } }
        @{ Name = 'newline commit SHA'; Tag = @{ object = @{ sha = (('a' * 40) + "`n") } } }
    ) {
        $result = Invoke-ReleaseProducerFixture -Tag $Tag
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'not a verified annotated tag for an exact commit'
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
        @(Get-Content (Join-Path $result.Root 'api.calls')).Count | Should -Be 2
    }

    It 'blocks a two-sided same-commit tag replacement when the ref is unprotected' {
        $result = Invoke-ReleaseProducerFixture -Case 'same-commit-tag-replaced-before-read'
        $originalTag = (Get-Content (Join-Path $result.Root 'original-tag-object.txt')).Trim()
        $replacementTag = (Get-Content (Join-Path $result.Root 'replacement-tag-object.txt')).Trim()
        $eventCommit = (Get-Content (Join-Path $result.Root 'expected-commit.txt')).Trim()
        $originalTag | Should -Not -Be $replacementTag
        $ref = Get-Content (Join-Path $result.Root 'ref.json') -Raw | ConvertFrom-Json
        $tag = Get-Content (Join-Path $result.Root 'tag.json') -Raw | ConvertFrom-Json
        $ref.object.sha | Should -Be $replacementTag
        $tag.sha | Should -Be $replacementTag
        $tag.object.sha | Should -Be $eventCommit
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Release tag ref is not protected'
        Test-Path (Join-Path $result.Root 'api.calls') | Should -BeFalse
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
    }
    It 'rejects mismatched local, event or remote identities: <_>' -ForEach @(
        'local-tag-moved', 'local-tag-object-changed', 'event-commit-mismatch',
        'event-commit-short', 'head-commit-mismatch', 'remote-commit-mismatch'
    ) {
        $result = Invoke-ReleaseProducerFixture -Case $_
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'does not match the checked-out tag and event commit'
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
    }

    It 'fails closed before publishing a commit output: <_>' -ForEach @(
        'branch-ref', 'local-tag-lightweight', 'malformed-ref-json', 'malformed-tag-json'
    ) {
        $result = Invoke-ReleaseProducerFixture -Case $_
        $result.ExitCode | Should -Not -Be 0
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
        Test-Path (Join-Path $result.Root 'bundle.outputs') | Should -BeFalse
    }

    It 'rejects a verified matching commit outside the default branch' {
        $result = Invoke-ReleaseProducerFixture -Case 'outside-default-branch'
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match "does not point to a commit on 'main'"
        Test-Path (Join-Path $result.Root 'verify.outputs') | Should -BeFalse
    }

    It 'keeps the archive bound to the verified commit when the tag and HEAD move afterward' {
        $result = Invoke-ReleaseProducerFixture -Case 'moved-after-verification'
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $commit = Get-Content (Join-Path $result.Root 'expected-commit.txt')
        Get-Content (Join-Path $result.Root 'tag-after.txt') | Should -Not -Be $commit
        Get-Content (Join-Path $result.Root 'archived-commit.txt') | Should -Be $commit
        Get-Content (Join-Path $result.Root 'bundled-payload.txt') | Should -Be 'reviewed release'
    }

    It 'does not build an archive without the verified commit output' {
        $result = Invoke-ReleaseProducerFixture -Case 'missing-verified-output'
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'requires the verified commit output'
        Test-Path (Join-Path $result.Root 'bundle.outputs') | Should -BeFalse
        @(Get-ChildItem $result.Root -Filter '*.tar.gz').Count | Should -Be 0
    }
}
