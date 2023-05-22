import GameServer.EnvExtensions

open Lean Meta Elab Command

set_option autoImplicit false

/-! # Game metadata -/

/-- Switch to the specified `Game` (and create it if non-existent). Example: `Game "NNG"` -/
elab "Game" n:str : command => do
  let name := n.getString
  setCurGameId name
  if (← getGame? name).isNone then
    insertGame name {name}

/-- Create a new world in the active game. Example: `World "Addition"` -/
elab "World" n:str : command => do
  let name := n.getString
  setCurWorldId name
  if ¬ (← getCurGame).worlds.nodes.contains name then
    addWorld {name}

/-- Define the current level number. Levels inside a world must be
numbered consecutive starting with `1`. Example: `Level 1` -/
elab "Level" level:num : command => do
  let level := level.getNat
  setCurLevelIdx level
  addLevel {index := level}

/-- Define the title of the current game/world/level. -/
elab "Title" t:str : command => do
  match ← getCurLayer with
  | .Level => modifyCurLevel fun level => pure {level with title := t.getString}
  | .World => modifyCurWorld  fun world => pure {world with title := t.getString}
  | .Game => modifyCurGame  fun game => pure {game with title := t.getString}

/-- Define the introduction of the current game/world/level. -/
elab "Introduction" t:str : command => do
  match ← getCurLayer with
  | .Level => modifyCurLevel fun level => pure {level with introduction := t.getString}
  | .World => modifyCurWorld  fun world => pure {world with introduction := t.getString}
  | .Game => modifyCurGame  fun game => pure {game with introduction := t.getString}

/-- Define the conclusion of the current game or current level if some
building a level. -/
elab "Conclusion" t:str : command => do
  match ← getCurLayer with
  | .Level => modifyCurLevel fun level => pure {level with conclusion := t.getString}
  | .World => modifyCurWorld  fun world => pure {world with conclusion := t.getString}
  | .Game => modifyCurGame  fun game => pure {game with conclusion := t.getString}

/-! ## World Paths -/

/-- The worlds of a game are joint by paths. These are defined with the syntax
`Path World₁ → World₂ → World₃`. -/
def Parser.path := Parser.sepBy1Indent Parser.ident "→"

/-- The worlds of a game are joint by paths. These are defined with the syntax
`Path World₁ → World₂ → World₃`. -/
elab "Path" s:Parser.path : command => do
  let mut last : Option Name := none
  for stx in s.raw.getArgs.getEvenElems do
    let some l := last
      | do
          last := some stx.getId
          continue
    modifyCurGame fun game =>
      pure {game with worlds := {game.worlds with edges := game.worlds.edges.push (l, stx.getId)}}
    last := some stx.getId



/-! # Inventory

The inventory contains docs for tactics, lemmas, and definitions. These are all locked
in the first level and get enabled during the game.
-/

/-! ## Doc entries -/

/-- Checks if `inventoryKeyExt` contains an entry with `(type, name)` and yields
a warning otherwise. If `template` is provided, it will add such an entry instead of yielding a
warning. -/
def checkInventoryDoc (type : InventoryType) (name : Ident)
    (template : Option String := none) : CommandElabM Unit := do
  -- note: `name` is an `Ident` (instead of `Name`) for the log messages.
  let env ← getEnv
  let n := name.getId
  -- Find a key with matching `(type, name)`.
  match (inventoryKeyExt.getState env).findIdx?
    (fun x => x.name == n && x.type == type) with
  -- Nothing to do if the entry exists
  | some _ => pure ()
  | none =>
    match template with
    -- Warn about missing documentation
    | none =>
      -- We just add a dummy entry
      modifyEnv (inventoryKeyExt.addEntry · {
        type := type
        name := name.getId
        category := if type == .Lemma then s!"{n.getPrefix}" else "" })
      logWarningAt name (m!"Missing {type} Documentation: {name}\nAdd `{type}Doc {name}` " ++
        m!"somewhere above this statement.")
    -- Add the default documentation
    | some s =>
      modifyEnv (inventoryKeyExt.addEntry · {
        type := type
        name := name.getId
        category := if type == .Lemma then s!"{n.getPrefix}" else ""
        content := s })
      logInfoAt name (m!"Missing {type} Documentation: {name}, used provided default (e.g. " ++
      m!"statement description) instead. If you want to write your own description, add " ++
      m!"`{type}Doc {name}` somewhere above this statement.")

