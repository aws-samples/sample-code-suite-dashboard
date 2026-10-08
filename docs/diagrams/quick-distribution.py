"""Generate the proposed distribution and customer-install architecture.

Run: python3 docs/diagrams/quick-distribution.py
Output: docs/diagrams/quick-distribution.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.analytics import Athena, Glue, Quicksight
from diagrams.aws.compute import Lambda
from diagrams.aws.devtools import Codebuild, Codepipeline
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import Cloudformation
from diagrams.aws.storage import S3
from diagrams.onprem.client import User
from diagrams.onprem.vcs import Github

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
    "Distributable Code Suite dashboard for Amazon Quick customers",
    filename="docs/diagrams/quick-distribution",
    show=False,
    direction="LR",
    graph_attr=GRAPH,
    node_attr=NODE,
    edge_attr=EDGE,
):
    with Cluster("Published project artifacts", graph_attr={"fontsize": "20"}):
        repo = Github("Public repository")
        installer = Cloudformation("CloudFormation\ninstaller")
        bundle = Quicksight("QuickSight\nasset bundle")
        app_recipe = User("Quick app\ncreation recipe")
        repo >> Edge(color="darkblue") >> [installer, bundle, app_recipe]

    with Cluster("Customer AWS account", graph_attr={"fontsize": "20"}):
        with Cluster("Installed AWS resources", graph_attr={"fontsize": "17"}):
            pipeline = Codepipeline("CodePipeline")
            build = Codebuild("CodeBuild")
            events = Eventbridge("EventBridge")
            enrich = Lambda("Enrichment Lambda")
            lake = S3("Customer data lake")
            catalog = Glue("Glue catalog")
            query = Athena("Athena")

        with Cluster("Customer Amazon Quick account", graph_attr={"fontsize": "17"}):
            dataset = Quicksight("Customer-specific\ndataset")
            dashboard = Quicksight("Imported QuickSight\ndashboard")
            app = Quicksight("App in Quick\n(created in customer account)")
            users = User("Customer users")

    installer >> Edge(color="darkblue", label="deploy") >> events
    bundle >> Edge(color="darkblue", label="import with\ncustomer overrides") >> dashboard
    app_recipe >> Edge(color="darkblue", style="dashed", label="create/configure") >> app

    [pipeline, build] >> Edge(color="darkgreen", label="state changes") >> events
    events >> Edge(color="darkgreen") >> enrich >> Edge(color="darkgreen") >> lake
    lake >> Edge(color="darkgreen") >> catalog >> Edge(color="darkgreen") >> query
    query >> Edge(color="darkblue", label="SPICE or\ndirect query") >> dataset
    dataset >> Edge(color="darkblue") >> dashboard
    dashboard >> Edge(color="darkblue", label="embed visuals") >> app
    users >> Edge(color="darkblue", label="account share") >> app
