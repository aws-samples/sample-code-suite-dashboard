"""Dual-frontend architecture: app in Amazon Quick AND the local React UI.

Run: python3 docs/diagrams/connector.py
Output: docs/diagrams/connector.png

Two frontends share one backend. The app in Amazon Quick reaches it through an
OpenAPI action connector (OAuth 2.0 client credentials -> JWT-authorized
/connector/* routes). The existing local React/Vite dashboard still works
unchanged, hitting the same HTTP API's AWS_IAM routes via a SigV4-signing dev
proxy. No QuickSight dataset. The ingestion pipeline that feeds the data lake is
unchanged.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.analytics import Athena, Glue
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.devtools import Codebuild, Codepipeline
from diagrams.aws.integration import Eventbridge, SimpleQueueServiceSqs
from diagrams.aws.management import CloudwatchAlarm
from diagrams.aws.ml import Q as AmazonQ
from diagrams.aws.mobile import APIGateway
from diagrams.aws.security import Cognito
from diagrams.aws.security import IdentityAndAccessManagementIam as IAM
from diagrams.aws.storage import S3
from diagrams.onprem.client import User
from diagrams.programming.framework import React

GRAPH = {
    "fontsize": "26",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "ortho",
    "nodesep": "0.7",
    "ranksep": "1.2",
}
NODE = {"fontsize": "16"}
EDGE = {"penwidth": "2.5", "fontsize": "14"}

with Diagram(
    "Dual frontend: app in Amazon Quick + local React UI",
    filename="docs/diagrams/connector",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
    edge_attr=EDGE,
):
    users = User("Customer users")

    with Cluster("Customer Amazon Quick account", graph_attr={"fontsize": "20"}):
        app = AmazonQ("App in Quick\n(sandboxed iframe)")
        connector = APIGateway("OpenAPI action connector\n(OAuth 2.0 client credentials)")
        app >> Edge(color="purple", label="connector actions") >> connector

    with Cluster("Local developer machine (still supported)", graph_attr={"fontsize": "18"}):
        dev = User("Developer")
        ui = React("Vite UI + SigV4 proxy\nlocalhost:5173")
        dev >> Edge(color="darkorange") >> ui

    with Cluster("Customer AWS account", graph_attr={"fontsize": "20"}):
        idp = Cognito("OAuth token issuer\n(Cognito / OIDC)")

        with Cluster("HTTP API (two auth paths)", graph_attr={"fontsize": "16"}):
            api = APIGateway("HTTP API\nJWT /connector/* +\nAWS_IAM routes")
            stats = Lambda("Stats Lambda")

        with Cluster("Read / query path", graph_attr={"fontsize": "16"}):
            athena = Athena("Athena workgroup")
            glue = Glue("Glue Data Catalog\n(4 tables)")
            s3 = S3("S3 data lake\nraw + enriched")

        with Cluster("Chat path", graph_attr={"fontsize": "16"}):
            ddb = Dynamodb("Chat state\n(24h TTL)")
            worker = Lambda("Chat Worker\nLambda")
            agent = AmazonQ("DevOps Agent\nAgentSpace")

        with Cluster("Event ingestion (unchanged)", graph_attr={"fontsize": "16"}):
            src = Codepipeline("CodePipeline /\nCodeBuild")
            build = Codebuild("CodeBuild\nprojects")
            eb = Eventbridge("EventBridge\n(4 rules)")
            fh = APIGateway("Firehose")
            enrich = Lambda("Enrichment\nLambda")
            dlq = SimpleQueueServiceSqs("DLQ")

        reader = IAM("PipelineDashboardReader\n(cross-account, read-only)")

        with Cluster("Alarms (no notification target)", graph_attr={"fontsize": "16"}):
            alarm_stats = CloudwatchAlarm("stats-lambda-errors")
            alarm_enrich = CloudwatchAlarm("enrichment-lambda-errors")
            alarm_dlq = CloudwatchAlarm("enrichment-dlq-not-empty")

    # Frontend 1: app in Quick via connector (OAuth2/JWT)
    users >> Edge(color="darkblue") >> app
    connector >> Edge(color="purple", label="token request") >> idp
    connector >> Edge(color="purple", label="GET /connector/* (JWT)") >> api
    api >> Edge(color="purple", label="validate JWT") >> idp
    api >> Edge(color="purple", label="invoke") >> stats

    # Frontend 2: local React UI via the existing AWS_IAM routes (unchanged)
    ui >> Edge(color="darkorange", label="SigV4 /api/* (AWS_IAM)") >> api

    # Read path
    stats >> Edge(color="darkblue", label="query") >> athena >> Edge(color="darkblue") >> glue
    glue >> Edge(color="darkblue") >> s3
    stats >> Edge(color="darkblue", style="dashed", label="sts:AssumeRole") >> reader

    # Chat path
    stats >> Edge(color="purple", label="write / poll") >> ddb
    stats >> Edge(color="purple", label="async invoke") >> worker
    worker >> Edge(color="purple", label="CreateChat /\nSendMessage") >> agent
    worker >> Edge(color="purple", label="write answer") >> ddb

    # Ingestion path (unchanged)
    [src, build] >> Edge(color="darkgreen", label="state changes") >> eb
    eb >> Edge(color="darkgreen", label="*-events-rule") >> fh >> Edge(color="darkgreen") >> s3
    eb >> Edge(color="darkgreen", label="*-enrichment-rule") >> enrich
    enrich >> Edge(color="darkgreen", label="enriched/") >> s3
    enrich >> Edge(color="firebrick", style="dashed", label="on failure") >> dlq

    # Monitoring (terminal)
    stats >> Edge(color="gray", style="dotted") >> alarm_stats
    enrich >> Edge(color="gray", style="dotted") >> alarm_enrich
    dlq >> Edge(color="gray", style="dotted") >> alarm_dlq
