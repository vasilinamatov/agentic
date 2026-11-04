# Cloud Compute Pricebook

Generate a standalone HTML comparison of representative Linux on-demand compute instances across AWS, Azure, and Google Cloud.

## Generate locally

Run the PowerShell generator from this directory. It fetches current public list prices from the AWS Price List file, Azure Retail Prices API, and Google Cloud Billing Catalog API, then writes `index.html` and `site/index.html`.

```powershell
./generate-pricing.ps1
```

It writes `index.html`, which can be opened directly in a browser. Google requires the Cloud Billing API to be enabled and an API key available in `GOOGLE_CLOUD_API_KEY`. For GitHub Actions, add that value as a repository Actions secret with the same name; restrict the key to the Cloud Billing API. AWS and Azure lookups do not need credentials. If your PowerShell execution policy blocks local scripts, use your organization's approved method to run the script rather than changing the machine-wide policy.

## Automated workflow

The GitHub Actions workflow generates the page when the generator/workflow changes on `main`, once a week, or when manually started from the Actions tab. It deploys the page to GitHub Pages; enable Pages with **Build and deployment / Source: GitHub Actions** in repository settings. The published URL appears in the `github-pages` deployment environment. AWS publishes its regional EC2 offer as a large CSV file, which the generator streams to avoid loading the full catalog into memory.

The checked-in `index.html` is only a preview with illustrative values. A local generator run replaces it with fetched rates; GitHub Actions deploys its generated page to Pages without committing generated data back to the repository. Prices are public retail/on-demand list rates, not negotiated quotes, and exclude commitments, storage, networking, taxes, and support. Google N2 rates are calculated from public per-vCPU and per-GiB catalog rates. Monthly costs use a configurable number of hours (730 by default).