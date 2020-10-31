import nico
import ./colors
import options
import strformat

var buttonDown = false

var logCount = 0
var logMax = 1000

const winnercolor = red
const losercolor = blue

template llog(x: varargs[untyped]) =
  if logCount < logMax:
    echo logCount, ": ", x
    logCount.inc
    if logCount >= logMax:
      echo "STOPPING LOGGING"

var gridSize = 7
var gridCount = 19
# var votingTime: Slice[float] = 1.0 .. 5.0
var votingTime: Slice[float] = 0.1 .. 0.3
# var timeBetweenVoters: Slice[float] = 0.0 .. 1.5
var timeBetweenVoters: Slice[float] = 0.0 .. 0.1
# var voterSpeed: Slice[float] = 10.0 .. 15.0
var voterSpeed: Slice[float] = 30.0 .. 40.0
# var timeBetweenVoters: Slice[float] = 1000.0 .. 1000.5
var targetWinnerPct = 0.60
var totalVotes = 100
var patrolIdleTime = 0.2 .. 2.0
var patrolViewRadius = 3 * gridSize
var selectRadius = 2 * gridSize
var beltSpeed = 30.0
var tolerance_div = 10.0

const
  BallotWidth = 3
  BallotHeight = 3
  MachineWidth = 7
  MachineHeight = 7

type
  Point[T] = tuple
    x: T
    y: T
  Box[T] = tuple
    tl: Point[T]
    br: Point[T]

proc overlaps*[T](atl, abr, btl, bbr: Point[T]): bool =
  if abr.x < btl.x:
    # a is to the left of b
    result = false
  elif bbr.x < atl.x:
    # b is to the left of a
    result = false
  elif abr.y < btl.y:
    # a is above b
    result = false
  elif bbr.y < atl.y:
    # b is above a
    result = false
  else:
    result = true

proc overlaps*[T](b1: Box[T], b2: Box[T]): bool {.inline.} =
  overlaps(b1.tl, b1.br, b2.tl, b2.br)

proc unitDirection*(f: Point[float], t: Point[float]): Point[float] =
  let dx = t.x - f.x
  let dy = t.y - f.y
  let mag = sqrt(dx*dx + dy*dy)
  if mag == 0:
    return (0.0, 0.0)
  else:
    return (dx / mag, dy / mag)

proc distance*(f: Point[float], t: Point[float]): float =
  let dx = t.x - f.x
  let dy = t.y - f.y
  return sqrt(dx*dx + dy*dy)

proc toFloat*(p: Point[int]): Point[float] =
  (p.x.toFloat, p.y.toFloat)

proc grid(x: int): int =
  x * gridSize

proc grid(p: Point[int]): Point[int] =
  (p.x.grid, p.y.grid)

type
  Direction* = enum
    Up
    Right
    Down
    Left
  Facing* = enum
    faceDown
    faceLeft
    faceUp
    faceRight

  BoothVoterState = enum
    bvsIdle
    bvsComing
    bvsVoting
    bvsLeaving
    bvsDone
  Booth* = ref object
    x*: int
    y*: int
    voter*: Option[Creature]
    vote*: int
    voterState*: BoothVoterState
    stateSecondsLeft*: float32
    game: ref Game

  Creature* = object
    x*: float
    y*: float
    vx*: float
    vy*: float
    color*: int
    facing*: Facing
    blinkLeft*: float32
    speed*: float32
  
  Ballot* = object
    x*: float32
    y*: float32
    vote*: int
    index*: int
    flipped*: bool
  
  Belt* = object
    dir*: Direction
    tl*: Point[int]
    br*: Point[int]
    offset*: float32
    speed*: float32
  
  CountingMachine* = ref object
    x*: int
    y*: int
    game*: ref Game
    animOffset*: float32
    lastBallot: int
    broken: bool

  PatrolState = enum
    patrolIdle
    patrolWalk

  Patroller* = object
    creature: Creature
    state: PatrolState
    stateSecondsLeft: float
    waypointId: int
    waypoints: seq[Point[int]]

  SelectableKind = enum
    selNothing
    selBooth
    selBallot
    selCounter
    selPatroller
  Selectable = object
    distance: float32
    case kind*: SelectableKind
    of selNothing:
      discard
    of selBooth:
      booth: Booth
    of selBallot:
      ballot: Ballot
    of selCounter:
      countingMachine: CountingMachine
    of selPatroller:
      patroller: Patroller

  GameState = enum
    Voting
    GameOver
    Audit
  Game = object
    state: GameState
    player1: Creature
    player1_selected: Selectable
    player2: Creature
    creatures: seq[Creature]
    booths: seq[Booth]
    ballots: seq[Ballot]
    belts: seq[Belt]
    counters: seq[CountingMachine]
    patrollers: seq[Patroller]

    winnerVotes: int
    loserVotes: int
    true_votes: seq[int]
    counted_votes: seq[int]
    game_over_msg: string

    # audit
    pre_audit_winner: int
    target_ballot: int
    audit_s_value: float
    audit_tol_value: float
    audit_T_value: float
    audited_ballots: seq[int]

