#Requires -Modules Pester
<#
    Pester tests for tests/Invoke-ParallelPester.ps1 (AB#8811): the merged result of the parallel runner must fail
    whenever a single file fails - a failed test, a failed BeforeAll, a file that cannot be discovered, a file
    without tests.

    The runner is pointed at small test files written into TestDrive, never at ./tests itself.

    Run:  Invoke-Pester ./tests/ParallelPester.Tests.ps1
#>

BeforeAll {
    $script:Runner = Join-Path $PSScriptRoot 'Invoke-ParallelPester.ps1'

    function New-SampleSuite([string]$name, [hashtable]$files) {
        $folder = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        foreach ($file in $files.Keys) { Set-Content -Path (Join-Path $folder $file) -Value $files[$file] }
        return $folder
    }

    $script:Passing = "Describe 'ok' { It 'one' { 1 | Should -Be 1 }; It 'two' { 2 | Should -Be 2 } }"
    $script:Failing = "Describe 'mixed' { It 'passes' { 1 | Should -Be 1 }; It 'fails' { 1 | Should -Be 2 }; It 'is skipped' -Skip { } }"
}

Describe 'Invoke-ParallelPester' {
    It 'merges the counts of all files and succeeds when every file passes' {
        $suite = New-SampleSuite 'green' @{ 'A.Tests.ps1' = $script:Passing; 'B.Tests.ps1' = $script:Passing; 'helper.ps1' = 'throw "not a test file"' }

        $result = & $script:Runner -Path $suite -ThrottleLimit 2 -PassThru

        $result.Success | Should -BeTrue
        $result.TotalCount | Should -Be 4
        $result.PassedCount | Should -Be 4
        $result.FailedCount | Should -Be 0
        $result.FailedFileCount | Should -Be 0
        @($result.Files.File) | Should -Be @('A.Tests.ps1', 'B.Tests.ps1')
        @($result.Files.Success | Sort-Object -Unique) | Should -Be @($true)
    }

    It 'fails the merged result when one file has a failed test, and names the test' {
        $suite = New-SampleSuite 'red' @{ 'A.Tests.ps1' = $script:Passing; 'B.Tests.ps1' = $script:Failing }

        $result = & $script:Runner -Path $suite -PassThru

        $result.Success | Should -BeFalse
        $result.TotalCount | Should -Be 5
        $result.PassedCount | Should -Be 3
        $result.FailedCount | Should -Be 1
        $result.SkippedCount | Should -Be 1
        $result.FailedFileCount | Should -Be 1
        ($result.Files | Where-Object File -eq 'A.Tests.ps1').Success | Should -BeTrue
        $failed = $result.Files | Where-Object File -eq 'B.Tests.ps1'
        $failed.Success | Should -BeFalse
        @($failed.FailedTests.Name) | Should -Be @('mixed.fails')
        $failed.FailedTests[0].Error | Should -Match 'Expected 2'
    }

    It 'fails for a file whose BeforeAll throws, a file that cannot be parsed and a file without tests' {
        $suite = New-SampleSuite 'broken' @{
            'A.Tests.ps1'       = $script:Passing
            'Setup.Tests.ps1'   = "Describe 'setup' { BeforeAll { throw 'setup broke' }; It 'never runs' { 1 | Should -Be 1 } }"
            'Syntax.Tests.ps1'  = "Describe 'syntax' { It 'unclosed' { "
            'Nothing.Tests.ps1' = "# no tests in here"
        }

        $result = & $script:Runner -Path $suite -PassThru

        $result.Success | Should -BeFalse
        $result.FailedFileCount | Should -Be 3
        ($result.Files | Where-Object File -eq 'A.Tests.ps1').Success | Should -BeTrue
        foreach ($name in 'Setup.Tests.ps1', 'Syntax.Tests.ps1', 'Nothing.Tests.ps1') {
            $file = $result.Files | Where-Object File -eq $name
            $file.Success | Should -BeFalse -Because "$name must not count as passed"
            ($file.Error -or $file.FailedCount -gt 0) | Should -BeTrue -Because "$name must say what failed"
        }
        ($result.Files | Where-Object File -eq 'Nothing.Tests.ps1').Error | Should -Be 'the file ran no test'
    }

    It 'sets the exit code: 1 when a file fails, 0 when all pass' {
        $red = New-SampleSuite 'exit-red' @{ 'B.Tests.ps1' = $script:Failing }
        $green = New-SampleSuite 'exit-green' @{ 'A.Tests.ps1' = $script:Passing }

        & $script:Runner -Path $red 6>$null
        $LASTEXITCODE | Should -Be 1
        & $script:Runner -Path $green 6>$null
        $LASTEXITCODE | Should -Be 0
    }

    It 'takes single files and refuses a path that does not exist or holds no test file' {
        $suite = New-SampleSuite 'single' @{ 'A.Tests.ps1' = $script:Passing; 'B.Tests.ps1' = $script:Failing }

        $result = & $script:Runner -Path (Join-Path $suite 'A.Tests.ps1') -PassThru
        $result.Success | Should -BeTrue
        @($result.Files.File) | Should -Be @('A.Tests.ps1')

        { & $script:Runner -Path (Join-Path $suite 'missing') -PassThru } | Should -Throw '*does not exist*'
        $empty = New-SampleSuite 'empty' @{ 'readme.txt' = 'nothing' }
        { & $script:Runner -Path $empty -PassThru } | Should -Throw '*no *.Tests.ps1*'
    }
}