/-- Documentation entry of a tactic. Example:

```
TacticDoc rw "`rw` stands for rewrite, etc. "
```

* The identifier is the tactics name. Some need to be escaped like `«have»`.
* The description is a string supporting Markdown.
 -/
elab "TacticDoc" name:ident content:str : command =>
  modifyEnv (inventoryKeyExt.addEntry · {
    type := .Tactic
    name := name.getId
    displayName := name.getId.toString
    content := content.getString })

/-- Documentation entry of a lemma. Example:

```
LemmaDoc Nat.succ_pos as "succ_pos" in "Nat" "says `0 < n.succ`, etc."
```

* The first identifier is used in the commands `[New/Only/Disabled]Lemma`.
  It is preferably the true name of the lemma. However, this is not required.
* The string following `as` is the displayed name (in the Inventory).
* The identifier after `in` is the category to group lemmas by (in the Inventory).
* The description is a string supporting Markdown.
 -/
elab "LemmaDoc" name:ident "as" displayName:str "in" category:str content:str : command =>
  modifyEnv (inventoryKeyExt.addEntry · {
    type := .Lemma
    name := name.getId
    category := category.getString
    displayName := displayName.getString
    content := content.getString })
-- TODO: Catch the following behaviour.
-- 1. if `LemmaDoc` appears in the same file as `Statement`, it will silently use
-- it but display the info that it wasn't found in `Statement`
-- 2. if it appears in a later file, however, it will silently not do anything and keep
-- the first one.


/-- Documentation entry of a definition. Example:

```
DefinitionDoc Function.Bijective as "Bijective" "defined as `Injective f ∧ Surjective`, etc."
```

* The first identifier is used in the commands `[New/Only/Disabled]Definition`.
  It is preferably the true name of the definition. However, this is not required.
* The string following `as` is the displayed name (in the Inventory).
* The description is a string supporting Markdown.
 -/
elab "DefinitionDoc" name:ident "as" displayName:str template:str : command =>
  modifyEnv (inventoryKeyExt.addEntry · {
    type := .Definition
    name := name.getId,
    displayName := displayName.getString,
    content := template.getString })

/-! ## Add inventory items -/

-- namespace Lean.PrettyPrinter
-- def ppSignature' (c : Name) : MetaM String := do
--   let decl ← getConstInfo c
--   let e := .const c (decl.levelParams.map mkLevelParam)
--   let (stx, _) ← delabCore e (delab := Delaborator.delabConstWithSignature)
--   let f ← ppTerm stx
--   return toString f
-- end Lean.PrettyPrinter

def getStatement (name : Name) : CommandElabM MessageData := do
  -- let c := name.getId

  let decl ← getConstInfo name
  -- -- TODO: How to go between CommandElabM and MetaM

  -- addCompletionInfo <| .id name c (danglingDot := false) {} none
  return ← addMessageContextPartial (.ofPPFormat { pp := fun
    | some ctx => ctx.runMetaM <| ppExpr decl.type
    -- PrettyPrinter.ppSignature' c
    -- PrettyPrinter.ppSignature c
    | none     => return "that's a bug." })

-- Note: We use `String` because we can't send `MessageData` as json, but
-- `MessageData` might be better for interactive highlighting.
/-- Get a string of the form `my_lemma (n : ℕ) : n + n = 2 * n`. -/
def getStatementString (name : Name) : CommandElabM String := do
  try
    return ← (← getStatement name).toString
  catch
  | _ => throwError m!"Could not find {name} in context."
  -- TODO: I think it would be nicer to unresolve Namespaces as much as possible.

/-- Declare tactics that are introduced by this level. -/
elab "NewTactic" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Tactic name -- TODO: Add (template := "[docstring]")
  modifyCurLevel fun level => pure {level with
    tactics := {level.tactics with new := args.map (·.getId)}}