var game: ref Game


#--------------------------------------------------------------
# Creatures
#--------------------------------------------------------------

const
  CreatureHeight = 5

proc draw*(p: Creature) =
  # body
  setColor(p.color)
  boxfill(p.x, p.y, 3, 5)
  # eyes
  if p.blinkLeft == 0:
    setColor(if p.color in {white, peach, yellow}: dusk else: white)
    if p.facing in {faceDown, faceLeft}:
      # left eye
      pset(p.x, p.y)
    if p.facing in {faceDown, faceRight}:
      # right eye
      pset(p.x+2, p.y)

proc update*(c: var Creature, dt: float32) =
  if c.vy != 0.0:
    c.vy *= 0.75
    c.y += c.vy
    if abs(c.vy) < 0.1:
      c.vy = 0
    if c.vy > 0:
      c.facing = faceDown
    elif c.vy < 0:
      c.facing = faceUp
  if c.vx != 0.0:
    c.vx *= 0.75
    c.x += c.vx
    if abs(c.vx) < 0.1:
      c.vx = 0
    if c.vx > 0:
      c.facing = faceRight
    elif c.vx < 0:
      c.facing = faceLeft
  if c.blinkLeft > 0:
    c.blinkLeft -= min([dt, c.blinkLeft])
  else:
    if rnd(0, 2000) < 5:
      c.blinkLeft = rnd(0.1, 0.2)

proc hitbox*(c: Creature): Box[int] =
  ((c.x.int, c.y.int), (c.x.int+3-1, c.y.int+5-1))

proc center*(c: Creature): Point[float] =
  (c.x + 1.0, c.y + 2.0)

proc move*(game: ref Game, c: var Creature, amount: Point[float]) =
  c.x += amount.x
  c.y += amount.y

#--------------------------------------------------------------
# Ballot
#--------------------------------------------------------------

proc draw*(b: Ballot) =
  setColor(white)
  boxfill(b.x, b.y, 3, 1)

  if b.flipped:
    setColor(light_grey)
  else:
    if b.vote == 0:
      setColor(winnercolor)
    else:
      setColor(losercolor)
  boxfill(b.x, b.y + 1, 3, 2)

proc update*(b: Ballot, dt: float32) =
  discard

proc hitbox*(b: Ballot): Box[int] {.inline.} =
  ((b.x.int, b.y.int), (b.x.int+3-1, b.y.int+3-1))

proc move*(game: ref Game, b: var Ballot, amount: Point[float]) =
  b.x += amount.x
  b.y += amount.y

proc center*(b: Ballot): Point[float] =
  (b.x + 1.0, b.y + 1.0)

#--------------------------------------------------------------
# Voting booths
#--------------------------------------------------------------
const
  BoothHeight = 7
  BoothWidth = 7

proc drawBg*(booth: Booth) =
  # back
  setColor(dark_blue)
  boxfill(booth.x, booth.y, BoothWidth, BoothHeight+1)
  setColor(denim)
  vline(booth.x, booth.y, booth.y + BoothHeight)
  vline(booth.x + BoothWidth-1, booth.y, booth.y + BoothHeight)
  hline(booth.x, booth.y, booth.x + BoothWidth-1)

  # machine
  setColor(sea)
  hline(booth.x + 2, booth.y + 4, booth.x + BoothWidth - 3)
  vline(booth.x + 3, booth.y + 4, booth.y + BoothHeight)

  # curtain
  setColor(dusk)
  vline(booth.x + 5, booth.y + 1, booth.y + BoothHeight - 1)

