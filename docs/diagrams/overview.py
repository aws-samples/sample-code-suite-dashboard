"""High-level overview of the AWS Code Suite observability system.

Run: python3 docs/diagrams/overview.py
Output: docs/diagrams/overview.png

Clean, left-to-right, four grouped sections, two visually distinct data paths
(historical forensics vs real-time visibility), with the app in Amazon Quick as
the primary frontend and the React dashboard as a dimmed optional secondary.
Kept to ~15 icons for an uncluttered, presentation-friendly layout.
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

# Path colors: forensics (amber) vs real-time (teal); control/auth (grey/purple).
FORENSICS = "#b7791f"   # amber
REALTIME = "#0d7377"    # teal
PRIMARY = "#7b2ff7"     # purple - the Quick app path (prominent)
SECONDARY = "#9aa7b5"   # dimmed grey - optional React path
CONTROL = "#5f6b7a"     # grey - assume-role / deploy

GRAPH = {
    "fontsize": "22",
    "bgcolor": "white",
    "pad": "0.75",
    "splines": "spline",
    "nodesep": "0.55",
    "ranksep": "1.4",
}
NODE = {"fontsize": "13"}
EDGE = {"penwidth": "2.2", "fontsize": "12"}

with Diagram(
    "Unified observability for AWS Code Suite pipelines across accounts",
    filename="docs/diagrams/overview",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
    edge_attr=EDGE,
):
    # ---- Section 1: Member accounts (dashed = many) ----
    with Cluster(
        "Member accounts (xN)",
        graph_attr={"fontsize": "18", "style": "dashed,rounded", "bgcolor": "#f4f6f8", "penwidth": "2"},
    ):
        pipe = Codepipeline("CodePipeline")
        build = Codebuild("CodeBuild")
        reader = IAMRole("PipelineDashboardReader")

    with Cluster(
        "Org onboarding",
        graph_attr={"fontsize": "16", "bgcolor": "#f4f6f8", "penwidth": "1.5"},
    ):
        org = Organizations("AWS Organizations")
        stackset = Cloudformation("CloudFormation\nStackSets")
        org >> Edge(color=CONTROL, style="dashed", label="deploys reader\nrole via StackSet") >> stackset

    # ---- Section 2: Ingestion ----
    with Cluster(
        "Ingestion",
        graph_attr={"fontsize": "18", "bgcolor": "#eef3f7", "penwidth": "1.5"},
    ):
        eb = Eventbridge("EventBridge\nrules")

        with Cluster(
            "Historical forensics",
            graph_attr={"fontsize": "15", "bgcolor": "#fbf3e4", "penwidth": "1.5"},
        ):
            fh = KinesisDataFirehose("Data Firehose")
            lake = S3("S3\ntime-partitioned")
            glue = Glue("Glue catalog")
            athena = Athena("Athena")

        with Cluster(
            "Real-time visibility",
            graph_attr={"fontsize": "15", "bgcolor": "#e4f1f1", "penwidth": "1.5"},
        ):
            enrich = Lambda("Enrichment\nLambda")
            enriched = S3("S3\nenriched prefix")

    # ---- Section 3: Serving ----
    with Cluster(
        "Serving",
        graph_attr={"fontsize": "18", "bgcolor": "#eef3f7", "penwidth": "1.5"},
    ):
        stats = Lambda("Stats Lambda")
        api = APIGateway("API Gateway\nHTTP API")
        cognito = Cognito("Cognito\nJWT authorizer")

    # ---- Section 4: Frontends ----
    with Cluster(
        "Frontends",
        graph_attr={"fontsize": "18", "bgcolor": "#f3eefb", "penwidth": "1.5"},
    ):
        quick = Quicksight("App in Amazon Quick")
        react = Client("React dashboard\n(optional)")

    # ===== Flows =====
    # Events in
    pipe >> Edge(color="#232f3e", label="events") >> eb
    build >> Edge(color="#232f3e") >> eb

    # Historical forensics path (amber)
    eb >> Edge(color=FORENSICS, label="raw JSON") >> fh
    fh >> Edge(color=FORENSICS) >> lake
    lake >> Edge(color=FORENSICS) >> glue
    glue >> Edge(color=FORENSICS) >> athena

    # Real-time visibility path (teal)
    eb >> Edge(color=REALTIME, label="enrich") >> enrich
    enrich >> Edge(color=REALTIME, label="enriched rows") >> enriched

    # Serving reads from both stores
    athena >> Edge(color=CONTROL) >> stats
    enriched >> Edge(color=CONTROL) >> stats
    stats >> Edge(color=CONTROL, style="dashed", label="sts:AssumeRole") >> reader
    stats >> Edge(color=CONTROL) >> api
    cognito >> Edge(color=CONTROL, style="dotted", label="validate JWT") >> api

    # Frontends: Quick (primary, bold purple) vs React (secondary, dimmed thin)
    api >> Edge(color=PRIMARY, penwidth="3.5", label="API calls\n(Connector: OAuth2 / JWT)") >> quick
    api >> Edge(color=SECONDARY, penwidth="1.3", style="dashed", label="SigV4") >> react
