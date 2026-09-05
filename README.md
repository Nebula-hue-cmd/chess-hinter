# chess_hint.lua

Chess move hinter, threat radar, analyzer and autoplay for "Just a baseplate" (Roblox),
built for the **Matcha Luau executor** (works on any executor with `loadstring` +
`HttpGet`/`request` via the universal loader below).

## What it does

On **your** turn, arrow #1/#2/#3 mark the top three fully-legal ranked moves
(green BEST, orange GOOD, cyan OK). On the opponent's turn a red arrow shows
their predicted move. A **pink** arrow is drawn for every one of your pieces an
enemy piece can capture (up to 5, king/high-value first; hanging pieces get a `!`),
with a blinking ring on the top threat. Check, checkmate and stalemate are detected.

A win bar at the bottom splits WHITE/BLACK win probability and shows the eval in
your own colour, plus a status panel in the corner.

The engine is a full-legal negamax with check-aware quiescence (QMAX 3),
aspiration-window iterative deepening, a transposition table, **null-move pruning**
(now in every mode) and a **history heuristic** for move ordering. Evaluation adds
piece-square tables, bishop pair / rook on the 7th / passed pawns, pawn structure and
rook open-file bonuses. In the **endgame** it switches to king-centralization tables,
searches two extra plies, and carries an **anti-stalemate filter**. **Max mode**
(toggle `O`/`]`) is a full-strength engine; press `N` to cycle intensity:
Normal (depth 10 / 8s) -> Hard (depth 12 / 14s) -> Extreme (depth 16 / 24s).
**Interior nodes are legally filtered**, so a suggested move can never hang your king.

Every search hard-stops at its time/node budget, so the hints never freeze.

## Controls

| Key | Action |
|-----|--------|
| `P` | show / hide overlay |
| `O` / `]` | cycle depth: Fast (4) <-> Deep (7) <-> **Max** |
| `N` | Max intensity: Normal (10/8s) <-> Hard (12/14s) <-> Extreme (16/24s) |
| `L` | autoplay ON/OFF |
| `K` | threat warnings ON/OFF |
| `M` | autoplay pace: relaxed <-> normal <-> turbo |

Autoplay plays after a human-like delay scaled by complexity, verifies the move
landed, retries once on a missed click, and **keeps playing** until you press `L`.
Move detection is board-square based (survives the game spawning fresh piece
models), so the turn flips and autoplay keeps re-arming indefinitely.

## Usage - universal loader (any executor)

`chess_hint.lua` in this repo is the **obfuscated self-extractor**. Load it with:

```lua
local u="https://raw.githubusercontent.com/Nebula-hue-cmd/chess-hinter/master/chess_hint.lua"
local b
if httpget then b=httpget(u)
elseif request then b=request({Url=u}).Body
elseif http_request then b=http_request({Url=u}).Body
else b=game:HttpGet(u,true) end
loadstring(b)()
```

Matcha users may also drop the raw file at `C:/matcha/workspace/chess_hint.lua` and run:

```lua
loadstring(readfile("chess_hint.lua"))()
```

Re-executing retires the previous instance (newest wins). The script self-heals on
rejoins and waits for the game's `GameStatus` UI before identifying your colour.

## Compatibility notes (Matcha VM)

- Drawings only for overlays - the VM has no `Instance.new` / GUI.
- `WorldToScreen` is only valid inside a `RenderStepped` callback.
- Drawing `.Color` is write-only: it is never read.
- The search yields periodically so hotkeys stay responsive.

## Files

- `chess_hint.lua` - obfuscated self-extractor (the plaintext v5.7 source stays local for editing).
- `README.md` - this file.

## License

MIT - see [LICENSE](LICENSE).