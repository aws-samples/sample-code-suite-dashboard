"""Generate the architecture diagram for aws-code-observability-dashboard.

Run: python3 docs/diagrams/architecture.py
Output: docs/diagrams/architecture.png
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import Athena, Glue
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.devtools import Codepipeline, Codebuild
from diagrams.aws.integration import Eventbridge, SimpleQueueServiceSqs
from diagrams.aws.management import CloudwatchAlarm
from diagrams.aws.ml import Q as AmazonQ
from diagrams.aws.mobile import APIGateway
from diagrams.aws.security import IdentityAndAccessManagementIam as IAM
from diagrams.aws.storage import S3
from diagrams.onprem.client import User
from diagrams.programming.framework import React

graph_attr = {
    "fontsize": "26",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "ortho",
    "nodesep": "0.6",
    "ranksep": "1.1",
}
node_attr = {"fontsize": "16"}
edge_attr = {"penwidth": "2.5", "fontsize": "14"}

with Diagram(
    "aws-code-observability-dashboard (CloudFormation stack)",
    filename="docs/diagrams/architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    with Cluster("Developer (local)", graph_attr={"fontsize": "18"}):
        dev = User("Developer")
        ui = React("Vite UI + SigV4\nlocalhost:5173")
        dev >> Edge(color="darkblue") >> ui

    with Cluster("Central AWS account", graph_attr={"fontsize": "20"}):
        api = APIGateway("HTTP API\n(AWS_IAM auth)")

        with Cluster("Read / query path", graph_attr={"fontsize": "16"}):
            stats = Lambda("Stats Lambda")
            glue = Glue("Glue Data Catalog\n(4 tables)")
            athena = Athena("Athena workgroup")

        with Cluster("Event ingestion", graph_attr={"fontsize": "16"}):
            src = Codepipeline("CodePipeline /\nCodeBuild\n(event producers)")
            eb = Eventbridge("EventBridge\n(4 rules)")
            fh = APIGateway("Firehose\n(pipeline/build)")
            enrich = Lambda("Enrichment\nLambda")
            dlq = SimpleQueueServiceSqs("DLQ")
            s3 = S3("S3 data lake\nraw + enriched")

        with Cluster("DevOps Agent chat", graph_attr={"fontsize": "16"}):
            ddb = Dynamodb("Chat state\n(24h TTL)")
            worker = Lambda("Chat Worker\nLambda")
            agent = AmazonQ("DevOps Agent\nAgentSpace")

        with Cluster("CloudWatch alarms (no notification target)", graph_attr={"fontsize": "16"}):
            alarm_stats = CloudwatchAlarm("stats-lambda-errors")
            alarm_enrich = CloudwatchAlarm("enrichment-lambda-errors")
            alarm_dlq = CloudwatchAlarm("enrichment-dlq-not-empty")

    with Cluster("Tracked accounts (N) / Organization", graph_attr={"fontsize": "18"}):
        reader = IAM("PipelineDashboardReader\n(read-only)")
        tracked = Codepipeline("CodePipeline /\nCodeBuild")
        reader >> Edge(style="dashed") >> tracked

    # Read path
    ui >> Edge(color="darkblue", label="SigV4 /api/*") >> api
    api >> Edge(color="darkblue", label="invoke") >> stats
    stats >> Edge(color="darkblue") >> athena >> Edge(color="darkblue") >> glue
    stats >> Edge(color="darkblue", style="dashed", label="sts:AssumeRole") >> reader

    # Ingestion path: producers emit -> EventBridge fans out to TWO consumers
    src >> Edge(color="darkgreen", label="state-change events") >> eb
    eb >> Edge(color="darkgreen", label="*-events-rule") >> fh >> Edge(color="darkgreen") >> s3
    eb >> Edge(color="darkgreen", label="*-enrichment-rule") >> enrich
    enrich >> Edge(color="darkgreen", label="enriched/") >> s3
    enrich >> Edge(color="firebrick", style="dashed", label="on failure") >> dlq
    s3 >> Edge(color="darkgreen") >> glue

    # Chat path
    stats >> Edge(color="purple", label="write / poll") >> ddb
    stats >> Edge(color="purple", label="async invoke") >> worker
    worker >> Edge(color="purple", label="CreateChat /\nSendMessage") >> agent
    worker >> Edge(color="purple", label="write answer") >> ddb

    # Monitoring: each alarm watches a metric of one resource. No AlarmActions
    # are configured, so alarms have no downstream target (console-only state).
    stats >> Edge(color="gray", style="dotted", label="Errors metric") >> alarm_stats
    enrich >> Edge(color="gray", style="dotted", label="Errors metric") >> alarm_enrich
    dlq >> Edge(color="gray", style="dotted", label="queue depth") >> alarm_dlq
