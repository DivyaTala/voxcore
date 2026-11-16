# UVM regression for the AES-128 peripheral on the Vivado simulator (xsim).
#   .\run_xsim.ps1                       aes_full_test on seeds 1..5, then the mutation check
#   .\run_xsim.ps1 -Test aes_rand_test -Seeds 7
# Builds in a scratch folder (xsim does not like spaces in paths).
param(
    [string]$Test = "aes_full_test",
    [int[]]$Seeds = @(1, 2, 3, 4, 5),
    [string]$Vivado = "C:\AMDDesignTools\2025.2\Vivado\bin",
    [string]$Work = "$env:TEMP\aes_uvm_xsim"
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path "$here\..\.."
New-Item -ItemType Directory -Force $Work | Out-Null
Copy-Item "$root\rtl\periph\aes128_enc.sv", "$root\rtl\periph\aes_apb.sv", "$root\data\aes_sbox.svh" $Work -Force
Copy-Item "$here\*.sv", "$here\aes_ref.c" $Work -Force
Push-Location $Work
$src = "aes128_enc.sv", "aes_apb.sv", "aes_apb_if.sv", "aes_uvm_pkg.sv", "aes_sva.sv", "tb_top.sv"

function Build([string]$snap, [string]$define) {
    $defs = @(); if ($define) { $defs = @("-d", $define) }
    & "$Vivado\xvlog.bat" -sv -L uvm @defs @src | Select-String "ERROR"
    & "$Vivado\xelab.bat" tb_top -L uvm -sv_lib dpi -timescale 1ns/1ps -s $snap | Select-String "ERROR"
}
function Run([string]$snap, [string]$test, [int]$seed) {
    $log = "run_${snap}_${test}_${seed}.log"
    # the plusarg goes through cmd so that '=' survives
    cmd /c "`"$Vivado\xsim.bat`" $snap -R -testplusarg `"UVM_TESTNAME=$test`" -sv_seed $seed -log $log" | Out-Null
    return Get-Content $log
}

& "$Vivado\xsc.bat" aes_ref.c | Select-String "ERROR"
Build "aes_sim" ""
$fail = 0
foreach ($seed in $Seeds) {
    $l = Run "aes_sim" $Test $seed
    $sb = ($l | Select-String "\[SB\] \d").Line -replace '^.*\[SB\] ', ''
    $cov = ($l | Select-String "functional coverage").Line -replace '^.*\[SB\] ', ''
    $res = ($l | Select-String "==== .* ====").Line -replace '^.*\[TEST\] ', ''
    $asrt = @($l | Select-String "Assertion|assertion.*fail").Count
    "seed ${seed}: $res"; "    $sb"; "    $cov; assertion failures: $asrt"
    if ($res -notmatch "PASSED" -or $asrt -ne 0) { $fail++ }
}

# mutation check: each injected bug must make the known-answer test fail
foreach ($bug in "AES_BUG_RCON", "AES_BUG_LASTMIX") {
    Build "aes_$bug" $bug
    $l = Run "aes_$bug" "aes_kat_test" 1
    if ($l | Select-String "PASSED ====") { "${bug}: NOT CAUGHT"; $fail++ } else { "${bug}: caught" }
}
Build "aes_sim" "" | Out-Null      # leave the clean build in the work library
Pop-Location
if ($fail) { "==== aes_uvm regression FAILED ($fail) ===="; exit 1 } else { "==== aes_uvm regression PASSED ====" }