/-- Declare lemmas that are introduced by this level. -/
elab "NewLemma" args:ident* : command => do
  for name in ↑args do
    checkInventoryDoc .Lemma name -- TODO: Add (template := "[mathlib]")
  modifyCurLevel fun level => pure {level with
    lemmas := {level.lemmas with new := args.map (·.getId)}}

/-- Declare definitions that are introduced by this level. -/
elab "NewDefinition" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Definition name -- TODO: Add (template := "[mathlib]")
  modifyCurLevel fun level => pure {level with
    definitions := {level.definitions with new := args.map (·.getId)}}

/-- Declare tactics that are temporarily disabled in this level.
This is ignored if `OnlyTactic` is set. -/
elab "DisabledTactic" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Tactic name
  modifyCurLevel fun level => pure {level with
    tactics := {level.tactics with disabled := args.map (·.getId)}}

/-- Declare lemmas that are temporarily disabled in this level.
This is ignored if `OnlyLemma` is set. -/
elab "DisabledLemma" args:ident* : command => do
  for name in ↑args  do checkInventoryDoc .Lemma name
  modifyCurLevel fun level => pure {level with
    lemmas := {level.lemmas with disabled := args.map (·.getId)}}

/-- Declare definitions that are temporarily disabled in this level -/
elab "DisabledDefinition" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Definition name
  modifyCurLevel fun level => pure {level with
    definitions := {level.definitions with disabled := args.map (·.getId)}}

/-- Temporarily disable all tactics except the ones declared here -/
elab "OnlyTactic" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Tactic name
  modifyCurLevel fun level => pure {level with
    tactics := {level.tactics with only := args.map (·.getId)}}

/-- Temporarily disable all lemmas except the ones declared here -/
elab "OnlyLemma" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Lemma name
  modifyCurLevel fun level => pure {level with
    lemmas := {level.lemmas with only := args.map (·.getId)}}

/-- Temporarily disable all definitions except the ones declared here.
This is ignored if `OnlyDefinition` is set. -/
elab "OnlyDefinition" args:ident* : command => do
  for name in ↑args do checkInventoryDoc .Definition name
  modifyCurLevel fun level => pure {level with
    definitions := {level.definitions with only := args.map (·.getId)}}

/-- Define which tab of Lemmas is opened by default. Usage: `LemmaTab "Nat"`.
If omitted, the current tab will remain open. -/
elab "LemmaTab"  category:str : command =>
  modifyCurLevel fun level => pure {level with lemmaTab := category.getString}

/-! # Exercise Statement -/

/-- A `attr := ...` option for `Statement`. Add attributes to the defined theorem. -/
syntax statementAttr := "(" &"attr" ":=" Parser.Term.attrInstance,* ")"
-- TODO

