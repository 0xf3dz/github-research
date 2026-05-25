# Data and Query for "Does AI Assistance Erode Open-Source Maintenance?"

This repository contains the BigQuery SQL used to extract the panel dataset
analysed in my MSc dissertation.

## Contents

- `query.sql` — Google BigQuery query against the `githubarchive.month.*`
tables. Extracts monthly commit, issue, star, and fork activity for ~65,000
public GitHub repositories between September 2024 and September 2025, with
AI co-authorship detection via commit-message trailers.

## Dataset

The processed panel dataset (501,983 repository-month observations) is
archived on Zenodo:

**DOI:** https://doi.org/10.5281/zenodo.20370476

## Citing

If you use this query or dataset, please cite:

> Scandizzo, F. (2026). *AI-assisted commits and maintenance metrics for
> 65,452 public GitHub repositories (September 2024–September 2025)*
> [Data set]. Zenodo. https://doi.org/10.5281/zenodo.20370476

## License

Data (Zenodo): CC-BY 4.0
