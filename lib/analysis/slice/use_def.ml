open Core_kernel
open Helpers

module Use = struct
  module T = struct
    (** Uses occur from instructions *)
    type t = {
      label : Instr.Label.t;
      var: Var.t;
    }
    [@@deriving sexp, equal, compare]
  end
  include T

  module Set = Set.Make(T)
  module Map = Map.Make(T)
  let to_string (use : t) : string = Printf.sprintf "iuse(%s, %s)" (Instr.Label.to_string use.label) (Var.to_string use.var)
  let make (label : Instr.Label.t) (var : Var.t) = { label; var; }
end

module Def = struct
  module T = struct
    (** Definitions can occur in multiple places
        - As a result from an instruction (e.g., i32.add defines a new variable)
        - In merge nodes
        - At the entry of a function (e.g., for local, global, and memory variables) *)
    type t =
      | Instruction of Instr.Label.t * Var.t (* Label of the instruction and variable defined *) (* TODO: the label is part of the variable *)
      | Entry of Var.t (* Only the variable defined (because use-def is intraprocedural, we know the function) *)
      | Constant of Prim_value.t (* A constant does not really have a definition *)
    [@@deriving equal, compare]

    let to_string (def : t) : string = match def with
      | Instruction (n, v) -> Printf.sprintf "idef(%s, %s)" (Instr.Label.to_string n) (Var.to_string v)
      | Entry v -> Printf.sprintf "edef(%s)" (Var.to_string v)
      | Constant v -> Printf.sprintf "const(%s)" (Prim_value.to_string v)
  end
  include T
end

module UseDefChains = struct
  (** Use-definition chains, as a mapping from uses (as the index of the instruction that uses the variable, and the variable name) to their definition (as the index of the instruction that defines the variable)*)
  module T = struct
    type t = Def.t Use.Map.t
    [@@deriving compare, equal]

    (** Convert a use-def map to its string representation *)
    let to_string (m : t) : string =
      String.concat ~sep:", " (List.map (Use.Map.to_alist m) ~f:(fun (k, v) -> Printf.sprintf "%s -> %s" (Use.to_string k) (Def.to_string v)))
  end
  include T
  include Test.Helpers(T)

  (** The empty use-def map *)
  let empty : t = Use.Map.empty

  (** Add an element to the use-def map *)
  let add (m : t) (use : Use.t) (def : Def.t) : t =
    match Use.Map.add m ~key:use ~data:def with
    | `Duplicate -> failwith (Printf.sprintf "Cannot have more than one definition for a use in use-def chains, when adding %s ->%s to %s" (Use.to_string use) (Def.to_string def) (to_string m))
    | `Ok r -> r

  (** Gets an element from the use-def map *)
  let get (m : t) (use : Use.t) : Def.t =
    match Use.Map.find m use with
    | Some def -> def
    | None -> failwith "use-def lookup did not find a definition for a use"
end

