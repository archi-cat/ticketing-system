# 2. Use PostgreSQL Flexible Server (not Azure SQL)

Date: 2026-04-27
Status: Accepted

## Context

The application needs a relational database for transactional data (events, reservations, bookings). Azure offers two primary managed relational database options: Azure SQL Database and Azure Database for PostgreSQL Flexible Server.

## Decision drivers

- The database driver and ODBC complexity in container images
- Cost at the smallest viable production-pattern tier
- Compatibility with the broader Python ecosystem
- Long-term portability across cloud providers
- Cross-region replication support at the chosen tier

## Considered options

### Azure SQL Database (Standard S1)
- Mature service, deep Microsoft ecosystem integration
- Auto-failover groups available
- Requires Microsoft ODBC Driver 18 in container images
- Entra admin setup is complex (requires SQL admin + Entra group + Directory Readers role on the SQL server's identity)

### Azure Database for PostgreSQL Flexible Server (B1ms)
- Simpler driver model — `pip install psycopg2-binary` is sufficient
- Read replicas across regions supported in this tier
- Entra ID authentication is first-class without SQL admin workarounds
- Larger Python community ecosystem
- Portable to AWS RDS / GCP Cloud SQL / self-hosted Kubernetes

## Decision

We will use **Azure Database for PostgreSQL Flexible Server**, version 16, on the Burstable B1ms tier.

## Consequences

### Positive
- Significantly simpler container images (no ODBC driver install)
- Cleaner Entra ID auth — no Directory Readers manual step
- Cross-cloud portability if the project is later replicated to AWS/GCP
- Larger community of patterns and tools (Alembic, SQLAlchemy 2.0 async)

### Negative
- B1ms tier replication uses read replicas with manual failover, not auto-failover groups
- Some specialised SQL Server-specific tooling not applicable (acceptable — none is in scope here)
- Cross-region failover automation must be implemented manually (acceptable — this is part of the learning value)