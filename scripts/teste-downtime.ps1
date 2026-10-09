# Bate na app a cada 200 ms durante o deploy e conta quantas requisicoes falharam.
# Uso (PowerShell):  .\scripts\teste-downtime.ps1 -Url http://<ip-da-vm>/ -Segundos 180
# Resultado esperado de um deploy sem queda: "Erros: 0" e a troca de versao/cor aparecendo no meio.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$Segundos = 180
)

$fim = (Get-Date).AddSeconds($Segundos)
$ok = 0; $erro = 0; $ultimo = ""

Write-Host "Monitorando $Url por $Segundos s... (dispare o deploy agora)"
while ((Get-Date) -lt $fim) {
    try {
        $r = Invoke-RestMethod -Uri $Url -TimeoutSec 3
        $ok++
        $atual = "$($r.versao) [$($r.cor)]"
        if ($atual -ne $ultimo) {
            Write-Host "$(Get-Date -Format HH:mm:ss.fff)  ->  $atual" -ForegroundColor Green
            $ultimo = $atual
        }
    }
    catch {
        $erro++
        Write-Host "$(Get-Date -Format HH:mm:ss.fff)  ERRO: $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 200
}

Write-Host ""
Write-Host "Requisicoes OK: $ok   Erros: $erro"
if ($erro -eq 0) { Write-Host "ZERO DOWNTIME - OK" -ForegroundColor Green }
else { Write-Host "HOUVE QUEDA" -ForegroundColor Red }