proc drawFG*(booth: Booth) =
  if booth.voter.isSome:
    booth.voter.get().draw()
  if booth.voterState in {bvsVoting, bvsDone}:
    # curtain
    for x in 1..<(BoothWidth-1):
      if x mod 2 == 0:
        setColor(eggplant)
      else:
        setColor(dusk)
      vline(booth.x + x, booth.y+1, booth.y+1 + BoothHeight - 2)

proc hitbox*(booth: Booth): Box[int] =
  ((booth.x, booth.y), (booth.x + BoothWidth - 1, booth.y + BoothHeight))

proc center*(booth: Booth): Point[float] =
  (booth.x.toFloat + 3.0, booth.y.toFloat + 3.0)

proc update*(b: var Booth, dt: float32) =
  b.stateSecondsLeft -= min(b.stateSecondsLeft, dt)
  if b.voter.isSome():
    var voter = b.voter.get()
    voter.update(dt)
    b.voter = some(voter)

  case b.voterState
  of bvsIdle:
    if b.stateSecondsLeft == 0:
      if (game.winnerVotes + game.loserVotes) > 0:
        b.voterState = bvsComing
        b.voter = some(Creature(
          x: float(b.x + 2),
          y: float(screenHeight + 1),
          facing: faceUp,
          color: rnd(3, 15),
          speed: rnd(voterSpeed.a, voterSpeed.b),
        ))
        if game.winnerVotes > 0 and game.loserVotes > 0:
          b.vote = if rnd(0.0, 1.0) <= targetWinnerPct: 0 else: 1
          if b.vote == 0:
            game.winnerVotes.dec()
          else:
            game.loserVotes.dec()
        elif game.winnerVotes > 0:
          b.vote = 0
          game.winnerVotes.dec()
        elif game.loserVotes > 0:
          b.vote = 1
          game.loserVotes.dec()
      else:
        b.voterState = bvsDone
  of bvsComing:
    var voter = b.voter.get()
    voter.y -= dt * voter.speed
    if voter.y <= (b.y + 3):
      # just arrived in the booth
      b.voterState = bvsVoting
      b.stateSecondsLeft = rnd(votingTime.a, votingTime.b)
    b.voter = some(voter)
  of bvsVoting:
    if b.stateSecondsLeft == 0:
      b.game.ballots.add(Ballot(
        vote: b.vote,
        x: b.x.toFloat + 2,
        y: b.y.toFloat - 4,
      ))
      b.game.true_votes.add(b.vote)
      b.voterState = bvsLeaving
  of bvsLeaving:
    var voter = b.voter.get()
    voter.facing = faceDown
    voter.y += dt * voter.speed
    if voter.y > screenHeight:
      # just left the screen
      b.voterState = bvsIdle
      b.stateSecondsLeft = rnd(timeBetweenVoters.a, timeBetweenVoters.b)
    b.voter = some(voter)
  of bvsDone:
    discard

#-------------------------------------------------------------------
# Counting Machines
#-------------------------------------------------------------------
proc draw*(m: CountingMachine) =
  setColor(white)
  rectfill(m.x, m.y, m.x + MachineWidth - 1, m.y + MachineHeight - 1)
  # top
  if m.broken:
    setColor(dark_orange)
  else:
    setColor(light_grey)
  rectfill(m.x+1, m.y+1, m.x + MachineWidth - 2, m.y + 4)
  if m.lastBallot >= 0:
    # last ballot
    if m.lastBallot == 0:
      setColor(winnercolor)
    else:
      setColor(losercolor)
    rectfill(m.x+1, m.y+1, m.x + MachineWidth - 2, m.y + 4)

proc hitbox*(m: CountingMachine): Box[int] =
  ((m.x, m.y), (m.x + MachineWidth - 1, m.y + MachineHeight - 1))

proc nearBox*(m: CountingMachine): Box[int] =
  let hb = m.hitbox
  return ((hb.tl.x-2, hb.tl.y-2), (hb.br.x+2, hb.br.y+2))

proc center*(m: CountingMachine): Point[float] =
  (m.x.toFloat + 3.0, m.y.toFloat + 3.0)

