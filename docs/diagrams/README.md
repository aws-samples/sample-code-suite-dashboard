# Architecture diagrams

Diagrams for the dashboard and its Amazon Quick migration options. Each `.py`
file generates the matching `.png` using the [`diagrams`](https://diagrams.mingrammer.com/)
library (Graphviz backend).

## Diagrams

| File | Shows |
|---|---|
| `architecture_diagram.png` | Current deployed system (CloudFormation stack): ingestion, data lake, stats/enrichment Lambdas, HTTP API, chat, cross-account reader, and CloudWatch alarms. |
| `connector_architecture_diagram.png` | Target connector-only design: an app in Amazon Quick reaching the backend through an OAuth2/JWT-authorized OpenAPI connector (no QuickSight dataset). |
| `quickapp_migration_diagram.png` | Earlier migration proposal exploring dataset + connector + Quick space bindings. |
| `quick_distribution_diagram.png` | Distribution model: CloudFormation installer + QuickSight asset bundle for customer-account install. |

## Regenerate

Requires Python with the `diagrams` package and Graphviz (`dot`) installed.

```bash
pip install diagrams          # and: brew install graphviz  (macOS)
python3 docs/diagrams/connector_architecture_diagram.py
```

Run from the repo root — each script writes its `.png` to `docs/diagrams/`.
