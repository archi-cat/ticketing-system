"""Architecture diagram generator. Run: python diagram.py"""
from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import AKS, ContainerRegistries
from diagrams.azure.database import DatabaseForPostgresqlServers
from diagrams.azure.integration import ServiceBus
from diagrams.azure.network import VirtualNetworks
from diagrams.azure.identity import EntraManagedIdentities
from diagrams.azure.monitor import ApplicationInsights, LogAnalyticsWorkspaces
from diagrams.onprem.client import Users
from diagrams.onprem.inmemory import Redis

graph_attr = {
    "fontsize": "14",
    "fontname": "Helvetica",
    "bgcolor":  "white",
    "pad":      "0.85",
    "splines":  "ortho",
}

with Diagram(
    "Ticketing System — Phase 1 (single region)",
    filename="architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    user = Users("Customer")

    with Cluster("Azure — uksouth"):
        with Cluster("AKS Cluster"):
            api       = AKS("API\nFastAPI")
            worker    = AKS("Worker\nasyncio consumer")
            scheduler = AKS("Scheduler\nAPScheduler")

        with Cluster("Data"):
            postgres = DatabaseForPostgresqlServers("PostgreSQL\nFlexible Server")
            redis    = Redis("Redis\nPremium P1")
            sb       = ServiceBus("Service Bus\nPremium")

        with Cluster("Identity"):
            uami = EntraManagedIdentities("Workload\nIdentity (UAMI)")

        with Cluster("Observability"):
            appi = ApplicationInsights("App Insights")
            logs = LogAnalyticsWorkspaces("Log Analytics")

    user >> Edge(label="HTTPS") >> api

    api >> Edge(color="darkgreen", style="dashed", label="auth") >> uami
    uami >> Edge(color="darkgreen", style="dashed") >> postgres

    api >> Edge(label="cache + locks")    >> redis
    api >> Edge(label="publish events")    >> sb

    sb     >> Edge(label="consume")        >> worker
    worker >> Edge(label="update state")   >> postgres

    scheduler >> Edge(label="leader lock") >> redis
    scheduler >> Edge(label="sweep expired") >> postgres

    api       >> Edge(color="orange", style="dashed") >> appi
    worker    >> Edge(color="orange", style="dashed") >> appi
    scheduler >> Edge(color="orange", style="dashed") >> appi
    appi      >> Edge(color="orange", style="dashed") >> logs