proc update*(m: var CountingMachine, dt: float32) =
  m.animOffset -= min(m.animOffset, dt)
  if m.animOffset == 0:
    m.lastBallot = -1

proc canSee*[T](pat: Patroller, thing: T): bool

proc countBallot*(m: var CountingMachine, ballot: var Ballot) =
  var vote = ballot.vote
  if m.broken and ballot.vote != 1:
    vote = 1
    for p in m.game.patrollers:
      if p.canSee(ballot) or p.canSee(m):
        vote = ballot.vote
        m.broken = false
  m.lastBallot = vote
  m.game[].counted_votes.add(vote)
  m.animOffset = 1.0

proc breakBox*(m: var CountingMachine) =
  m.broken = true

proc fixBox*(m: var CountingMachine) =
  m.broken = false

#-------------------------------------------------------------------
# Patrollers
#-------------------------------------------------------------------
proc update*(pat: var Patroller, dt: float32) =
  pat.creature.update(dt)
  pat.stateSecondsLeft -= min(dt, pat.stateSecondsLeft)
  case pat.state
  of patrolIdle:
    if pat.stateSecondsLeft == 0 and pat.waypoints.len >= 2:
      pat.state = patrolWalk
  of patrolWalk:
    let target = pat.waypoints[pat.waypointId]
    let pos:Point[float] = (pat.creature.x, pat.creature.y)
    let dir = unitDirection(pos, target.toFloat)
    if dir == (0.0, 0.0):
      # already there
      pat.waypointId = (pat.waypointId + 1) mod pat.waypoints.len
      pat.state = patrolIdle
      pat.stateSecondsLeft = rnd(patrolIdleTime.a, patrolIdleTime.b)
      pat.creature.facing = rnd([faceDown, faceLeft, faceRight])
    else:
      # not there yet
      var amountx = dir.x * pat.creature.speed
      var amounty = dir.y * pat.creature.speed
      let dx = target.x.toFloat - pos.x
      let dy = target.y.toFloat - pos.y
      if abs(dx) < abs(amountx):
        amountx = dx
      if abs(dy) < abs(amounty):
        amounty = dy
      if abs(amountx) > abs(amounty):
        if amountx > 0:
          pat.creature.facing = faceRight
        else:
          pat.creature.facing = faceLeft
      else:
        if amounty < 0:
          pat.creature.facing = faceUp
        else:
          pat.creature.facing = faceDown
      pat.creature.x += amountx
      pat.creature.y += amounty

proc draw*(pat: Patroller) =
  when true:
    # draw view size
    setColor(black)
    circ(pat.creature.x + 1, pat.creature.y + 2, patrolViewRadius)
  pat.creature.draw()

proc center*(pat: Patroller): Point[float] {.inline.} =
  pat.creature.center()

proc canSee*[T](pat: Patroller, thing: T): bool =
  let distance = pat.center.distance(thing.center())
  result = distance <= patrolViewRadius

#-------------------------------------------------------------------
# Belts
#-------------------------------------------------------------------
proc update*(belt: var Belt, dt: float32) =
  belt.offset += belt.speed * dt
  if belt.offset > 3:
    belt.offset -= 3

proc draw*(belt: Belt) =
  setColor(charcoal)
  rectfill(belt.tl.x, belt.tl.y, belt.br.x, belt.br.y)
  setColor(dark_grey)
  case belt.dir:
  of Up:
    let height = abs(belt.br.y - belt.tl.y)
    for i in 0..<height:
      if (i + belt.offset.int) mod 3 == 0:
        hline(belt.tl.x, belt.tl.y + i, belt.br.x)
  of Down:
    let height = abs(belt.br.y - belt.tl.y)
    for i in 0..<height:
      if (i + belt.offset.int) mod 3 == 0:
        hline(belt.tl.x, belt.tl.y + height - i, belt.br.x)
  of Right:
    let width = abs(belt.br.x - belt.tl.x)
    for i in 0..<width:
      if (i + belt.offset.int) mod 3 == 0:
        vline(belt.tl.x + width - i, belt.tl.y, belt.br.y) 
  of Left:
    let width = abs(belt.br.x - belt.tl.x)
    for i in 0..<width:
      if (i + belt.offset.int) mod 3 == 0:
        vline(belt.tl.x + i, belt.tl.y, belt.br.y) 

