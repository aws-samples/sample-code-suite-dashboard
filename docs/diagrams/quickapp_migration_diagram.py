"""Proposed migration architecture: dashboard -> Amazon Quick App.

Run: python3 docs/diagrams/quickapp_migration_diagram.py
Output: docs/diagrams/quickapp_migration_diagram.png

Shows the target state for hosting the dashboard as an app in Amazon Quick.
The sandboxed app cannot call API Gateway directly, so the read path is
served by a QuickSight dataset (backed by the existing S3 + Glue + Athena
data lake) and the chat path is served by an action connector (OpenAPI/MCP)
over the existing chat API.
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import Athena, Glue, Quicksight
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.devtools import Codepipeline
from diagrams.aws.integration import Eventbridge, SimpleQueueServiceSqs
from diagrams.aws.ml import Q as AmazonQ
from diagrams.aws.mobile import APIGateway
from diagrams.aws.storage import S3
from diagrams.onprem.client import User

graph_attr = {
    "fontsize": "26",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "ortho",
    "nodesep": "0.7",
    "ranksep": "1.2",
}
node_attr = {"fontsize": "16"}
edge_attr = {"penwidth": "2.5", "fontsize": "14"}

with Diagram(
    "Migration target: dashboard as an app in Amazon Quick",
    filename="docs/diagrams/quickapp_migration_diagram",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    user = User("End user\n(browser)")

    with Cluster("Amazon Quick (managed, sandboxed)", graph_attr={"fontsize": "20"}):
        app = AmazonQ("App in Quick\n(sandboxed iframe,\nno direct AWS/API access)")
        with Cluster("Allowed data bindings", graph_attr={"fontsize": "16"}):
            dataset = Quicksight("QuickSight dataset\n(read-only, SPICE)")
            connector = APIGateway("Action connector\n(OpenAPI / MCP)")
            space = S3("Quick space\n(shared storage /\nchat knowledge base)")

    with Cluster("Central AWS account (existing backend, mostly reused)", graph_attr={"fontsize": "20"}):
        with Cluster("Read / query path (feeds the dataset)", graph_attr={"fontsize": "16"}):
            s3 = S3("S3 data lake\nraw + enriched")
            glue = Glue("Glue Data Catalog\n(4 tables)")
            athena = Athena("Athena workgroup")

        with Cluster("Event ingestion (unchanged)", graph_attr={"fontsize": "16"}):
            src = Codepipeline("CodePipeline /\nCodeBuild")
            eb = Eventbridge("EventBridge\n(4 rules)")
            fh = APIGateway("Firehose")
            enrich = Lambda("Enrichment\nLambda")
            dlq = SimpleQueueServiceSqs("DLQ")

        with Cluster("Chat path (reused via connector)", graph_attr={"fontsize": "16"}):
            chat_api = APIGateway("Chat API\n(POST /chat,\nGET /chat/{id})")
            stats = Lambda("Stats/chat Lambda")
            ddb = Dynamodb("Chat state\n(24h TTL)")
            worker = Lambda("Chat Worker\nLambda")
            agent = AmazonQ("DevOps Agent\nAgentSpace")

    # Ingestion (unchanged)
    src >> Edge(color="darkgreen") >> eb
    eb >> Edge(color="darkgreen", label="*-events-rule") >> fh >> Edge(color="darkgreen") >> s3
    eb >> Edge(color="darkgreen", label="*-enrichment-rule") >> enrich
    enrich >> Edge(color="darkgreen", label="enriched/") >> s3
    enrich >> Edge(color="firebrick", style="dashed", label="on failure") >> dlq
    s3 >> Edge(color="darkgreen") >> glue >> Edge(color="darkgreen") >> athena

    # NEW read path: dataset built on Athena/Glue/S3, app reads dataset
    athena >> Edge(color="darkblue", label="SPICE ingest /\ndirect query") >> dataset
    user >> Edge(color="darkblue") >> app
    app >> Edge(color="darkblue", label="read visuals / rows") >> dataset

    # Chat path via connector (internal apps only)
    app >> Edge(color="purple", label="invoke (authorized)") >> connector
    connector >> Edge(color="purple") >> chat_api >> Edge(color="purple") >> stats
    stats >> Edge(color="purple", label="write / poll") >> ddb
    stats >> Edge(color="purple", label="async invoke") >> worker
    worker >> Edge(color="purple", label="CreateChat /\nSendMessage") >> agent
    worker >> Edge(color="purple", label="write answer") >> ddb

    # Space (optional shared layer)
    app >> Edge(color="gray", style="dashed", label="files / chat KB") >> space
