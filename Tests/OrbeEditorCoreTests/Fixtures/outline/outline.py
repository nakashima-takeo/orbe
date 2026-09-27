"""Task queue with retry support."""

import asyncio
from dataclasses import dataclass, field

MAX_RETRIES = 3
default_timeout: float = 1.5
_registry = {}
host, port = "localhost", 8080

type JobId = int


@dataclass
class Job:
    """A unit of work."""

    name: str
    retries: int = 0
    tags: list[str] = field(default_factory=list)

    def __post_init__(self):
        self.created = asyncio.get_event_loop().time()

    @property
    def is_exhausted(self) -> bool:
        return self.retries >= MAX_RETRIES

    @is_exhausted.setter
    def is_exhausted(self, value: bool) -> None:
        self.retries = MAX_RETRIES if value else 0

    class Status:
        PENDING = "pending"
        DONE = "done"


class Queue:
    def __init__(self, *jobs: Job, limit=10, **options):
        self._jobs = list(jobs)
        self.limit = limit

    async def run(self, worker):
        results = []
        for job in self._jobs:
            outcome = await worker(job)
            results.append(outcome)
        results = sorted(results)

        def summarize(items):
            total = len(items)
            return total

        return summarize(results)

    @staticmethod
    def empty(cls=None):
        return Queue()


def register(name, job):
    _registry[name] = job
    return lambda: _registry.pop(name)


async def main():
    queue = Queue(Job("build"), Job("test"))
    await queue.run(lambda job: asyncio.sleep(0))


if __name__ == "__main__":
    asyncio.run(main())
