$ErrorActionPreference = 'Stop'

function Invoke-PricingApi {
  param([Parameter(Mandatory)][string]$Uri)
  Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 300 -ErrorAction Stop
}

function Get-AwsRates {
  param([Parameter(Mandatory)][string[]]$InstanceTypes)

  $csvPath = Join-Path ([System.IO.Path]::GetTempPath()) "aws-ec2-us-east-1-$PID.csv"
  $oldProgressPreference = $ProgressPreference
  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri 'https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/us-east-1/index.csv' -OutFile $csvPath -TimeoutSec 300 -ErrorAction Stop
    $rows = @(Get-Content -LiteralPath $csvPath | Select-Object -Skip 5 | ConvertFrom-Csv | Where-Object {
      $_.'Product Family' -eq 'Compute Instance' -and
      $_.'Instance Type' -in $InstanceTypes -and
      $_.'Operating System' -eq 'Linux' -and
      $_.Tenancy -eq 'Shared' -and
      $_.'Pre Installed S/W' -eq 'NA' -and
      $_.CapacityStatus -eq 'Used' -and
      $_.operation -like 'RunInstances*' -and
      $_.TermType -eq 'OnDemand' -and
      $_.Unit -eq 'Hrs' -and
      $_.StartingRange -eq '0' -and
      $_.Currency -eq 'USD'
    })

    $rates = @{}
    foreach ($instanceType in $InstanceTypes) {
      $row = $rows | Where-Object { $_.'Instance Type' -eq $instanceType } | Select-Object -First 1
      if ($null -eq $row) {
        Write-Warning "AWS price list has no Linux shared on-demand entry for $instanceType in us-east-1; skipping this size."
        continue
      }
      $rates[$instanceType] = [double]::Parse($row.PricePerUnit, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $rates
  }
  finally {
    $ProgressPreference = $oldProgressPreference
    Remove-Item -LiteralPath $csvPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-AzureHourlyRate {
  param([Parameter(Mandatory)][string]$ArmSkuName)

  $filter = "serviceName eq 'Virtual Machines' and armRegionName eq 'eastus' and armSkuName eq '$ArmSkuName' and priceType eq 'Consumption'"
  $uri = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&$filter=' + [uri]::EscapeDataString($filter)
  $azureMatches = @()

  while ($uri) {
    $response = Invoke-PricingApi -Uri $uri
    $azureMatches += @($response.Items | Where-Object {
            $_.armSkuName -eq $ArmSkuName -and
      $_.currencyCode -eq 'USD' -and
      $_.type -eq 'Consumption' -and
      $_.unitOfMeasure -eq '1 Hour' -and
      $_.productName -notmatch 'Windows|Low Priority|Spot'
    })
    $uri = $response.NextPageLink
  }

  if ($azureMatches.Count -eq 0) {
    throw "Azure Retail Prices has no Linux consumption rate for $ArmSkuName in East US."
  }

  [double](($azureMatches | Sort-Object retailPrice | Select-Object -First 1).retailPrice)
}

function Get-GoogleUnitRate {
  param(
    [Parameter(Mandatory)]$Sku,
    [Parameter(Mandatory)][string]$ExpectedUnit
  )

  $currentPrice = $Sku.pricingInfo | Sort-Object effectiveTime -Descending | Select-Object -First 1
  $expression = $currentPrice.pricingExpression
  if ($expression.usageUnit -ne $ExpectedUnit) {
    throw "Unexpected Google Cloud pricing unit '$($expression.usageUnit)' for $($Sku.description)."
  }

  $tier = $expression.tieredRates | Where-Object { $_.startUsageAmount -eq 0 } | Select-Object -First 1
  if ($null -eq $tier -or $tier.unitPrice.currencyCode -ne 'USD') {
    throw "Google Cloud USD price was not found for $($Sku.description)."
  }

  [double]$tier.unitPrice.units + ([double]$tier.unitPrice.nanos / 1000000000)
}

function Get-GoogleN2Rates {
  param([Parameter(Mandatory)][string]$ApiKey)

  $encodedKey = [uri]::EscapeDataString($ApiKey)
  $serviceResponse = Invoke-PricingApi -Uri "https://cloudbilling.googleapis.com/v1/services?pageSize=5000&key=$encodedKey"
  $service = $serviceResponse.services | Where-Object { $_.displayName -eq 'Compute Engine' } | Select-Object -First 1
  if ($null -eq $service) {
    throw 'Google Cloud Billing Catalog did not return the Compute Engine service.'
  }

  $skus = [System.Collections.Generic.List[object]]::new()
  $pageToken = $null
  do {
    $uri = "https://cloudbilling.googleapis.com/v1/$($service.name)/skus?pageSize=5000&currencyCode=USD&key=$encodedKey"
    if ($pageToken) {
      $uri += '&pageToken=' + [uri]::EscapeDataString($pageToken)
    }
    $page = Invoke-PricingApi -Uri $uri
    foreach ($sku in $page.skus) {
      if ($sku.serviceRegions -contains 'us-east1' -and $sku.category.usageType -eq 'OnDemand') {
        $skus.Add($sku)
      }
    }
    $pageToken = $page.nextPageToken
  } while ($pageToken)

  $coreSku = $skus | Where-Object { $_.description -match 'N2 Instance Core running in Americas' } | Select-Object -First 1
  $ramSku = $skus | Where-Object { $_.description -match 'N2 Instance Ram running in Americas' } | Select-Object -First 1
  if ($null -eq $coreSku -or $null -eq $ramSku) {
    throw 'Google Cloud N2 on-demand core/RAM SKUs were not found for us-east1.'
  }

  @{
    core = Get-GoogleUnitRate -Sku $coreSku -ExpectedUnit 'h'
    ram = Get-GoogleUnitRate -Sku $ramSku -ExpectedUnit 'GiBy.h'
  }
}

$awsInstanceTypes = @('m7i.large', 'm7i.xlarge', 'm7i.2xlarge')
$awsRates = @{}
try {
  $awsRates = Get-AwsRates -InstanceTypes $awsInstanceTypes
}
catch {
  Write-Warning "AWS prices are unavailable and will be omitted: $($_.Exception.Message)"
}

$googleRates = $null
$googleApiKey = $env:GOOGLE_CLOUD_API_KEY
if ([string]::IsNullOrWhiteSpace($googleApiKey)) {
  Write-Warning 'GOOGLE_CLOUD_API_KEY is not set; Google Cloud prices will be omitted.'
}
else {
  try {
    $googleRates = Get-GoogleN2Rates -ApiKey $googleApiKey
  }
  catch {
    Write-Warning "Google Cloud prices are unavailable and will be omitted: $($_.Exception.Message)"
  }
}

$sizes = @(
  @{ vcpu = 2; memory = 8; aws = 'm7i.large'; azure = 'D2s v5'; azureArm = 'Standard_D2s_v5'; google = 'n2-standard-2' }
  @{ vcpu = 4; memory = 16; aws = 'm7i.xlarge'; azure = 'D4s v5'; azureArm = 'Standard_D4s_v5'; google = 'n2-standard-4' }
  @{ vcpu = 8; memory = 32; aws = 'm7i.2xlarge'; azure = 'D8s v5'; azureArm = 'Standard_D8s_v5'; google = 'n2-standard-8' }
)

$pricing = [System.Collections.Generic.List[object]]::new()
foreach ($size in $sizes) {
  if ($awsRates.ContainsKey($size.aws)) {
    $pricing.Add(@{ cloud = 'AWS'; vm = $size.aws; vcpu = $size.vcpu; memory = $size.memory; rate = $awsRates[$size.aws]; region = 'us-east-1' })
  }

  try {
    $azureRate = Get-AzureHourlyRate -ArmSkuName $size.azureArm
    $pricing.Add(@{ cloud = 'Azure'; vm = $size.azure; vcpu = $size.vcpu; memory = $size.memory; rate = $azureRate; region = 'East US' })
  }
  catch {
    Write-Warning "Azure price for $($size.azure) is unavailable and will be omitted: $($_.Exception.Message)"
  }

  if ($null -ne $googleRates) {
    $pricing.Add(@{ cloud = 'Google Cloud'; vm = $size.google; vcpu = $size.vcpu; memory = $size.memory; rate = (($size.vcpu * $googleRates.core) + ($size.memory * $googleRates.ram)); region = 'us-east1' })
  }
}

if ($pricing.Count -eq 0) {
  throw 'No cloud prices could be retrieved; the pricing page was not generated.'
}

$pricingJson = ConvertTo-Json -InputObject @($pricing.ToArray()) -Depth 4 -Compress
$generatedDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
$html = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Cloud Compute Pricebook</title>
  <style>
    :root {
      font-family: "Segoe UI", "Aptos", sans-serif;
      color: #17211f;
      background: #f3f5f2;
      font-synthesis: none;
      --ink: #17211f;
      --muted: #64716c;
      --line: #dce3dd;
      --green: #17684d;
      --lime: #d7ed70;
      --paper: #fff;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-width: 320px; }
    header {
      background: #163d32;
      color: #f6f7ee;
      padding: 34px max(24px, calc((100vw - 1120px) / 2)) 32px;
      border-bottom: 5px solid var(--lime);
    }
    .eyebrow { color: #c9dfa0; font-size: 11px; font-weight: 700; letter-spacing: 1.4px; text-transform: uppercase; }
    h1 { font-size: clamp(28px, 4vw, 42px); line-height: 1.08; margin: 10px 0 8px; font-weight: 650; }
    header p { color: #d2dfd8; margin: 0; font-size: 14px; }
    main { max-width: 1120px; margin: 0 auto; padding: 28px 24px 48px; }
    .controls { display: flex; align-items: end; gap: 18px; flex-wrap: wrap; margin-bottom: 20px; }
    label { display: grid; gap: 7px; color: var(--muted); font-size: 12px; font-weight: 650; }
    select, input {
      min-height: 42px; border: 1px solid #cbd5ce; border-radius: 4px; background: white;
      color: var(--ink); font: inherit; font-size: 14px; padding: 0 12px;
    }
    select { min-width: 190px; }
    input { width: 120px; }
    .basis { margin-left: auto; color: var(--muted); font-size: 12px; padding-bottom: 10px; }
    .summary { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin: 0 0 22px; }
    .metric { padding: 16px 18px; background: var(--paper); border: 1px solid var(--line); border-top: 3px solid #83a98e; }
    .metric span { display: block; color: var(--muted); font-size: 11px; font-weight: 700; letter-spacing: .6px; text-transform: uppercase; }
    .metric strong { display: block; margin-top: 8px; font-size: 23px; font-weight: 650; }
    .metric small { color: var(--muted); font-size: 12px; }
    .table-wrap { background: white; border: 1px solid var(--line); overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; min-width: 700px; text-align: left; }
    th { background: #eaf0e9; color: #43534b; font-size: 11px; letter-spacing: .5px; text-transform: uppercase; }
    th, td { padding: 13px 16px; border-bottom: 1px solid #e8ede8; }
    tbody tr:last-child td { border-bottom: 0; }
    td { font-size: 13px; }
    .cloud { font-weight: 700; }
    .vm { font-family: Consolas, "Courier New", monospace; font-size: 12px; }
    .money { font-variant-numeric: tabular-nums; white-space: nowrap; }
    .best { color: #145a40; font-weight: 750; }
    .tag { display: inline-block; margin-left: 7px; padding: 3px 6px; background: #e4f1d0; color: #365c2b; font-size: 10px; font-weight: 700; text-transform: uppercase; }
    .note { margin: 18px 0; padding: 14px 16px; background: #fff6df; border-left: 3px solid #d59d32; color: #594923; font-size: 12px; line-height: 1.55; }
    footer { display: flex; justify-content: space-between; gap: 14px; flex-wrap: wrap; color: var(--muted); font-size: 11px; }
    footer a { color: var(--green); text-decoration-thickness: 1px; text-underline-offset: 3px; }
    @media (max-width: 620px) {
      header { padding: 26px 20px 24px; }
      main { padding: 22px 16px 36px; }
      .summary { grid-template-columns: 1fr; gap: 8px; }
      .metric { padding: 12px 14px; }
      .metric strong { display: inline-block; margin: 6px 8px 0 0; font-size: 20px; }
      .basis { width: 100%; margin: -4px 0 0; padding: 0; }
    }
  </style>
</head>
<body>
  <header>
    <div class="eyebrow">Infrastructure / Compute</div>
    <h1>Cloud compute pricebook</h1>
    <p>Comparable Linux virtual machines, on-demand, across AWS, Azure, and Google Cloud.</p>
  </header>
  <main>
    <section class="controls" aria-label="Pricing controls">
      <label>Machine size
        <select id="size">
          <option value="all">All sizes</option>
          <option value="2">2 vCPU / 8 GiB</option>
          <option value="4">4 vCPU / 16 GiB</option>
          <option value="8">8 vCPU / 32 GiB</option>
        </select>
      </label>
      <label>Hours per month
        <input id="hours" type="number" min="1" max="744" value="730">
      </label>
      <div class="basis">USD · Linux · On-demand · No discounts</div>
    </section>
    <section class="summary" aria-label="Selected size summary">
      <div class="metric"><span>Lowest hourly</span><strong id="lowest-hourly">-</strong><small id="lowest-hourly-cloud"></small></div>
      <div class="metric"><span>Lowest monthly</span><strong id="lowest-monthly">-</strong><small id="lowest-monthly-cloud"></small></div>
      <div class="metric"><span>Monthly hours</span><strong id="hours-label">730</strong><small>adjustable estimate</small></div>
    </section>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Cloud</th><th>Instance</th><th>vCPU</th><th>Memory</th><th>Region</th><th>Hourly</th><th>Monthly</th></tr></thead>
        <tbody id="rows"></tbody>
      </table>
    </div>
    <p class="note"><strong>Public on-demand list prices, fetched __GENERATED_DATE__.</strong> Rates are retrieved from the providers' public price catalogs for the listed Linux VM sizes and regions. They do not include negotiated discounts, reservations or commitments, storage, networking, taxes, or support. AWS and Azure list prices are matched to the named VM; Google Cloud N2 is calculated from public per-vCPU and per-GiB rates. Verify your exact configuration before budgeting or purchasing.</p>
    <footer>
      <span>Generated from provider catalogs · Monthly estimate uses 730 hours by default.</span>
      <span><a href="https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-ppslong.html">AWS Price List</a> · <a href="https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices">Azure Retail Prices</a> · <a href="https://docs.cloud.google.com/billing/v1/how-tos/catalog-api">Google Cloud Catalog</a></span>
    </footer>
  </main>
  <script>
    const pricing = __PRICING_DATA__;
    const size = document.getElementById('size');
    const hours = document.getElementById('hours');
    const rows = document.getElementById('rows');
    const money = value => '$' + value.toFixed(4);
    function render() {
      const selectedSize = size.value;
      const monthlyHours = Math.max(1, Math.min(744, Number(hours.value) || 730));
      hours.value = monthlyHours;
      document.getElementById('hours-label').textContent = monthlyHours;
      const visible = pricing.filter(item => selectedSize === 'all' || item.vcpu === Number(selectedSize));
      if (visible.length === 0) {
        rows.innerHTML = '<tr><td colspan="7">No prices are available for this size.</td></tr>';
        document.getElementById('lowest-hourly').textContent = '-';
        document.getElementById('lowest-hourly-cloud').textContent = '';
        document.getElementById('lowest-monthly').textContent = '-';
        document.getElementById('lowest-monthly-cloud').textContent = '';
        return;
      }
      const minRate = Math.min(...visible.map(item => item.rate));
      rows.innerHTML = visible.map(item => {
        const best = item.rate === minRate;
        return '<tr>' +
          '<td class="cloud">' + item.cloud + (best ? '<span class="tag">Lowest</span>' : '') + '</td>' +
          '<td class="vm">' + item.vm + '</td>' +
          '<td>' + item.vcpu + '</td>' +
          '<td>' + item.memory + ' GiB</td>' +
          '<td>' + item.region + '</td>' +
          '<td class="money ' + (best ? 'best' : '') + '">' + money(item.rate) + '</td>' +
          '<td class="money ' + (best ? 'best' : '') + '">' + money(item.rate * monthlyHours) + '</td>' +
          '</tr>';
      }).join('');
      const winner = visible.find(item => item.rate === minRate);
      document.getElementById('lowest-hourly').textContent = money(minRate);
      document.getElementById('lowest-hourly-cloud').textContent = winner.cloud + ' · ' + winner.vm;
      document.getElementById('lowest-monthly').textContent = money(minRate * monthlyHours);
      document.getElementById('lowest-monthly-cloud').textContent = winner.cloud + ' · ' + winner.vm;
    }
    size.addEventListener('change', render);
    hours.addEventListener('input', render);
    render();
  </script>
</body>
</html>
'@

$html = $html.Replace('__PRICING_DATA__', $pricingJson).Replace('__GENERATED_DATE__', $generatedDate)
Set-Content -Path (Join-Path $PSScriptRoot 'index.html') -Value $html -Encoding utf8
$sitePath = Join-Path $PSScriptRoot 'site'
New-Item -ItemType Directory -Path $sitePath -Force | Out-Null
Set-Content -Path (Join-Path $sitePath 'index.html') -Value $html -Encoding utf8
Write-Output "Generated $(Join-Path $PSScriptRoot 'index.html')"