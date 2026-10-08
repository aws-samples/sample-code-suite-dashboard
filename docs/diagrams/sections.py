"""Section diagrams for the AWS Code Suite Dashboard.

Run: python3 docs/diagrams/sections.py
Outputs (docs/diagrams/):
  overview.png            - end-to-end one-glance picture
  two-paths.png           - forensics vs real-time fan-out from EventBridge
  multi-account.png       - Organizations / StackSets reader-role pattern
  serving-frontends.png   - serving layer + dual frontend (Quick + optional React)

Each diagram is kept compact (few icons, moderate aspect ratio) so it stays
legible on its own. One diagram per concept reads far better than a single
dense wide diagram. Official AWS icons via the `diagrams` library.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.analytics import Athena, Glue, KinesisDataFirehose, Quicksight
from diagrams.aws.compute import Lambda
from diagrams.aws.devtools import Codebuild, Codepipeline
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudformation, Organizations
from diagrams.aws.mobile import APIGateway
from diagrams.aws.security import Cognito
from diagrams.aws.security import IdentityAndAccessManagementIamRole as IAMRole
from diagrams.aws.storage import S3
from diagrams.onprem.client import Client

FORENSICS = "#b7791f"   # amber
REALTIME = "#0d7377"    # teal
PRIMARY = "#7b2ff7"     # purple (Quick app)
SECONDARY = "#9aa7b5"   # dimmed grey (optional React)
CONTROL = "#5f6b7a"     # grey (auth / assume-role / deploy)
EVENT = "#232f3e"       # near-black (events)

BASE_GRAPH = {"bgcolor": "white", "pad": "0.4", "fontsize": "20"}
NODE = {"fontsize": "13"}
EDGE = {"penwidth": "2.2", "fontsize": "12"}

with Diagram(
    "End-to-end overview",
    filename="docs/diagrams/overview",
    show=False,
    direction="LR",
    graph_attr={**BASE_GRAPH, "ranksep": "0.9", "nodesep": "0.5"},
    node_attr=NODE,
    edge_attr=EDGE,
):
    with Cluster("Accounts (xN)", graph_attr={"fontsize": "15", "style": "dashed,rounded", "bgcolor": "#f4f6f8"}):
        src = Codepipeline("CodePipeline\n+ CodeBuild")
    eb = Eventbridge("EventBridge")
    with Cluster("Data lake", graph_attr={"fontsize": "15", "bgcolor": "#eef3f7"}):
        lake = S3("S3\n(raw + enriched)")
        athena = Athena("Athena")
    api = APIGateway("HTTP API")
    quick = Quicksight("App in\nAmazon Quick")

    src >> Edge(color=EVENT, label="events") >> eb
    eb >> Edge(color=CONTROL) >> lake
    lake >> Edge(color=CONTROL) >> athena
    athena >> Edge(color=CONTROL, label="query") >> api
    api >> Edge(color=PRIMARY, penwidth="3.2", label="connector") >> quick

with Diagram(
    "Two parallel data paths",
    filename="docs/diagrams/two-paths",
    show=False,
    direction="LR",
    graph_attr={**BASE_GRAPH, "ranksep": "1.1", "nodesep": "0.5"},
    node_attr=NODE,
    edge_attr=EDGE,
):
    eb = Eventbridge("EventBridge\nrules")
    with Cluster("Historical forensics", graph_attr={"fontsize": "15", "bgcolor": "#fbf3e4"}):
        fh = KinesisDataFirehose("Data Firehose")
        raw = S3("S3 raw\n(partitioned)")
        glue = Glue("Glue")
        athena = Athena("Athena")
        fh >> Edge(color=FORENSICS) >> raw >> Edge(color=FORENSICS) >> glue >> Edge(color=FORENSICS) >> athena
    with Cluster("Real-time visibility", graph_attr={"fontsize": "15", "bgcolor": "#e4f1f1"}):
        enrich = Lambda("Enrichment\nLambda")
        enriched = S3("S3 enriched")
        enrich >> Edge(color=REALTIME, label="flat rows") >> enriched
    eb >> Edge(color=FORENSICS, label="raw JSON") >> fh
    eb >> Edge(color=REALTIME, label="enrich") >> enrich

with Diagram(
    "Multi-account aggregation",
    filename="docs/diagrams/multi-account",
    show=False,
    direction="LR",
    graph_attr={**BASE_GRAPH, "ranksep": "1.1", "nodesep": "0.5"},
    node_attr=NODE,
    edge_attr=EDGE,
):
    with Cluster("Management account", graph_attr={"fontsize": "15", "bgcolor": "#eef3f7"}):
        org = Organizations("AWS\nOrganizations")
        stackset = Cloudformation("CloudFormation\nStackSets")
        stats = Lambda("Stats Lambda")
        org >> Edge(color=CONTROL) >> stackset
    with Cluster("Member accounts (xN)", graph_attr={"fontsize": "15", "style": "dashed,rounded", "bgcolor": "#f4f6f8"}):
        reader = IAMRole("PipelineDashboardReader\n(read-only)")
        pipe = Codepipeline("CodePipeline\n+ CodeBuild")
        reader >> Edge(color=SECONDARY, style="dashed") >> pipe
    stackset >> Edge(color=CONTROL, label="deploy role") >> reader
    stats >> Edge(color=PRIMARY, style="dashed", label="sts:AssumeRole\n+ ListAccounts") >> reader

with Diagram(
    "Serving and frontends",
    filename="docs/diagrams/serving-frontends",
    show=False,
    direction="LR",
    graph_attr={**BASE_GRAPH, "ranksep": "1.0", "nodesep": "0.5"},
    node_attr=NODE,
    edge_attr=EDGE,
):
    with Cluster("Data lake", graph_attr={"fontsize": "15", "bgcolor": "#eef3f7"}):
        athena = Athena("Athena")
        enriched = S3("S3 enriched")
    stats = Lambda("Stats Lambda")
    with Cluster("HTTP API", graph_attr={"fontsize": "15", "bgcolor": "#eef3f7"}):
        api = APIGateway("API Gateway")
        cognito = Cognito("Cognito\nJWT")
        cognito >> Edge(color=CONTROL, style="dotted", label="validate") >> api
    quick = Quicksight("App in Amazon Quick")
    react = Client("React dashboard\n(optional)")

    athena >> Edge(color=CONTROL) >> stats
    enriched >> Edge(color=CONTROL) >> stats
    stats >> Edge(color=CONTROL) >> api
    api >> Edge(color=PRIMARY, penwidth="3.2", label="connector\n(OAuth2 / JWT)") >> quick
    api >> Edge(color=SECONDARY, penwidth="1.3", style="dashed", label="SigV4") >> react
