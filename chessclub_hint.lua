-- Chess Club Move Hinter v1 for "Chess Club" (Roblox)
-- Built for the Matcha LuaVM. Reads the 2D board UI (PlayerGui.2DBoard):
-- piece buttons carry colour+type in their names (White_Pawn..Black_King),
-- square buttons carry algebraic names (a8..h1) + screen positions.
-- There is NOTHING to infer: no orientation, no colour guessing, no memory
-- files. Mid-game attach works instantly with a full exact map.
--
-- Overlays (Drawing, screen pixels - no camera math):
--   * Up to 3 ranked FULLY-LEGAL moves for the side to move, labelled
--     "W: e2e4 +0.3" / "B: ..." (green #1 BEST / amber #2 / sky #3).
--   * Panel: engine, depth, clocks, side to move, eval, status.
--
-- Controls (keys, polled):
--   P  show/hide overlay     O  cycle depth: fast <-> deep <-> max
--   X  engine: CarbonX <-> Sunfish   G  best-move-only
--   C  my colour: unknown -> White -> Black (YOUR TURN indicator only)
--
-- Usage: loadstring(game:HttpGet("<raw url>"))()  (or paste the file).
-- Re-executing retires the previous instance (newest wins).
--
-- v1 notes / honest limits:
--   * Turn = the side whose clock ticks (Value labels polled).
--   * "You" perspective: usernames only say who sits where, not colours;
--     press C to declare your colour for the turn indicator + eval sign.
--     Arrows always serve the side to move and say so in the label.

_G.__CCHESS_GEN = (_G.__CCHESS_GEN or 0) + 1
local MY_GEN = _G.__CCHESS_GEN
local running = true
local VISIBLE = true

-- Services resolve lazily: the instance index can still be building at
-- injection and game:GetService() may return nil. Every loop retries, so the
-- script boots inert and comes alive when the game is reachable.
local Players = nil
local lp = nil
local function ensureServices()
    if Players == nil then
        local okP, p = pcall(function() return game:GetService("Players") end)
        if okP and p then Players = p end
    end
    if Players ~= nil and lp == nil then
        local okL, l = pcall(function() return Players.LocalPlayer end)
        if okL and l then lp = l end
    end
    return lp ~= nil
end

-- Windows VK codes for the hotkeys
local VK = { P = 80, O = 79, X = 88, G = 71, C = 67 }

-- ---- settings -----------------------------------------------------------
local depthMode = "fast"          -- "fast" | "deep" | "max"
local engineName = "carbonx"      -- "carbonx" | "sunfish"
local onlyBest = false
local myColor = nil               -- nil | true (White) | false (Black); C key

local MODES = {
    fast = { myDepth = 5, oppDepth = 5, budget = 0.6 },
    deep = { myDepth = 8, oppDepth = 8, budget = 1.6 },
    max  = { myDepth = 10, oppDepth = 8, budget = 6.0 },
}
local MODE_ORDER = { "fast", "deep", "max" }
local ENGINE_ORDER = { "carbonx", "sunfish" }

local function effMode()
    return MODES[depthMode] or MODES.fast
end

local MAX_ARROWS = 3

-- ==== local lastYieldT ====
local lastYieldT = 0
local nodeCnt = 0
-- Hard time/node bounds for a single search. The old code only checked the
-- budget BETWEEN root moves / depths; a single deep negamax (Max mode,
-- endgame +2) could run for effectively forever, freezing the arrow updates.
-- These are checked from inside the tree (searchYield + negamax/quiesce re-entry)
-- so a search always unwinds within ~the budget.
local searchDeadline = 0
local searchBaseNodes = 0
local timeAborted = false
local searchNodeCap = 0
local function beginSearch(budget)
    searchDeadline = tick() + budget
    searchBaseNodes = nodeCnt
    searchNodeCap = math.max(300000, math.floor(budget * 320000))
    timeAborted = false
end

local function searchOver()
    if timeAborted then return true end
    if nodeCnt - searchBaseNodes >= searchNodeCap then timeAborted = true; return true end
    if tick() >= searchDeadline then timeAborted = true; return true end
    return false
end

local function searchYield()
    nodeCnt = nodeCnt + 1
    if searchOver() then return end
    if nodeCnt % 1200 == 0 then
        local n = tick()
        if n - lastYieldT > 0.05 then
            task.wait()
            lastYieldT = tick()
        end
    end
end

-- ---- static chess data --------------------------------------------------
-- ==== local PIECE_VAL ====
local PIECE_VAL = { P=100, N=320, B=330, R=500, Q=900, K=20000 }
local FILES = {"a","b","c","d","e","f","g","h"}
local ORIGIN_X = 1004
local ORIGIN_Z = 4
local SPACING = 4
-- v5.14 multi-user hardening: the board geometry is DERIVED from the Board
-- folder's own square parts (named "1,1".."8,8") instead of being hardcoded,
-- so the script still works if the developer moves the board, re-skins it or
-- ships another map. The constants above stay as a fallback until a valid 8x8
-- set has been found. Detection is retried every few seconds in case the
-- workspace Board folder mounts slightly after the player joins.
local geomReady = false
local geomWarned = false
local lastGeomTry = 0
local function detectBoardGeometry()
    local boardFolder = workspace and workspace:FindFirstChild("Board")
    if not boardFolder then
        if not geomWarned then
            geomWarned = true
            print("[Chess Hinter] No Board folder mounted yet - using default board geometry.")
        end
        return false
    end
    geomWarned = false
    -- A square is either a direct Part named "f,r" OR a Model named "f,r"
    -- whose mesh/part sits one level down (both layouts exist in this game),
    -- so read the first Part-ish position reachable from the named node.
    local function partPos(node)
        local p = node.Position
        if p then return p end
        for _, c in ipairs(node:GetChildren()) do
            if c.ClassName == "Part" or c.ClassName == "MeshPart" then
                local cp = c.Position
                if cp then return cp end
            end
        end
        return nil
    end
    local byName = {}
    for _, sq in ipairs(boardFolder:GetChildren()) do
        byName[sq.Name] = partPos(sq)
    end
    local a1 = byName["1,1"]
    if not a1 then return false end
    local sp = 0
    local b2 = byName["2,1"]
    local c1 = byName["1,2"]
    if b2 then sp = (b2 - a1).Magnitude end
    if (sp <= 0 or sp > 12) and c1 then sp = (c1 - a1).Magnitude end
    if sp <= 0 or sp > 12 then return false end
    local h8 = byName["8,8"]
    if not h8 then return false end
    -- the far corner must sit ~7 squares away on BOTH axes (an axis-aligned
    -- 8x8 grid with this spacing) - this also rejects rotated/misnamed sets so
    -- the mapping formulas below (which assume file-along-X, rank-along-Z)
    -- stay valid.
    local dx = math.abs(h8.X - a1.X)
    local dz = math.abs(h8.Z - a1.Z)
    if math.abs(dx - 7 * sp) > sp * 0.6 or math.abs(dz - 7 * sp) > sp * 0.6 then
        return false
    end
    ORIGIN_X = a1.X
    ORIGIN_Z = a1.Z
    SPACING = sp
    return true
end
-- ==== local KNIGHT_OFF ====
local KNIGHT_OFF = {{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}
local KING_OFF = {{-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1}}
local DIAG = {{-1,-1},{-1,1},{1,-1},{1,1}}
local ORTHO = {{-1,0},{1,0},{0,-1},{0,1}}

-- Piece-square tables (White's perspective; flipped for black)
-- ==== local PST = { ====
local PST = {
    P = {  0,0,0,0,0,0,0,0, 5,10,10,-20,-20,10,10,5, 5,-5,-10,0,0,-10,-5,5, 0,0,0,20,20,0,0,0, 5,5,10,25,25,10,5,5, 10,10,20,30,30,20,10,10, 50,50,50,50,50,50,50,50, 0,0,0,0,0,0,0,0 },
    N = {-50,-40,-30,-30,-30,-30,-40,-50, -40,-20,0,5,5,0,-20,-40, -30,5,10,15,15,10,5,-30, -30,0,15,20,20,15,0,-30, -30,5,15,20,20,15,5,-30, -30,0,10,15,15,10,0,-30, -40,-20,0,0,0,0,-20,-40, -50,-40,-30,-30,-30,-30,-40,-50 },
    B = {-20,-10,-10,-10,-10,-10,-10,-20, -10,5,0,0,0,0,5,-10, -10,10,10,10,10,10,10,-10, -10,0,10,10,10,10,0,-10, -10,5,5,10,10,5,5,-10, -10,0,10,10,10,10,0,-10, -10,0,5,0,0,5,0,-10, -20,-10,-10,-10,-10,-10,-10,-20 },
    R = {  0,0,0,5,5,0,0,0, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, 5,10,10,10,10,10,10,5, 0,0,0,0,0,0,0,0 },
    Q = {-20,-10,-10,-5,-5,-10,-10,-20, -10,0,5,0,0,0,0,-10, -10,5,5,5,5,5,0,-10, 0,0,5,5,5,5,0,-5, -5,0,5,5,5,5,0,-5, -10,0,5,5,5,5,0,-10, -10,0,0,0,0,0,0,-10, -20,-10,-10,-5,-5,-10,-10,-20 },
    K = { 20,30,10,0,0,10,30,20, 20,20,0,0,0,0,20,20, -10,-20,-20,-20,-20,-20,-20,-10, -20,-30,-30,-40,-40,-30,-30,-20, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30 },
}

-- Endgame king PST: the middlegame K table above keeps the king in its box,
-- which is exactly wrong for conversion. In the endgame the king wants the
-- centre (escorting pawns, driving the mate). Row layout matches PST (index
-- (rank-1)*8+file from White's side, mirrored for Black).
local KING_END = {
    -50,-40,-30,-20,-20,-30,-40,-50,
    -30,-20,-10,  0,  0,-10,-20,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 30, 40, 40, 30,-10,-30,
    -30,-10, 20, 30, 30, 20,-10,-30,
    -30,-30,  0,  0,  0,  0,-30,-30,
    -50,-30,-30,-30,-30,-30,-30,-50,
}

-- NOTE: there is intentionally NO piece-Address -> colour cache. Colour is
-- re-derived from the current z on every scan (see scanPieces / boardFromList).
-- A cache is unsafe here: this game spawns fresh models on every move and can
-- recycle Address slots, so a stale entry could mark one of OUR pieces as the
-- enemy's - and the engine would happily draw a "capture" arrow onto our own
-- piece. Re-deriving self-heals any transient mid-animation frame within a
-- scan or two instead of poisoning the rest of the game.
-- Opening-variety cache: boardHash -> chosen root move index
local positionCache = {}

local myWhite = nil
-- The GameStatus labels briefly swap sides during transitions / new pairings,
-- so a single reading can give a wrong colour. Only adopt a reading after it
-- has been stable across several consecutive scans (the loop calls this ~2/s).
local colorCandidate = nil
local colorCount = 0
-- Did the current candidate come from the NAME tiers (only those are
-- orientation-independent and can calibrate the White<->Z relation)?
local colorCandidateByLabel = false
-- True while the GameStatus labels show no active pairing ("Waiting for
-- players", empty frames). Used to distinguish a lobby wait from a genuine
-- stuck state on the panel.
local waitingForMatch = true

-- The labels are "<name>'s turn" (account names) but the arena also emits a
-- display-name form WITHOUT the trailing s: "Display Name' turn" (one
-- apostrophe, space, "turn") - e.g. "Cultist of Solaris' turn". Matcha cannot
-- read DisplayName, so account names only match players whose display name
-- equals theirs. Handle the surplus cases below (see detectColor) - and never
-- require the 's, or a display-name opponent parses to nil, the lobby guard
-- reads "not a real pairing", and colour detection stalls at round start.
local function parseLabelName(label)
    if not label then return nil end
    -- In a live match the label carries a clock suffix: "Name's turn (09:28)".
    -- Stop at the FIRST "'s turn" / "' turn" and ignore whatever follows it.
    local name = label:match("^%s*(.-)[']s? turn")
    if name then
        name = name:gsub("%s+$", "")
        if name ~= "" then return name end
    end
    return nil
end

-- Quick lobby-vs-match test used only for the panel status text.
local function matchReadyFromLabels()
    local gs = lp.PlayerGui and lp.PlayerGui:FindFirstChild("GameStatus")
    if not gs then return false end
    local w = gs:FindFirstChild("White")
    local b = gs:FindFirstChild("Black")
    local wi = w and w:FindFirstChild("Info")
    local bi = b and b:FindFirstChild("Info")
    if wi and bi and wi.Text and bi.Text ~= "" then
        return wi.Text:match("turn") ~= nil or bi.Text:match("turn") ~= nil
    end
    return false
end

-- Signal 3: physical seat. In this level White ALWAYS sits the row-1 (small Z)
-- half; that is exactly the rule boardFromList uses to colour every piece.
-- Only conclude when the character is actually near the board (else the lobby
-- could fool it). Board centre = (ORIGIN_X+3.5*SPACING, 0, ORIGIN_Z+3.5*SPACING).
local function colorFromSeat()
    local char = lp.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local p = root and root.Position
    if not p then return nil end
    local cx = ORIGIN_X + 3.5 * SPACING
    local cz = ORIGIN_Z + 3.5 * SPACING
    if (p - Vector3.new(cx, 0, cz)).Magnitude <= 42 then
        return p.Z < cz
    end
    return nil
end

local colorStuckReported = false

-- Names that are arena/AI placeholders rather than human accounts. NOTE:
-- "Noob" is also the game's AI opponent (BuffNoob/EasyNoob models), so a pair
-- containing it must NOT be auto-rejected - the user-vs-AI match is a real
-- match. The guard only refuses a pairing where BOTH sides are placeholder
-- names (or the frames are empty/identical), which is the true lobby
-- screensaver. Any residual misread still self-corrects through the seat
-- fallback, the label-vs-seat pin, the first-move pin and the king gate.
local PLACEHOLDER_NAMES = { Noob = true, Spectator = true, Observer = true, Viewer = true, Bot = true }

-- Resolve the side WITHOUT the debounce. forceSeat (used only at a confirmed
-- round start) also trusts the seat even when GameStatus was just cleared,
-- so a new round can adopt its real colour immediately instead of showing
-- the previous round's value for ~2s while the debounce re-settles.
local function resolveColorNow(forceSeat)
    local gs = lp.PlayerGui and lp.PlayerGui:FindFirstChild("GameStatus")
    local wName, bName
    if gs then
        local wFrame = gs:FindFirstChild("White")
        local bFrame = gs:FindFirstChild("Black")
        local wInfo = wFrame and wFrame:FindFirstChild("Info")
        local bInfo = bFrame and bFrame:FindFirstChild("Info")
        wName = parseLabelName(wInfo and wInfo.Text or "")
        bName = parseLabelName(bInfo and bInfo.Text or "")
        -- 1) our account name on a frame => definitive, opponent irrelevant.
        --    MUST run before any placeholder guard: "Noob" is the game's AI
        --    opponent (BuffNoob/EasyNoob), so a real user-vs-AI match shows
        --    W='<player>' B='Noob's turn' - rejecting the pair as a "lobby
        --    placeholder" froze colour detection for everyone facing the AI.
        if wName == lp.Name then return true, true end
        if bName == lp.Name then return false, true end
        -- 2) the opponent's account name pins the OTHER frame
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp then
                if wName ~= nil and wName == p.Name then return false, true end
                if bName ~= nil and bName == p.Name then return true, true end
            end
        end
        -- 3) only reject pairings that cannot be the local player's match:
        --    an empty frame, both sides the same name, or a pair where BOTH
        --    sides are arena/AI placeholder names. A pairing with exactly one
        --    placeholder side (e.g. user-with-display-name vs the AI, or an
        --    observer screen we cannot name) falls through to the physical
        --    seat, which is correct whenever the player is near the board.
        local wP = PLACEHOLDER_NAMES[wName or ""]
        local bP = PLACEHOLDER_NAMES[bName or ""]
        if wName == nil or bName == nil or wName == bName or (wP and bP) then
            -- v5.31d: labels too ambiguous to conclude (one side unparseable,
            -- e.g. a display-name opponent, or a bot label showing "text") -
            -- fall back to the PHYSICAL SEAT right here, not just after a full
            -- 32-piece board. colorFromSeat() is lobby-safe: it returns nil
            -- unless the character is actually sitting near the board centre,
            -- and the caller's 3-stable de-bounce absorbs a transient misread.
            -- (forceSeat is kept so round-start/king-gate paths still work.)
            return colorFromSeat(), false
        end
        -- 4) a real pairing visible but no account name matched -> the seat
        return colorFromSeat(), false
    end
    if forceSeat then return colorFromSeat(), false end
    return nil, false
end

-- Which end is White? Pinned by calibrateOrientation (worldNormal); until a
-- signal pins it, the z-rule assumes "White sits small-Z" like the seat does.
-- (v5.11 removed the meshSplit brightness experiment: this game paints every
-- piece the same colour, so model brightness carries no team signal and the
-- locked threshold mislabelled BOTH armies as White.)
local worldNormal = nil
-- v5.22 provenance: WHO pinned the orientation. "seat" is the weakest signal
-- (a seat reading can be inverted if the game doesn't seat the player on their
-- own half) and must yield to a LABEL pin or the FIRST-MOVE pin. Previously the
-- first pin won forever, so a seat pin adopted a second early could keep the
-- whole army wrong after labels arrived - the enemy-arrow bug.
local worldNormalSrc = nil

-- The label tiers above are orientation-independent (they state who is White by
-- NAME). The seat is a pure world-Z reading. Comparing them once the labels
-- adopt a colour pins the ACTUAL sign of the White<->Z relation in this match,
-- so the z-rule stops assuming every match is oriented like the author's.
-- v5.22: byLabel pins may REPLACE a weaker existing seat pin (never the other
-- way round); the first-move pin (strongest) is applied in noteBoard.
local function calibrateOrientation(byLabel)
    if myWhite == nil then return end
    local sw = colorFromSeat()
    if sw == nil then return end
    if not byLabel and worldNormal ~= nil and worldNormalSrc ~= "seat" then return end
    local nextV = (myWhite == sw)
    local nextSrc = byLabel and "label" or "seat"
    if worldNormal ~= nextV then
        worldNormal = nextV
        worldNormalSrc = nextSrc
        print("[Chess Hinter] Board orientation pinned by " .. tostring(nextSrc)
              .. ": White sits "
              .. (nextV and "small-Z (normal)" or "LARGE-Z (inverted)") .. ".")
    else
        worldNormalSrc = nextSrc
    end
end

local function detectColor(forceSeat)
    local gs = lp.PlayerGui and lp.PlayerGui:FindFirstChild("GameStatus")
    waitingForMatch = not matchReadyFromLabels()
    if not gs then colorCount = 0; return end
    local reading, byLabel = resolveColorNow(forceSeat or false)
    if reading == nil then
        -- ambiguous / mid-transition: don't trust it, reset the streak
        local wInfo = gs:FindFirstChild("White") and gs.White:FindFirstChild("Info")
        local bInfo = gs:FindFirstChild("Black") and gs.Black:FindFirstChild("Info")
        if not colorStuckReported and (wInfo or bInfo) then
            colorStuckReported = true
            print("[Chess Hinter] No name matched the GameStatus labels: W='"
                  .. tostring(wInfo and wInfo.Text)
                  .. "' B='"
                  .. tostring(bInfo and bInfo.Text)
                  .. "'; seat says "
                  .. tostring(colorFromSeat())
                  .. ".")
        end
        colorCount = 0
        return
    end
    colorStuckReported = false
    if reading == colorCandidate then
        colorCount = colorCount + 1
    else
        colorCandidate = reading
        colorCandidateByLabel = byLabel
        colorCount = 1
    end
    if colorCount >= 3 then
        myWhite = colorCandidate
        calibrateOrientation(colorCandidateByLabel)
    end
end

-- Turn detection is BOARD-based. (The GameStatus Info labels are static
-- "<name>'s turn" on BOTH sides, so reading them ALWAYS says "my turn" and the
-- whole opponent-prediction branch never ran.) Whites always move first; after
-- any move the side to move is exactly the opposite of who just moved.
local function isBoardTurnMine()
    local lw = lastMove and lastMove.white
    return (lw == nil and myWhite == true) or lw ~= myWhite
end

-- Best-effort PART for a piece model (white has direct Mesh, black pieces
-- usually live under Meshes/). Used for both position and team colour.
local function piecePart(piece)
    local mesh = piece:FindFirstChild("Mesh")
    if mesh then
        local cls = mesh.ClassName
        if cls == "MeshPart" or cls == "Part" then return mesh end
        local par = mesh.Parent
        if par and par ~= piece and (par.ClassName == "MeshPart" or par.ClassName == "Part") then
            return par
        end
    end
    local stack = {}
    for _, c in ipairs(piece:GetChildren()) do stack[#stack + 1] = c end
    while #stack > 0 do
        local node = table.remove(stack)
        if node.ClassName == "MeshPart" or node.ClassName == "Part" then return node end
        for _, c in ipairs(node:GetChildren()) do stack[#stack + 1] = c end
    end
    return nil
end

local function piecePos(piece)
    local part = piecePart(piece)
    return part and part.Position
end

-- ---- which end is White? ------------------------------------------------
-- ColorFromSeat and the naive z-rule assume White ALWAYS sits small-Z. That is
-- true in the author's matches but NOT universally: if the match seated White
-- at the other end, every colour computed from z is inverted and the engine
-- "plays for the enemy" - exactly what testers reported. One self-calibrating
-- source replaces the blind assumption:
--   worldNormal - the GameStatus labels are orientation-independent (they state
--     who is White by name), so the first time we adopt a label-derived myWhite
--     we compare it to the physical seat and PIN the true relation between
--     world-Z and White. The z-rule then uses that pinned orientation.
-- v5.10 also tried reading the piece MODELS' brightness to tell the armies
-- apart without the pin. v5.11 removed it: this game paints every piece the
-- same colour (all parts read (240,118,4)), so brightness carries no team
-- signal and the locked split classified BOTH armies as White - the exact
-- "arrows point at my own pieces" bug. Colour now comes from the labels, the
-- orientation pin, and the seat only.
-- The old behaviour is kept whenever the pins are absent, so legitimately
-- normal matches are byte-for-byte unchanged.
local function pieceIsWhite(z)
    local zSmall = z < (ORIGIN_Z + 3.5 * SPACING)
    if worldNormal ~= nil then return zSmall == worldNormal end
    return zSmall
end

-- v5.25 ARMY MAP (replaces the v5.16 IDENT Address-keyed cache): colour
-- comes from a board's per-square colours, and a square-diff carries it
-- through each move (verified live: scans with no move keep every model
-- Address stable, so square -> colour is a sound identity proxy). The old
-- cache keyed colour by model Address, but this game rebuilds moved models
-- with fresh Addresses and recycles the pool - a recycled slot then wore the
-- LAST owner's colour, painting the ENEMY's fresh models as "mine" (arrows
-- on enemy pieces, enemy moves suggested, inverted bar).
local function isStandardStart(list)
    if not list or #list ~= 32 then return false end
    local seen = {}
    local backCount, pawnCount = 0, 0
    local types = {}
    for _, e in ipairs(list) do
        local key = e.file .. "," .. e.rank
        if seen[key] then return false end
        seen[key] = true
        if e.rank == 1 or e.rank == 8 then
            backCount = backCount + 1
            if e.letter ~= "R" and e.letter ~= "N" and e.letter ~= "B"
               and e.letter ~= "Q" and e.letter ~= "K" then return false end
            types[e.letter] = (types[e.letter] or 0) + 1
        elseif e.rank == 2 or e.rank == 7 then
            pawnCount = pawnCount + 1
            if e.letter ~= "P" then return false end
        else
            return false
        end
    end
    if backCount ~= 16 or pawnCount ~= 16 then return false end
    return types.K == 2 and types.Q == 2
       and (types.R or 0) == 4 and (types.N or 0) == 4 and (types.B or 0) == 4
end

-- v5.26 commit-guard state. bad counts refused/oscillating diffs so a
-- mis-reading scan can never permanently poison the army map; prev/prevPrev
-- track the last ACCEPTED changes so an A,B,A,B scan artifact is refused too.
-- v5.32 promotion watch: the game materialises a promotion in TWO scans (the
-- pawn vanishes, the new piece spawns a scan later). promo remembers the
-- vanished pawn's colour across the gap so the birth is painted correctly.
-- v5.33 phase tracker: chess law says moves strictly alternate colours.
-- phase = the white-flag of the side that made the LAST accepted move
-- (nil = unknown); pmap = square-key -> white for phase-proven squares, which
-- paintArmy applies over inheritance (law-backed, newer). Phase pins from the
-- game-start first move, any pawn move's rank direction + orientation, or a
-- watched promotion birth; contradictions and multi-frames clear it to unknown
-- (never flip it). This is what lets a mid-game attach heal forward - colours
-- travel with MOVES here, never with positions, so a crossed piece can never
-- be re-guessed into the wrong army.
-- ONE table = ONE chunk register: the module lives at the 200-register
-- ceiling, so all of this shares a table.
local commitGuard = { bad = 0, prev = nil, prevPrev = nil, promo = nil,
                      phase = nil, pmap = {}, ustreak = 0 }
-- Raw squares+letters of the last stable scan (no colours needed). When there
-- is no committed board at all, noteBoard still diffs shapes against this so
-- the phase tracker can pin and paint from ANY state, not just an anchored one.
local prevRawList = nil

-- paintArmy(list, base): paint `list` from a previously-committed `base`
-- (nil = round-start bootstrap, where both armies sit at home and the z-half
-- rule is exact). Pure and exported so the VM battery can unit-test every
-- move class below without the live game.
-- (isStandardStart + commitGuard live ABOVE here: paintArmy references both,
-- and chunk-level forward references would silently bind globals.)
local function paintArmy(list, base)
    if not base then
        -- v5.33: the z-half rule is EXACT on one shape only - the full
        -- 32-piece standard start - and a confident lie everywhere else
        -- (every crossed piece miscolours into the wrong army). So it paints
        -- standard starts and NOTHING else: a mid-game board with no trusted
        -- base keeps every white == nil (honest unknown) until the phase
        -- tracker or a trusted memory restore colours it square by square.
        -- The v5.31g vetoes are gone with the guess itself - a "believable"
        -- wrong map was the reported bug.
        if isStandardStart(list) then
            for _, e in ipairs(list) do e.white = pieceIsWhite(e.z) end
        end
    else
    local baseBySq = {}
    for _, e in ipairs(base) do baseBySq[e.rank .. "," .. e.file] = e end
    -- squares occupied in both snapshots where the SAME model letter still
    -- sits there keep their committed colour (a piece only changes a square
    -- by travelling to it; a re-render is same square). A DIFFERENT letter on
    -- a square is a capture: the arriving piece is the MOVER and must never
    -- inherit the victim's colour - it stays nil so the gone-colour logic
    -- below colours it with the mover's own army (the victim-square inherit
    -- was flipping capturers into their victim's army on every cross-type
    -- capture, the "take MY horse" corruption).
    for _, e in ipairs(list) do
        local be = baseBySq[e.rank .. "," .. e.file]
        if be and be.letter == e.letter then e.white = be.white end
    end
    -- gone = squares held last commit, empty now = the mover's origin(s);
    -- every emptied square must belong to one army (else it is a rare
    -- multi-owner frame, e.g. en passant, and we leave committed colours).
    local have = {}
    for _, e in ipairs(list) do have[e.rank .. "," .. e.file] = true end
    local goneCol = nil
    for _, e in ipairs(base) do
        if not have[e.rank .. "," .. e.file] then
            if goneCol == nil then goneCol = e.white
            elseif e.white ~= goneCol then goneCol = nil break end
        end
    end
    if goneCol ~= nil then
        -- quiet/castling/promotion: squares that gained a piece with no
        -- committed colour are the move's destination(s) - the mover lands
        -- there. painted == 0 means a CAPTURE: the dest kept the victim's
        -- committed colour, so find the square the capturer re-typed.
        local painted = 0
        for _, e in ipairs(list) do
            if e.white == nil then
                -- v5.33: never wash a back-rank major while a promotion may
                -- be landing (armed watch) - the birth logic owns those
                -- squares; a wash here is how a quiet move elsewhere stole a
                -- newborn piece into the wrong army.
                local promoLook = (e.rank == 8 or e.rank == 1)
                    and (e.letter == "Q" or e.letter == "R"
                         or e.letter == "B" or e.letter == "N")
                if not (promoLook and commitGuard.promo ~= nil) then
                    e.white = goneCol
                    painted = painted + 1
                end
            end
        end
        if painted == 0 then
            local repainted = 0
            for _, e in ipairs(list) do
                for _, be in ipairs(base) do
                    if be.rank == e.rank and be.file == e.file and be.letter ~= e.letter then
                        local promoLook = (e.rank == 8 or e.rank == 1)
                            and (e.letter == "Q" or e.letter == "R"
                                 or e.letter == "B" or e.letter == "N")
                        if not (promoLook and commitGuard.promo ~= nil) then
                            e.white = goneCol
                            repainted = repainted + 1
                        end
                        break
                    end
                end
            end
            if repainted == 0 then
                -- same-type capture (PxP, NxN...): the piece type cannot betray
                -- the mover. The one signal left is the model ADDRESS - moved
                -- models get a fresh Address while unmoved ones keep theirs
                -- (verified live). Trust only a UNIQUE changed-Address square
                -- whose committed occupant was the enemy (else a wholesale
                -- model rebuild makes every address differ and we back off).
                local cand = nil
                for _, e in ipairs(list) do
                    local ba
                    for _, be in ipairs(base) do
                        if be.rank == e.rank and be.file == e.file then ba = be break end
                    end
                    if ba and ba.white ~= goneCol and ba.a ~= nil and e.a ~= nil and ba.a ~= e.a then
                        if cand == nil then cand = e else cand = nil break end
                    end
                end
                if cand then cand.white = goneCol end
            end
        end
    end
    -- v5.27: NO z-half fallback here. By-half painting is only exact on a
    -- full standard start; on an inherited board any leftover nil (a same-type
    -- capture, an en-passant frame) stays nil - a "ghost" the engine simply
    -- does not see until that square's piece moves and the map re-derives it.
    end
    -- v5.34 home-square kings: a ghost king sitting EXACTLY on its side's
    -- back rank (files c-g) never moved, so it is that side's - phase and
    -- inheritance simply never saw it move. Needs the orientation pin.
    -- Soundness: a king that crossed the midline travelled (phase paints
    -- movers), so an unpainted king on a home square is home; the only lie
    -- needs an enemy king marched onto d1/e1 wholly unobserved. pmap below
    -- still wins any disagreement (newer, law-backed).
    if worldNormal ~= nil then
        local wBack = worldNormal and 1 or 8
        local bBack = worldNormal and 8 or 1
        for _, e in ipairs(list) do
            if e.letter == "K" and e.white == nil and e.file >= 3 and e.file <= 7 then
                if e.rank == wBack then e.white = true
                elseif e.rank == bBack then e.white = false end
            end
        end
    end
    -- v5.33 phase overlay: squares proven by chess-law move tracking beat
    -- anything inherited (they are newer and law-backed). Runs on both
    -- branches above, so a phased map survives even with no committed board
    -- at all (mid-game attach healing forward).
    local pm = commitGuard.pmap
    if pm then
        for _, e in ipairs(list) do
            local c = pm[e.rank .. "," .. e.file]
            if c ~= nil then e.white = c end
        end
    end
    return list
end

local function scanPieces()
    local piecesFolder = workspace and workspace:FindFirstChild("Pieces")
    if not piecesFolder then return nil end
    local list = {}
    for _, piece in ipairs(piecesFolder:GetChildren()) do
        local part = piecePart(piece)
        local pos = part and part.Position
        if pos then
            local file = math.floor((pos.X - ORIGIN_X) / SPACING + 1.5)
            local rank = math.floor((pos.Z - ORIGIN_Z) / SPACING + 1.5)
            if file >= 1 and file <= 8 and rank >= 1 and rank <= 8 then
                local letter = ({ King="K", Queen="Q", Rook="R", Bishop="B", Knight="N", Pawn="P" })[piece.Name]
                if letter then
                    list[#list + 1] = { file = file, rank = rank, letter = letter,
                                        z = pos.Z, white = nil, a = piece.Address }
                end
            end
        end
    end
    -- v5.33: a base (committed list or memorised board) is only trustworthy
    -- while it still describes (almost) this live position AND it carries real
    -- colour knowledge (same two failure modes as v5.31g: round-change stale
    -- boards and colour-less tombstones). What changed: a dropped base now
    -- falls back to TRUSTED MEMORY, never to a guess - paintArmy has no
    -- mid-game bootstrap left, so the worst case is honest unknown squares
    -- that the phase tracker heals as pieces move.
    local function baseFresh(b)
        if not b then return false end
        local knownB = 0
        for _, be in ipairs(b) do
            if be.white ~= nil then knownB = knownB + 1 end
        end
        if knownB < 4 then return false end
        if #list == 0 then return true end
        local liveSq = {}
        for _, e in ipairs(list) do liveSq[e.file .. "," .. e.rank] = true end
        local shared = 0
        for _, be in ipairs(b) do
            if liveSq[be.file .. "," .. be.rank] then shared = shared + 1 end
        end
        return shared >= #b - 6
    end
    local base = nil
    if baseFresh(committedList) then
        base = committedList
    else
        committedList = nil
        if baseFresh(sessionBase) then base = sessionBase end
    end
    return paintArmy(list, base)
end

local function boardFromList(list)
    local bd = {}
    for rank = 1, 8 do bd[rank] = {} end
    for _, e in ipairs(list) do
        bd[e.rank][e.file] = { piece = e.letter, white = e.white }
    end
    return bd
end

local function readBoard()
    local list = scanPieces()
    if not list then return nil end
    if isStandardStart(list) then positionCache = {} end
    return boardFromList(list)
end

-- Track the last played move (any side). The old version keyed on instance
-- ADDRESSES - but this game replaces the piece models rather than moving them,
-- so a move was never detected and the turn never flipped. Now we diff the
-- BOARD BY SQUARE: whatever piece left an occupied square is the mover (its
-- colour comes from the previous scan's entry, still valid even if the game
-- spawns a fresh model for the piece).
-- v5.22: the diff base is now the last COMMITTED board, not the previous scan.
-- A piece mid-hop makes consecutive scans differ (a ghost frame with the mover
-- missing, the landing square mis-owned, or a phantom piece inside the band).
-- The old frame-by-frame diff turned every such ghost into a fake "last move",
-- which kept movedSince=true forever and made the engine re-search (and
-- re-draw arrows) every ~0.5s until the first real move - the pre-move storm.
-- with a committed base, transients never become moves and never re-searches.
local lastMove = nil
local lastLoggedHash = ""
-- Stability gate: only SEARCH a board that has been IDENTICAL for two
-- consecutive scans. A piece mid-hop makes one scan read a ghost board (the
-- mover missing, a landing square mis-owned, sometimes a phantom piece inside
-- the band) and the engine would happily search it - that is where the
-- occasional absurd "best move" comes from. Two-in-a-row dedupe waits out the
-- hop, then the newly-committed position is searched instead.
local lastSig = nil
local stableSig = nil
-- The last board snapshot that passed the stability gate (or the seeded
-- standard start). noteBoard diffs against THIS, so a single transient frame
-- can neither produce a move nor poison identity tracking.
local committedList = nil
-- First-move orientation pin (v5.13): White ALWAYS moves first, so the first
-- move the engine observes after a fresh standard start tells it which half of
-- the board White sits on - chess law, requiring no labels, display names or
-- model colours. sawStandardStart is true while the engine is watching a pure
-- 32-piece standard start (so a move observed after it really is move #1);
-- firstMovePinned records that the orientation was decided from a real first
-- move and should not be re-derived.
local sawStandardStart = false
local firstMovePinned = false
-- v5.29 BOARD MEMORY (persistence): the "old system, made better". Colours
-- are computed ONCE at an exact anchor (full standard start, or a restore of
-- a previously-memorised board) and then carried by the square-diff tracker;
-- a reload never re-guesses the whole board again, so crossed pieces keep
-- their true army instead of flipping to "enemy". The rule that keeps it
-- honest: sessionBase is only ever non-nil when the in-memory board is
-- TRUSTED (exact bootstrap or accepted move diff from one), and only that
-- state is written to disk. A fresh mid-game half-rule bootstrap has no
-- trust and cannot overwrite the memorised board. readfile/writefile are the
-- executor's own API (shared sandbox = survives reloads of the script).
local sessionBase = nil
local function persistBoard(kind, list)
    if _G.__CHESS_DEBUG or _G.__CHESS_PERSIST == false then
        if kind == "save" then return list end
        return nil
    end
    if kind == "load" then
        local okR, chunk = pcall(readfile, "chesshinter_state.lua")
        if not okR or type(chunk) ~= "string" or chunk == "" then return nil end
        local out = {}
        for line in chunk:gmatch("([^\n]+)") do
            local f, r, li, w
            local okG, n1, n2, n3, n4 = pcall(function()
                f, r, li, w = line:match("^(%d+),(%d+),(%u),(%d)$")
            end)
            if okG and f and r and li then
                out[#out + 1] = { file = tonumber(f), rank = tonumber(r), letter = li,
                                  z = 4 + (tonumber(r) - 1) * 4, white = w == "1", a = -1 }
            end
        end
        if #out == 0 or #out > 32 then return nil end
        -- v5.30 restore gate: a memorised board is trusted ONLY if it is a
        -- plausible position - every square legal, at most 32 pieces and
        -- EXACTLY one king per side. A single bad king-count or an out-of-
        -- range square means the fossil is corrupt and must NOT seed colours
        -- (it would be re-saved on every commit and poison every reload).
        local wkG, bkG = 0, 0
        for _, e in ipairs(out) do
            if e.file < 1 or e.file > 8 or e.rank < 1 or e.rank > 8 then return nil end
            if e.letter == "K" then
                if e.white then wkG = wkG + 1 else bkG = bkG + 1 end
            end
        end
        if wkG ~= 1 or bkG ~= 1 then
            if _G.__CHESS_DEBUG then print("[persist] gate REJECT king-count " .. wkG .. "/" .. bkG) end
            return nil
        end
        if _G.__CHESS_DEBUG then print("[persist] gate ACCEPT n=" .. #out) end
        return out
    end
    if not list then return sessionBase end
    local parts = {}
    local allKnown = true
    for _, e in ipairs(list) do if e.white == nil then allKnown = false break end end
    if allKnown then
        for _, e in ipairs(list) do
            parts[#parts + 1] = e.file .. "," .. e.rank .. "," .. e.letter .. "," .. (e.white and "1" or "0")
        end
    end
    if #parts > 0 then
        pcall(writefile, "chesshinter_state.lua", table.concat(parts, "\n"))
    end
    local out = {}
    for _, e in ipairs(list) do
        out[#out + 1] = { file = e.file, rank = e.rank, letter = e.letter, z = e.z, white = e.white, a = e.a }
    end
    sessionBase = out
    return out
end

local function noteBoard(list)
    -- v5.33: a nil scan resets shape tracking (never diff against a ghost).
    if not list then prevRawList = nil; return end
    -- Raw snapshot for the shape tracker (squares+letters+model address;
    -- colours ignored). The address is what betrays same-type captures
    -- (destination keeps its letter, only the model is new).
    local rawNow = {}
    for _, e in ipairs(list) do
        rawNow[#rawNow + 1] = { file = e.file, rank = e.rank, letter = e.letter, a = e.a }
    end
    local prevRaw = prevRawList
    prevRawList = rawNow
    -- v5.33 phase helpers (nested: zero chunk registers). Square keys are
    -- rank..","..file everywhere here.
    local function phasePaint(squares, colour)
        for _, s in ipairs(squares) do
            commitGuard.pmap[s.rank .. "," .. s.file] = colour
        end
        for _, e in ipairs(list) do
            local c = commitGuard.pmap[e.rank .. "," .. e.file]
            if c ~= nil then e.white = c end
        end
    end
    local function phasePin(moverWhite, squares, why)
        -- hard facts only (pawn direction, watched birth, game-start first
        -- move): trusted unconditionally, parity (re-)established. Prints
        -- once per unknown->known transition so the console shows WHAT
        -- established the colours (pawn/birth/first-move).
        if moverWhite == nil then return end
        local had = commitGuard.phase
        commitGuard.phase = moverWhite
        phasePaint(squares, moverWhite)
        if had == nil then
            print("[Chess Hinter] phase pinned " .. (moverWhite and "white" or "black")
                  .. " by " .. tostring(why))
        end
    end
    local function phaseAdvance(moverWhite, squares)
        -- soft inheritance: maintains parity, never establishes it.
        if moverWhite == nil then return end
        local ph = commitGuard.phase
        if ph == nil then return end
        if moverWhite == ph then
            commitGuard.phase = nil -- same side twice: slipped, forget it
            return
        end
        commitGuard.phase = moverWhite
        phasePaint(squares, moverWhite)
    end
    local function pawnColour(oRank, dRank)
        -- a pawn's rank direction IS its colour given the orientation pin.
        if worldNormal == nil or dRank == oRank then return nil end
        return ((dRank - oRank) > 0) == worldNormal
    end
    -- Shared shape resolvers (explicit args so both the raw and committed
    -- paths use them; raw entries carry no white field, committed ones do).
    local function resolveEp(goneSq, appearedSq)
        if #goneSq ~= 2 or #appearedSq ~= 1 then return nil, nil end
        local a = appearedSq[1]
        local fg = nil
        for _, oe in ipairs(goneSq) do
            if oe.letter == "P" and math.abs(a.file - oe.file) == 1
               and math.abs(a.rank - oe.rank) == 1 then
                for _, vo in ipairs(goneSq) do
                    if vo ~= oe and vo.letter == "P" and vo.rank == oe.rank then
                        if oe.white ~= nil and vo.white ~= nil and vo.white ~= oe.white then
                            return oe, nil
                        elseif oe.white == nil and vo.white == nil then
                            fg = fg or oe
                        end
                        break
                    end
                end
            end
        end
        return nil, fg
    end
    local function castleGeo(goneSq, appearedSq)
        -- letters + home/dest squares only (colours may be ghosts).
        local kO, rO = nil, nil
        for _, oe in ipairs(goneSq) do
            if oe.letter == "K" then kO = oe
            elseif oe.letter == "R" then rO = oe end
        end
        if not kO or not rO then return false end
        if kO.file ~= 5 or (kO.rank ~= 1 and kO.rank ~= 8) then return false end
        if rO.rank ~= kO.rank or (rO.file ~= 1 and rO.file ~= 8) then return false end
        local kD, rD = nil, nil
        for _, ne in ipairs(appearedSq) do
            if ne.rank == kO.rank then
                if ne.file == 7 or ne.file == 3 then kD = ne
                elseif ne.file == 6 or ne.file == 4 then rD = ne end
            end
        end
        if not kD or not rD then return false end
        if rO.file == 8 then
            return kD.file == 7 and rD.file == 6
        else
            return kD.file == 3 and rD.file == 4
        end
    end
    -- v5.33 raw-shape tracker: with no committed board, still diff square
    -- SHAPES against the previous stable scan so the phase tracker pins and
    -- paints from ANY state (a mid-game attach heals forward move by move,
    -- colours travelling with moves, never with positions).
    local function trackRawShape(cur, prev)
        if not prev then return end
        local oldSq = {}
        for _, e in ipairs(prev) do oldSq[e.file .. "," .. e.rank] = e end
        local newSq = {}
        for _, e in ipairs(cur) do newSq[e.file .. "," .. e.rank] = e end
        local gone, appeared, retyped = {}, {}, {}
        for key, oe in pairs(oldSq) do
            if not newSq[key] then gone[#gone + 1] = oe end
        end
        for key, ne in pairs(newSq) do
            local oe = oldSq[key]
            if not oe then appeared[#appeared + 1] = ne
            elseif oe.letter ~= ne.letter then retyped[#retyped + 1] = ne end
        end
        local nG, nA, nR = #gone, #appeared, #retyped
        if nG + nA + nR == 0 then return end
        -- promotion birth: needs the armed watch; colours geometrically
        -- (back rank + orientation) even when no colour was ever known.
        -- Same-square model swaps arrive as re-types, spawns as appeared -
        -- both are birth candidates.
        if nG == 0 and (nA + nR) >= 1 and (nA + nR) <= 2 and commitGuard.promo ~= nil then
            local pw = commitGuard.promo
            local bc = pw.white
            local births = {}
            local cands = {}
            for _, ne in ipairs(appeared) do cands[#cands + 1] = ne end
            for _, ne in ipairs(retyped) do cands[#cands + 1] = ne end
            for _, ne in ipairs(cands) do
                if (ne.rank == 8 or ne.rank == 1)
                   and (ne.letter == "Q" or ne.letter == "R"
                        or ne.letter == "B" or ne.letter == "N") then
                    births[#births + 1] = ne
                    if bc == nil and worldNormal ~= nil then
                        bc = ((ne.rank == 8) == worldNormal)
                    end
                end
            end
            if #births > 0 and bc ~= nil then
                for _, ne in ipairs(births) do ne.white = bc end
                phasePin(bc, births, "promotion")
                commitGuard.promo = nil
                commitGuard.bad = 0
                committedList = cur
                if sessionBase ~= nil then persistBoard("save", cur) end
                return
            end
            commitGuard.promo = nil
            return
        end
        -- promotion vanish without colours: handled in the lone-vanish
        -- branch below (Address search first, geometry watch second).
        -- single-move shapes: pawn deltas pin by direction, everything else
        -- follows alternation (only when phase is already known).
        local org, dst = nil, nil
        if nG == 1 and nA == 1 and nR == 0 then
            org, dst = gone[1], appeared[1]
        elseif nG == 1 and nA == 0 and nR == 1 then
            org, dst = gone[1], retyped[1]
        end
        if org and dst then
            commitGuard.promo = nil
            local adr = math.abs(dst.rank - org.rank)
            local adf = math.abs(dst.file - org.file)
            local pawnShape = org.letter == "P"
                and ((adf == 0 and (adr == 1 or adr == 2))
                     or (adf == 1 and adr == 1))
            if pawnShape then
                phasePin(pawnColour(org.rank, dst.rank), { org, dst }, "pawn move")
            else
                local ph = commitGuard.phase
                if ph ~= nil then
                    commitGuard.phase = not ph
                    phasePaint({ org, dst }, not ph)
                end
            end
            return
        end
        if nG == 2 and nA == 2 and nR == 0 and castleGeo(gone, appeared) then
            -- geometric castle: all four squares belong to the mover. A
            -- non-geometric 2+2 is two moves in one window - falls through
            -- to unrecognised (parity forgotten) instead of painting four
            -- squares one colour.
            commitGuard.promo = nil
            local ph = commitGuard.phase
            if ph ~= nil then
                commitGuard.phase = not ph
                local all = {}
                for _, s in ipairs(gone) do all[#all + 1] = s end
                for _, s in ipairs(appeared) do all[#all + 1] = s end
                phasePaint(all, not ph)
            end
            return
        end
        if nG == 2 and nA == 1 and nR == 0 then
            -- en passant shape via the shared resolver (geometric tier works
            -- colour-less; tier 1 cannot occur here - raw entries are nil).
            local _, epGeoR = resolveEp(gone, appeared)
            commitGuard.promo = nil
            if epGeoR then
                local a = appeared[1]
                phasePin(pawnColour(epGeoR.rank, a.rank), { epGeoR, a }, "en passant")
            else
                commitGuard.phase = nil
            end
            return
        end
        if nG == 1 and nA == 0 and nR == 0 then
            -- lone vanish. A pawn leaving rank 7/2 is ALWAYS promotion
            -- phase 1 (any move from there reaches the back rank, so a
            -- capture would change the letter and arrive as a re-type, not
            -- a vanish) - arm the geometry watch first.
            local org = gone[1]
            if org.letter == "P" and (org.rank == 7 or org.rank == 2)
               and worldNormal ~= nil and commitGuard.promo == nil then
                commitGuard.promo = { geo = true }
                return
            end
            -- same-type capture (destination kept its letter - only the
            -- model Address betrays it).
            local cand = nil
            for key, ne in pairs(newSq) do
                local oe = oldSq[key]
                if oe and oe.a ~= nil and ne.a ~= nil and oe.a ~= ne.a then
                    if cand == nil then cand = ne else cand = nil break end
                end
            end
            if cand ~= nil then
                local adr = math.abs(cand.rank - org.rank)
                local adf = math.abs(cand.file - org.file)
                local pawnShape = org.letter == "P"
                    and ((adf == 0 and (adr == 1 or adr == 2))
                         or (adf == 1 and adr == 1))
                commitGuard.promo = nil
                if pawnShape then
                    phasePin(pawnColour(org.rank, cand.rank), { org, cand }, "pawn move")
                else
                    local ph = commitGuard.phase
                    if ph ~= nil then
                        commitGuard.phase = not ph
                        phasePaint({ org, cand }, not ph)
                    end
                end
                return
            end
            -- true lone vanish: remnant/glitch; no parity info either way,
            -- so clear a stale watch but leave the phase it never corrupted.
            commitGuard.promo = nil
            return
        end
        -- unrecognised multi-change: parity may have slipped, forget the
        -- phase - but keep a watch whose birth square is still waiting.
        local keepPromo = false
        if commitGuard.promo ~= nil then
            for _, e in ipairs(cur) do
                if e.white == nil and (e.rank == 8 or e.rank == 1)
                   and (e.letter == "Q" or e.letter == "R"
                        or e.letter == "B" or e.letter == "N") then
                    keepPromo = true
                    break
                end
            end
        end
        if not keepPromo then commitGuard.promo = nil end
        commitGuard.phase = nil
    end
    local base = committedList
    if not base then
        trackRawShape(list, prevRaw)
        -- v5.31f: never adopt a list that carries NO colour knowledge. A held
        -- bootstrap (mid-game join, shuffled round) returns every white == nil;
        -- adopting it would make committedList a tombstone that every later
        -- scan inherits nil from - "colours unknown - start a new round" forever,
        -- even after a fresh standard start. Keep committedList nil so the next
        -- exact standard start (or a trusted memory restore) re-seeds colours.
        local known = 0
        for _, e in ipairs(list) do
            if e.white ~= nil then known = known + 1 end
        end
        if known < 4 then return end
        committedList = list
        return
    end
    local oldBySq = {}
    for _, e in ipairs(base) do oldBySq[e.file .. "," .. e.rank] = e end
    local newBySq = {}
    for _, e in ipairs(list) do newBySq[e.file .. "," .. e.rank] = e end

    -- squares that BECAME empty: the piece that was there moved away
    local gone = {}
    for key, oe in pairs(oldBySq) do
        local ne = newBySq[key]
        if not ne then gone[#gone + 1] = oe end
    end
    -- squares that were EMPTY and now hold a piece (the move's destination)
    local appeared = {}
    for key, ne in pairs(newBySq) do
        local oe = oldBySq[key]
        if not oe then appeared[#appeared + 1] = ne end
    end
    -- v5.33 deterministic order: `pairs` iteration is arbitrary, but gone[1]
    -- feeds the last-move arrow, the book and the phase pin, so the origin
    -- must not depend on hash order.
    local function sortSq(t)
        table.sort(t, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.rank < b.rank
        end)
    end
    sortSq(gone)
    sortSq(appeared)
    -- v5.25/v5.32/v5.33 mover pre-resolution (gone colours are committed and
    -- exact). Tier 1 is fully coloured; tier 2 (epGeo) is geometric for
    -- attach healing (pawn delta + victim beside, colours unknown). epGeo
    -- feeds the geometry guard; the commit path derives its side from the
    -- pawn delta when the tier-1 colour is missing.
    local moverColor = nil
    local mixedGone = false
    if #gone >= 1 then
        for _, oe in ipairs(gone) do
            local c = oe.white
            if c ~= nil then
                if moverColor == nil then moverColor = c
                elseif c ~= moverColor then moverColor = nil; mixedGone = true; break end
            end
        end
    end
    local epFrom, epGeo = resolveEp(gone, appeared)
    if epFrom and moverColor == nil then moverColor = epFrom.white end
    -- re-typed squares (same square, changed letter): captures and promotion
    -- landings. Anything beyond a single capture re-type is a double event,
    -- refused by the guard below.
    local retyped = {}
    for _, e in ipairs(list) do
        local be = oldBySq[e.file .. "," .. e.rank]
        if be and be.letter ~= e.letter then retyped[#retyped + 1] = e end
    end

    -- v5.34: identical boards (no squares changed at all) are not moves -
    -- return before the guard, which would refuse AND wrongly clear the
    -- phase. Every quiet stable scan was wiping the phase, so healing could
    -- never accumulate past one move ("tracking forever").
    if #gone == 0 and #appeared == 0 and #retyped == 0 then return end
    -- v5.32 promotion watch, part 1 (the vanish): a pawn leaving its
    -- pre-promotion rank with no piece appearing yet is either promotion
    -- phase 1 or a back-rank capture by a 7th-rank pawn - identical shapes.
    -- Either way, remember the pawn's colour: if a back-rank MAJOR appears
    -- next, it is that pawn grown up. promoWatch keeps the tail from wiping
    -- a watch set by THIS frame; any other accepted move clears a stale one.
    local promoWatch = false
    if #gone == 1 and #appeared == 0 then
        local oe = gone[1]
        if oe.letter == "P" and oe.white ~= nil
           and oe.rank == (oe.white and 7 or 2) then
            commitGuard.promo = { white = oe.white }
            promoWatch = true
            -- spawn-first animation order: the new piece may already sit on
            -- the back rank uncoloured - pin it now so no wash can steal it.
            local backRank = oe.white and 8 or 1
            for _, ne in ipairs(list) do
                if ne.rank == backRank and ne.white == nil
                   and (ne.letter == "Q" or ne.letter == "R"
                        or ne.letter == "B" or ne.letter == "N") then
                    ne.white = oe.white
                end
            end
        end
    end
    -- v5.32 promotion watch, part 2 (the birth): a piece materialising from
    -- nowhere is refused by the guard below - unless the watch says it is a
    -- promotion landing. Paint it the pawn's army, commit, keep lastMove
    -- (phase 1 already recorded the pawn's move, this is the same move).
    if #gone == 0 and (#appeared + #retyped) >= 1 and (#appeared + #retyped) <= 2 and commitGuard.promo ~= nil then
        -- colour from pawn memory, else geometrically (a watch armed by the
        -- colour-less raw path carries no white; the back rank + orientation
        -- is still a hard fact). Same-square model swaps arrive as re-types.
        local pw = commitGuard.promo
        local bc = pw.white
        local bcands = {}
        for _, ne in ipairs(appeared) do bcands[#bcands + 1] = ne end
        for _, ne in ipairs(retyped) do bcands[#bcands + 1] = ne end
        if bc == nil and pw.geo and worldNormal ~= nil then
            for _, ne in ipairs(bcands) do
                if ne.rank == 8 or ne.rank == 1 then
                    bc = ((ne.rank == 8) == worldNormal)
                    break
                end
            end
        end
        local births = {}
        local landed = false
        if bc ~= nil then
            local backRank = bc and 8 or 1
            for _, ne in ipairs(bcands) do
                if ne.rank == backRank
                   and (ne.letter == "Q" or ne.letter == "R"
                        or ne.letter == "B" or ne.letter == "N") then
                    ne.white = bc
                    births[#births + 1] = ne
                    landed = true
                end
            end
        end
        if landed then
            -- the promotion move just completed by this side: pin the phase.
            phasePin(bc, births, "promotion")
            commitGuard.promo = nil
            commitGuard.bad = 0
            committedList = list
            if sessionBase ~= nil then persistBoard("save", list) end
            return
        end
        commitGuard.promo = nil
    end

    -- v5.26 commit guard: only adopt a scan whose change looks like ONE chess
    -- move (quiet = 1 gone + 1 appeared, capture = 1 gone + 0 appeared,
    -- castle = 2+2, en passant = 2 gone + 1 appeared). A rebuild, a mis-read
    -- or a tray piece aliasing into the band is refused; persistent garbage
    -- MUST NOT re-seed colours however - the v5.27 rule: refuse, log once,
    -- keep the old committed map. Re-colouring a shuffled mid-game board with
    -- the z-half rule is exactly what flipped crossed pieces into "enemies"
    -- on every sandbox reset (the regression). Colours only ever re-seed at a
    -- FULL standard start (the only shape where the z-half rule is exact).
    local sigGone, sigCome = #gone, #appeared
    -- v5.33 geometry: 2+2 must be a castle and 2+1 an en passant (else two
    -- moves shared one window and parity would slip); anything beyond a
    -- single capture re-type is a double event too. All refused like any
    -- implausible change (colours kept, phase forgotten).
    local geoFail = false
    if sigGone == 2 and sigCome == 2 then
        geoFail = not castleGeo(gone, appeared)
    elseif sigGone == 2 and sigCome == 1 then
        geoFail = (epFrom == nil and epGeo == nil)
    elseif #retyped > 0 and not (sigGone == 1 and sigCome == 0) then
        geoFail = true
    end
    if geoFail or sigGone < 1 or sigGone > 3 or sigCome > 3 or (sigGone + sigCome) > 5 then
        commitGuard.bad = commitGuard.bad + 1
        -- v5.33: a refused frame may hide two moves (parity slip) - forget
        -- the phase; the next pawn move re-pins it. Colours are kept.
        commitGuard.phase = nil
        if commitGuard.bad == 6 then
            print("[Chess Hinter] Detection guard: ignoring implausible board change (colours kept).")
        end
        return
    end
    -- oscillation guard: the same change repeating, or alternating back and
    -- forth (A,B,A,B), is a scan artifact, not a move - refuse it.
    local gk, ak = {}, {}
    for _, oe in ipairs(gone) do gk[#gk + 1] = oe.file .. "," .. oe.rank end
    for _, ne in ipairs(appeared) do ak[#ak + 1] = ne.file .. "," .. ne.rank end
    table.sort(gk)
    table.sort(ak)
    local pairKey = table.concat(gk, "+") .. ">" .. table.concat(ak, "+")
    if pairKey == commitGuard.prev or pairKey == commitGuard.prevPrev then
        commitGuard.bad = commitGuard.bad + 1
        commitGuard.phase = nil
        if commitGuard.bad == 6 then
            print("[Chess Hinter] Detection guard: ignoring oscillating board change (colours kept).")
        end
        return
    end
    commitGuard.prevPrev = commitGuard.prev
    commitGuard.prev = pairKey
    commitGuard.bad = 0

    -- tier-2 en passant side from the pawn delta (geometric hard fact).
    local moverW = moverColor
    if moverW == nil and epGeo and #appeared == 1 then
        moverW = pawnColour(epGeo.rank, appeared[1].rank)
    end
    -- v5.34: ghost mover with known phase: alternation still identifies the
    -- mover (the expected side). Mixed-colour gone squares mean a double
    -- event - never guess those. Without this, healing stalls the moment a
    -- ghost piece moves (the common case mid-heal).
    if moverW == nil and not mixedGone and commitGuard.phase ~= nil then
        moverW = not commitGuard.phase
    end
    if moverW ~= nil then
        if (epFrom or epGeo) and appeared[1] then appeared[1].white = moverW end
        -- v5.32: rank-first convention, matching engine moves ({rankFrom,
        -- fileFrom, ...}), toAlg and the opening book. The old file-first
        -- order drew the arrow in the right place (squarePos takes file
        -- first) but printed wrong notation and could never match a book
        -- line, so findBookMove silently never fired.
        local fr, ff, tr, tf
        if epFrom or epGeo then
            local eo = epFrom or epGeo
            fr = eo.rank
            ff = eo.file
        else
            for _, oe in ipairs(gone) do fr = oe.rank; ff = oe.file; break end
        end
        if appeared[1] then
            tr = appeared[1].rank
            tf = appeared[1].file
        else
            tr = fr
            tf = ff
        end
        lastMove = { fr = fr, ff = ff, tr = tr, tf = tf, white = moverW }
        moveHist[#moveHist + 1] = { fr = fr, ff = ff, tr = tr, tf = tf, white = moverW }
        -- v5.33 phase tracking on the committed path: strict single-move
        -- shapes only (quiet/capture/vanish/geometric castle/ep). Anything
        -- else is a double event the guard should have refused - forget the
        -- phase rather than advance it on a mispaired origin/dest.
        -- (Flat locals, not a do-block: the balance harness counts do/end.)
        local nG, nA = #gone, #appeared
        local nR = #retyped
        local cls = nil
        if nG == 1 and nA == 1 and nR == 0 then cls = "quiet"
        elseif nG == 1 and nA == 0 and nR == 1 then cls = "capture"
        elseif nG == 1 and nA == 0 and nR == 0 then cls = "vanish"
        elseif nG == 2 and nA == 2 and nR == 0 then cls = "castle"
        elseif nG == 2 and nA == 1 and nR == 0 and (epFrom or epGeo) then cls = "ep" end
        if cls == nil then
            commitGuard.phase = nil
        else
            local orgSq = epFrom or epGeo or gone[1]
            local dstSq = appeared[1]
            if dstSq == nil and #retyped == 1 then dstSq = retyped[1] end
            local addrDst = nil
            if dstSq == nil and cls == "vanish" then
                -- same-type capture: the destination kept its letter, so
                -- only the model Address betrays it (unique change only -
                -- wholesale rebuilds back off, mirroring paintArmy).
                local cand = nil
                for _, e in ipairs(list) do
                    local ba = oldBySq[e.file .. "," .. e.rank]
                    if ba and ba.a ~= nil and e.a ~= nil and ba.a ~= e.a then
                        if cand == nil then cand = e else cand = nil break end
                    end
                end
                if cand ~= nil then dstSq = cand; addrDst = cand end
            end
            local pathSq = {}
            for _, oe in ipairs(gone) do pathSq[#pathSq + 1] = oe end
            for _, ne in ipairs(appeared) do pathSq[#pathSq + 1] = ne end
            for _, re in ipairs(retyped) do pathSq[#pathSq + 1] = re end
            -- an Address-found destination is in none of the diff lists.
            if addrDst ~= nil then pathSq[#pathSq + 1] = addrDst end
            if cls == "castle" then
                local mc = moverW
                if mc == nil and commitGuard.phase ~= nil then mc = not commitGuard.phase end
                phaseAdvance(mc, pathSq)
            else
                local orgLetter = ((epFrom or epGeo) and "P") or (gone[1] and gone[1].letter)
                if orgLetter == "P" and dstSq ~= nil then
                    phasePin(pawnColour(orgSq.rank, dstSq.rank), pathSq, "pawn move")
                else
                    phaseAdvance(moverW, pathSq)
                end
            end
        end
        -- First-move orientation pin (v5.13): the first move of a fresh
        -- round is WHITE's by chess law, so the half it came from is White's
        -- home side. Ranks 1-4 are the small-Z half. This is the only
        -- colour classification that cannot be misled by names, labels,
        -- seats or model colours - and it overrides an earlier label/seat
        -- pin if those had it the wrong way around.
        if sawStandardStart then
            sawStandardStart = false
            firstMovePinned = true
            local truth = (fr <= 4)
            if worldNormal ~= truth or worldNormalSrc ~= "move" then
                worldNormal = truth
                worldNormalSrc = "move"
                -- v5.33: the list was painted under the old orientation -
                -- repaint under the new one before it commits (a single move
                -- out of home cannot cross halves, so the z rule is exact).
                for _, e in ipairs(list) do e.white = pieceIsWhite(e.z) end
                print("[Chess Hinter] Board orientation pinned by FIRST MOVE: White sits "
                      .. (truth and "small-Z (normal)" or "LARGE-Z (inverted)") .. ".")
            end
            -- v5.33: the first move is White's by chess law - pin the phase
            -- too and mark its path White (rank-first fr/ff/tr/tf).
            phasePin(true, { { rank = fr, file = ff }, { rank = tr, file = tf } }, "first move")
            -- lastMove was detected with the PRE-pin colours; drop it so the
            -- turn logic re-derives cleanly on the next scan.
            lastMove = nil
        end
    end
    committedList = list
    -- a watch set by THIS frame survives; any other accepted move means the
    -- birth never came (it was a plain capture), so a stale watch dies here -
    -- UNLESS a newborn-looking square is still unpainted (quiet move + birth
    -- landing in one window), else the birth orphans on the very next scan.
    if not promoWatch then
        local birthPending = false
        for _, e in ipairs(list) do
            if e.white == nil and (e.rank == 8 or e.rank == 1)
               and (e.letter == "Q" or e.letter == "R"
                    or e.letter == "B" or e.letter == "N") then
                birthPending = true
                break
            end
        end
        if not birthPending then commitGuard.promo = nil end
    end
    if sessionBase ~= nil then persistBoard("save", list) end
end

-- ---- move generation (pseudo-legal, MVV-LVA ordered) ---------------------
-- ==== local function genMoves ====
local function genMoves(bd, white)
    local moves = {}
    for rank = 1, 8 do
        for file = 1, 8 do
            local sq = bd[rank][file]
            if sq and sq.white == white then
                local pt = sq.piece
                if pt == "P" then
                    local dir = white and 1 or -1
                    local startRank = white and 2 or 7
                    local promoRank = white and 8 or 1
                    local nr = rank + dir
                    if nr >= 1 and nr <= 8 and not bd[nr][file] then
                        if nr == promoRank then
                            for _, pp in ipairs({"Q","R","B","N"}) do moves[#moves+1] = {rank, file, nr, file, pp} end
                        else
                            moves[#moves+1] = {rank, file, nr, file, nil}
                            if rank == startRank then
                                local nr2 = rank + 2 * dir
                                if not bd[nr2][file] then moves[#moves+1] = {rank, file, nr2, file, nil} end
                            end
                        end
                    end
                    for _, df in ipairs({-1, 1}) do
                        local nf = file + df
                        if nf >= 1 and nf <= 8 and nr >= 1 and nr <= 8 then
                            local target = bd[nr][nf]
                            if target and target.white ~= nil and target.white ~= white then
                                if nr == promoRank then
                                    for _, pp in ipairs({"Q","R","B","N"}) do moves[#moves+1] = {rank, file, nr, nf, pp} end
                                else
                                    moves[#moves+1] = {rank, file, nr, nf, nil}
                                end
                            end
                        end
                    end
                elseif pt == "N" then
                    for _, d in ipairs(KNIGHT_OFF) do
                        local nr, nf = rank + d[1], file + d[2]
                        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
                            local t = bd[nr][nf]
                            if not t or (t.white ~= nil and t.white ~= white) then moves[#moves+1] = {rank, file, nr, nf, nil} end
                        end
                    end
                elseif pt == "K" then
                    for _, d in ipairs(KING_OFF) do
                        local nr, nf = rank + d[1], file + d[2]
                        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
                            local t = bd[nr][nf]
                            if not t or (t.white ~= nil and t.white ~= white) then moves[#moves+1] = {rank, file, nr, nf, nil} end
                        end
                    end
                elseif pt == "B" then
                    for _, d in ipairs(DIAG) do
                        for i = 1, 7 do
                            local nr, nf = rank + d[1]*i, file + d[2]*i
                            if nr < 1 or nr > 8 or nf < 1 or nf > 8 then break end
                            local t = bd[nr][nf]
                            if t then
                                if t.white ~= nil and t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
                                break
                            end
                            moves[#moves+1] = {rank, file, nr, nf, nil}
                        end
                    end
                elseif pt == "R" then
                    for _, d in ipairs(ORTHO) do
                        for i = 1, 7 do
                            local nr, nf = rank + d[1]*i, file + d[2]*i
                            if nr < 1 or nr > 8 or nf < 1 or nf > 8 then break end
                            local t = bd[nr][nf]
                            if t then
                                if t.white ~= nil and t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
                                break
                            end
                            moves[#moves+1] = {rank, file, nr, nf, nil}
                        end
                    end
                elseif pt == "Q" then
                    for _, d in ipairs({{-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1}}) do
                        for i = 1, 7 do
                            local nr, nf = rank + d[1]*i, file + d[2]*i
                            if nr < 1 or nr > 8 or nf < 1 or nf > 8 then break end
                            local t = bd[nr][nf]
                            if t then
                                if t.white ~= nil and t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
                                break
                            end
                            moves[#moves+1] = {rank, file, nr, nf, nil}
                        end
                    end
                end
            end
        end
    end
    -- MVV-LVA: captures first, most valuable victim first.
    local scored = {}
    for i, mv in ipairs(moves) do
        local victim = bd[mv[3]][mv[4]]
        local attacker = bd[mv[1]][mv[2]]
        local s = victim and ((PIECE_VAL[victim.piece] or 0) * 10 - (attacker and (PIECE_VAL[attacker.piece] or 0) or 0)) or 0
        scored[i] = { mv = mv, s = s }
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    for i, t in ipairs(scored) do moves[i] = t.mv end
    return moves
end
-- ==== local function applyMove ====
local function applyMove(bd, move)
    local new = {}
    for r = 1, 8 do
        new[r] = {}
        for f = 1, 8 do
            if bd[r][f] then new[r][f] = {piece = bd[r][f].piece, white = bd[r][f].white} end
        end
    end
    local fr, ff, tr, tf = move[1], move[2], move[3], move[4]
    local piece = new[fr][ff]
    new[fr][ff] = nil
    if move[5] then new[tr][tf] = {piece = move[5], white = piece.white}
    else new[tr][tf] = piece end
    return new
end

-- ---- FAST attack maps -----------------------------------------------------
-- ==== local function findKing ====
local function findKing(bd, white)
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq and sq.white == white and sq.piece == "K" then return r, f end
        end
    end
    return nil, nil
end

-- Does any `byWhite` piece attack square (f,r)? Ray scans only, no move list.
-- ==== local function isSquareThreatened ====
local function isSquareThreatened(bd, f, r, byWhite)
    local dir = byWhite and 1 or -1
    local pr = r - dir
    if pr >= 1 and pr <= 8 then
        local nf = f - 1
        if nf >= 1 then
            local sq = bd[pr][nf]
            if sq and sq.white == byWhite and sq.piece == "P" then return true end
        end
        nf = f + 1
        if nf <= 8 then
            local sq = bd[pr][nf]
            if sq and sq.white == byWhite and sq.piece == "P" then return true end
        end
    end
    for _, d in ipairs(KNIGHT_OFF) do
        local nr, nf = r + d[1], f + d[2]
        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
            local sq = bd[nr][nf]
            if sq and sq.white == byWhite and sq.piece == "N" then return true end
        end
    end
    for _, d in ipairs(KING_OFF) do
        local nr, nf = r + d[1], f + d[2]
        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
            local sq = bd[nr][nf]
            if sq and sq.white == byWhite and sq.piece == "K" then return true end
        end
    end
    for _, d in ipairs(DIAG) do
        local nr, nf = r + d[1], f + d[2]
        while nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 do
            local sq = bd[nr][nf]
            if sq then
                if sq.white == byWhite and (sq.piece == "B" or sq.piece == "Q") then return true end
                break
            end
            nr = nr + d[1]
            nf = nf + d[2]
        end
    end
    for _, d in ipairs(ORTHO) do
        local nr, nf = r + d[1], f + d[2]
        while nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 do
            local sq = bd[nr][nf]
            if sq then
                if sq.white == byWhite and (sq.piece == "R" or sq.piece == "Q") then return true end
                break
            end
            nr = nr + d[1]
            nf = nf + d[2]
        end
    end
    return false
end

-- Attacker squares ({r,f} list) targeting (f,r). Used for threat display and
-- the defended/hanging decision.
local function attackersOfSquare(bd, f, r, byWhite)
    local out = {}
    local dir = byWhite and 1 or -1
    local pr = r - dir
    if pr >= 1 and pr <= 8 then
        local nf = f - 1
        if nf >= 1 then
            local sq = bd[pr][nf]
            if sq and sq.white == byWhite and sq.piece == "P" then out[#out+1] = { r = pr, f = nf } end
        end
        nf = f + 1
        if nf <= 8 then
            local sq = bd[pr][nf]
            if sq and sq.white == byWhite and sq.piece == "P" then out[#out+1] = { r = pr, f = nf } end
        end
    end
    for _, d in ipairs(KNIGHT_OFF) do
        local nr, nf = r + d[1], f + d[2]
        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
            local sq = bd[nr][nf]
            if sq and sq.white == byWhite and sq.piece == "N" then out[#out+1] = { r = nr, f = nf } end
        end
    end
    for _, d in ipairs(KING_OFF) do
        local nr, nf = r + d[1], f + d[2]
        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
            local sq = bd[nr][nf]
            if sq and sq.white == byWhite and sq.piece == "K" then out[#out+1] = { r = nr, f = nf } end
        end
    end
    for _, d in ipairs(DIAG) do
        local nr, nf = r + d[1], f + d[2]
        while nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 do
            local sq = bd[nr][nf]
            if sq then
                if sq.white == byWhite and (sq.piece == "B" or sq.piece == "Q") then
                    out[#out+1] = { r = nr, f = nf }
                end
                break
            end
            nr = nr + d[1]
            nf = nf + d[2]
        end
    end
    for _, d in ipairs(ORTHO) do
        local nr, nf = r + d[1], f + d[2]
        while nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 do
            local sq = bd[nr][nf]
            if sq then
                if sq.white == byWhite and (sq.piece == "R" or sq.piece == "Q") then
                    out[#out+1] = { r = nr, f = nf }
                end
                break
            end
            nr = nr + d[1]
            nf = nf + d[2]
        end
    end
    return out
end
-- ==== local function inCheck ====
local function inCheck(bd, white)
    local kr, kf = findKing(bd, white)
    if not kr then return false end
    return isSquareThreatened(bd, kf, kr, not white)
end
-- ==== local function isLegalMove ====
local function isLegalMove(bd, mv, white)
    local nb = applyMove(bd, mv)
    local kr, kf = findKing(nb, white)
    if not kr then return false end
    return not isSquareThreatened(nb, kf, kr, not white)
end

-- Fully legal move list (pseudo-legal filtered by king safety). Used at
-- EVERY node so the engine never thinks it can walk into check.
-- ==== local function genLegalMoves ====
local function genLegalMoves(bd, white)
    local out = {}
    for _, mv in ipairs(genMoves(bd, white)) do
        if isLegalMove(bd, mv, white) then out[#out + 1] = mv end
    end
    return out
end

local function legalMoves(bd, white)
    return genLegalMoves(bd, white)
end

-- ---- evaluation + search ------------------------------------------------
-- ==== local function pawnPassed ====
local function pawnPassed(bd, f, r, white)
    local step = white and 1 or -1
    for nf = f - 1, f + 1 do
        if nf >= 1 and nf <= 8 then
            local rr = r + step
            while rr >= 1 and rr <= 8 do
                local sq = bd[rr][nf]
                if sq and sq.piece == "P" and sq.white ~= white then return false end
                rr = rr + step
            end
        end
    end
    return true
end

-- Endgame test: little non-pawn material left (roughly <= a queen + a rook
-- between BOTH sides). Cheap early-exit scan, re-done per eval leaf.
-- ==== local function isEndgame ====
local function isEndgame(bd)
    local hard = 0
    for rank = 1, 8 do
        for file = 1, 8 do
            local sq = bd[rank][file]
            -- v5.34 ghost: unknown squares are not material either way.
            if sq and sq.white ~= nil then
                local pt = sq.piece
                if pt ~= "P" and pt ~= "K" then
                    hard = hard + (PIECE_VAL[pt] or 0)
                    if hard > 1500 then return false end
                end
            end
        end
    end
    return true
end
-- ==== local function evaluate ====
local function evaluate(bd)
    local score = 0
    local EG = isEndgame(bd)
    local wB, bB = 0, 0
    local wR7, bR7 = false, false
    local whitePFile = {0,0,0,0,0,0,0,0}
    local blackPFile = {0,0,0,0,0,0,0,0}
    local whitePawns = {}
    local blackPawns = {}
    local whiteRooks = {}
    local blackRooks = {}
    local wMat, bMat = 0, 0
    local wPassers = {}
    local bPassers = {}
    -- v5.20: king squares + knight lists for king-safety / outpost terms
    local wk, wf, bk, bf = 0, 0, 0, 0
    local wKn, bKn = {}, {}
    for rank = 1, 8 do
        for file = 1, 8 do
            local sq = bd[rank][file]
            if sq then
                local pt = sq.piece
                local val = PIECE_VAL[pt] or 0
                if pt ~= "K" then
                    if sq.white == true then wMat = wMat + val -- v5.34 ghost: unknown is not enemy
                elseif sq.white == false then bMat = bMat + val end
                end
                local pstIdx
                if sq.white == true then pstIdx = (rank - 1) * 8 + file
                elseif sq.white == false then pstIdx = (8 - rank) * 8 + file
                else pstIdx = 1 end -- v5.34 ghost: unknown is not enemy
                local pst
                if pt == "K" and EG then pst = KING_END[pstIdx] or 0
                else pst = PST[pt] and PST[pt][pstIdx] or 0 end
                if sq.white == true then score = score + val + pst -- v5.34 ghost: unknown is not enemy
                elseif sq.white == false then score = score - val - pst end
                if pt == "K" and sq.white == true then wk, wf = rank, file
                elseif pt == "K" and sq.white == false then bk, bf = rank, file
                elseif pt == "N" and sq.white == true then wKn[#wKn + 1] = { file = file, rank = rank }
                elseif pt == "N" and sq.white == false then bKn[#bKn + 1] = { file = file, rank = rank } end -- v5.34 ghost: unknown is not enemy
                if pt == "B" then
                    if sq.white == true then wB = wB + 1 elseif sq.white == false then bB = bB + 1 end
                elseif pt == "R" then
                    if sq.white == true then whiteRooks[#whiteRooks + 1] = { file = file, rank = rank }
                    elseif sq.white == false then blackRooks[#blackRooks + 1] = { file = file, rank = rank } end
                    if sq.white == true and rank == 7 then wR7 = true end
                    if sq.white == false and rank == 2 then bR7 = true end -- v5.34 ghost: unknown is not enemy
                elseif pt == "P" then
                    if sq.white == true then
                        whitePFile[file] = whitePFile[file] + 1
                        whitePawns[#whitePawns + 1] = { file = file, rank = rank }
                    elseif sq.white == false then
                        blackPFile[file] = blackPFile[file] + 1
                        blackPawns[#blackPawns + 1] = { file = file, rank = rank }
                    end
                    if sq.white ~= nil and pawnPassed(bd, file, rank, sq.white) then
                        -- advancement bonus: the further up, the more valuable
                        local bonus = sq.white and (50 + (rank - 2) * 10) or (50 + (7 - rank) * 10)
                        if sq.white == true then score = score + bonus elseif sq.white == false then score = score - bonus end
                        if sq.white == true then wPassers[#wPassers + 1] = { file = file, rank = rank }
                        elseif sq.white == false then bPassers[#bPassers + 1] = { file = file, rank = rank } end
                    end -- v5.34 ghost: unknown is not enemy
                    -- pawn chain: supported by a friendly pawn one step up
                    local chain = false
                    local nr = rank + (sq.white and 1 or -1)
                    local row = nr >= 1 and nr <= 8 and bd[nr]
                    if row then
                        for _, nf in ipairs({ file - 1, file + 1 }) do
                            local nsq = nf >= 1 and nf <= 8 and row[nf]
                            if nsq and nsq.piece == "P" and nsq.white ~= nil and nsq.white == sq.white then chain = true end
                        end
                    end
                    if chain then
                        if sq.white == true then score = score + 6 elseif sq.white == false then score = score - 6 end
                    end
                end
            end
        end
    end
    -- pawn structure
    local wDoubles, bDoubles = 0, 0
    local totalP = {}
    for f = 1, 8 do
        totalP[f] = whitePFile[f] + blackPFile[f]
        if whitePFile[f] > 1 then wDoubles = wDoubles + (whitePFile[f] - 1) end
        if blackPFile[f] > 1 then bDoubles = bDoubles + (blackPFile[f] - 1) end
    end
    score = score - 18 * wDoubles + 18 * bDoubles
    for _, fp in ipairs(whitePawns) do
        local f = fp.file
        local isolated = not ((f > 1 and whitePFile[f - 1] > 0) or (f < 8 and whitePFile[f + 1] > 0))
        if isolated then score = score - 15 end
    end
    for _, fp in ipairs(blackPawns) do
        local f = fp.file
        local isolated = not ((f > 1 and blackPFile[f - 1] > 0) or (f < 8 and blackPFile[f + 1] > 0))
        if isolated then score = score + 15 end
    end
    -- rooks on open / semi-open files
    for _, rk in ipairs(whiteRooks) do
        local f = rk.file
        if totalP[f] == 0 then score = score + 25
        elseif blackPFile[f] > 0 and whitePFile[f] == 0 then score = score + 12 end
    end
    for _, rk in ipairs(blackRooks) do
        local f = rk.file
        if totalP[f] == 0 then score = score - 25
        elseif whitePFile[f] > 0 and blackPFile[f] == 0 then score = score - 12 end
    end
    if wB >= 2 then score = score + 40 end
    if bB >= 2 then score = score - 40 end
    if wR7 then score = score + 30 end
    if bR7 then score = score - 30 end
    -- ---- v5.20 king safety (middlegame only) ----
    if not EG and wk > 0 then
        -- pawn shield: friendly pawns in the three files around the king still
        -- on their shelter ranks block the enemy's attack lanes.
        local wShield, bShield = 0, 0
        for _, p in ipairs(whitePawns) do
            if math.abs(p.file - wf) <= 1 and p.rank <= 3 then wShield = wShield + 1 end
        end
        for _, p in ipairs(blackPawns) do
            if math.abs(p.file - bf) <= 1 and p.rank >= 6 then bShield = bShield + 1 end
        end
        score = score + 14 * wShield - 14 * bShield
        -- king tropism: enemy pieces crowding a king are a strike threat.
        -- Weighted by piece value so a queen parked beside the king hurts far
        -- more than a stray pawn.
        local TROP = { P = 4, N = 10, B = 10, R = 14, Q = 22 }
        for r = 1, 8 do
            for f = 1, 8 do
                local sq = bd[r][f]
                if sq and sq.piece ~= "K" then
                    local tv = TROP[sq.piece]
                    if tv then
                        if sq.white == true then
                            local d = math.abs(r - bk) + math.abs(f - bf)
                            if d <= 2 then score = score + tv * (3 - d) end
                        elseif sq.white == false then -- v5.34 ghost: unknown is not enemy
                            local d = math.abs(r - wk) + math.abs(f - wf)
                            if d <= 2 then score = score - tv * (3 - d) end
                        end
                    end
                end
            end
        end
    end
    -- knight outposts: a knight deep in enemy territory on a file no enemy
    -- pawn can challenge, backed by a friendly pawn on a neighbouring file.
    for _, kn in ipairs(wKn) do
        if kn.rank >= 5 and blackPFile[kn.file] == 0
           and (whitePFile[math.max(1, kn.file - 1)] > 0 or whitePFile[math.min(8, kn.file + 1)] > 0) then
            score = score + 18
        end
    end
    for _, kn in ipairs(bKn) do
        if kn.rank <= 4 and whitePFile[kn.file] == 0
           and (blackPFile[math.max(1, kn.file - 1)] > 0 or blackPFile[math.min(8, kn.file + 1)] > 0) then
            score = score - 18
        end
    end
    -- Endgame drive: with less material the king comes out to fight, and
    -- passed pawns carry the win - the engine has to WANT to escort them.
    if EG then
        local wk, wf = findKing(bd, true)
        local bk, bf = findKing(bd, false)
        -- king opposition / mating drive: the winning side's king chases the
        -- lone king down; the losing king wants to keep its distance.
        if wk and wf and bk and bf then
            local kd = math.abs(wk - bk) + math.abs(wf - bf)
            if wMat > bMat then score = score + math.max(0, 14 - kd) * 5
            elseif bMat > wMat then score = score - math.max(0, 14 - kd) * 5 end
        end
        -- the king escorts a passer toward promotion
        if wf and wk then
            for _, p in ipairs(wPassers) do
                local kdp = math.abs(wk - p.rank) + math.abs(wf - p.file)
                if kdp <= 5 then score = score + (5 - kdp) * 8 end
            end
        end
        if bf and bk then
            for _, p in ipairs(bPassers) do
                local kdp = math.abs(bk - p.rank) + math.abs(bf - p.file)
                if kdp <= 5 then score = score - (5 - kdp) * 8 end
            end
        end
        -- a passer this far up is a near-guaranteed queen
        for _, p in ipairs(wPassers) do
            if p.rank >= 6 then score = score + 30 end
        end
        for _, p in ipairs(bPassers) do
            if p.rank <= 3 then score = score - 30 end
        end
        -- connected passers defend each other on adjacent files
        local wPF, bPF = {}, {}
        for _, p in ipairs(wPassers) do wPF[p.file] = true end
        for _, p in ipairs(bPassers) do bPF[p.file] = true end
        for f = 1, 7 do
            if wPF[f] and wPF[f + 1] then score = score + 25 end
            if bPF[f] and bPF[f + 1] then score = score - 25 end
        end
        -- rook on the same file as its own passer supports the promotion
        for _, p in ipairs(wPassers) do
            for _, rk in ipairs(whiteRooks) do
                if rk.file == p.file then score = score + 25 end
            end
        end
        for _, p in ipairs(bPassers) do
            for _, rk in ipairs(blackRooks) do
                if rk.file == p.file then score = score - 25 end
            end
        end
    end
    -- v5.24 hanging-piece smell: a piece attacked by an ENEMY pawn with no
    -- friendly pawn of our own covering it sits one quiet ply from being won.
    -- qsearch finds this once the tactical sequence starts, but the move BEFORE
    -- (the quiet prelude) evaluates it as fine - which is exactly how a walk
    -- into a defended pawn reads as "good" until it is too late. The pawn-only
    -- attacker test is constant time, so this costs nothing in the search loop.
    for r = 1, 8 do
        local row = bd[r]
        for f = 1, 8 do
            local sq = row[f]
            if sq and sq.piece ~= "P" and sq.piece ~= "K" then
                local white = sq.white
                local pr = white and (r + 1) or (r - 1)
                local atked = false
                if pr >= 1 and pr <= 8 then
                    local prow = bd[pr]
                    if f > 1 then
                        local ap = prow[f - 1]
                        if ap and ap.piece == "P" and ap.white ~= nil and ap.white ~= white then atked = true end
                    end
                    if not atked and f < 8 then
                        local ap = prow[f + 1]
                        if ap and ap.piece == "P" and ap.white ~= nil and ap.white ~= white then atked = true end
                    end
                end
                if atked then
                    local dr = white and (r - 1) or (r + 1)
                    local support = false
                    if dr >= 1 and dr <= 8 then
                        local drow = bd[dr]
                        if f > 1 then
                            local dp = drow[f - 1]
                            if dp and dp.piece == "P" and dp.white == white then support = true end
                        end
                        if not support and f < 8 then
                            local dp = drow[f + 1]
                            if dp and dp.piece == "P" and dp.white == white then support = true end
                        end
                    end
                    if not support then
                        local v = PIECE_VAL[sq.piece] or 0
                        if white then score = score - v * 0.35 else score = score + v * 0.35 end
                    end
                end
            end
        end
    end
    return score
end
-- ==== local QMAX ====
local QMAX = 3

-- killer moves: quiet moves that produced beta cutoffs, per ply. Re-trying
-- them first at sibling nodes massively improves ordering (deeper search in
-- the same budget).
-- ==== local killers ====
local killers = {}
local history = {}  -- quiet-move history heuristic: {key -> bonus}
local function killerKey(fr, ff, tr, tf)
    return fr * 4096 + ff * 512 + tr * 64 + tf
end
local function rememberKiller(ply, key)
    local kk = killers[ply]
    if not kk then kk = {}; killers[ply] = kk end
    if kk[1] ~= key then kk[2] = kk[1]; kk[1] = key end
end

-- Transposition table: reuses prior searches of the same position instead of
-- re-searching them. The single biggest "more strength per node" lever there
-- is - this is what turns a brute-force budget into a real engine.
--   key: boardHash string
--   entry: { d=depth, s=score, f=flag(0 exact,1 lower,2 upper), m={best move} }
-- ==== local transTable ====
local transTable = {}
local ttCount = 0
local TT_DEPTH_GUARD = 2  -- probe only at depth >= this (hash string has a cost)
-- ==== local function probeTT ====
local function probeTT(hash, depth, alpha, beta, white)
    local e = transTable[hash]
    if not e or e.d < depth or e.w ~= white then return nil end
    local s = e.s
    -- mate scores are ply-relative; adjust badly if reused across paths, so only
    -- trust them lightly. For a hinter the plain cut works well enough.
    if e.f == 0 then return s end
    if e.f == 1 and s >= beta then return s end
    if e.f == 2 and s <= alpha then return s end
    return nil
end
-- ==== local function storeTT ====
local function storeTT(hash, depth, score, flag, white, bestMove)
    transTable[hash] = { d = depth, s = score, f = flag, w = white, m = bestMove }
    ttCount = ttCount + 1
    if ttCount > 60000 then
        transTable = {}
        ttCount = 0
    end
end

-- count non-pawn, non-king material for the side to move (null-move guard)
-- ==== local function hasNonPawn ====
local function hasNonPawn(bd, white)
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq and sq.white == white and sq.piece ~= "P" and sq.piece ~= "K" then return true end
        end
    end
    return false
end
-- ==== local function boardHash ====
local function boardHash(bd)
    local parts = {}
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq then
                parts[#parts + 1] = f .. "," .. r .. "," .. sq.piece .. (sq.white and "w" or "b")
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end
-- ==== local function quiesce ====
local function quiesce(bd, alpha, beta, white, qd)
    searchYield()
    if timeAborted then return alpha end
    qd = qd or 0
    if inCheck(bd, white) then
        -- must answer the check: no stand-pat, search all legal evasions.
        if qd >= QMAX + 1 then
            local e = evaluate(bd)
            return white and e or -e
        end
        local moves = genLegalMoves(bd, white)
        if #moves == 0 then
            -- v5.32: side-to-move perspective - being mated is always -m,
            -- whichever colour is mated. The old `white and -m or m` scored a
            -- mated BLACK side as +90000 (won), so the engine avoided mating
            -- Black and walked into mate playing Black (verified live: black-
            -- mated returned +90030).
            local m = 90000 + qd * 10
            return -m
        end
        local best = -9999999
        for _, mv in ipairs(moves) do
            local score = -quiesce(applyMove(bd, mv), -beta, -alpha, not white, qd + 1)
            if score >= beta then return beta end
            if score > best then best = score end
            if best > alpha then alpha = best end
        end
        return best
    end
    local standPat = evaluate(bd)
    local val = white and standPat or -standPat
    if val >= beta then return beta end
    if val > alpha then alpha = val end
    if qd >= QMAX then return alpha end
    -- v5.24 FIX: the old loop iterated genLegalMoves() and `break`ed on the
    -- first QUIET move, assuming the list was MVV-LVA ordered. genMoves walks
    -- the BOARD (rank/file), not by capture value - so the first move is
    -- usually a pawn PUSH and quiesce never searched a single capture: leaves
    -- were static eval. Build an explicit capture list, most-valuable-first,
    -- then delta-prune it.
    local caps = {}
    for _, mv in ipairs(genLegalMoves(bd, white)) do
        local cap = bd[mv[3]][mv[4]]
        if cap then
            caps[#caps + 1] = { mv = mv, s = (PIECE_VAL[cap.piece] or 0) * 10 }
        elseif mv[5] then
            caps[#caps + 1] = { mv = mv, s = 8000 } -- promotion: never pruned
        end
    end
    if #caps > 0 then
        table.sort(caps, function(a, b) return a.s > b.s end)
        for _, c in ipairs(caps) do
            local mv = c.mv
            if not mv[5] then
                local gain = val + (PIECE_VAL[bd[mv[3]][mv[4]].piece] or 0) + 150
                if gain <= alpha then break end
            end
            local score = -quiesce(applyMove(bd, mv), -beta, -alpha, not white, qd + 1)
            if score >= beta then return beta end
            if score > alpha then alpha = score end
        end
    end
    return alpha
end
-- ==== local function negamax ====
local function negamax(bd, depth, alpha, beta, white, ply)
    searchYield()
    if timeAborted then return alpha end
    if depth == 0 then
        return quiesce(bd, alpha, beta, white, 0)
    end
    -- transposition probe at higher depths only (the hash string is not free)
    local hash
    if depth >= TT_DEPTH_GUARD then
        hash = boardHash(bd)
        local tt = probeTT(hash, depth, alpha, beta, white)
        if tt ~= nil then return tt end
    end
    local inChk = inCheck(bd, white)
    -- v5.20 check extension: a position in check gets one extra ply (bounded),
    -- so forced tactical lines are followed to their conclusion rather than
    -- being cut by the depth limit mid-sequence.
    if inChk and depth < 24 then depth = depth + 1 end
    -- null-move pruning: when material is present and we're not in check, let
    -- the opponent move for free; if the reduced search still fails high, this
    -- whole node is a fail-high - skip it. (A subtle zugzwang-only artefact,
    -- so only when there are pieces that can pass the move.)
    if depth >= 3 and not inChk and hasNonPawn(bd, white) then
        local R = 2 + math.floor(depth / 6)
        local nullScore = -negamax(bd, depth - 1 - R, -beta, -beta + 1, not white, ply + 1)
        if nullScore >= beta then return nullScore end
    end
    local moves = genLegalMoves(bd, white)
    if #moves == 0 then
        if inChk then
            -- depth-aware mate score: shallower mates beat deeper ones.
            -- v5.32: side-to-move perspective, see the quiesce note above.
            local m = 90000 + depth * 10
            return -m
        end
        return 0 -- stalemate
    end
    -- v5.21 futility pruning: at shallow depth, if the static eval plus a
    -- generous margin can't reach alpha, no quiet continuation can - skip the
    -- sub-search (captures are still searched and quiescence guards every
    -- quiet tail). One static eval per shallow node is a small cost for
    -- skipping whole subtrees.
    local fut = nil
    if not inChk and depth <= 2 then
        local fe = evaluate(bd)
        fut = (white and fe or -fe)
    end
    -- move ordering: captures (already first via MVV-LVA), then TT-best,
    -- then killers, then the rest. Ordering is what lets alpha-beta widen.
    local ordered = {}
    local rest = {}
    local k1 = killers[ply] and killers[ply][1] or -1
    local k2 = killers[ply] and killers[ply][2] or -1
    local ttMv = (depth >= TT_DEPTH_GUARD) and hash and transTable[hash] and transTable[hash].m
    for _, mv in ipairs(moves) do
        local isTt = ttMv and mv[1] == ttMv[1] and mv[2] == ttMv[2]
                    and mv[3] == ttMv[3] and mv[4] == ttMv[4]
        if bd[mv[3]][mv[4]] then
            ordered[#ordered + 1] = mv
        elseif isTt then
            ordered[#ordered + 1] = mv
        else
            local key = killerKey(mv[1], mv[2], mv[3], mv[4])
            if key == k1 or key == k2 then ordered[#ordered + 1] = mv
            else rest[#rest + 1] = mv end
        end
    end
    for _, mv in ipairs(rest) do ordered[#ordered + 1] = mv end
    -- stale-history decay: keep recent moves on top without letting one early
    -- success dominate the search forever.
    if #rest > 1 then
        table.sort(rest, function(a, b)
            local ka = killerKey(a[1], a[2], a[3], a[4])
            local kb = killerKey(b[1], b[2], b[3], b[4])
            return (history[ka] or 0) > (history[kb] or 0)
        end)
        for i, mv in ipairs(rest) do ordered[#ordered + 1] = mv end
        for key, v in pairs(history) do if math.abs(v) < 64 then history[key] = nil end end
    end
    local best = -9999999
    local bestMove = nil
    local cut = false
    for i, mv in ipairs(ordered) do
        local newBd = applyMove(bd, mv)
        local score
        -- v5.20 PVS (principal variation search) + v5.19 LMR: the first move
        -- gets a full-window search; every later move is searched on a null
        -- window (-alpha-1,-alpha) first, and only re-opened if it beats alpha.
        -- Late quiet moves additionally get a one-ply-reduced first pass. This
        -- is the biggest alpha-beta efficiency gain after move ordering.
        local isTact = bd[mv[3]][mv[4]] ~= nil or mv[5] ~= nil
        local doLMR = depth >= 3 and i > 3 and not isTact and not inChk
        if i == 1 then
            score = -negamax(newBd, depth - 1, -beta, -alpha, not white, ply + 1)
        elseif fut and not isTact and fut + 240 * depth + 120 <= alpha then
            -- v5.21 futility: this quiet continuation can't lift the window.
            score = fut
        elseif doLMR then
            score = -negamax(newBd, depth - 2, -alpha - 1, -alpha, not white, ply + 1)
            if score > alpha and score < beta then
                score = -negamax(newBd, depth - 1, -beta, -alpha, not white, ply + 1)
            end
        else
            score = -negamax(newBd, depth - 1, -alpha - 1, -alpha, not white, ply + 1)
            if score > alpha and score < beta then
                score = -negamax(newBd, depth - 1, -beta, -alpha, not white, ply + 1)
            end
        end
        if score > best then best = score; bestMove = mv end
        if best > alpha then alpha = best end
        if alpha >= beta then
            cut = true
            if not bd[mv[3]][mv[4]] and depth >= 2 then
                local hk = killerKey(mv[1], mv[2], mv[3], mv[4])
                rememberKiller(ply, hk)
                history[hk] = (history[hk] or 0) + depth * depth
            end
            break
        end
        -- quiet moves that fail to score get their history demoted
        if not bd[mv[3]][mv[4]] then
            local hk = killerKey(mv[1], mv[2], mv[3], mv[4])
            local hv = history[hk]
            if hv then history[hk] = hv - depth end
        end
    end
    if hash and depth >= TT_DEPTH_GUARD then
        storeTT(hash, depth, best, cut and 1 or 0, white, bestMove)
    end
    return best
end
-- ==== local function toAlg ====
local function toAlg(fr, ff, tr, tf, promo)
    local s = FILES[ff] .. fr .. FILES[tf] .. tr
    if promo then s = s .. promo end
    return s
end

-- Root moves with same-side legal filtering (never suggest moving into check),
-- searched in previous-depth best order for better pruning + budget checks.
-- ==== local prevRootKeys ====
local prevRootKeys = {}
-- ==== local function scoreRootMoves ====
local function scoreRootMoves(bd, white, depth, deadline, prevKeys, alpha, beta)
    local legals = genLegalMoves(bd, white)
    local order = {}
    local used = {}
    if prevKeys then
        for _, key in ipairs(prevKeys) do
            for i, mv in ipairs(legals) do
                if not used[i] and toAlg(mv[1], mv[2], mv[3], mv[4], mv[5]) == key then
                    order[#order + 1] = { mv = mv, i = i }
                    used[i] = true
                    break
                end
            end
        end
    end
    for i, mv in ipairs(legals) do
        if not used[i] then order[#order + 1] = { mv = mv, i = i } end
    end
    local scored = {}
    for n = 1, #order do
        if timeAborted then break end
        if n > 1 and deadline and tick() > deadline then break end
        local o = order[n]
        local nb = applyMove(bd, o.mv)
        -- v5.20 root PVS: first move full window, the rest null-window with a
        -- re-search only when the zero-window score threatens the bound.
        local sc
        if n == 1 then
            sc = -negamax(nb, depth - 1, -beta, -alpha, not white, 1)
        else
            sc = -negamax(nb, depth - 1, -alpha - 1, -alpha, not white, 1)
            if sc > alpha and sc < beta then
                sc = -negamax(nb, depth - 1, -beta, -alpha, not white, 1)
            end
        end
        scored[n] = { mv = o.mv, score = sc, execNum = n }
        if timeAborted then break end
        if sc > alpha then alpha = sc end
        searchYield()
    end
    -- v5.24: STABLE root order - equal-scored moves must not shuffle, and a
    -- capture that ties a quiet move is presented FIRST (Lua's table.sort is
    -- unstable, and losing a free-piece tie to a random pawn move was exactly
    -- the "why doesn't it take the hanging piece" report). The epsilon keeps
    -- float noise (673.9999 vs 674.0000 for two lines that BOTH net the rook)
    -- from ranking the capture second.
    table.sort(scored, function(a, b)
        if math.abs(a.score - b.score) > 2 then return a.score > b.score end
        local va = bd[a.mv[3]][a.mv[4]] and (PIECE_VAL[bd[a.mv[3]][a.mv[4]].piece] or 0) or 0
        local vb = bd[b.mv[3]][b.mv[4]] and (PIECE_VAL[bd[b.mv[3]][b.mv[4]].piece] or 0) or 0
        if va ~= vb then return va > vb end
        return a.execNum < b.execNum
    end)
    return scored
end
-- ==== local function iterativeSearch ====
local function iterativeSearch(bd, white, maxDepth, budget)
    local t0 = tick()
    local deadline = t0 + budget
    beginSearch(budget)
    -- endgames have few moves a node, so we can afford (and badly need)
    -- extra depth to see the quiet mating manoeuvres that quiescence can't.
    -- v5.22: +3 -> +5. The old +3 still shuffled or stalemated in KQK/KRK-like
    -- endings because the forcing mating line ran past the horizon and the
    -- engine settled for a "safe" quiet continuation that only extended the
    -- game. A deeper endgame search sees the shortest mate instead.
    if isEndgame(bd) then maxDepth = maxDepth + 5 end
    local result = {}
    local prevScore = nil
    for depth = 1, maxDepth do
        if timeAborted or tick() > deadline then break end
        local alpha, beta = -9999999, 9999999
        -- aspiration window: re-use the last depth's score so we can prune
        -- hard; widen to a full search if this depth lands outside it.
        if depth >= 3 and prevScore ~= nil then
            alpha = prevScore - 50
            beta = prevScore + 50
        end
        local scored = scoreRootMoves(bd, white, depth, deadline, prevRootKeys, alpha, beta)
        if timeAborted then
            -- the search was cut mid-way: discard this partial iteration so we
            -- don't adopt a garbage root best and keep the last complete depth.
            break
        end
        if #scored > 0 then
            local bestScore = scored[1].score
            if (alpha ~= -9999999) and (bestScore <= alpha or bestScore >= beta) then
                scored = scoreRootMoves(bd, white, depth, deadline, prevRootKeys, -9999999, 9999999)
            end
        end
        if #scored > 0 then
            result = scored
            prevScore = scored[1].score
            prevRootKeys = {}
            for i, s in ipairs(scored) do
                prevRootKeys[i] = toAlg(s.mv[1], s.mv[2], s.mv[3], s.mv[4], s.mv[5])
            end
        end
        if timeAborted or tick() > deadline then break end
    end
    -- v5.22 mate-centring: once a forced mate is actually in view, keep
    -- deepening a little beyond the cap when the budget allows - the mate
    -- scores are depth-aware (shallower mate = higher score), so this locks
    -- the SHORTEST mate instead of the first one found. This directly fixes
    -- "near checkmate it picks a sequence that extends the game".
    if #result > 0 and result[1].score >= 85000 then
        for _ = 1, 4 do
            if timeAborted or tick() > deadline then break end
            local prevScoreX = result[1].score
            local scored = scoreRootMoves(bd, white, maxDepth + 1, deadline, prevRootKeys, -9999999, 9999999)
            if timeAborted then break end
            if #scored == 0 or scored[1].score <= prevScoreX then
                break
            end
            maxDepth = maxDepth + 1
            result = scored
            prevRootKeys = {}
            for i, s in ipairs(scored) do
                prevRootKeys[i] = toAlg(s.mv[1], s.mv[2], s.mv[3], s.mv[4], s.mv[5])
            end
        end
    end
    -- Anti-stalemate: shallow search can't see the quiet-move mating nets, so a
    -- winning engine keeps pounding a lone king until it runs out of squares.
    -- When clearly winning but no forced mate is in view, we prefer, among the
    -- near-best moves, the one that leaves the opponent the most legal moves.
    -- v5.24: never let that mobility pick steal the top slot from a genuine
    -- capture - "take the hanging piece" has to survive "reduce their replies".
    if #result > 1 then
        local best = result[1].score
        if best > 100 and best < 88000 then
            local pool = {}
            local hasCap = false
            for i = 1, #result do
                if result[i].score >= best - 12 then
                    pool[#pool + 1] = result[i]
                    local tgt = bd[result[i].mv[3]][result[i].mv[4]]
                    if tgt and tgt.piece ~= "P" then hasCap = true end
                end
            end
            if #pool > 1 and not hasCap then
                local bestIdx, bestMob = 1, -1
                for i = 1, #pool do
                    local nb = applyMove(bd, pool[i].mv)
                    local mob = #genLegalMoves(nb, not white)
                    if mob > bestMob then bestMob = mob; bestIdx = i end
                end
                local pick = pool[bestIdx]
                for i = 1, #result do
                    if result[i] == pick then
                        table.insert(result, 1, table.remove(result, i))
                        break
                    end
                end
            end
        end
    end
    return result
end

-- ---- Sunfish-style light engine -----------------------------------------
-- A derivative of the classic sunfish recipe: a very fast fixed-depth
-- alpha-beta search over a piece-square eval, with MVV-LVA move ordering and
-- capture-only quiescence at the horizon. Unlike CarbonX it never burrows to
-- deep ply; it trades depth for raw speed and a sharp, tactical personality.
-- Score scale matches CarbonX (centipawns, positive = good for side-to-move).
-- Sunfish strength ladder config (single table to keep module registers low).
--   blitz     ~2 ply, answers in a blink (party chess)
--   standard  ~3 ply, balanced default
--   strong    ~4 ply, real tournament amateur
--   brutal    ~5 ply, slow, sharp and stubborn
-- ==== local SF = { ====
local SF = {
    levelDepths = { blitz = 2, standard = 3, strong = 4, brutal = 5 },
    order = { "blitz", "standard", "strong", "brutal" },
    level = "standard",
}
-- ==== local SF_PST ====
local SF_PST = {
    P = {
        0,0,0,0,0,0,0,0,
        58,58,58,58,58,58,58,58,
        12,12,22,32,32,22,12,12,
        5,5,12,27,27,12,5,5,
        0,0,0,22,22,0,0,0,
        6,-4,-10,0,0,-10,-4,6,
        6,12,12,-22,-22,12,12,6,
        0,0,0,0,0,0,0,0,
    },
    N = {
        -52,-42,-32,-32,-32,-32,-42,-52,
        -42,-22,0,0,0,0,-22,-42,
        -32,0,12,17,17,12,0,-32,
        -32,6,17,22,22,17,6,-32,
        -32,0,17,22,22,17,0,-32,
        -32,6,12,17,17,12,6,-32,
        -42,-22,0,6,6,0,-22,-42,
        -52,-42,-32,-32,-32,-32,-42,-52,
    },
    B = {
        -22,-12,-12,-12,-12,-12,-12,-22,
        -12,0,0,0,0,0,0,-12,
        -12,0,6,12,12,6,0,-12,
        -12,6,6,12,12,6,6,-12,
        -12,0,12,12,12,12,0,-12,
        -12,12,12,12,12,12,12,-12,
        -12,6,0,0,0,0,6,-12,
        -22,-12,-12,-12,-12,-12,-12,-22,
    },
    R = {
        0,0,0,2,2,0,0,0,
        -4,0,0,0,0,0,0,-4,
        -4,0,0,0,0,0,0,-4,
        -4,0,0,0,0,0,0,-4,
        -4,0,0,0,0,0,0,-4,
        -4,0,0,0,0,0,0,-4,
        6,12,12,12,12,12,12,6,
        0,0,0,6,6,0,0,0,
    },
    Q = {
        -22,-12,-12,-6,-6,-12,-12,-22,
        -12,0,0,0,0,0,0,-12,
        -12,0,6,6,6,6,0,-12,
        -6,0,6,6,6,6,0,-6,
        0,0,6,6,6,6,0,-6,
        -12,6,6,6,6,6,0,-12,
        -12,0,6,0,0,0,0,-12,
        -22,-12,-12,-6,-6,-12,-12,-22,
    },
    K = {
        -32,-42,-42,-52,-52,-42,-42,-32,
        -32,-42,-42,-52,-52,-42,-42,-32,
        -32,-42,-42,-52,-52,-42,-42,-32,
        -32,-42,-42,-52,-52,-42,-42,-32,
        -22,-32,-32,-42,-42,-32,-32,-22,
        -12,-22,-22,-22,-22,-22,-22,-12,
        22,22,0,0,0,0,22,22,
        22,32,12,0,0,12,32,22,
    },
    KE = {
        -52,-42,-32,-22,-22,-32,-42,-52,
        -32,-22,-12,0,0,-12,-22,-32,
        -32,-12,22,32,32,22,-12,-32,
        -32,-12,32,42,42,32,-12,-32,
        -32,-12,32,42,42,32,-12,-32,
        -32,-12,22,32,32,22,-12,-32,
        -32,-32,0,0,0,0,-32,-32,
        -52,-32,-32,-32,-32,-32,-32,-52,
    },
}
-- ==== local sfNodes ====
local sfNodes = 0
-- ==== local function sfEval ====
local function sfEval(bd, whiteFollow)
    local score = 0
    local endgame = isEndgame(bd)
    local pawnFilesW, pawnFilesB, passed = {}, {}, 0
    for r = 1, 8 do
        local row = bd[r]
        for f = 1, 8 do
            local sq = row[f]
            if sq then
                local pc = sq.piece
                local pv = PIECE_VAL[pc] or 0
                local rowV = (sq.white == false) and (9 - r) or r
                local tbl
                if pc == "K" then tbl = endgame and SF_PST.KE or SF_PST.K
                elseif pc == "P" then
                    if sq.white == true then pawnFilesW[f] = (pawnFilesW[f] or 0) + 1
                    elseif sq.white == false then pawnFilesB[f] = (pawnFilesB[f] or 0) + 1 end
                    tbl = SF_PST.P
                elseif pc == "N" then tbl = SF_PST.N
                elseif pc == "B" then tbl = SF_PST.B
                elseif pc == "R" then tbl = SF_PST.R
                else tbl = SF_PST.Q end
                local v = pv + tbl[(rowV - 1) * 8 + f]
                -- v5.34 ghost: unknown squares contribute nothing (not enemy).
                if sq.white ~= nil then
                    score = score + ((sq.white == whiteFollow) and v or -v)
                end
            end
        end
    end
    -- pawn structure: penalties for doubled pawns come from the rarity of the
    -- square (second+ pawn on a file loses most of its PST every rank).
    for f, n in pairs(pawnFilesW) do if n > 1 then score = score - 28 * (n - 1) end end
    for f, n in pairs(pawnFilesB) do if n > 1 then score = score + 28 * (n - 1) end end
    -- passed-pawn bonus and king tropism in the endgame
    if endgame then
        local wk, bk
        for r = 1, 8 do
            local row = bd[r]
            for f = 1, 8 do
                local sq = row[f]
                if sq and sq.piece == "K" then
                    if sq.white == true then wk = { f = f, r = r } elseif sq.white == false then bk = { f = f, r = r } end
                end
            end
        end
        if wk and bk then
            local d = math.abs(wk.f - bk.f) + math.abs(wk.r - bk.r)
            -- king safety: closer = harder to advance; opponent attacked more
            score = score - (14 - d) * 8
        end
    end
    for f = 1, 8 do
        if pawnFilesW[f] and not pawnFilesB[f] then
            local adv = 0
            for r = 8, 2, -1 do if bd[r][f] and bd[r][f].piece == "P" and bd[r][f].white then adv = r; break end end
            if adv > 0 then score = score + (adv - 2) * 14 end
        end
        if pawnFilesB[f] and not pawnFilesW[f] then
            local adv = 0
            for r = 1, 7 do if bd[r][f] and bd[r][f].piece == "P" and not bd[r][f].white then adv = r; break end end
            if adv > 0 then score = score - (7 - adv) * 14 end
        end
    end
    return score
end
-- ==== local function sfCapScore ====
local function sfCapScore(bd, mv)
    return (PIECE_VAL[(bd[mv[3]][mv[4]] and bd[mv[3]][mv[4]].piece) or ""] or 0) * 10
         - (PIECE_VAL[(bd[mv[1]][mv[2]] and bd[mv[1]][mv[2]].piece) or ""] or 0)
end
-- ==== local function sfOrderMoves ====
local function sfOrderMoves(bd, white)
    local moves = genLegalMoves(bd, white)
    local scored = {}
    for _, mv in ipairs(moves) do
        scored[#scored + 1] = { mv = mv, s = sfCapScore(bd, mv) }
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    for i = 1, #scored do moves[i] = scored[i].mv end
    return moves
end
-- ==== local function sfQsearch ====
local function sfQsearch(bd, white, alpha, beta)
    sfNodes = sfNodes + 1
    if sfNodes % 384 == 0 then searchYield() end
    if timeAborted then return 0 end
    local stand = sfEval(bd, white)
    if stand >= beta then return beta end
    if stand > alpha then alpha = stand end
    local moves = genLegalMoves(bd, white)
    local caps = {}
    for _, mv in ipairs(moves) do
        local tgt = bd[mv[3]][mv[4]]
        if tgt then caps[#caps + 1] = { mv = mv, s = (PIECE_VAL[tgt.piece] or 0) * 10 - (PIECE_VAL[(bd[mv[1]][mv[2]] and bd[mv[1]][mv[2]].piece) or ""] or 0) } end
    end
    table.sort(caps, function(a, b) return a.s > b.s end)
    for _, c in ipairs(caps) do
        local sc = -sfQsearch(applyMove(bd, c.mv), not white, -beta, -alpha)
        if sc >= beta then return beta end
        if sc > alpha then alpha = sc end
    end
    return alpha
end
-- ==== local function sfNegamax ====
local function sfNegamax(bd, white, depth, alpha, beta)
    sfNodes = sfNodes + 1
    if sfNodes % 384 == 0 then searchYield() end
    if timeAborted then return 0 end
    -- v5.24: a check gets a free ply so forcing sequences resolve under the
    -- horizon. Shallow engines shuffle quiet pieces in check purely because
    -- the depth runs out before the check is resolved.
    if inCheck(bd, white) and depth < 12 then depth = depth + 1 end
    if depth <= 0 then return sfQsearch(bd, white, alpha, beta) end
    local moves = sfOrderMoves(bd, white)
    if #moves == 0 then
        return inCheck(bd, white) and -90000 or 0
    end
    local best = -9999999
    for _, mv in ipairs(moves) do
        local sc = -sfNegamax(applyMove(bd, mv), not white, depth - 1, -beta, -alpha)
        if sc > best then best = sc end
        if best > alpha then alpha = best end
        if alpha >= beta then break end
    end
    return best
end

-- Root: iterative deepening with a small aspiration window per existing score.
-- Returns the same shape as iterativeSearch: scored roots, best first.
-- ==== local function runSunfish ====
local function runSunfish(bd, white, budget)
    local deadline = tick() + math.max(budget, 0.15)
    beginSearch(budget)
    local depth = math.min(6, (SF.levelDepths[SF.level] or 3) + (depthMode == "max" and 1 or 0))
    if isEndgame(bd) then depth = math.min(6, depth + 1) end
    sfNodes = 0
    local roots = sfOrderMoves(bd, white)
    if #roots == 0 then return {} end
    local result = {}
    for d = 1, depth do
        if timeAborted or tick() > deadline then break end
        local newRes = {}
        local prevByKey = {}
        for _, s in ipairs(result) do
            prevByKey[toAlg(s.mv[1], s.mv[2], s.mv[3], s.mv[4], s.mv[5])] = s.score
        end
        for i, mv in ipairs(roots) do
            if timeAborted or tick() > deadline then break end
            local prev = prevByKey[toAlg(mv[1], mv[2], mv[3], mv[4], mv[5])]
            local alpha, beta = -9999999, 9999999
            if prev ~= nil and d >= 2 then
                alpha = prev - 80
                beta = prev + 80
            end
            local sc = -sfNegamax(applyMove(bd, mv), not white, d - 1, -beta, -alpha)
            if d >= 2 and (sc <= alpha or sc >= beta) then
                sc = -sfNegamax(applyMove(bd, mv), not white, d - 1, -9999999, 9999999)
            end
            newRes[#newRes + 1] = { mv = mv, score = sc }
        end
        if not timeAborted then
            table.sort(newRes, function(a, b)
                if math.abs(a.score - b.score) > 2 then return a.score > b.score end
                local va = bd[a.mv[3]][a.mv[4]] and (PIECE_VAL[bd[a.mv[3]][a.mv[4]].piece] or 0) or 0
                local vb = bd[b.mv[3]][b.mv[4]] and (PIECE_VAL[bd[b.mv[3]][b.mv[4]].piece] or 0) or 0
                return va > vb
            end)
            result = newRes
        end
    end
    local out = {}
    for i = 1, math.min(8, #result) do out[i] = result[i] end
    return out
end

-- ---- win chance ---------------------------------------------------------
-- v5.23 analyzer: Stockfish's fitted win-rate model (win_rate_model from
-- Stockfish src/uci.cpp). An eval does NOT mean the same thing in the opening
-- as in a simplified endgame, and the old flat logistic (scale 0.00368208)
-- ignored that: it read +1.0 as "already won" and let shallow scans flip the
-- bar wholesale. This model shifts the whole sigmoid with the game ply (the
-- a/b coefficients are 3rd-order polynomials fit on Fishtest data), so an
-- eval that breaks 50% is much bigger at move 5 than at move 50. Returns
-- (winRate, drawRate) for White.

-- ---- detection (2D board UI) --------------------------------------------
-- Piece buttons are named White_Pawn .. Black_King (colour+type free).
-- Square buttons are named a8 .. h1 with screen positions (no geometry).
local LETTER = { Pawn = "P", Knight = "N", Bishop = "B", Rook = "R", Queen = "Q", King = "K" }

local function findUI()
    if not lp then return nil end
    local pg = lp:FindFirstChild("PlayerGui")
    local gui = pg and pg:FindFirstChild("2DBoard")
    local main = gui and gui:FindFirstChild("Main")
    if not main then return nil end
    return {
        board = main:FindFirstChild("Board"),
        pieces = main:FindFirstChild("Pieces"),
        info = main:FindFirstChild("PlayerInfo"),
        timer = gui:FindFirstChild("SecondaryTimer"),
    }
end

local function readSquares(ui)
    if not ui.board then return nil end
    local pos = {}
    for _, s in ipairs(ui.board:GetChildren()) do
        local nm = s.Name
        if type(nm) == "string" and #nm == 2 then
            local ap = s.AbsolutePosition
            if ap then pos[nm] = { x = ap.X, y = ap.Y } end
        end
    end
    local a1, h8 = pos["a1"], pos["h8"]
    if not a1 or not h8 then return nil end
    -- collapsed/hidden boards stack every square on one pixel: reject them.
    local span = math.abs(a1.x - h8.x) + math.abs(a1.y - h8.y)
    if span < 200 then return nil end
    local e2, e4 = pos["e2"], pos["e4"]
    local sp = nil
    if e2 and e4 then
        sp = (math.abs(e2.x - e4.x) + math.abs(e2.y - e4.y)) / 2
    end
    if not sp or sp < 15 or sp > 300 then return nil end
    return { pos = pos, sp = sp }
end

local function readPieces(ui, sq)
    local out = {}
    if not ui.pieces then return out end
    for _, p in ipairs(ui.pieces:GetChildren()) do
        local side, kind = string.match(p.Name or "", "^(White|Black)_(%a+)$")
        local letter = kind and LETTER[kind]
        if side and letter then
            local ap = p.AbsolutePosition
            if ap then
                local best, bestD = nil, nil
                for sn, sp in pairs(sq.pos) do
                    local dx, dy = sp.x - ap.X, sp.y - ap.Y
                    local d = dx * dx + dy * dy
                    if not bestD or d < bestD then bestD = d best = sn end
                end
                local lim = sq.sp * 0.75
                if best and bestD <= lim * lim then
                    out[#out + 1] = {
                        file = string.byte(best, 1) - 96,
                        rank = tonumber(string.sub(best, 2, 2)),
                        letter = letter,
                        white = (side == "White"),
                    }
                end
            end
        end
    end
    return out
end

local function parseClock(txt)
    if type(txt) ~= "string" then return nil end
    local parts = {}
    for num in string.gmatch(txt, "(%d+)") do parts[#parts + 1] = tonumber(num) end
    if #parts == 2 then return parts[1] * 60 + parts[2] end
    if #parts == 3 then return parts[1] * 3600 + parts[2] * 60 + parts[3] end
    return nil
end

local function readClocks(ui)
    local w, b = nil, nil
    local wt = ui.timer and ui.timer:FindFirstChild("WhiteTime")
    local bt = ui.timer and ui.timer:FindFirstChild("BlackTime")
    local wv = wt and wt:FindFirstChild("Value")
    local bv = bt and bt:FindFirstChild("Value")
    if wv then w = { text = wv.Text, secs = parseClock(wv.Text) } end
    if bv then b = { text = bv.Text, secs = parseClock(bv.Text) } end
    return w, b
end

local function labelText(ui, frameName, childName)
    local fr = ui.info and ui.info:FindFirstChild(frameName)
    local t = fr and fr:FindFirstChild(childName)
    return t and t.Text or nil
end

local function boardFromList(list)
    local bd = {}
    for r = 1, 8 do bd[r] = {} end
    for _, e in ipairs(list) do
        bd[e.rank][e.file] = { piece = e.letter, white = e.white }
    end
    return bd
end

local function boardSig(list)
    local t = {}
    for _, e in ipairs(list) do
        t[#t + 1] = e.file .. "," .. e.rank .. e.letter .. (e.white and "W" or "B")
    end
    table.sort(t)
    return table.concat(t, ";")
end

-- ---- shared search state -------------------------------------------------
local paths = nil
local searching = false
local haveEval = false
local evalWhite = 0
local lastSearchKey = ""
local lastSig = nil
local stableSig = nil
local searchedOnce = false
local lastW, lastB = nil, nil
local turnWhite = nil
local lastStatus = "starting..."
local curSq = nil
local curSp = 60
local lastClocks = { w = "?", b = "?" }

-- ---- overlay arrows (screen pixels) --------------------------------------
-- Square buttons report positions; endpoints use their centers. If arrows
-- ever sit a constant offset off the pieces, set YOFF (topbar inset varies).
local YOFF = 0

local arrows = {}
for i = 1, MAX_ARROWS do
    local line = Drawing.new("Line")
    line.Thickness = 3
    line.Visible = false
    local h1 = Drawing.new("Line")
    h1.Thickness = 3
    h1.Visible = false
    local h2 = Drawing.new("Line")
    h2.Thickness = 3
    h2.Visible = false
    local lbl = Drawing.new("Text")
    lbl.Size = 14
    lbl.Center = true
    lbl.Outline = true
    lbl.Visible = false
    arrows[i] = { line = line, h1 = h1, h2 = h2, lbl = lbl }
end

local function hideArrow(i)
    local a = arrows[i]
    if a then
        a.line.Visible = false
        a.h1.Visible = false
        a.h2.Visible = false
        a.lbl.Visible = false
    end
end

local function setArrow(i, x1, y1, x2, y2, color, label)
    local a = arrows[i]
    if not a then return end
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 4 then hideArrow(i) return end
    local ux, uy = dx / len, dy / len
    -- shorten so the head lands on the piece, tail leaves it
    local sx, sy = x1 + ux * 8, y1 + uy * 8
    local ex, ey = x2 - ux * 10, y2 - uy * 10
    a.line.From = Vector2.new(sx, sy)
    a.line.To = Vector2.new(ex, ey)
    a.line.Color = color
    a.line.Visible = true
    local hl = 13
    local a1 = math.atan2(uy, ux) + 2.6
    local a2 = math.atan2(uy, ux) - 2.6
    a.h1.From = Vector2.new(ex, ey)
    a.h1.To = Vector2.new(ex + math.cos(a1) * hl, ey + math.sin(a1) * hl)
    a.h1.Color = color
    a.h1.Visible = true
    a.h2.From = Vector2.new(ex, ey)
    a.h2.To = Vector2.new(ex + math.cos(a2) * hl, ey + math.sin(a2) * hl)
    a.h2.Color = color
    a.h2.Visible = true
    a.lbl.Text = label
    a.lbl.Position = Vector2.new((sx + ex) / 2, (sy + ey) / 2 - 20)
    a.lbl.Color = color
    a.lbl.Visible = true
end

-- ---- panel ----------------------------------------------------------------
local panelBg = Drawing.new("Square")
panelBg.Filled = true
panelBg.Color = Color3.fromRGB(13, 20, 32)
panelBg.Transparency = 0.25
panelBg.Visible = false

local panelTitle = Drawing.new("Text")
panelTitle.Size = 15
panelTitle.Font = 11
panelTitle.Color = Color3.fromRGB(240, 244, 248)
panelTitle.Outline = true
panelTitle.Visible = false

local panelRows = {}
for i = 1, 4 do
    local t = Drawing.new("Text")
    t.Size = 13
    t.Font = 1
    t.Color = Color3.fromRGB(203, 213, 225)
    t.Outline = true
    t.Visible = false
    panelRows[i] = t
end

local function hidePanel()
    panelBg.Visible = false
    panelTitle.Visible = false
    for _, r in ipairs(panelRows) do r.Visible = false end
end

local ARROW_COLORS = {
    Color3.fromRGB(74, 222, 128),
    Color3.fromRGB(251, 191, 36),
    Color3.fromRGB(56, 189, 248),
}

-- ---- background search loop ----------------------------------------------
task.spawn(function()
    while running do
        if _G.__CCHESS_GEN ~= MY_GEN then break end
        local okLoop, errLoop = pcall(function()
            if not ensureServices() then task.wait(1.0) return end
            local ui = findUI()
            local sq = ui and readSquares(ui)
            if not sq then
                paths = nil
                searching = false
                haveEval = false
                lastStatus = "waiting for board..."
                task.wait(0.5)
                return
            end
            curSq = sq
            curSp = sq.sp
            local list = readPieces(ui, sq)
            local sig = boardSig(list)
            if sig == lastSig then
                if not stableSig then stableSig = sig end
            else
                lastSig = sig
                stableSig = nil
            end
            local stable = (stableSig == sig)
            -- clocks: the side whose clock decreased is to move
            local w, b = readClocks(ui)
            if w then lastClocks.w = w.text or "?" end
            if b then lastClocks.b = b.text or "?" end
            if w and b and w.secs and b.secs then
                if lastW and lastB then
                    if w.secs < lastW then turnWhite = true
                    elseif b.secs < lastB then turnWhite = false end
                elseif #list == 32 and w.secs == b.secs then
                    turnWhite = true -- fresh clocks, full board: White to move
                end
                lastW, lastB = w.secs, b.secs
            end
            -- whose board: match our name to a seat label
            local me = lp and lp.Name
            local youU = labelText(ui, "YouUsernameMaterial", "Username")
            local oppU = labelText(ui, "OpponentUsernameMaterial", "Username")
            local mine = false
            if me then
                if (youU and string.find(youU, me, 1, true))
                    or (oppU and string.find(oppU, me, 1, true)) then
                    mine = true
                end
            end
            local bd = boardFromList(list)
            -- kings must be exactly one per colour (names are exact, so any
            -- other count means a broken/transient read - hold, don't guess)
            local wK, bK = 0, 0
            for r = 1, 8 do
                for f = 1, 8 do
                    local s2 = bd[r][f]
                    if s2 and s2.piece == "K" then
                        if s2.white then wK = wK + 1 else bK = bK + 1 end
                    end
                end
            end
            local sane = (wK == 1 and bK == 1)
            local grounded = (turnWhite ~= nil) and sane and (#list > 0)
            local m = effMode()
            local key = sig .. "|" .. tostring(turnWhite) .. "|" .. depthMode .. "|" .. engineName
            local fresh = false
            if key ~= lastSearchKey then
                lastSearchKey = key
                fresh = true
            end
            if not grounded then
                if paths or haveEval then
                    paths = nil
                    haveEval = false
                    searching = false
                end
                if turnWhite == nil then
                    lastStatus = mine and "waiting for clock..." or "not your board"
                elseif not sane then
                    lastStatus = "kings " .. wK .. "/" .. bK .. " - holding..."
                else
                    lastStatus = "waiting..."
                end
            elseif fresh and sane and (stable or not searchedOnce) then
                paths = nil
                searching = true
                lastStatus = "thinking..."
                local scored = nil
                if engineName == "sunfish" then
                    scored = runSunfish(bd, turnWhite, m.budget)
                else
                    scored = iterativeSearch(bd, turnWhite, m.myDepth, m.budget)
                end
                if not scored or #scored == 0 then
                    scored = nil
                    local legal = genLegalMoves(bd, turnWhite)
                    if #legal > 0 then
                        beginSearch(m.budget)
                        local bestScore = -negamax(applyMove(bd, legal[1]), m.myDepth - 1, -9999999, 9999999, not turnWhite, 0)
                        local mv = legal[1]
                        scored = { { mv = mv, score = bestScore } }
                    end
                end
                if scored and #scored > 0 then
                    local limit = math.min(onlyBest and 1 or MAX_ARROWS, #scored)
                    paths = {}
                    for i = 1, limit do
                        local sc = scored[i]
                        local mv = sc.mv
                        local tier = (i == 1) and "BEST" or ((i == 2) and "GOOD" or "OK")
                        local tag = (turnWhite and "W: " or "B: ")
                        local alg = toAlg(mv[1], mv[2], mv[3], mv[4], mv[5])
                        local txt
                        if math.abs(sc.score) >= 88000 then
                            txt = tag .. alg .. " MATE"
                        else
                            txt = string.format("%s%s %+.1f", tag, alg, sc.score / 100)
                        end
                        paths[i] = { mv = mv, score = sc.score, tier = tier, label = txt }
                    end
                    local whiteCp = turnWhite and scored[1].score or -scored[1].score
                    if math.abs(whiteCp) > 1500 then whiteCp = (whiteCp > 0 and 1500 or -1500) end
                    evalWhite = whiteCp
                    haveEval = true
                else
                    paths = nil
                    haveEval = true
                    evalWhite = 0
                end
                searching = false
                searchedOnce = true
            end
            task.wait(0.5)
        end)
        if not okLoop then
            print("[Club Hinter] loop error (recovering): " .. tostring(errLoop))
            lastSearchKey = ""
            searching = false
            task.wait(0.5)
        end
    end
end)

-- ---- renderer --------------------------------------------------------------
task.spawn(function()
    while running do
        if _G.__CCHESS_GEN ~= MY_GEN then break end
        if not VISIBLE then
            for i = 1, MAX_ARROWS do hideArrow(i) end
            hidePanel()
        else
            local shown = 0
            if paths and curSq then
                for i = 1, #paths do
                    local p = paths[i]
                    local mv = p and p.mv
                    if not mv then break end
                    local a = curSq.pos[string.char(mv[2] + 96) .. mv[1]]
                    local c = curSq.pos[string.char(mv[4] + 96) .. mv[3]]
                    if a and c then
                        shown = shown + 1
                        setArrow(shown,
                            a.x + curSp / 2, a.y + curSp / 2 + YOFF,
                            c.x + curSp / 2, c.y + curSp / 2 + YOFF,
                            ARROW_COLORS[shown] or ARROW_COLORS[3],
                            "#" .. shown .. " " .. p.tier .. " " .. p.label)
                    end
                end
            end
            for i = shown + 1, MAX_ARROWS do hideArrow(i) end
            -- panel (top-left, below the topbar)
            local px, py = 16, 84
            panelBg.Position = Vector2.new(px, py)
            panelBg.Size = Vector2.new(228, 118)
            panelBg.Visible = true
            panelTitle.Text = "Club Hinter"
            panelTitle.Position = Vector2.new(px + 10, py + 6)
            panelTitle.Visible = true
            local eng = (engineName == "sunfish") and "SUNFISH" or "CARBONX"
            local tn = (turnWhite == nil) and "?" or (turnWhite and "White" or "Black")
            if myColor ~= nil and turnWhite ~= nil then
                tn = tn .. (turnWhite == myColor and " (YOU)" or " (opp)")
            end
            local evtxt = ""
            if haveEval then
                local own = myColor == nil and evalWhite or (myColor and evalWhite or -evalWhite)
                evtxt = string.format("  %+.1f", own / 100)
            end
            local rows = {
                eng .. " " .. string.upper(depthMode) .. (onlyBest and " best-only" or ""),
                "W " .. lastClocks.w .. "  B " .. lastClocks.b,
                tn .. " to move" .. evtxt,
                searching and "thinking..." or lastStatus,
            }
            local y = py + 28
            for i, txt in ipairs(rows) do
                panelRows[i].Text = txt
                panelRows[i].Position = Vector2.new(px + 10, y)
                panelRows[i].Visible = true
                y = y + 21
            end
        end
        task.wait(0.08)
    end
    for i = 1, MAX_ARROWS do hideArrow(i) end
    hidePanel()
end)

-- ---- input -----------------------------------------------------------------
task.spawn(function()
    local held = {}
    local keys = {
        { v = VK.P, name = "P" }, { v = VK.O, name = "O" },
        { v = VK.X, name = "X" }, { v = VK.G, name = "G" },
        { v = VK.C, name = "C" },
    }
    while running do
        if _G.__CCHESS_GEN ~= MY_GEN then break end
        for _, k in ipairs(keys) do
            local down = iskeypressed(k.v)
            if down and not held[k.v] then
                held[k.v] = true
                if k.v == VK.P then
                    VISIBLE = not VISIBLE
                    print("[Club Hinter] Visibility:", VISIBLE)
                elseif k.v == VK.O then
                    for i, mn in ipairs(MODE_ORDER) do
                        if mn == depthMode then
                            depthMode = MODE_ORDER[(i % #MODE_ORDER) + 1]
                            break
                        end
                    end
                    lastSearchKey = ""
                    print("[Club Hinter] Depth mode:", depthMode)
                elseif k.v == VK.X then
                    for i, en in ipairs(ENGINE_ORDER) do
                        if en == engineName then
                            engineName = ENGINE_ORDER[(i % #ENGINE_ORDER) + 1]
                            break
                        end
                    end
                    lastSearchKey = ""
                    print("[Club Hinter] Engine:", engineName)
                elseif k.v == VK.G then
                    onlyBest = not onlyBest
                    if onlyBest and paths and #paths > 1 then
                        paths = { paths[1] }
                    end
                    print("[Club Hinter] Hint arrows:", onlyBest and "best ONLY" or "top 3 shown")
                elseif k.v == VK.C then
                    if myColor == nil then myColor = true
                    elseif myColor == true then myColor = false
                    else myColor = nil end
                    local s = (myColor == nil) and "unknown" or (myColor and "White" or "Black")
                    print("[Club Hinter] I play:", s)
                end
            elseif not down then
                held[k.v] = false
            end
        end
        task.wait(0.08)
    end
end)

print("[Club Hinter] Loaded v1")
print("[Club Hinter] Keys: P hide | O depth (fast|deep|max) | X engine | G best-only | C my colour")
