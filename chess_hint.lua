-- Chess Move Hinter v5.4 for "Chess!" (Roblox)
-- Built for the Matcha LuaVM (Drawing, WorldToScreen, synthetic mouse).
--
-- Overlays:
--   * On YOUR turn: up to 3 ranked FULLY-LEGAL moves (green #1 BEST / orange
--     #2 GOOD / cyan #3 OK). Interior nodes are legal too, so a suggested move
--     can never hang your king.
--   * On the opponent's turn: red arrow = predicted opponent move.
--   * Threat layer: a PINK arrow for EVERY own piece an enemy can capture
--     (up to 5, King/high-value first), '!' flag on hanging pieces, ring on
--     the top threat.
--   * "CHECK!" warning (mate/stalemate detected too).
--   * Last-move arrow, bottom-center win bar (backdrop, WHITE/BLACK %,
--     eval label coloured from your own perspective).
--
-- Controls (keys):
--   P  show/hide overlay          O  cycle depth: Fast(3) <-> Deep(6)
--   L  autoplay ON/OFF            K  threat warnings ON/OFF
--   M  autoplay pace: turbo <-> normal <-> relaxed
--
-- v5 changes:
--   * Fast attack maps (isSquareThreatened / attackersOfSquare) replace the
--     slow move-list scan; legality enforced in negamax AND quiesce.
--   * Iterative deepening with previous-depth root ordering + per-depth budget.
--   * Yields inside the search keep hotkeys/buttons responsive even at depth 6.
--   * Eval: bishop pair, rook on 7th, passed pawns; stalemate = 0, mate score
--     is depth-aware so the engine prefers faster mates.
--   * Threat layer generalized to ANY at-risk piece (defended vs hanging).
--   * Win bar rebuilt with backdrop + consistent WHITE/BLACK % + view colour.
--   * detectColor never crashes on a missing GameStatus; the engine simply
--     waits until the colour resolves (retries every second).
--
-- Autoplay (safe mode): makes the engine's move after a human-like delay that
-- scales with move complexity, with a realistic mouse (noised aim, two-beat
-- grab-and-drop) and a small chance to play the 2nd-best move while clearly
-- winning. Pace is switchable with M. The move is verified after clicking:
-- failed clicks retry once, then autoplay disables itself. Normal mouse
-- clicks, no Hybrid mode required.
--
-- Usage: loadstring(readfile("chess_hint.lua"))()  (or paste the file).
-- Re-executing retires the previous instance (newest wins). Self-heals on joins.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer

-- ---- instance control: newest exec wins -------------------------------
_G.__CHESS_GEN = (_G.__CHESS_GEN or 0) + 1
local MY_GEN = _G.__CHESS_GEN
local running = true
local VISIBLE = true

-- Windows VK codes for the hotkeys
local VK_P = 80
local VK_O = 79
local VK_L = 76
local VK_K = 75
local VK_M = 77
local VK_BRACKET_R = 221

-- ---- settings -----------------------------------------------------------
local depthMode = "fast"          -- "fast" | "deep" | "max"
local autoPlay = false
local showThreats = true

local MODES = {
    fast = { myDepth = 3, oppDepth = 2, budget = 0.5 },
    deep = { myDepth = 6, oppDepth = 4, budget = 1.5 },
    max  = { myDepth = 10, oppDepth = 7, budget = 8.0 },
}
local MODE_ORDER = { "fast", "deep", "max" }

-- Autoplay human model: how fast/perfect the "human" plays.
--   base    quiet-move thinking        fetch   extra delay on captures
--   extra   randomness scale           cap     hard ceiling / 3 = floor
--   inacc   chance to play 2nd-best    grab/drop/between = click timing
local AUTO_PACE = {
    relaxed = { base = 1.6, fetch = 0.9,  extra = 0.5, cap = 5.0, inacc = 0.04, grab = 0.22, drop = 0.20, between = 0.30 },
    normal  = { base = 0.9, fetch = 0.55, extra = 0.3, cap = 3.0, inacc = 0.07, grab = 0.14, drop = 0.12, between = 0.18 },
    turbo   = { base = 0.45, fetch = 0.3, extra = 0.2, cap = 1.6, inacc = 0.08, grab = 0.06, drop = 0.05, between = 0.08 },
}
local PACE_ORDER = { "relaxed", "normal", "turbo" }
local autoPace = "turbo"

-- ---- cooperative yielding inside the search -----------------------------
-- The background search runs in its own task.spawn thread. Without yields, a
-- long synchronous negamax starves the input thread and hotkeys / the autoplay
-- toggle feel dead. Yield a few times per second from inside the recursion.
local lastYieldT = 0
local nodeCnt = 0
local function searchYield()
    nodeCnt = nodeCnt + 1
    if nodeCnt % 1200 == 0 then
        local n = tick()
        if n - lastYieldT > 0.05 then
            task.wait()
            lastYieldT = tick()
        end
    end
end

-- ---- static chess data --------------------------------------------------
local PIECE_VAL = { P=100, N=320, B=330, R=500, Q=900, K=20000 }
local FILES = {"a","b","c","d","e","f","g","h"}
local NAME_TO_LETTER = { King="K", Queen="Q", Rook="R", Bishop="B", Knight="N", Pawn="P" }

local ORIGIN_X = 1004
local ORIGIN_Z = 4
local SPACING = 4

local KNIGHT_OFF = {{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}}
local KING_OFF = {{-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1}}
local DIAG = {{-1,-1},{-1,1},{1,-1},{1,1}}
local ORTHO = {{-1,0},{1,0},{0,-1},{0,1}}

-- Piece-square tables (White's perspective; flipped for black)
local PST = {
    P = {  0,0,0,0,0,0,0,0, 5,10,10,-20,-20,10,10,5, 5,-5,-10,0,0,-10,-5,5, 0,0,0,20,20,0,0,0, 5,5,10,25,25,10,5,5, 10,10,20,30,30,20,10,10, 50,50,50,50,50,50,50,50, 0,0,0,0,0,0,0,0 },
    N = {-50,-40,-30,-30,-30,-30,-40,-50, -40,-20,0,5,5,0,-20,-40, -30,5,10,15,15,10,5,-30, -30,0,15,20,20,15,0,-30, -30,5,15,20,20,15,5,-30, -30,0,10,15,15,10,0,-30, -40,-20,0,0,0,0,-20,-40, -50,-40,-30,-30,-30,-30,-40,-50 },
    B = {-20,-10,-10,-10,-10,-10,-10,-20, -10,5,0,0,0,0,5,-10, -10,10,10,10,10,10,10,-10, -10,0,10,10,10,10,0,-10, -10,5,5,10,10,5,5,-10, -10,0,10,10,10,10,0,-10, -10,0,5,0,0,5,0,-10, -20,-10,-10,-10,-10,-10,-10,-20 },
    R = {  0,0,0,5,5,0,0,0, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, -5,0,0,0,0,0,0,-5, 5,10,10,10,10,10,10,5, 0,0,0,0,0,0,0,0 },
    Q = {-20,-10,-10,-5,-5,-10,-10,-20, -10,0,5,0,0,0,0,-10, -10,5,5,5,5,5,0,-10, 0,0,5,5,5,5,0,-5, -5,0,5,5,5,5,0,-5, -10,0,5,5,5,5,0,-10, -10,0,0,0,0,0,0,-10, -20,-10,-10,-5,-5,-10,-10,-20 },
    K = { 20,30,10,0,0,10,30,20, 20,20,0,0,0,0,20,20, -10,-20,-20,-20,-20,-20,-20,-10, -20,-30,-30,-40,-40,-30,-30,-20, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30, -30,-40,-40,-50,-50,-40,-40,-30 },
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

-- Piece identity cache: Address -> {piece, white}
local pieceColor = {}
-- Opening-variety cache: boardHash -> chosen root move index
local positionCache = {}

local myWhite = nil

local function detectColor()
    local gs = lp.PlayerGui and lp.PlayerGui:FindFirstChild("GameStatus")
    if not gs then return end
    local wFrame = gs:FindFirstChild("White")
    local bFrame = gs:FindFirstChild("Black")
    local wInfo = wFrame and wFrame:FindFirstChild("Info")
    local bInfo = bFrame and bFrame:FindFirstChild("Info")
    local inW = wInfo and wInfo.Text and wInfo.Text:find(lp.Name) ~= nil
    local inB = bInfo and bInfo.Text and bInfo.Text:find(lp.Name) ~= nil
    if inW and not inB then myWhite = true
    elseif inB and not inW then myWhite = false end
end

local function isMyTurnText()
    local gs = lp.PlayerGui and lp.PlayerGui:FindFirstChild("GameStatus")
    if not gs then return false end
    local frame = myWhite and gs:FindFirstChild("White") or gs:FindFirstChild("Black")
    local info = frame and frame:FindFirstChild("Info")
    return info and info.Text and info.Text:find(lp.Name) ~= nil
end

-- Best-effort position for a piece model (white has direct Mesh, black pieces
-- usually live under Meshes/).
local function piecePos(piece)
    local mesh = piece:FindFirstChild("Mesh")
    local p = mesh and mesh.Position
    if p then return p end
    local stack = {}
    for _, c in ipairs(piece:GetChildren()) do stack[#stack + 1] = c end
    while #stack > 0 do
        local node = table.remove(stack)
        if node.ClassName == "MeshPart" or node.ClassName == "Part" then
            local q = node.Position
            if q then return q end
        end
        for _, c in ipairs(node:GetChildren()) do stack[#stack + 1] = c end
    end
    return nil
end

local function scanPieces()
    local piecesFolder = workspace:FindFirstChild("Pieces")
    if not piecesFolder then return nil end
    local list = {}
    for _, piece in ipairs(piecesFolder:GetChildren()) do
        local pos = piecePos(piece)
        if pos then
            local file = math.floor((pos.X - ORIGIN_X) / SPACING + 1.5)
            local rank = math.floor((pos.Z - ORIGIN_Z) / SPACING + 1.5)
            if file >= 1 and file <= 8 and rank >= 1 and rank <= 8 then
                local letter = NAME_TO_LETTER[piece.Name]
                if letter then
                    list[#list + 1] = { a = piece.Address, file = file, rank = rank, letter = letter, z = pos.Z }
                end
            end
        end
    end
    return list
end

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

local function boardFromList(list)
    local bd = {}
    for rank = 1, 8 do bd[rank] = {} end
    for _, e in ipairs(list) do
        local info = pieceColor[e.a]
        if not info then
            info = { piece = e.letter, white = e.z < (ORIGIN_Z + 3.5 * SPACING) }
            pieceColor[e.a] = info
        end
        bd[e.rank][e.file] = info
    end
    return bd
end

local function readBoard()
    local list = scanPieces()
    if not list then return nil end
    if isStandardStart(list) then pieceColor = {}; positionCache = {} end
    return boardFromList(list)
end

-- Track the last played move (any side) by comparing instance addresses.
local lastScan = nil
local lastMove = nil
local lastLoggedHash = ""

local function noteBoard(list)
    if lastScan then
        local byAddr = {}
        for _, e in ipairs(list) do byAddr[e.a] = e end
        for _, e in ipairs(lastScan) do
            local ne = byAddr[e.a]
            if ne and (ne.file ~= e.file or ne.rank ~= e.rank) then
                local info = pieceColor[e.a]
                lastMove = { fr = e.file, ff = e.rank, tr = ne.file, tf = ne.rank,
                             white = info and info.white }
                break
            end
        end
    end
    lastScan = list
end

-- ---- move generation (pseudo-legal, MVV-LVA ordered) ---------------------
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
                            if target and target.white ~= white then
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
                            if not t or t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
                        end
                    end
                elseif pt == "K" then
                    for _, d in ipairs(KING_OFF) do
                        local nr, nf = rank + d[1], file + d[2]
                        if nr >= 1 and nr <= 8 and nf >= 1 and nf <= 8 then
                            local t = bd[nr][nf]
                            if not t or t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
                        end
                    end
                elseif pt == "B" then
                    for _, d in ipairs(DIAG) do
                        for i = 1, 7 do
                            local nr, nf = rank + d[1]*i, file + d[2]*i
                            if nr < 1 or nr > 8 or nf < 1 or nf > 8 then break end
                            local t = bd[nr][nf]
                            if t then
                                if t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
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
                                if t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
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
                                if t.white ~= white then moves[#moves+1] = {rank, file, nr, nf, nil} end
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

local function inCheck(bd, white)
    local kr, kf = findKing(bd, white)
    if not kr then return false end
    return isSquareThreatened(bd, kf, kr, not white)
end

local function isLegalMove(bd, mv, white)
    local nb = applyMove(bd, mv)
    local kr, kf = findKing(nb, white)
    if not kr then return false end
    return not isSquareThreatened(nb, kf, kr, not white)
end

-- Fully legal move list (pseudo-legal filtered by king safety). Used at
-- EVERY node so the engine never thinks it can walk into check.
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
local function isEndgame(bd)
    local hard = 0
    for rank = 1, 8 do
        for file = 1, 8 do
            local sq = bd[rank][file]
            if sq then
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
    for rank = 1, 8 do
        for file = 1, 8 do
            local sq = bd[rank][file]
            if sq then
                local pt = sq.piece
                local val = PIECE_VAL[pt] or 0
                local pstIdx
                if sq.white then pstIdx = (rank - 1) * 8 + file
                else pstIdx = (8 - rank) * 8 + file end
                local pst
                if pt == "K" and EG then pst = KING_END[pstIdx] or 0
                else pst = PST[pt] and PST[pt][pstIdx] or 0 end
                if sq.white then score = score + val + pst else score = score - val - pst end
                if pt == "B" then
                    if sq.white then wB = wB + 1 else bB = bB + 1 end
                elseif pt == "R" then
                    if sq.white then whiteRooks[#whiteRooks + 1] = file
                    else blackRooks[#blackRooks + 1] = file end
                    if sq.white and rank == 7 then wR7 = true end
                    if not sq.white and rank == 2 then bR7 = true end
                elseif pt == "P" then
                    if sq.white then
                        whitePFile[file] = whitePFile[file] + 1
                        whitePawns[#whitePawns + 1] = { file = file, rank = rank }
                    else
                        blackPFile[file] = blackPFile[file] + 1
                        blackPawns[#blackPawns + 1] = { file = file, rank = rank }
                    end
                    if pawnPassed(bd, file, rank, sq.white) then
                        -- advancement bonus: the further up, the more valuable
                        local bonus = sq.white and (50 + (rank - 2) * 10) or (50 + (7 - rank) * 10)
                        if sq.white then score = score + bonus else score = score - bonus end
                    end
                    -- pawn chain: supported by a friendly pawn one step up
                    local chain = false
                    local nr = rank + (sq.white and 1 or -1)
                    local row = nr >= 1 and nr <= 8 and bd[nr]
                    if row then
                        for _, nf in ipairs({ file - 1, file + 1 }) do
                            local nsq = nf >= 1 and nf <= 8 and row[nf]
                            if nsq and nsq.piece == "P" and nsq.white == sq.white then chain = true end
                        end
                    end
                    if chain then
                        if sq.white then score = score + 6 else score = score - 6 end
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
    for _, f in ipairs(whiteRooks) do
        if totalP[f] == 0 then score = score + 25
        elseif blackPFile[f] > 0 and whitePFile[f] == 0 then score = score + 12 end
    end
    for _, f in ipairs(blackRooks) do
        if totalP[f] == 0 then score = score - 25
        elseif whitePFile[f] > 0 and blackPFile[f] == 0 then score = score - 12 end
    end
    if wB >= 2 then score = score + 40 end
    if bB >= 2 then score = score - 40 end
    if wR7 then score = score + 30 end
    if bR7 then score = score - 30 end
    return score
end

local QMAX = 3

-- killer moves: quiet moves that produced beta cutoffs, per ply. Re-trying
-- them first at sibling nodes massively improves ordering (deeper search in
-- the same budget).
local killers = {}
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
local transTable = {}
local ttCount = 0
local TT_DEPTH_GUARD = 2  -- probe only at depth >= this (hash string has a cost)

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

local function storeTT(hash, depth, score, flag, white, bestMove)
    transTable[hash] = { d = depth, s = score, f = flag, w = white, m = bestMove }
    ttCount = ttCount + 1
    if ttCount > 60000 then
        transTable = {}
        ttCount = 0
    end
end

-- count non-pawn, non-king material for the side to move (null-move guard)
local function hasNonPawn(bd, white)
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq and sq.white == white and sq.piece ~= "P" and sq.piece ~= "K" then return true end
        end
    end
    return false
end

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

local function quiesce(bd, alpha, beta, white, qd)
    searchYield()
    qd = qd or 0
    if inCheck(bd, white) then
        -- must answer the check: no stand-pat, search all legal evasions.
        if qd >= QMAX + 1 then
            local e = evaluate(bd)
            return white and e or -e
        end
        local moves = genLegalMoves(bd, white)
        if #moves == 0 then
            local m = 90000 + qd * 10
            return white and -m or m
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
    for _, mv in ipairs(genLegalMoves(bd, white)) do
        if not bd[mv[3]][mv[4]] then break end
        local score = -quiesce(applyMove(bd, mv), -beta, -alpha, not white, qd + 1)
        if score >= beta then return beta end
        if score > alpha then alpha = score end
    end
    return alpha
end

local function negamax(bd, depth, alpha, beta, white, ply)
    searchYield()
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
    -- null-move pruning (MAX mode): if material is present and we're not in
    -- check, let the opponent move for free; if the reduced search still fails
    -- high, this whole node is a fail-high - skip it.
    if depthMode == "max" and depth >= 3 and not inChk and hasNonPawn(bd, white) then
        local R = 2
        local nullScore = -negamax(bd, depth - 1 - R, -beta, -beta + 1, not white, ply + 1)
        if nullScore >= beta then return nullScore end
    end
    local moves = genLegalMoves(bd, white)
    if #moves == 0 then
        if inChk then
            -- depth-aware mate score: shallower mates beat deeper ones
            local m = 90000 + depth * 10
            return white and -m or m
        end
        return 0 -- stalemate
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
    local best = -9999999
    local bestMove = nil
    local cut = false
    for _, mv in ipairs(ordered) do
        local newBd = applyMove(bd, mv)
        local score = -negamax(newBd, depth - 1, -beta, -alpha, not white, ply + 1)
        if score > best then best = score; bestMove = mv end
        if best > alpha then alpha = best end
        if alpha >= beta then
            cut = true
            if not bd[mv[3]][mv[4]] and depth >= 2 then
                rememberKiller(ply, killerKey(mv[1], mv[2], mv[3], mv[4]))
            end
            break
        end
    end
    if hash and depth >= TT_DEPTH_GUARD then
        storeTT(hash, depth, best, cut and 1 or 0, white, bestMove)
    end
    return best
end

local function toAlg(fr, ff, tr, tf, promo)
    local s = FILES[ff] .. fr .. FILES[tf] .. tr
    if promo then s = s .. promo end
    return s
end

-- Root moves with same-side legal filtering (never suggest moving into check),
-- searched in previous-depth best order for better pruning + budget checks.
local prevRootKeys = {}

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
        if n > 1 and deadline and tick() > deadline then break end
        local o = order[n]
        local nb = applyMove(bd, o.mv)
        scored[n] = { mv = o.mv, score = -negamax(nb, depth - 1, -beta, -alpha, not white, 1) }
        searchYield()
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    return scored
end

local function iterativeSearch(bd, white, maxDepth, budget)
    local t0 = tick()
    local deadline = t0 + budget
    -- endgames have few moves a node, so we can afford (and badly need)
    -- extra depth to see the quiet mating manoeuvres that quiescence can't.
    if isEndgame(bd) then maxDepth = maxDepth + 2 end
    local result = {}
    local prevScore = nil
    for depth = 1, maxDepth do
        if tick() > deadline then break end
        local alpha, beta = -9999999, 9999999
        -- aspiration window: re-use the last depth's score so we can prune
        -- hard; widen to a full search if this depth lands outside it.
        if depth >= 3 and prevScore ~= nil then
            alpha = prevScore - 50
            beta = prevScore + 50
        end
        local scored = scoreRootMoves(bd, white, depth, deadline, prevRootKeys, alpha, beta)
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
        if tick() > deadline then break end
    end
    -- Anti-stalemate: shallow search can't see the quiet-move mating nets, so a
    -- winning engine keeps pounding a lone king until it runs out of squares.
    -- When clearly winning but no forced mate is in view, we prefer, among the
    -- near-best moves, the one that leaves the opponent the most legal moves.
    if #result > 1 then
        local best = result[1].score
        if best > 300 and best < 88000 then
            local pool = {}
            for i = 1, #result do
                if result[i].score >= best - 12 then pool[#pool + 1] = result[i] end
            end
            if #pool > 1 then
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

-- ---- win chance ---------------------------------------------------------
local function winProb(cp)
    local a = 0.00368208 * math.clamp(cp, -3000, 3000)
    local p = 50 * (1 + (2 / (1 + math.exp(-a)) - 1))
    return math.clamp(p * 0.01, 0.03, 0.97)
end

-- ---- generalized threats: ANY own piece an enemy can capture -------------
local MAX_THREAT_SLOTS = 5

-- One arrow per at-risk own piece, King first then value desc, capped.
local function collectThreats(bd, side)
    local out = {}
    if not showThreats then return out end
    local pieces = {}
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq and sq.white == side then
                pieces[#pieces + 1] = { r = r, f = f, piece = sq.piece,
                                        val = PIECE_VAL[sq.piece] or 0, king = sq.piece == "K" }
            end
        end
    end
    table.sort(pieces, function(a, b)
        if a.king ~= b.king then return a.king end
        return a.val > b.val
    end)
    for _, p in ipairs(pieces) do
        if #out >= MAX_THREAT_SLOTS then break end
        local atk = attackersOfSquare(bd, p.f, p.r, not side)
        if #atk > 0 then
            -- defended = an own piece also attacks that square
            local defended = #attackersOfSquare(bd, p.f, p.r, side) > 0
            -- least-valuable attacker -> the realistic capture
            local best = nil
            local bestVal = 1e9
            for _, a in ipairs(atk) do
                local av = PIECE_VAL[bd[a.r][a.f].piece] or 0
                if av < bestVal then bestVal = av; best = a end
            end
            out[#out + 1] = { ar = best.r, af = best.f, tr = p.r, tf = p.f,
                              piece = p.piece, val = p.val, defended = defended }
        end
    end
    return out
end

-- Summary counts for the panel: total, king-attackers, hanging pieces.
local function threatSummary(bd, side)
    local n, kingAtk, hang = 0, 0, 0
    for r = 1, 8 do
        for f = 1, 8 do
            local sq = bd[r][f]
            if sq and sq.white == side then
                local atk = attackersOfSquare(bd, f, r, not side)
                if #atk > 0 then
                    n = n + 1
                    if sq.piece == "K" then kingAtk = kingAtk + #atk end
                    if #attackersOfSquare(bd, f, r, side) == 0 then hang = hang + 1 end
                end
            end
        end
    end
    return n, kingAtk, hang
end

-- ---- human-like move delay -----------------------------------------------
-- How long the autopilot "thinks" before grabbing a piece, tuned by amount
-- of things a human would notice: captures, promotions, checks, endgames,
-- a wide choice set. Randomness makes humans inconsistent.
local function moveDelay(bd, mv, side, pace)
    local p = AUTO_PACE[pace] or AUTO_PACE.normal
    local dif = 0
    if bd[mv[3]][mv[4]] then dif = dif + p.fetch end
    if mv[5] then dif = dif + 0.6 end
    local moved = bd[mv[1]][mv[2]]
    if moved and moved.piece == "K" then dif = dif + 0.5 end
    if inCheck(bd, side) then dif = dif + 0.7 end
    local n = 0
    for r = 1, 8 do
        for f = 1, 8 do if bd[r][f] then n = n + 1 end end
    end
    if n <= 8 then dif = dif + 0.4 end
    local nLegal = #legalMoves(bd, side)
    if nLegal > 35 then dif = dif + 0.2 end
    local t = p.base + dif + p.extra * math.random()
    if math.random() < 0.12 then t = t + p.extra end -- ponder briefly
    return math.clamp(t, p.cap * 0.3, p.cap)
end

-- ---- clicking ------------------------------------------------------------
local function squarePos(file, rank)
    return Vector3.new(ORIGIN_X + (file - 1) * SPACING, 1, ORIGIN_Z + (rank - 1) * SPACING)
end

-- Capture a square's on-screen position inside a real render frame.
-- jit = random world-unit offset inside the square so clicks don't always
-- land dead-centre. lift = world-unit height above the surface to project
-- at: taller for grabbing a piece, near-zero for empty-destination clicks so
-- the cursor lands on the tile's middle, not the tile above it.
local function captureScreenPos(file, rank, jit, lift)
    local result = nil
    local jx, jz = 0, 0
    if jit then jx, jz = (math.random() * 2 - 1) * jit, (math.random() * 2 - 1) * jit end
    local ly = lift or 0.45
    local conn
    conn = RunService.RenderStepped:Connect(function()
        if result ~= nil then return end
        local s, vis = WorldToScreen(squarePos(file, rank) + Vector3.new(jx, ly, jz))
        if vis and s and s.X then result = s end
    end)
    local t0 = tick()
    while result == nil and tick() - t0 < 2.0 do task.wait() end
    if conn then conn:Disconnect() end
    return result
end

local function clickSquare(file, rank, jit, hoverMs, lift)
    local pos = captureScreenPos(file, rank, jit, lift)
    if not pos then return false end
    -- human-ish mouse: flick to a noised midpoint, then the target, then click
    local mx = pos.X + (math.random() * 2 - 1) * 10
    local my = pos.Y + (math.random() * 2 - 1) * 10
    mousemoveabs(mx, my)
    task.wait(0.03 + math.random() * 0.05)
    mousemoveabs(pos.X, pos.Y)
    task.wait(hoverMs or 0.14 + math.random() * 0.1)
    mouse1click()
    task.wait(0.05 + math.random() * 0.1)
    return true
end

-- ---- drawing: hint arrows -------------------------------------------------
local ARROW_COLORS = {
    Color3.fromRGB(0, 255, 100),
    Color3.fromRGB(255, 150, 0),
    Color3.fromRGB(100, 200, 255),
}
local MAX_ARROWS = 3

local arrows = {}
for i = 1, MAX_ARROWS do
    local col = ARROW_COLORS[i]
    local line = Drawing.new("Line"); line.Thickness = 3; line.Color = col; line.Visible = false
    local h1 = Drawing.new("Line"); h1.Thickness = 3; h1.Color = col; h1.Visible = false
    local h2 = Drawing.new("Line"); h2.Thickness = 3; h2.Color = col; h2.Visible = false
    local lbl = Drawing.new("Text")
    lbl.Size = (i == 1 and 17 or 14)
    lbl.Color = col
    lbl.Outline = true
    lbl.Center = true
    lbl.Visible = false
    arrows[i] = { line = line, h1 = h1, h2 = h2, lbl = lbl }
end

local function setArrow(slot, fromScreen, toScreen, label, color)
    local e = arrows[slot]
    local col = color or ARROW_COLORS[slot]
    e.line.Color = col
    e.h1.Color = col
    e.h2.Color = col
    e.lbl.Color = col
    e.line.From = fromScreen
    e.line.To = toScreen
    e.line.Visible = true
    local dx = toScreen.X - fromScreen.X
    local dy = toScreen.Y - fromScreen.Y
    local mag = math.sqrt(dx * dx + dy * dy)
    local dirX, dirY = 0, 0
    if mag > 0 then dirX, dirY = dx / mag, dy / mag end
    local headLen, headWidth = 12, 6
    e.h1.From = Vector2.new(toScreen.X - dirX*headLen + (-dirY)*headWidth, toScreen.Y - dirY*headLen + dirX*headWidth)
    e.h1.To = toScreen
    e.h1.Visible = true
    e.h2.From = Vector2.new(toScreen.X - dirX*headLen - (-dirY)*headWidth, toScreen.Y - dirY*headLen - dirX*headWidth)
    e.h2.To = toScreen
    e.h2.Visible = true
    if label then
        local mx = (fromScreen.X + toScreen.X) / 2
        local my = (fromScreen.Y + toScreen.Y) / 2
        e.lbl.Text = label
        e.lbl.Position = Vector2.new(mx, my - 22)
        e.lbl.Visible = true
    end
end

local function hideArrow(slot)
    local e = arrows[slot]
    e.line.Visible = false
    e.h1.Visible = false
    e.h2.Visible = false
    e.lbl.Visible = false
end

-- Threat arrows (5 pink — clear them from move advice) + last-move + autoplay-intent
local R = Color3.fromRGB(255, 60, 60)
local T = Color3.fromRGB(255, 95, 200)
local threatSlots = {}
for i = 1, MAX_THREAT_SLOTS do
    local line = Drawing.new("Line"); line.Thickness = 2; line.Color = T; line.Visible = false
    local h1 = Drawing.new("Line"); h1.Thickness = 2; h1.Color = T; h1.Visible = false
    local h2 = Drawing.new("Line"); h2.Thickness = 2; h2.Color = T; h2.Visible = false
    local lbl = Drawing.new("Text")
    lbl.Size = 14
    lbl.Color = T
    lbl.Outline = true
    lbl.Center = true
    lbl.Visible = false
    threatSlots[i] = { line = line, h1 = h1, h2 = h2, lbl = lbl }
end

local Y = Color3.fromRGB(230, 210, 120)
local lastLine = Drawing.new("Line"); lastLine.Thickness = 2; lastLine.Color = Y; lastLine.Visible = false
local lastH1 = Drawing.new("Line"); lastH1.Thickness = 2; lastH1.Color = Y; lastH1.Visible = false
local lastH2 = Drawing.new("Line"); lastH2.Thickness = 2; lastH2.Color = Y; lastH2.Visible = false

local M = Color3.fromRGB(235, 80, 255)
local intentLine = Drawing.new("Line"); intentLine.Thickness = 3; intentLine.Color = M; intentLine.Visible = false
local intentH1 = Drawing.new("Line"); intentH1.Thickness = 3; intentH1.Color = M; intentH1.Visible = false
local intentH2 = Drawing.new("Line"); intentH2.Thickness = 3; intentH2.Color = M; intentH2.Visible = false

-- shared arrowhead helper for the custom arrows
local function drawArrowsInto(e, fromScreen, toScreen)
    e.line.From = fromScreen
    e.line.To = toScreen
    e.line.Visible = true
    local dx = toScreen.X - fromScreen.X
    local dy = toScreen.Y - fromScreen.Y
    local mag = math.sqrt(dx * dx + dy * dy)
    local dirX, dirY = 0, 0
    if mag > 0 then dirX, dirY = dx / mag, dy / mag end
    local headLen, headWidth = 10, 5
    e.h1.From = Vector2.new(toScreen.X - dirX*headLen + (-dirY)*headWidth, toScreen.Y - dirY*headLen + dirX*headWidth)
    e.h1.To = toScreen
    e.h1.Visible = true
    e.h2.From = Vector2.new(toScreen.X - dirX*headLen - (-dirY)*headWidth, toScreen.Y - dirY*headLen - dirX*headWidth)
    e.h2.To = toScreen
    e.h2.Visible = true
end

local function hideSet(e)
    e.line.Visible = false
    e.h1.Visible = false
    e.h2.Visible = false
    if e.lbl then e.lbl.Visible = false end
end

-- Threat highlight ring + check warning ring + "CHECK!" text
local ring = Drawing.new("Square")
ring.Filled = false
ring.Thickness = 3
ring.Color = R
ring.Visible = false

local checkText = Drawing.new("Text")
checkText.Size = 30
checkText.Center = true
checkText.Outline = true
checkText.Color = R
checkText.Visible = false

local resultText = Drawing.new("Text")
resultText.Size = 26
resultText.Center = true
resultText.Outline = true
resultText.Color = Color3.fromRGB(255, 220, 90)
resultText.Visible = false

-- ---- drawing: win bar -----------------------------------------------------
local barBack = Drawing.new("Square"); barBack.Filled = true; barBack.Color = Color3.new(0.08, 0.08, 0.08); barBack.Transparency = 0.25; barBack.Visible = false
local barWhite = Drawing.new("Square"); barWhite.Filled = true; barWhite.Color = Color3.fromRGB(240, 240, 240); barWhite.Visible = false
local barBlack = Drawing.new("Square"); barBlack.Filled = true; barBlack.Color = Color3.fromRGB(40, 40, 40); barBlack.Visible = false
local barBorder = Drawing.new("Square"); barBorder.Filled = false; barBorder.Thickness = 1; barBorder.Color = Color3.fromRGB(255, 255, 255); barBorder.Visible = false
local barCenter = Drawing.new("Line"); barCenter.Thickness = 1; barCenter.Color = Color3.fromRGB(255, 255, 255); barCenter.Visible = false
local barLabelW = Drawing.new("Text"); barLabelW.Size = 14; barLabelW.Color = Color3.fromRGB(255, 255, 255); barLabelW.Outline = true; barLabelW.Center = true; barLabelW.Visible = false
local barLabelB = Drawing.new("Text"); barLabelB.Size = 14; barLabelB.Color = Color3.fromRGB(200, 200, 200); barLabelB.Outline = true; barLabelB.Center = true; barLabelB.Visible = false
local barEvalLbl = Drawing.new("Text"); barEvalLbl.Size = 14; barEvalLbl.Color = Color3.fromRGB(255, 255, 120); barEvalLbl.Outline = true; barEvalLbl.Center = true; barEvalLbl.Visible = false

local cam = workspace:FindFirstChildOfClass("Camera")

local function viewport()
    if not cam then cam = workspace:FindFirstChildOfClass("Camera") end
    local s = cam and cam.ViewportSize
    if s and s.X and s.X > 0 then return s end
    return Vector2.new(1280, 720)
end

-- winP = White's win probability (0..1), evalWhite = eval in White's favour.
local function drawBar(winP, evalWhite)
    local vp = viewport()
    local barW, barH = 560, 12
    local x0 = vp.X / 2 - barW / 2
    local y0 = vp.Y - 88
    local w = math.clamp(barW * winP, 0, barW)
    barBack.Position = Vector2.new(x0, y0); barBack.Size = Vector2.new(barW, barH); barBack.Visible = true
    barWhite.Position = Vector2.new(x0, y0); barWhite.Size = Vector2.new(w, barH); barWhite.Visible = true
    barBlack.Position = Vector2.new(x0 + w, y0); barBlack.Size = Vector2.new(barW - w, barH); barBlack.Visible = true
    barBorder.Position = Vector2.new(x0, y0); barBorder.Size = Vector2.new(barW, barH); barBorder.Visible = true
    barCenter.From = Vector2.new(x0 + barW / 2, y0); barCenter.To = Vector2.new(x0 + barW / 2, y0 + barH); barCenter.Visible = true
    local whitePct = math.floor(winP * 100 + 0.5)
    local blackPct = 100 - whitePct
    barLabelW.Text = "WHITE " .. whitePct .. "%"
    barLabelW.Position = Vector2.new(x0 - 76, y0 + barH / 2)
    barLabelW.Visible = true
    barLabelB.Text = "BLACK " .. blackPct .. "%"
    barLabelB.Position = Vector2.new(x0 + barW + 76, y0 + barH / 2)
    barLabelB.Visible = true
    local evalTxt
    if math.abs(evalWhite) >= 90000 then
        evalTxt = "CHECKMATE"
    elseif math.abs(evalWhite) < 10 then
        evalTxt = "drawish"
    else
        local s = evalWhite > 0 and "White +" or "Black +"
        evalTxt = s .. string.format("%.1f", math.abs(evalWhite) / 100)
    end
    barEvalLbl.Text = evalTxt
    -- colour from our own perspective
    local good
    if myWhite then good = evalWhite > 10 else good = evalWhite < -10 end
    if math.abs(evalWhite) < 10 then
        barEvalLbl.Color = Color3.fromRGB(255, 230, 120)
    elseif good then
        barEvalLbl.Color = Color3.fromRGB(130, 255, 130)
    else
        barEvalLbl.Color = Color3.fromRGB(255, 130, 130)
    end
    barEvalLbl.Position = Vector2.new(x0 + barW / 2, y0 - 18)
    barEvalLbl.Visible = true
end

local function hideBar()
    barBack.Visible = false; barWhite.Visible = false; barBlack.Visible = false
    barBorder.Visible = false; barCenter.Visible = false
    barLabelW.Visible = false; barLabelB.Visible = false; barEvalLbl.Visible = false
end

-- ---- drawing: UI panel ----------------------------------------------------
local panelBg = Drawing.new("Square")
panelBg.Filled = true
panelBg.Color = Color3.new(0, 0, 0)
panelBg.Transparency = 0.35
panelBg.Visible = false

local panelBorder = Drawing.new("Square")
panelBorder.Filled = false
panelBorder.Thickness = 1
panelBorder.Color = Color3.fromRGB(90, 200, 255)
panelBorder.Visible = false

local panelTitle = Drawing.new("Text")
panelTitle.Size = 15
panelTitle.Color = Color3.fromRGB(90, 200, 255)
panelTitle.Outline = true
panelTitle.Visible = false

local panelRows = {}
local rowSpecs = {
    { key = "depth" },
    { key = "auto" },
    { key = "threat" },
    { key = "status" },
}
for i = 1, #rowSpecs do
    local t = Drawing.new("Text")
    t.Size = 13
    t.Color = Color3.fromRGB(220, 220, 220)
    t.Outline = true
    t.Visible = false
    rowSpecs[i].obj = t
    panelRows[i] = t
end

local function hidePanel()
    panelBg.Visible = false
    panelBorder.Visible = false
    panelTitle.Visible = false
    for _, r in ipairs(panelRows) do r.Visible = false end
end

local function drawPanel(pInfo)
    local vp = viewport()
    local px, py = vp.X - 212, 12
    local pw, ph = 200, 128
    panelBg.Position = Vector2.new(px, py)
    panelBg.Size = Vector2.new(pw, ph)
    panelBg.Visible = true
    panelBorder.Position = Vector2.new(px, py)
    panelBorder.Size = Vector2.new(pw, ph)
    panelBorder.Visible = true

    local title = "CHESS HINTER  (P hide)"
    panelTitle.Text = title
    panelTitle.Position = Vector2.new(px + 8, py + 2)
    panelTitle.Visible = true

    local rows = {
        "Depth: " .. pInfo.depth .. "   [O]",
        pInfo.auto,
        "Threat:" .. pInfo.threat .. "  [K]",
        pInfo.status,
    }
    local y = py + 26
    for i, txt in ipairs(rows) do
        panelRows[i].Text = txt
        panelRows[i].Position = Vector2.new(px + 8, y)
        panelRows[i].Visible = true
        y = y + 22
    end
end

-- ---- shared search state -------------------------------------------------
local paths = nil
local predict = nil
local thr = {}
local thrSummary = { n = 0, kingAtk = 0, hang = 0 }
local inCheckNow = false
local mates = nil           -- "win" | "loss" | "draw"
local autoIntent = nil      -- mv being prepared by autoplay
local autoState = "off"     -- "off" | "thinking" | "clicking"
local thrExplained = false
local evalWhite = 0         -- eval in WHITE's favour
local win = 0.5             -- WHITE win probability (bar/labels)
local haveEval = false
local autoKey = nil
local autoBusy = false
-- Re-search a position only when it actually changes (or the mode flips).
-- Without this, an 8s Max search would burn CPU re-running itself.
local lastSearchKey = ""

-- ---- detect + shared info at startup -------------------------------------
detectColor()
if myWhite ~= nil then
    print("[Chess Hinter] Playing as:", myWhite and "White" or "Black")
else
    print("[Chess Hinter] Color not detected yet - waiting for GameStatus.")
end

-- ---- background search loop ----------------------------------------------
task.spawn(function()
    while running do
        if _G.__CHESS_GEN ~= MY_GEN then break end
        detectColor()
        if myWhite == nil then
            task.wait(1.0)
        else
            local list = scanPieces()
            if list and isStandardStart(list) then pieceColor = {}; positionCache = {}; transTable = {}; killers = {} end
            local bd = list and boardFromList(list) or nil
            if bd and list then
                noteBoard(list)
                local isMyTurn = isMyTurnText()
                local m = MODES[depthMode]
                local st = boardHash(bd)
                local key = st .. "|" .. (isMyTurn and "M" or "O") .. "|" .. depthMode
                local fresh = false
                if key ~= lastSearchKey then
                    lastSearchKey = key
                    fresh = true
                end
                if fresh then
                    if isMyTurn then
                    local scored = iterativeSearch(bd, myWhite, m.myDepth, m.budget)
                    if #scored == 0 then
                        scored = nil
                        local legal = genLegalMoves(bd, myWhite)
                        if #legal == 0 then
                            mates = inCheck(bd, myWhite) and "loss" or "draw"
                            paths = nil
                            predict = nil
                            haveEval = true
                            if mates == "loss" then
                                evalWhite = myWhite and -90000 or 90000
                            else
                                evalWhite = 0
                            end
                            win = winProb(evalWhite)
                        else
                            mates = nil
                            local bestScore = -9999999
                            for i = 1, math.min(3, #legal) do
                                local mv = legal[i]
                                local s = -negamax(applyMove(bd, mv), m.myDepth - 1, -9999999, 9999999, not myWhite, 0)
                                if s > bestScore then bestScore = s end
                            end
                            local bestMove = legal[1]
                            for _, mv in ipairs(legal) do
                                if (bd[mv[3]][mv[4]] and (PIECE_VAL[bd[mv[3]][mv[4]].piece] or 0) >= 500) or mv[5] then
                                    bestMove = mv
                                    break
                                end
                            end
                            paths = { { mv = bestMove, score = bestScore, tier = "BEST",
                                        alg = toAlg(bestMove[1], bestMove[2], bestMove[3], bestMove[4], bestMove[5]) } }
                            predict = nil
                            evalWhite = myWhite and bestScore or -bestScore
                            win = winProb(evalWhite)
                            haveEval = true
                        end
                    else
                        mates = nil
                        local hash = boardHash(bd)

                        -- opening variety as before
                        local choice = positionCache[hash]
                        if not choice then
                            local pool = {}
                            local bestScore = scored[1].score
                            for i, s in ipairs(scored) do
                                if s.score >= bestScore - 35 then pool[#pool + 1] = i end
                            end
                            choice = pool[math.random(1, #pool)]
                            positionCache[hash] = choice
                        end
                        local display = { scored[choice] }
                        for i, s in ipairs(scored) do
                            if i ~= choice then display[#display + 1] = s end
                        end

                        paths = {}
                        local limit = math.min(MAX_ARROWS, #display)
                        for i = 1, limit do
                            local sc = display[i]
                            local mv = sc.mv
                            local tier
                            if i == 1 then tier = "BEST"
                            elseif i == 2 then tier = "GOOD"
                            else tier = "OK" end
                            paths[i] = { mv = mv, score = sc.score, tier = tier,
                                         alg = toAlg(mv[1], mv[2], mv[3], mv[4], mv[5]) }
                        end
                        predict = nil
                        evalWhite = myWhite and scored[1].score or -scored[1].score
                        win = winProb(evalWhite)
                        haveEval = true

                        -- autoplay: arm once per fresh position
                        if autoPlay and isMyTurn and autoKey ~= hash and not autoBusy and scored[1] then
                            autoKey = hash
                            local p = AUTO_PACE[autoPace] or AUTO_PACE.normal
                            -- humans occasionally play the 2nd-best move when cruising
                            local mvh = scored[1].mv
                            -- humans occasionally play the 2nd-best move when cruising
                            -- (except in MAX mode - there the autoplay is all-in)
                            if depthMode ~= "max" and #scored >= 2 and math.random() < p.inacc then
                                local own = myWhite and evalWhite or -evalWhite
                                if own > 150 then mvh = scored[2].mv end
                            end
                            autoBusy = true
                            task.spawn(function()
                                autoState = "thinking"
                                local delay = moveDelay(bd, mvh, myWhite, autoPace)
                                autoIntent = mvh
                                task.wait(delay)
                                autoIntent = nil
                                if _G.__CHESS_GEN ~= MY_GEN or not running then autoBusy = false return end
                                local cbd = readBoard()
                                if not (cbd and boardHash(cbd) == hash and isMyTurnText()) then
                                    autoState = "off"
                                    autoBusy = false
                                    return
                                end
                                autoState = "clicking"
                                local ok1 = clickSquare(mvh[2], mvh[1], 0.35, p.grab)
                                if ok1 then
                                    task.wait(0.1 + math.random() * 0.12 + p.between)
                                    local ok2 = clickSquare(mvh[4], mvh[3], 0.15, p.drop, 0.08)
                                    if not ok2 then
                                        autoState = "off"
                                        autoBusy = false
                                        return
                                    end
                                    task.wait(0.35)
                                    local vbd = readBoard()
                                    if vbd and boardHash(vbd) ~= hash then
                                        print("[Chess Hinter] auto played " .. toAlg(mvh[1], mvh[2], mvh[3], mvh[4], mvh[5]))
                                    else
                                        -- retry once, then skip this position but STAY ON
                                        task.wait(0.8)
                                        clickSquare(mvh[2], mvh[1], 0.35, p.grab)
                                        task.wait(0.25)
                                        clickSquare(mvh[4], mvh[3], 0.15, p.drop, 0.08)
                                        task.wait(0.35)
                                        local vbd2 = readBoard()
                                        if not (vbd2 and boardHash(vbd2) ~= hash) then
                                            print("[Chess Hinter] auto skipped " .. toAlg(mvh[1], mvh[2], mvh[3], mvh[4], mvh[5]) .. " (click missed); staying ON.")
                                        end
                                    end
                                end
                                autoState = "off"
                                autoBusy = false
                            end)
                        end
                    end
                else
                    local scored = iterativeSearch(bd, not myWhite, m.oppDepth, math.min(m.budget, 0.5))
                    if #scored > 0 then
                        local mv = scored[1].mv
                        predict = { mv = mv, alg = toAlg(mv[1], mv[2], mv[3], mv[4], mv[5]) }
                        paths = nil
                        local es = scored[1].score -- opponent's (side-to-move) perspective
                        evalWhite = myWhite and -es or es
                        win = winProb(evalWhite)
                        haveEval = true
                    else
                        -- opponent side has no legal move -> we won or draw
                        local oppLegal = genLegalMoves(bd, not myWhite)
                        if #oppLegal == 0 then
                            if inCheck(bd, not myWhite) then
                                mates = "win"
                                evalWhite = myWhite and 90000 or -90000
                            else
                                mates = "draw"
                                evalWhite = 0
                            end
                            win = winProb(evalWhite)
                            haveEval = true
                        else
                            mates = nil
                        end
                    end
                end
                end

                -- threats (both turns)
                thr = collectThreats(bd, myWhite)
                local tn, tk, th = threatSummary(bd, myWhite)
                thrSummary = { n = tn, kingAtk = tk, hang = th }
                inCheckNow = inCheck(bd, myWhite)
                if #thr > 0 and not thrExplained then
                    thrExplained = true
                    print("[Chess Hinter] PINK arrows = pieces the enemy can capture (danger, NOT move suggestions)")
                end

                -- log one line per changed position
                local st = boardHash(bd)
                if st ~= lastLoggedHash then
                    lastLoggedHash = st
                    local line = "[Chess Hinter] " .. (isMyTurn and "my turn" or "opp turn")
                    if isMyTurn and paths and paths[1] then
                        line = line .. " best " .. paths[1].alg .. string.format(" %+.1f", evalWhite / 100)
                    elseif predict then
                        line = line .. " predict " .. predict.alg
                    else
                        line = line .. " no legal move"
                    end
                    if thrSummary.n > 0 then line = line .. " | risk x" .. thrSummary.n end
                    if inCheckNow then line = line .. " | CHECK" end
                    print(line)
                end
            end
            task.wait(0.5)
        end
    end
end)

-- ---- renderer ------------------------------------------------------------
local renderConn
renderConn = RunService.RenderStepped:Connect(function(dt)
    if _G.__CHESS_GEN ~= MY_GEN then
        for i = 1, MAX_ARROWS do hideArrow(i) end
        for i = 1, MAX_THREAT_SLOTS do hideSet(threatSlots[i]) end
        hideSet(lastLine and {line=lastLine,h1=lastH1,h2=lastH2})
        hideSet(intentLine and {line=intentLine,h1=intentH1,h2=intentH2})
        hideBar()
        hidePanel()
        ring.Visible = false
        checkText.Visible = false
        resultText.Visible = false
        running = false
        renderConn:Disconnect()
        return
    end

    if not VISIBLE then
        for i = 1, MAX_ARROWS do hideArrow(i) end
        for i = 1, MAX_THREAT_SLOTS do hideSet(threatSlots[i]) end
        hideSet(lastLine and {line=lastLine,h1=lastH1,h2=lastH2})
        hideSet(intentLine and {line=intentLine,h1=intentH1,h2=intentH2})
        hideBar()
        hidePanel()
        ring.Visible = false
        checkText.Visible = false
        resultText.Visible = false
        return
    end

    -- hint arrows (hidden while autoplay is executing its own move)
    local shown = 0
    local plist = paths
    if plist and not autoIntent then
        for i = 1, #plist do
            local p = plist[i]
            if not (p and p.mv) then break end
            local mv = p.mv
            local fromS, fromVis = WorldToScreen(squarePos(mv[2], mv[1]) + Vector3.new(0, 0.6, 0))
            local toS, toVis = WorldToScreen(squarePos(mv[4], mv[3]) + Vector3.new(0, 0.6, 0))
            if fromVis and toVis and fromS and toS then
                shown = shown + 1
                local label = string.format("#%d %s %s  %+.1f", i, p.tier, p.alg, p.score / 100)
                setArrow(i, fromS, toS, label)
            end
        end
    elseif predict then
        local pr = predict
        if pr and pr.mv then
            local mv = pr.mv
            local fromS, fromVis = WorldToScreen(squarePos(mv[2], mv[1]) + Vector3.new(0, 0.6, 0))
            local toS, toVis = WorldToScreen(squarePos(mv[4], mv[3]) + Vector3.new(0, 0.6, 0))
            if fromVis and toVis and fromS and toS then
                shown = 1
                setArrow(1, fromS, toS, "opp: " .. pr.alg, Color3.fromRGB(255, 80, 80))
            end
        end
    end
    for i = shown + 1, MAX_ARROWS do hideArrow(i) end

    -- threat arrows (one per at-risk own piece)
    local nThreat = 0
    if showThreats then
        for i = 1, math.min(MAX_THREAT_SLOTS, #thr) do
            local t = thr[i]
            local fromS, fromVis = WorldToScreen(squarePos(t.af, t.ar) + Vector3.new(0, 0.7, 0))
            local toS, toVis = WorldToScreen(squarePos(t.tf, t.tr) + Vector3.new(0, 0.2, 0))
            if fromVis and toVis and fromS and toS then
                nThreat = nThreat + 1
                local slot = threatSlots[nThreat]
                drawArrowsInto(slot, fromS, toS)
                if t.defended then
                    slot.lbl.Visible = false
                else
                    slot.lbl.Text = "!"
                    slot.lbl.Position = Vector2.new((fromS.X + toS.X) / 2, (fromS.Y + toS.Y) / 2 - 24)
                    slot.lbl.Visible = true
                end
            end
        end
        for i = nThreat + 1, MAX_THREAT_SLOTS do hideSet(threatSlots[i]) end

        if thr[1] and (math.floor(tick() * 2) % 2 == 0) then
            local tq = thr[1]
            local s, vis = WorldToScreen(squarePos(tq.tf, tq.tr) + Vector3.new(0, 0.15, 0))
            local e1, e1v = WorldToScreen(squarePos(tq.tf + 0.5, tq.tr) + Vector3.new(0, 0.15, 0))
            if vis and e1v and s then
                local halfPx = math.abs(e1.X - s.X)
                ring.Position = Vector2.new(s.X - halfPx, s.Y - halfPx)
                ring.Size = Vector2.new(halfPx * 2, halfPx * 2)
                ring.Visible = true
            else
                ring.Visible = false
            end
        else
            ring.Visible = false
        end
    else
        for i = 1, MAX_THREAT_SLOTS do hideSet(threatSlots[i]) end
        ring.Visible = false
    end

    -- last move arrow
    if lastMove then
        local fromS, fromVis = WorldToScreen(squarePos(lastMove.fr, lastMove.ff) + Vector3.new(0, 0.6, 0))
        local toS, toVis = WorldToScreen(squarePos(lastMove.tr, lastMove.tf) + Vector3.new(0, 0.6, 0))
        if fromVis and toVis and fromS and toS then
            local e = { line = lastLine, h1 = lastH1, h2 = lastH2 }
            local ecol = lastMove.white == myWhite and Y or Color3.fromRGB(150, 150, 150)
            e.line.Color = ecol
            e.h1.Color = ecol
            e.h2.Color = ecol
            drawArrowsInto(e, fromS, toS)
        else
            hideSet({ line = lastLine, h1 = lastH1, h2 = lastH2 })
        end
    else
        hideSet({ line = lastLine, h1 = lastH1, h2 = lastH2 })
    end

    -- autoplay intent arrow
    if autoIntent then
        local mv = autoIntent
        local fromS, fromVis = WorldToScreen(squarePos(mv[2], mv[1]) + Vector3.new(0, 0.6, 0))
        local toS, toVis = WorldToScreen(squarePos(mv[4], mv[3]) + Vector3.new(0, 0.6, 0))
        if fromVis and toVis and fromS and toS then
            drawArrowsInto({ line = intentLine, h1 = intentH1, h2 = intentH2 }, fromS, toS)
        else
            hideSet({ line = intentLine, h1 = intentH1, h2 = intentH2 })
        end
    else
        hideSet({ line = intentLine, h1 = intentH1, h2 = intentH2 })
    end

    -- check / result warning
    local vp = viewport()
    if inCheckNow and (math.floor(tick() * 2) % 2 == 0) then
        checkText.Text = "CHECK!"
        checkText.Position = Vector2.new(vp.X / 2, vp.Y * 0.22)
        checkText.Visible = true
    else
        checkText.Visible = false
    end
    if mates then
        resultText.Text = mates == "win" and "CHECKMATE - YOU WIN" or (mates == "loss" and "CHECKMATE - YOU LOSE" or "STALEMATE")
        resultText.Position = Vector2.new(vp.X / 2, vp.Y * 0.16)
        resultText.Visible = true
    else
        resultText.Visible = false
    end

    -- win bar
    if haveEval then drawBar(win, evalWhite) else hideBar() end

    -- panel
    local pInfo = {
        depth = depthMode == "max" and "MAX (10)" or (depthMode == "deep" and "DEEP (6)" or "FAST (3)"),
        auto = "Auto:  " .. (autoPlay and "ON" or "OFF") .. "(" .. autoPace .. ")  [L]",
        threat = showThreats and "ON" or "OFF",
        status = "",
    }
    if myWhite == nil then
        pInfo.status = "detecting colour..."
    else
        local parts = {}
        if thrSummary.kingAtk > 0 then parts[#parts + 1] = "KING x" .. thrSummary.kingAtk end
        if thrSummary.hang > 0 then parts[#parts + 1] = "HANG x" .. thrSummary.hang end
        if thrSummary.n > 0 then parts[#parts + 1] = "RISK x" .. thrSummary.n end
        if #parts > 0 then
            pInfo.status = "!! " .. table.concat(parts, "  ")
        elseif inCheckNow then
            pInfo.status = "in check"
        elseif haveEval then
            local ownEval = myWhite and evalWhite or -evalWhite
            pInfo.status = string.format("eval %+.1f", ownEval / 100)
        else
            pInfo.status = "no game"
        end
    end
    drawPanel(pInfo)
end)

-- ---- input ---------------------------------------------------------------
task.spawn(function()
    local held = {}
    while running do
        if _G.__CHESS_GEN ~= MY_GEN then break end
        for _, k in ipairs({ {v=VK_P, name="P"}, {v=VK_O, name="O"}, {v=VK_BRACKET_R, name="]"}, {v=VK_L, name="L"}, {v=VK_K, name="K"}, {v=VK_M, name="M"} }) do
            local down = iskeypressed(k.v)
            if down and not held[k.v] then
                held[k.v] = true
                if k.v == VK_P then
                    VISIBLE = not VISIBLE
                    print("[Chess Hinter] Visibility:", VISIBLE)
                elseif k.v == VK_O or k.v == VK_BRACKET_R then
                    for i, mn in ipairs(MODE_ORDER) do
                        if mn == depthMode then
                            depthMode = MODE_ORDER[(i % #MODE_ORDER) + 1]
                            break
                        end
                    end
                    print("[Chess Hinter] Depth mode:", depthMode)
                elseif k.v == VK_L then
                    autoPlay = not autoPlay
                    autoKey = nil
                    print("[Chess Hinter] Autoplay:", autoPlay and "ON" or "OFF")
                elseif k.v == VK_K then
                    showThreats = not showThreats
                    print("[Chess Hinter] Threat warnings:", showThreats and "ON" or "OFF")
                elseif k.v == VK_M then
                    for i, pn in ipairs(PACE_ORDER) do
                        if pn == autoPace then
                            autoPace = PACE_ORDER[(i % #PACE_ORDER) + 1]
                            break
                        end
                    end
                    print("[Chess Hinter] Auto pace:", autoPace)
                end
            elseif not down then
                held[k.v] = false
            end
        end
        task.wait(0.08)
    end
end)

print("[Chess Hinter] Loaded v5.4")
print("[Chess Hinter] Keys: P hide | O/] depth (fast|deep|max) | L autoplay | K threats | M pace (" .. autoPace .. ")")