(** Return the list of variables defined by an instruction *)
(* TODO: this should be part of Spec_inference? *)
let instr_def (cfg : Spec.t Cfg.t) (instr : Spec.t Instr.t) : Var.t list =
  let defs = match instr with
    | Instr.Data i ->
      let top_n n = List.take i.annotation_after.vstack n in
      begin match i.instr with
        | Nop | Drop | MemoryGrow -> []
        | Select | MemorySize
        | Unary _ | Binary _ | Compare _ | Test _ | Convert _
        | Const _ -> top_n 1
        | LocalGet _ ->
          if !Spec_inference.propagate_locals then
            []
          else
            top_n 1
        | GlobalGet _ ->
          if !Spec_inference.propagate_globals then
            []
          else
            top_n 1
        | LocalSet l | LocalTee l ->
          if !Spec_inference.propagate_locals then
            []
          else
            [get_nth i.annotation_after.locals l]
        | GlobalSet g ->
          if !Spec_inference.propagate_globals then
            []
          else
            [get_nth i.annotation_after.globals g]
        | Load _ -> top_n 1
        | Store _ ->
          []
          (*let addr = List.nth_exn i.annotation_before.vstack 1 (* address is not the top of the stack but the element after *) in
            [match Var.OffsetMap.find i.annotation_after.memory (addr, offset) with
             | Some v -> v
             | None -> failwith (Printf.sprintf "Wrong memory annotation while looking for %s+%d in memory (instr: %s), annot after: %s" (Var.to_string addr) offset (Instr.to_string instr Spec_inference.state_to_string) (Spec_inference.state_to_string i.annotation_after))] *)
      end
    | Instr.Control i ->
      let top_n n = List.take i.annotation_after.vstack n in
      begin match i.instr with
        | Block _ | Loop _ -> [] (* we handle instruction individually rather than through their block *)
        | If _ -> [] (* We could say that if defines its "resulting" value, but that will be handled by the merge node *)
        | Call ((_, arity_out), _) -> top_n arity_out
        | CallIndirect ((_, arity_out), _) -> top_n arity_out
        | Merge ->
          (* Merge instruction defines new variabes *)
          let block = Cfg.find_enclosing_block cfg instr in
          let vars = List.map (Spec_inference.new_merge_variables cfg block) ~f:snd in
          (* There might be duplicates. For example, i3 becomes m0 from one branch, and i4 becomes m0 from another branch.
             If that is the case, we have two definitions of m0.
             Hence we eliminate duplicates *)
          Var.Set.to_list (Var.Set.of_list vars)
        | Br _ | BrIf _ | BrTable _ | Return | Unreachable -> []
      end
  in
  List.filter defs ~f:(function
      | Var.Const _ -> false (* constants are not variables that can be defined (otherwise definitions are not unique anymore) *)
      | Var.Local _ -> false (* locals don't have a definition point (they are part of the entry state) *)
      | Var.Global _ -> false (* same for globals *)
      | _ -> true)

(** Return the list of variables used by an instruction *)
let instr_use (cfg : Spec.t Cfg.t) (instr : Spec.t Instr.t) : Var.t list = match instr with
  | Instr.Data i ->
    let top_n n = List.take i.annotation_before.vstack n in
    begin match i.instr with
      | Nop -> []
      | Drop -> top_n 1
      | Select -> top_n 3
      | MemorySize -> []
      | MemoryGrow -> top_n 1
      | Const _ -> []
      | Unary _ | Test _ | Convert _ -> top_n 1
      | Binary _ | Compare _ -> top_n 2
      | LocalGet l -> [get_nth i.annotation_before.locals l] (* use local l *)
      | LocalSet _ | LocalTee _ -> top_n 1 (* use top of the stack to define local *)
      | GlobalGet g -> [get_nth i.annotation_before.globals g] (* use global g *)
      | GlobalSet _ -> top_n 1
      | Load _ -> top_n 1 (* use memory address from the top of the stack *)
      | Store _ -> top_n 2 (* use address and valu from the top of the stack *)
    end
  | Instr.Control i ->
    let top_n n = List.take i.annotation_before.vstack n in
    begin match i.instr with
      | Block _ | Loop _ -> [] (* we handle instruction individually rather than through their block *)
      | If _ -> top_n 1 (* relies on top value to decide the branch taken *)
      | Call ((arity_in, _), _) -> top_n arity_in (* uses the n arguments from the stack *)
      | CallIndirect ((arity_in, __), _) -> top_n (arity_in + 1) (* + 1 because we need to pop the index that will refer to the called function, on top of the arguments *)
      | BrIf _ | BrTable _ -> top_n 1
      | Merge ->
        (* Merge instruction uses the variables it redefines *)
        let block = Cfg.find_enclosing_block cfg instr in
        List.map (Spec_inference.new_merge_variables cfg block) ~f:fst
      | Br _ | Return | Unreachable -> []
    end

(** Compute data dependence from the CFG of a function, and return the following elements:
    1. A map from variables to their definitions
    2. A map from variables to their uses
    3. A map of use-def chains *)
let make (cfg : Spec.t Cfg.t) : (Def.t Var.Map.t * Use.Set.t Var.Map.t * UseDefChains.t) =
  (* To construct the use-def map, we walk over each instruction, and collect uses and defines.
     There is exactly one define per variable.
     e.g., [] i32.const 0 [x] defines x
           [x, y] i32.add [z] defines z, uses x, y
     On top of being defined by instructions, variable may be defined in merge nodes, and may be
     defined at the entry node of a function.

     However, there can be more than one use for a variable!

     We compute the following maps while walking over the instructions:
       uses: (int list) Var.Map.t (* The list of instructions that use a given variable *)
       def: int Var.Map.t (* The instruction that defines a given variable *)

     From this, it is a matter of folding over use to construct the DefUseMap:
       Given a use of v at instruction lab, add key:(lab, v) data:(lookup defs v) *)
  (* The defs map will map variables to their definition.
     Because we are in SSA, there can only be one instruction that define a variable *)
  let defs: Def.t Var.Map.t = Var.Map.empty in
  (* The uses map will map variables to all of its uses *)
  let uses: Use.Set.t Var.Map.t = Var.Map.empty in
  (* Add definitions for all locals, globals, and memory variables *)
  let defs =
    let entry_spec = Cfg.state_before_block cfg cfg.entry_block in
    let vars = Spec_inference.vars_of entry_spec in
    Var.Set.fold vars ~init:defs ~f:(fun defs var ->
        match Var.Map.add defs ~key:var ~data:(Def.Entry var) with
        | `Duplicate -> failwith "use_def: more than one entry definition for a variable"
        | `Ok r -> r) in
  (* Add definitions for all constants *)
  let defs =
    let all_vars : Var.Set.t = List.fold_left (Cfg.all_instructions cfg)
        ~init:Var.Set.empty
        ~f:(fun acc instr -> Var.Set.union acc
               (Var.Set.union
                  (Spec.vars_of (Instr.annotation_before instr))
                  (Spec.vars_of (Instr.annotation_after instr)))) in
    Var.Set.fold all_vars ~init:defs ~f:(fun defs var ->
        match var with
        | Var.Const n -> begin match Var.Map.add defs ~key:var ~data:(Def.Constant n)  with
            | `Duplicate -> defs (* already in the set *)
            | `Ok r -> r
          end
        | _ -> defs) in
  (* For each merge block, update the defs and uses map *)
  (* let (defs, uses) = List.fold_left (Cfg.all_merge_blocks cfg)
      ~init:(defs, uses)
      ~f:(fun (defs, uses) block ->
          List.fold_left (Spec_inference.new_merge_variables cfg block)
            ~init:(defs, uses)
            ~f:(fun (defs, uses) (old_var, new_var) ->
                (begin match Var.Map.add defs ~key:new_var ~data:(Def.Merge (block.idx, new_var)) with
                   | `Duplicate ->
                     (* Duplicate definitions are allowed in merge blocks, e.g.,
                        on one branch, var i1 is on the top of the stack
                        on another branch, var i2 is on the top of the stack
                        as new merge variable, we get m1, which is return as (i1, m1), (i2, m1) by `new_merge_variables` *)
                     defs
                 | `Ok r -> r
                 end,
                 Var.Map.update uses old_var ~f:(function
                     | Some v -> Use.Set.add v (Use.Merge (block.idx, old_var))
                     | None -> Use.Set.singleton (Use.Merge (block.idx, old_var)))))) in *)
  (* For each instruction, update the defs and uses map *)
  let (defs, uses) = List.fold_left (Cfg.all_instructions cfg)
      ~init:(defs, uses)
      ~f:(fun (defs, uses) instr ->
          let defs = List.fold_left (instr_def cfg instr) ~init:defs ~f:(fun defs var ->
              Log.debug (Printf.sprintf "instruction %s defines %s\n" (Instr.to_string instr ~annot_str:Spec.to_string) (Var.to_string var));
              match Var.Map.add defs ~key:var ~data:(Def.Instruction (Instr.label instr, var)) with
              | `Duplicate -> failwith (Printf.sprintf "use_def: duplicate define of %s in instruction %s, was already defined at %s"
                                          (Var.to_string var) (Instr.to_string instr ~annot_str:Spec.to_string)
                                          (Def.to_string (Var.Map.find_exn defs var)))
              | `Ok r -> r) in
          let uses = List.fold_left (instr_use cfg instr) ~init:uses ~f:(fun uses var ->
              Log.debug (Printf.sprintf "instruction %s uses %s\n" (Instr.to_string instr ~annot_str:Spec.to_string) (Var.to_string var));
              Var.Map.update uses var ~f:(function
                  | Some v -> Use.Set.add v { label = Instr.label instr; var }
                  | None -> Use.Set.singleton { label = Instr.label instr; var })) in
          (defs, uses)) in
  (* From this, it is a matter of folding over use to construct the DefUseMap:
     Given a use of v at instruction lab, add key:(lab, v) data:(lookup defs v) *)
  let udchains = Var.Map.fold uses ~init:UseDefChains.empty ~f:(fun ~key:var ~data:uses map ->
      Use.Set.fold uses ~init:map ~f:(fun map use ->
          UseDefChains.add map use (match Var.Map.find defs var with
              | Some v -> v
              | None -> failwith (Printf.sprintf "Use-def chain incorrect: could not find def of variable %s" (Var.to_string var))))) in
  (defs, uses, udchains)


module Test = struct
  let%test "simplest ud chain" =
    let open Instr.Label.Test in
    let module_ = Wasm_module.of_string "(module
  (type (;0;) (func (param i32) (result i32)))
  (func (;test;) (type 0) (param i32) (result i32)
    memory.size ;; Instr 0 [i0] defines i0, uses nothing
    memory.size ;; Instr 1 [i1] defines i1, uses nothing
    i32.add     ;; Instr 2 [i2] defines i2, uses i0 and i1
                ;; return block: defines ret, uses i2
    )
  )" in
    let cfg = Spec_analysis.analyze_intra1 module_ 0l in
    let _, _, actual = make cfg in
    let expected = Use.Map.of_alist_exn [(Use.make (lab 2) (Var.Var (lab 0)), Def.Instruction (lab 0, (Var.Var (lab 0))));
                                         (Use.make (lab 2) (Var.Var (lab 1)), Def.Instruction (lab 1, Var.Var (lab 1)));
                                         (Use.make (merge 1) (Var.Var (lab 2)), Def.Instruction (lab 2, Var.Var (lab 2)))] in
    UseDefChains.check_equality ~actual:actual ~expected:expected

  let%test "ud-chain with locals" =
    let open Instr.Label.Test in
    let module_ = Wasm_module.of_string "(module
  (type (;0;) (func (param i32 i32) (result i32)))
  (func (;test;) (type 0) (param i32 i32) (result i32)
    local.get 0 ;; Instr 0
    local.get 1 ;; Instr 1
    i32.add)    ;; Instr 2
  )" in
    let cfg = Spec_analysis.analyze_intra1 module_ 0l in
    let _, _, actual = make cfg in
    let expected = Use.Map.of_alist_exn [(Use.make (lab 0) (Var.Local 0), Def.Entry (Var.Local 0));
                                         (Use.make (lab 1) (Var.Local 1), Def.Entry (Var.Local 1));
                                         (Use.make (lab 2) (Var.Local 0), Def.Entry (Var.Local 0));
                                         (Use.make (lab 2) (Var.Local 1), Def.Entry (Var.Local 1));
                                         (Use.make (merge 1) (Var.Var (lab 2)), Def.Instruction (lab 2, Var.Var (lab 2)))] in
    UseDefChains.check_equality ~actual:actual ~expected:expected

  let%test "use-def with merge blocks" =
    let open Instr.Label.Test in
    let module_ = Wasm_module.of_string "(module
  (type (;0;) (func (param i32) (result i32)))
  (func (;test;) (type 0) (param i32) (result i32)
    memory.size     ;; Instr 0 [i0]
    if (result i32) ;; Instr 1 [] uses i0
      memory.size   ;; Instr 2 [i2]
    else
      memory.size   ;; Instr 3 [i3]
    end
    ;; At this point we have a merge block, merging i2 and i3 into m4_1
    memory.size     ;; Instr 4
    i32.add)        ;; Instr 5
    ;; Final merge block: i5 -> ret
  )" in
    let cfg = Spec_analysis.analyze_intra1 module_ 0l in
    let _, _, actual = make cfg in
    let expected = Use.Map.of_alist_exn [(Use.make (lab 1) (Var.Var (lab 0)), Def.Instruction (lab 0, Var.Var (lab 0)));
                                         (Use.make (lab 5) (Var.Var (lab 4)), Def.Instruction (lab 4, Var.Var (lab 4)));
                                         (Use.make (lab 5) (Var.Merge (4, 1)), Def.Instruction (merge 4, Var.Merge (4, 1)));
                                         (Use.make (merge 4) (Var.Var (lab 2)), Def.Instruction (lab 2, Var.Var (lab 2)));
                                         (Use.make (merge 4) (Var.Var (lab 3)), Def.Instruction (lab 3, Var.Var (lab 3)));
                                         (Use.make (merge 6) (Var.Var (lab 5)), Def.Instruction (lab 5, Var.Var (lab 5)))] in
    UseDefChains.check_equality ~actual:actual ~expected:expected

  let%test "use-def with memory" =
    let open Instr.Label.Test in
    let module_ = Wasm_module.of_string "(module
  (type (;0;) (func (param i32) (result i32)))
  (func (;test;) (type 0) (param i32) (result i32)
    memory.size     ;; Instr 0, Var 0
    memory.size     ;; Instr 1, Var 1
    i32.store       ;; Instr 2, i0+0 mapped to i1 (no new var!)
    memory.size     ;; Instr 3, Var 3
    memory.size     ;; Instr 4, Var 4
    i32.store)       ;; Instr 5, i3+0 mapped to i4 (no new var!)
  )" in
    let cfg = Spec_analysis.analyze_intra1 module_ 0l in
    let _, _, actual = make cfg in
    let expected = Use.Map.of_alist_exn [(Use.make (lab 2) (Var.Var (lab 0)), Def.Instruction (lab 0, Var.Var (lab 0)));
                                         (Use.make (lab 2) (Var.Var (lab 1)), Def.Instruction (lab 1, Var.Var (lab 1)));
                                         (Use.make (lab 5) (Var.Var (lab 3)), Def.Instruction (lab 3, Var.Var (lab 3)));
                                         (Use.make (lab 5) (Var.Var (lab 4)), Def.Instruction (lab 4, Var.Var (lab 4)))] in
    UseDefChains.check_equality ~actual:actual ~expected:expected
end
