# Ploi + DigitalOcean plan finder

Lists which droplet plans you can create in each DigitalOcean region through
Ploi: Ploi reports the plans/regions for your DO credentials, DigitalOcean's
`/v2/sizes` reports where each size runs, and only pairs both agree on are
returned. Python 3 standard library only.

```sh
cp .env.example .env        # add PLOI_API_TOKEN and DO_API_TOKEN (never commit .env)
python3 ploi_do_plan_finder.py --regions atl1,nyc3 --min-memory-mb 2048 --output-format markdown
```

Every setting can come from `.env`, an environment variable or a `--flag`
(flags win). Library use and all options are in the module docstring.
