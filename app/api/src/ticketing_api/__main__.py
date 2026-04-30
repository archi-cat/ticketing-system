"""Entry point — `python -m ticketing_api`.

Production runs uvicorn directly via the Dockerfile CMD. This module exists
mainly for local development convenience.
"""

import uvicorn

from ticketing_api.settings import get_settings


def main() -> None:
    settings = get_settings()
    uvicorn.run(
        "ticketing_api.main:app",
        host=settings.http_host,
        port=settings.http_port,
        log_config=None,  # we configure logging ourselves via structlog
        reload=settings.environment == "local",
    )


if __name__ == "__main__":
    main()