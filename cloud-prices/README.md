# Cloud Prices

This folder contains the cloud compute price comparison app:

- `generate-pricing.ps1` fetches public AWS, Azure, and Google Cloud Linux on-demand rates.
- `index.html` is the checked-in preview page.
- `site/` is generated for GitHub Pages deployment.

Run `./generate-pricing.ps1` from this folder to generate current pricing. Google Cloud is optional: set `GOOGLE_CLOUD_API_KEY` to include its data. If the key is missing or a provider's prices cannot be retrieved, that provider's unavailable entries are skipped; warnings explain omissions. At least one rate must be retrieved for generation to succeed.

The GitHub Actions workflow is at `../.github/workflows/pricing.yml` because GitHub only discovers workflows in the repository-level `.github/workflows` folder.

Before the first deployment, a repository administrator must enable GitHub Pages in **Settings → Pages** and set **Build and deployment → Source** to **GitHub Actions**. The workflow token cannot perform this repository-admin setup.
