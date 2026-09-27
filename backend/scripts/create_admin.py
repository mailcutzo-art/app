"""Grant the admin role to an existing user.

    uv run python scripts/create_admin.py <email or handle>

The user must have signed in at least once. The grant is written to the audit log and applies
to their next request (their cached permissions are dropped).
"""

import argparse
import asyncio
import sys

from app.core.config import get_settings
from app.core.resources import open_resources
from app.modules.users import service
from app.modules.users.models import Role


async def create_admin(identifier: str) -> int:
    async with (
        open_resources(get_settings(), component="create-admin") as resources,
        resources.sessionmaker() as db,
    ):
        try:
            user = await service.find_user(db, identifier)
        except LookupError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        if user is None:
            print(
                f"error: no user matches {identifier!r}; they must sign in once first",
                file=sys.stderr,
            )
            return 1
        granted = await service.grant_role(db, resources.redis, user, Role.ADMIN)
        name = f"@{user.handle}" if user.handle else user.display_name
    print(f"{name} ({user.id}) {'is now an admin' if granted else 'was already an admin'}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Grant the admin role to an existing user.")
    parser.add_argument("user", help="email address or handle (with or without a leading @)")
    sys.exit(asyncio.run(create_admin(parser.parse_args().user)))