proc hitbox*(b: Belt): Box[int] {.inline.} =
  (b.tl, b.br)

proc moveAmount*(belt: var Belt, hitbox: Box[int], dt: float): Point[float] =
  # echo "moveThing", $belt, $ballot
  if overlaps[int](belt.tl, belt.br, hitbox.tl, hitbox.br):
    case belt.dir:
    of Up:
      return (0.0, -belt.speed * dt)
    of Down:
      return (0.0, belt.speed * dt)
    of Left:
      return (-belt.speed * dt, 0.0)
    of Right:
      return (belt.speed * dt, 0.0)

proc moveThing*[T](game: ref Game, belt: var Belt, thing: var T, dt: float) =
  let amount = belt.moveAmount(thing.hitbox, dt)
  if amount.x != 0 or amount.y != 0:
    game.move(thing, amount)

#-------------------------------------------------------------------
# Game
#-------------------------------------------------------------------

proc selectIfNearer(game: ref Game, selectable: Selectable) =
  if selectable.distance > selectRadius:
    return
  if game.player1_selected.kind == selNothing or selectable.distance < game.player1_selected.distance:
    game.player1_selected = selectable

proc selectable(game: ref Game, booth: var Booth): Selectable =
  let d = distance(booth.center, game.player1.center)
  Selectable(distance: d, kind: selBooth, booth: booth)

proc selectable(game: ref Game, countingMachine: var CountingMachine): Selectable =
  let d = distance(countingMachine.center, game.player1.center)
  Selectable(distance: d, kind: selCounter, countingMachine: countingMachine)

proc selectable(game: ref Game, ballot: var Ballot): Selectable =
  let d = distance(ballot.center, game.player1.center)
  Selectable(distance: d, kind: selBallot, ballot: ballot)

proc game_over*(game: ref Game, msg: string = "") =
  game.state = GameOver
  game.game_over_msg = msg

proc nextAuditBallot*(game: ref Game) =
  game.target_ballot = rnd(0, game.ballots.len-1)

proc update*(game: ref Game, dt: float) =
  game.player1_selected = Selectable(kind: selNothing)
  case game.state
  of GameOver:
    discard
  of Voting:
    for b in game.belts.mitems:
      b.update(dt)
      game.moveThing(b, game.player1, dt)
    for c in game.creatures.mitems:
      c.update(dt)
    for booth in game.booths.mitems:
      booth.update(dt)
      # game.selectIfNearer(game.selectable(booth))
    var tokeep: seq[Ballot]
    for ballot in game.ballots.mitems:
      var keep = true
      ballot.update(dt)
      for belt in game.belts.mitems:
        game.moveThing(belt, ballot, dt)
      for machine in game.counters.mitems:
        if overlaps(machine.hitbox, ballot.hitbox):
          machine.countBallot(ballot)
          keep = false
      if keep:
        # game.selectIfNearer(game.selectable(ballot))
        tokeep.add(ballot)
    for machine in game.counters.mitems:
      machine.update(dt)
      game.selectIfNearer(game.selectable(machine))
    for p in game.patrollers.mitems:
      p.update(dt)
    game.ballots = tokeep
    game.player1.update(dt)
    if game.counted_votes.len == totalVotes:
      # Start the audit
      game.state = Audit
      var counted_votes0 = 0
      var counted_votes1 = 0
      for v in game.counted_votes:
        if v == 0:
          counted_votes0.inc
        elif v == 1:
          counted_votes1.inc
      var winner_votes = 0
      if counted_votes0 == counted_votes1:
        game.game_over("It's a tie!")
        return
      elif counted_votes0 > counted_votes1:
        game.pre_audit_winner = 0
        winner_votes = counted_votes0
      else:
        game.pre_audit_winner = 1
        winner_votes = counted_votes1
      game.audit_s_value = winner_votes.toFloat / game.counted_votes.len.toFloat
      game.audit_tol_value = (game.audit_s_value - 0.50) / tolerance_div
      for i,v in game.true_votes:
        let col = i mod gridCount
        let row = 4 + i div gridCount
        game.ballots.add Ballot(
          vote: v,
          x: col.grid.toFloat + 2,
          y: row.grid.toFloat + 2,
          flipped: true,
          index: i,
        )
        game.nextAuditBallot()
  of Audit:
    game.player1.update(dt)
    for ballot in game.ballots.mitems:
      game.selectIfNearer(game.selectable(ballot))

