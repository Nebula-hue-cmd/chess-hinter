# chess_hint.lua

Chess move hinter, threat radar, analyzer and autoplay for "Just a baseplate" (Roblox),
built for the **Matcha Luau executor**.

## What it does

On **your** turn, arrow #1/#2/#3 mark the top three fully-legal ranked moves
(green BEST, orange GOOD, cyan OK). On the opponent's turn a red arrow shows
their predicted move. A **pink** arrow is drawn for every one of your pieces an
enemy piece can capture (up to 5, king/high-value first; hanging pieces get a `!`),
with a blinking ring on the top threat. Pink looks nothing like the move arrows, so
it reads as a danger radar, not a move suggestion. Check, checkmate and stalemate
are detected.

A win bar at the bottom splits WHITE/BLACK win probability and shows the eval in
your own colour (green when you're winning, red when losing), plus a status panel
in the corner.

The engine is a full-legal negamax with check-aware quiescence (QMAX 3), killer-move
ordering and aspiration-window iterative deepening - so it reaches much deeper in the
same budget. Deep mode adds a **transposition table** (reusing prior search results)
and **null-move pruning**, letting it see far beyond its nominal depth. Evaluation adds
material + piece-square tables, bishop pair / rook on the 7th / passed pawns, plus
pawn structure (doubled, isolated, chains) and rook open/semi-open file bonuses. In
the **endgame it switches to a king-centralization table** and searches two extra
plies, and carries an **anti-stalemate filter**. **Max mode** (toggle with `O`/`]`) is a
full-strength engine that autoplay also plays at maximum strength. Once you're in Max,
press `N` to cycle the **intensity**: Normal (depth 10 / 8s) -> Hard (depth 12 / 14s)
-> Extreme (depth 16 / 24s). **Interior nodes are legally filtered**, so a suggested
move can never hang your king.

## Controls

| Key | Action |
|-----|--------|
| `P` | show / hide overlay |
| `O` / `]` | cycle depth: Fast (3) <-> Deep (6) <-> **Max** |
| `N` | Max intensity: Normal (10/8s) <-> Hard (12/14s) <-> Extreme (16/24s) |
| `L` | autoplay ON/OFF |
| `K` | threat warnings ON/OFF |
| `M` | autoplay pace: relaxed <-> normal <-> turbo |

Autoplay plays the best move after a human-like delay that scales with complexity,
verifies the board changed afterwards and retries a failed click once - then it
skips that position but **stays on**, so it keeps playing until you press `L`.
Destination clicks aim at the middle of the target tile (not above it), so the
cursor can't drift onto a neighbouring tile.

## Usage

```lua
loadstring(readfile("chess_hint.lua"))()
```

or paste the file into the Matcha console. Re-executing retires the previous
instance (newest wins). It self-heals on rejoins and waits for the game's
`GameStatus` UI before identifying your colour - it never runs blind.

## Compatibility notes (Matcha VM)

- Drawings only for overlays - the VM has no `Instance.new` / GUI.
- `WorldToScreen` is only valid inside a `RenderStepped` callback.
- Drawing `.Color` is write-only: it is never read.
- The search yields periodically so hotkeys stay responsive even at depth 6.

## Files

- `chess_hint.lua` - the whole script (self-contained, ~1900 lines).

## License

MIT - see [LICENSE](LICENSE).