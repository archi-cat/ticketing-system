"""Entry point — `python -m ticketing_scheduler`."""

import asyncio

from ticketing_scheduler.main import run


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
