Surviving Mars 1.5 (build 1011140) - crude P2P multiplayer
===========================================================

What it does
------------
Every player keeps playing their own colony on their own map. Each OTHER player
shows up in your game as a Space Race rival colony (Planetary View), with their
real funding, stock, colonist count and researched techs. Everything you can do
to an AI rival you can do to them, and it lands on their real colony:

  - Trade routes   : goods/funding you receive are taken from their colony;
                     what you ship arrives there on a cargo rocket.
  - Help rockets   : your cargo arrives at their colony.
  - Distress call  : they answer automatically according to their standing
                     with you, paid out of their real stock/funding.
  - Covert ops     : steal tech, steal drones, lure colonists, sabotage
                     (breaks a share of their buildings).
  - Tech exchange  : the tech you hand over is granted in their game.
  - Standing       : one shared value per pair of players.

There is no server. One player hosts, up to three others connect directly.

Requirements
------------
  - Surviving Mars 1.5, build 1011140, with the Space Race DLC, on every PC.
  - The host needs a reachable TCP port (default 27600): same LAN, a forwarded
    port, or a VPN such as Tailscale / ZeroTier / Hamachi.

Install / uninstall
-------------------
  Install  : copy multiplayer.hpk into   <game folder>\DLC\
  Uninstall: delete that file. Saves keep working; a former player's colony
             simply stays behind as an idle rival.

Playing
-------
  1. Start or load a game. A "Multiplayer" notification appears on screen;
     click it to open the menu.
  2. One player picks "Host a game". The others pick "Join" (address from the
     settings file) or "Join another address..." and type ip:port.
  3. Each connected player appears as a rival colony within a few seconds.
  4. A human rival never opens trade routes on their own: use
     Multiplayer menu -> "Offer a trade route". Pick the player, what you
     sell, what you want in return (funding or another resource) and a price
     (cheap / fair / expensive). The route then appears in their Planetary
     View, and each rocket they send along it trades at those terms.

Settings file:  %AppData%\Surviving Mars\multiplayer.cfg   (created on first run)
     name=YourName
     host=127.0.0.1
     port=27600
     id=...           (identifies you in other players' saves; do not share one
                       file between two players)

Limitations (by design - this is not a polished feature)
---------------------------------------------------------
  - Colonies are separate simulations. Game speed and pause are not linked;
    a player who is paused or offline is just a frozen rival.
  - No encryption and no cheat protection. Play only with people you trust.
  - A rival slot is one of the stock sponsors, so the dialogue portraits and
    flavour text are that sponsor's; only the colony name is the player's.
  - Milestone and anomaly races against human players are not implemented.
  - Trade is not checked against what the other player can afford: resources
    are taken up to what they have in depots, funding can go negative.
  - Changes made to a rival while that player is disconnected are dropped.

Rebuilding
----------
  python build_hpk.py      (packs .\src into multiplayer.hpk)

Troubleshooting
---------------
  Live log:  %AppData%\Surviving Mars\multiplayer-<YourName>-<host|client>.log
  The same lines (prefixed [MP]) also end up in %AppData%\Surviving Mars\logs\,
  but the game only writes that file when it exits.

Two games on one PC (testing)
-----------------------------
  Just start both, host in one and join 127.0.0.1 in the other. Both read the
  same multiplayer.cfg, so they share a name, and the joining game gets a
  throwaway id for that session (its rival colony in the host's save is not
  reused next time). For distinct names, start the first game, wait for its
  menu, change name= and id= in multiplayer.cfg, then start the second.

Notes for anyone changing the pack
----------------------------------
  - autorun.lua must declare required_lua_revision, or the game mounts the pack
    and then silently drops it.
  - Code\MpBoot.lua is the only file the game loads by itself; it loads the
    files in Mp\ one at a time and logs any that fail.
  - The game's Lua has no `math` library.