/-- Define the statement of the current level. -/
elab "Statement" statementName:ident ? descr:str ? sig:declSig val:declVal : command => do
  let lvlIdx ← getCurLevelIdx

  let descr := match descr with
    | none => none
    | some s => s.getString

  -- Save the messages before evaluation of the proof.
  let initMsgs ← modifyGet fun st => (st.messages, { st with messages := {} })

  -- The default name of the statement is `[Game].[World].level[no.]`, e.g. `NNG.Addition.level1`
  -- However, this should not be used when designing the game.
  let defaultDeclName : Ident := mkIdent <| (← getCurGame).name ++ (← getCurWorld).name ++
    ("level" ++ toString lvlIdx : String)

  -- Add theorem to context.
  match statementName with
  | some name =>
    let env ← getEnv
    if env.contains name.getId then
      let origType := (env.constants.map₁.find! name.getId).type
      -- TODO: Check if `origType` agrees with `sig` and output `logInfo` instead of `logWarning`
      -- in that case.
      logWarningAt name (m!"Environment already contains {name.getId}! Only the existing " ++
      m!"statement will be available in later levels:\n\n{origType}")
      let thmStatement ← `(theorem $defaultDeclName $sig $val)
      elabCommand thmStatement
      -- Check that statement has a docs entry.
      checkInventoryDoc .Lemma name (template := descr)

    else
      let thmStatement ← `( theorem $name $sig $val)
      elabCommand thmStatement
      -- Check that statement has a docs entry.
      checkInventoryDoc .Lemma name (template := descr)

  | none =>
    let thmStatement ← `(theorem $defaultDeclName $sig $val)
    elabCommand thmStatement

  let msgs := (← get).messages

  let mut hints := #[]
  let mut nonHintMsgs := #[]
  for msg in msgs.msgs do
    -- Look for messages produced by the `Hint` tactic. They are used to pass information about the
    -- intermediate goal state
    if let MessageData.withNamingContext _ $ MessageData.withContext ctx $
        .tagged `Hint $
        .nest strict $
        .nest hidden $
        .compose (.ofGoal text) (.ofGoal goal) := msg.data then
      let hint ← liftTermElabM $ withMCtx ctx.mctx $ withLCtx ctx.lctx #[] $ withEnv ctx.env do
        return {
          goal := ← abstractCtx goal
          text := ← instantiateMVars (mkMVar text)
          strict := strict == 1
          hidden := hidden == 1
        }
      hints := hints.push hint
    else
      nonHintMsgs := nonHintMsgs.push msg

  -- restore saved messages and non-hint messages
  modify fun st => { st with
    messages := initMsgs ++ ⟨nonHintMsgs.toPArray'⟩
  }

  let scope ← getScope
  let env ← getEnv

  let st ← match statementName with
  | some name => getStatementString name.getId
  | none =>  getStatementString defaultDeclName.getId -- TODO: We dont want the internal lemma name here

  let head := match statementName with
  | some name => Format.join ["theorem ", name.getId.toString]
  | none => "example"

  modifyCurLevel fun level => pure { level with
    module := env.header.mainModule
    goal := sig,
    scope := scope,
    descrText := descr
    statementName := match statementName with
    | none => default
    | some name => name.getId
    descrFormat := (Format.join [head, " ", st, " := by"]).pretty 10
    hints := hints }

/-! # Hints -/

syntax hintArg := atomic(" (" (&"strict" <|> &"hidden") " := " withoutPosition(term) ")")

/-- Remove any spaces at the beginning of a new line -/
partial def removeIndentation (s : String) : String :=
  let rec loop (i : String.Pos) (acc : String) (removeSpaces := false) : String :=
    let c := s.get i
    let i := s.next i
    if s.atEnd i then
      acc.push c
    else if removeSpaces && c == ' ' then
      loop i acc (removeSpaces := true)
    else if c == '\n' then
      loop i (acc.push c) (removeSpaces := true)
    else
      loop i (acc.push c)
  loop ⟨0⟩ ""