proc draw*(game: ref Game) =
  setColor(blue)
  case game.player1_selected.kind
  of selBooth:
    let hb = game.player1_selected.booth.hitbox
    rectfill(hb.tl.x-1, hb.tl.y-1, hb.br.x+1, hb.br.y+1)
  of selCounter:
    let hb = game.player1_selected.countingMachine.hitbox
    rectfill(hb.tl.x-1, hb.tl.y-1, hb.br.x+1, hb.br.y+1)
  of selBallot:
    setColor(yellow)
    let hb = game.player1_selected.ballot.hitbox
    rectfill(hb.tl.x-1, hb.tl.y-1, hb.br.x+1, hb.br.y+1)
  else:
    discard
  if game.state in {GameOver, Voting}:
    for b in game.belts:
      b.draw()
  case game.state
  of GameOver, Voting:
    # selection box
    for b in game.booths:
      b.drawBg()
    for b in game.ballots:
      b.draw()
    for m in game.counters:
      m.draw()
    for c in game.creatures:
      c.draw()
    for p in game.patrollers:
      p.draw()
    for b in game.booths:
      b.drawFg()
    if game.state == GameOver:
      setColor(red)
      let msg = if game.game_over_msg != "": game.game_over_msg else: "GAME OVER"
      printc(msg, screenWidth div 2, screenHeight div 2 - 7)
  of Audit:
    setColor(white)
    print("Audit time!", 0, 0)
    print("Get ballot " & $(game.target_ballot + 1), 0, 7)
    for b in game.ballots:
      b.draw()
    if game.player1_selected.kind == selBallot:
      setColor(white)
      print($(game.player1_selected.ballot.index+1), 0, 14)
    setColor(light_grey)
    proc nfloat(x: float): string =
      fmt"{x:2.3f}"
    printr("s = " & nfloat(game.audit_s_value), screenWidth, 0)
    printr("t = " & nfloat(game.audit_tol_value), screenWidth, 7)
    var s = game.audit_s_value
    var t = game.audit_tol_value
    # Step 1
    var tval = 1.0
    for i,b in game.audited_ballots:
      let ballot = game.ballots[b]
      if ballot.vote == game.pre_audit_winner:
        # Step 4
        llog "vote for winner"
        llog "b: ", $tval
        llog "(s - t)", $(s - t)
        llog " / 0.50", $((s - t) / 0.50)
        tval = tval * (s - t) / 0.50
        llog "tval: ", $tval
      else:
        # Step 5
        llog "vote not for winner"
        llog "b: ", $tval
        llog "(1 - (s - t))", $(1 - (s - t))
        llog " / 0.50", $((1 - (s - t)) / 0.50)
        tval = tval * (1 - (s - t)) / 0.50
        llog "tval: ", $tval
    # llog "tval: ", $tval
    # llog "nfloat: ", nfloat(tval)
    printr("T = " & nfloat(tval), screenWidth, 14)
    if tval > 9.9:
      if game.pre_audit_winner == 1:
        setColor(blue)
        printc("You successfully stole the election!", screenWidth div 2, screenHeight div 2)
      else:
        setColor(red)
        printc("Audit says you lost!", screenWidth div 2, screenHeight div 2)
    elif tval < 0.011:
      setColor(red)
      printc("Audit caught you!", screenWidth div 2, screenHeight div 2)
  game.player1.draw()

