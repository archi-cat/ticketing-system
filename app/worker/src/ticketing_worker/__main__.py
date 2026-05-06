"""Entry point — `python -m ticketing_worker`."""

import asyncio

from ticketing_worker.main import run


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()