/-- A tactic that can be used inside `Statement`s to indicate in which proof states players should
see hints. The tactic does not affect the goal state.
-/
elab "Hint" args:hintArg* msg:interpolatedStr(term) : tactic => do
  let mut strict := false
  let mut hidden := false

  -- remove spaces at the beginngng of new lines
  let msg := TSyntax.mk $ msg.raw.setArgs $ ← msg.raw.getArgs.mapM fun m => do
    match m with
    | Syntax.node info k args =>
      if k == interpolatedStrLitKind && args.size == 1 then
        match args.get! 0 with
        | (Syntax.atom info' val) =>
          let val := removeIndentation val
          return Syntax.node info k #[Syntax.atom info' val]
        | _ => return m
      else
        return m
    | _ => return m

  for arg in args do
    match arg with
    | `(hintArg| (strict := true)) => strict := true
    | `(hintArg| (strict := false)) => strict := false
    | `(hintArg| (hidden := true)) => hidden := true
    | `(hintArg| (hidden := false)) => hidden := false
    | _ => throwUnsupportedSyntax

  let goal ← Tactic.getMainGoal
  goal.withContext do
    -- We construct an expression that can produce the hint text. The difficulty is that we
    -- want the text to possibly contain quotation of the local variables which might have been
    -- named differently by the player.
    let varsName := `vars
    let text ← withLocalDeclD varsName (mkApp (mkConst ``Array [levelZero]) (mkConst ``Expr)) fun vars => do
      let mut text ← `(m! $msg)
      let goalDecl ← goal.getDecl
      let decls := goalDecl.lctx.decls.toArray.filterMap id
      for i in [:decls.size] do
        text ← `(let $(mkIdent decls[i]!.userName) := $(mkIdent varsName)[$(quote i)]!; $text)
      return ← mkLambdaFVars #[vars] $ ← Term.elabTermAndSynthesize text none
    let textmvar ← mkFreshExprMVar none
    guard $ ← isDefEq textmvar text -- Store the text in a mvar.
    -- The information about the hint is logged as a message using `logInfo` to transfer it to the
    -- `Statement` command:
    logInfo $
      .tagged `Hint $
      .nest (if strict then 1 else 0) $
      .nest (if hidden then 1 else 0) $
      .compose (.ofGoal textmvar.mvarId!) (.ofGoal goal)

/-- This tactic allows us to execute an alternative sequence of tactics, but without affecting the
proof state. We use it to define Hints for alternative proof methods or dead ends. -/
elab "Branch" t:tacticSeq : tactic => do
  let b ← saveState
  Tactic.evalTactic t

  -- Show an info whether the branch proofs all remaining goals.
  let gs ← Tactic.getUnsolvedGoals
  if gs.isEmpty then
    logInfo "This branch finishes the proof."
  else
    logInfo "This branch leaves open goals."

  let msgs ← Core.getMessageLog
  b.restore
  Core.setMessageLog msgs



/-- The tactic block inside `Template` will be copied into the users editor.
Use `Hole` inside the template for a part of the proof that should be replaced
with `sorry`. -/
elab "Template" t:tacticSeq : tactic => do
  --let b ← saveState
  Tactic.evalTactic t

  -- -- Not correct
  -- let gs ← Tactic.getUnsolvedGoals
  -- if ¬ gs.isEmpty then
  --   logWarning "To work as intended, `Template` should contain the entire proof"


  -- -- Show an info whether the branch proofs all remaining goals.
  -- let gs ← Tactic.getUnsolvedGoals
  -- if gs.isEmpty then
  --   logInfo "This branch finishes the proof."
  -- else
  --   logInfo "This branch leaves open goals."

  -- let msgs ← Core.getMessageLog
  -- b.restore
  -- Core.setMessageLog msgs


/-- A hole inside a template proof that will be replaced by `sorry`. -/
elab "Hole" t:tacticSeq : tactic => do
  Tactic.evalTactic t





/-! # Make Game -/

def GameLevel.getInventory (level : GameLevel) : InventoryType → InventoryInfo
| .Tactic => level.tactics
| .Definition => level.definitions
| .Lemma => level.lemmas

def GameLevel.setComputedInventory (level : GameLevel) :
    InventoryType → Array ComputedInventoryItem → GameLevel
| .Tactic, v =>     {level with tactics     := {level.tactics     with computed := v}}
| .Definition, v => {level with definitions := {level.definitions with computed := v}}
| .Lemma, v =>      {level with lemmas      := {level.lemmas      with computed := v}}

/-- Build the game. This command will precompute various things about the game, such as which
tactics are available in each level etc. -/
elab "MakeGame" : command => do
  let game ← getCurGame

  -- Check for loops in world graph
  if game.worlds.hasLoops then
    throwError "World graph must not contain loops! Check your `Path` declarations."

  -- Now create The doc entries from the templates
  for item in inventoryKeyExt.getState (← getEnv) do
    -- TODO: Add information about inventory items
    let name := item.name
    match item.type with
    | .Lemma =>
      modifyEnv (inventoryExt.addEntry · { item with
        -- Add the lemma statement to the doc.
        statement := (← getStatementString name)
      })
    | _ =>
      modifyEnv (inventoryExt.addEntry · {
        item with
      })

  -- Compute which inventory items are available in which level:
  for inventoryType in #[.Tactic, .Definition, .Lemma] do
    let mut newItemsInWorld : HashMap Name (HashSet Name) := {}
    let mut lemmaStatements : HashMap (Name × Nat) Name := {}
    let mut allItems : HashSet Name := {}
    for (worldId, world) in game.worlds.nodes.toArray do
      let mut newItems : HashSet Name := {}
      for (levelId, level) in world.levels.toArray do
        let newLemmas := (level.getInventory inventoryType).new
        newItems := newItems.insertMany newLemmas
        allItems := allItems.insertMany newLemmas
        if inventoryType == .Lemma then
          -- For levels `2, 3, …` we check if the previous level was named
          -- in which case we add it as available lemma.
          match levelId with
          | 0 => pure ()
          | 1 => pure () -- level ids start with 1, so we need to skip 1, too.
          | i₀ + 1 =>
            -- add named statement from previous level to the available lemmas.
            match (world.levels.find! (i₀)).statementName with
            | .anonymous => pure ()
            | .num _ _ => panic "Did not expect to get a numerical statement name!"
            | .str pre s =>
              let name := Name.str pre s
              newItems := newItems.insert name
              allItems := allItems.insert name
              lemmaStatements := lemmaStatements.insert (worldId, levelId) name
      if inventoryType == .Lemma then
        -- if named, add the lemma from the last level of the world to the inventory
        let i₀ := world.levels.size
        match (world.levels.find! (i₀)).statementName with
        | .anonymous => pure ()
        | .num _ _ => panic "Did not expect to get a numerical statement name!"
        | .str pre s =>
          let name := Name.str pre s
          newItems := newItems.insert name
          allItems := allItems.insert name
      newItemsInWorld := newItemsInWorld.insert worldId newItems

    -- Basic inventory item availability: all locked.
    let Availability₀ : HashMap Name ComputedInventoryItem :=
      HashMap.ofList $
        ← allItems.toList.mapM fun item => do
          let data := (← getInventoryItem? item inventoryType).get!
          -- TODO: BUG, panic at `get!` in vscode
          return (item, {
            name := item
            displayName := data.displayName
            category := data.category })

    -- Availability after a given world
    let mut itemsInWorld : HashMap Name (HashMap Name ComputedInventoryItem) := {}
    for (worldId, _) in game.worlds.nodes.toArray do
      -- Unlock all items from previous worlds
      let mut items := Availability₀
      let predecessors := game.worlds.predecessors worldId
      for predWorldId in predecessors do
        for item in newItemsInWorld.find! predWorldId do
          let data := (← getInventoryItem? item inventoryType).get!
          items := items.insert item {
            name := item
            displayName := data.displayName
            category := data.category
            locked := false }
      itemsInWorld := itemsInWorld.insert worldId items

    for (worldId, world) in game.worlds.nodes.toArray do
      let mut items := itemsInWorld.find! worldId

      let levels := world.levels.toArray.insertionSort fun a b => a.1 < b.1

      for (levelId, level) in levels do
        let levelInfo := level.getInventory inventoryType

        -- unlock items that are unlocked in this level
        for item in levelInfo.new do
          let data := (← getInventoryItem? item inventoryType).get!
          items := items.insert item {
            name := item
            displayName := data.displayName
            category := data.category
            locked := false }

        -- add the exercise statement from the previous level
        -- if it was named
        if inventoryType == .Lemma then
          match lemmaStatements.find? (worldId, levelId) with
          | none => pure ()
          | some name =>
            let data := (← getInventoryItem? name inventoryType).get!
            items := items.insert name {
              name := name
              displayName := data.displayName
              category := data.category
              locked := false }

        -- add marks for `disabled` and `new` lemmas here, so that they only apply to
        -- the current level.
        let itemsArray := items.toArray
          |>.insertionSort (fun a b => a.1.toString < b.1.toString)
          |>.map (·.2)
          |>.map (fun item => { item with
            disabled := if levelInfo.only.size == 0 then
                levelInfo.disabled.contains item.name
              else
                not (levelInfo.only.contains item.name)
            new := levelInfo.new.contains item.name
            })

        modifyLevel ⟨← getCurGameId, worldId, levelId⟩ fun level => do
          return level.setComputedInventory inventoryType itemsArray



/-! # Debugging tools -/

-- /-- Print current game for debugging purposes. -/
-- elab "PrintCurGame" : command => do
--   logInfo (toJson (← getCurGame))

/-- Print current level for debugging purposes. -/
elab "PrintCurLevel" : command => do
  logInfo (repr (← getCurLevel))

/-- Print levels for debugging purposes. -/
elab "PrintLevels" : command => do
  logInfo $ repr $ (← getCurWorld).levels.toArray