proc gameInit() =
  loadFont(0, "font.png")
  setPalette loadPalettePico8Extra()
  new(game)
  game.player1 = Creature(color: losercolor, speed: 20)
  game.player2 = Creature(color: orange, speed: 20)
  game.creatures = newSeq[Creature]()
  game.booths = newSeq[Booth]()
  game.ballots = newSeq[Ballot]()
  game.belts = newSeq[Belt]()
  game.counters = newSeq[CountingMachine]()
  game.patrollers = newSeq[Patroller]()
  game.true_votes = newSeq[int]()
  game.counted_votes = newSeq[int]()
  game.winnerVotes = (totalVotes.toFloat * targetWinnerPct).toInt
  game.loserVotes = totalVotes - game.winnerVotes
  
  proc boothAt(game: ref Game, x, y: int, belt_y: int) =
    game.booths.add Booth(
      x: x,
      y: y,
      game: game
    )
    game.belts.add Belt(
      dir: Up,
      tl: (x+1, belt_y),
      br: (x + 5, y),
      speed: beltSpeed,
    )
    game.counters.add CountingMachine(
      x: x,
      y: belt_y - MachineHeight,
      lastBallot: -1,
      game: game,
    )

  let booth_y = screenHeight - 1 - CreatureHeight - CreatureHeight
  game.boothAt(1.grid, screenHeight - 2.grid, 5.grid)
  game.boothAt(3.grid, screenHeight - 3.grid, 7.grid)
  game.boothAt(6.grid, screenHeight - 6.grid, 6.grid)
  game.boothAt(70, booth_y - 30, screenHeight div 2 - 10)
  game.boothAt(90, booth_y - 5, screenHeight div 2 + 15)
  game.boothAt(110, booth_y - 17, screenHeight div 2 - 12)

  game.patrollers.add Patroller(
    creature: Creature(
      color: dark_purple,
      speed: 0.3,
      x: 1.grid.toFloat,
      y: 1.grid.toFloat,
    ),
    waypoints: @[
      (0.grid + 2, 3.grid + 1),
      (2.grid + 2, 3.grid + 1),
      (4.grid + 2, 5.grid + 1),
      (6.grid + 2, 3.grid + 1),
    ]
  )


proc gameUpdate(dt: float32) =
  buttonDown = btn(pcA)
  if btnp(pcA):
    case game.state
    of GameOver:
      gameInit()
      return
    of Voting:
      case game.player1_selected.kind
      of selCounter:
        var m = game.player1_selected.countingMachine
        for patroller in game.patrollers:
          if patroller.canSee(m):
            echo "patroller can see"
            game.game_over("You were caught!")
          else:
            echo "pateroller didn't see"
        if m.broken:
          m.fixBox()
        else:
          m.breakBox()
      else:
        discard
    of Audit:
      case game.player1_selected.kind
      of selBallot:
        var ballot = game.player1_selected.ballot
        ballot = game.ballots[ballot.index]
        ballot.flipped = false
        game.ballots[ballot.index] = ballot
        echo "adding audited ballot: ", $ballot.index
        game.audited_ballots.add ballot.index
        game.nextAuditBallot()
      else:
        discard
        
  if btn(pcLeft):
    game.player1.vx -= game.player1.speed * dt
  if btn(pcRight):
    game.player1.vx += game.player1.speed * dt
  if btn(pcUp):
    game.player1.vy -= game.player1.speed * dt
  if btn(pcDown):
    game.player1.vy += game.player1.speed * dt
  game.update(dt)

proc gameDraw() =
  cls()
  setColor(midnight)
  boxfill(0, 0, screenWidth, screenHeight)
  for x in 0..(screenWidth div gridSize):
    for y in 0..(screenHeight div gridSize):
      if (x+y) mod 2 == 0:
        setColor(dark_blue)
        setColor(black)
        boxfill(x.grid, y.grid, gridSize, gridSize)
  
  var true_votes0 = 0
  var true_votes1 = 0
  for v in game.true_votes:
    if v == 0:
      true_votes0.inc
    elif v == 1:
      true_votes1.inc

  var counted_votes0 = 0
  var counted_votes1 = 0
  for v in game.counted_votes:
    if v == 0:
      counted_votes0.inc
    elif v == 1:
      counted_votes1.inc

  # Votes for true winner
  setColor(dark_grey)
  printr($true_votes0, screenWidth div 2 - 2, 1)
  setColor(winnercolor)
  printr($counted_votes0, screenWidth div 2 - 2, 8)

  # Votes for true loser
  setColor(dark_grey)
  print($true_votes1, screenWidth div 2 + 4, 1)
  setColor(losercolor)
  print($counted_votes1, screenWidth div 2 + 4, 8)

  game.draw()

nico.init("myOrg", "myApp")
nico.createWindow("myApp", gridSize * gridCount, gridSize * gridCount, 4, false)
nico.run(gameInit, gameUpdate, gameDraw)
