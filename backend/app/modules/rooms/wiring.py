"""Connecting rooms to the rest of the app (run by ``matches.wiring.install`` in every process).

- **Blocks:** blocking someone cancels pending invites between the two
  (``social.blocks.register_block_hook``); joins refuse anyone blocked by (or blocking) a
  member.
- **Bans and account deletion:** ``matches.withdraw`` takes the player out of their room (and
  its game), through the outbox.
- **Invites:** expiry and block cancellations are outbox topics (``rooms.invites``).
"""

from app.modules.rooms import invites
from app.modules.social.blocks import register_block_hook


def install() -> None:
    register_block_hook(invites.cancel_between)
