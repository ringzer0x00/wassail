open Core_kernel

module Label = struct
  (** The section in which an instruction is contained *)
  type section =
    | Function of Int32.t (** Instruction is part of the function with the given index *)
    | Elem of Int32.t (** Instruction is part of table elements with the given index *)
    | MergeInFunction of Int32.t (** Instruction is a merge instruction in the given function *)
  [@@deriving sexp, compare, equal]

  let section_to_string (s : section) = match s with
    | Function n -> Printf.sprintf "%ld" n
    | Elem n -> Printf.sprintf "elem%ld" n
    | MergeInFunction n -> Printf.sprintf "m%ld" n

  module T = struct
    (** A label is a unique identifier for an instruction *)
    type t = {
      section: section;
      id: int;
    }
    [@@deriving sexp, compare, equal]

    let to_string (l : t) : string = match l.section with
      | Function _ -> Printf.sprintf "%d" l.id (* Printed differently to have a cleaner output *)
      | _ -> Printf.sprintf "%s_%d" (section_to_string l.section) l.id
  end
  include T

  let maker (section : section) : unit -> t =
    let counter = ref 0 in
    fun () ->
      let id = !counter in
      counter := !counter + 1;
      { section; id }

  module Set = Set.Make(T)
  module Map = Map.Make(T)

  (** Test data *)
  module Test = struct
    let lab (n : int) = {
      section = Function 0l;
      id = n;
    }
    let merge (n : int) = {
      section = MergeInFunction 0l;
      id = n;
    }
  end
end

module T = struct
  (** A container for an instruction with a label *)
  type ('a, 'b) labelled = {
    label : Label.t; (** The label of the instruction *)
    instr : 'a; (** The instruction itself *)
    annotation_before: 'b; (** The annotation before the instruction *)
    annotation_after: 'b; (** The annotation after the instruction *)
  }
  [@@deriving sexp, compare, equal]

  (** An arity: it is a pair composed of the number of elements taken from the
     stack, and the number of elements put back on the stack *)
  type arity = int * int
  [@@deriving sexp, compare, equal]

  (** The optional type of a block *)
  type block_type = Type.t option
  [@@deriving sexp, compare, equal]

  (** Data instructions *)
  type data =
    | Nop
    | Drop
    | Select
    | MemorySize | MemoryGrow
    | Const of Prim_value.t
    | Unary of Unop.t
    | Binary of Binop.t
    | Compare of Relop.t
    | Test of Testop.t
    | Convert of Convertop.t
    | LocalGet of Int32.t
    | LocalSet of Int32.t
    | LocalTee of Int32.t
    | GlobalGet of Int32.t
    | GlobalSet of Int32.t
    | Load of Memoryop.t
    | Store of Memoryop.t

  (** Control instructions *)
  and 'a control =
    | Block of block_type * arity * 'a t list
    | Loop of block_type * arity * 'a t list
    | If of block_type * arity * 'a t list * 'a t list
    | Call of arity * Int32.t
    | CallIndirect of arity * Int32.t
    | Br of Int32.t
    | BrIf of Int32.t
    | BrTable of Int32.t list * Int32.t
    | Return
    | Unreachable
    | Merge (* Special instruction not existing in Wasm, used to handle control-flow merges *)

  (** Labelled control instructions *)
  and 'a labelled_control = ('a control, 'a) labelled

  (** Labelled data instructions *)
  and 'a labelled_data = (data, 'a) labelled

  (** All instructions *)
  and 'a t =
    | Data of 'a labelled_data
    | Control of 'a labelled_control
  [@@deriving sexp, compare, equal]

end
include T

(** Return the label of an instruction *)
let label (instr : 'a t) : Label.t = match instr with
  | Data i -> i.label
  | Control i -> i.label

(** Convert a data instruction to its string representation *)
let data_to_string (instr : data) : string =
  match instr with
     | Nop -> "nop"
     | Drop -> "drop"
     | Select -> "select"
     | MemorySize -> "memory_size"
     | MemoryGrow -> "memory_grow"
     | Const v -> Printf.sprintf "const %s" (Prim_value.to_string v)
     | Binary b -> Printf.sprintf "binary %s" (Binop.to_string b)
     | Unary u -> Printf.sprintf "unary %s" (Unop.to_string u)
     | Compare r -> Printf.sprintf "compare %s" (Relop.to_string r)
     | Test t -> Printf.sprintf "test %s" (Testop.to_string t)
     | Convert t -> Printf.sprintf "cvt %s" (Convertop.to_string t)
     | LocalGet v -> Printf.sprintf "local.get %s" (Int32.to_string v)
     | LocalSet v -> Printf.sprintf "local.set %s" (Int32.to_string v)
     | LocalTee v -> Printf.sprintf "local.tee %s" (Int32.to_string v)
     | GlobalGet v -> Printf.sprintf "global.get %s" (Int32.to_string v)
     | GlobalSet v -> Printf.sprintf "global.set %s" (Int32.to_string v)
     | Load op -> Printf.sprintf "load %s" (Memoryop.to_string op)
     | Store op -> Printf.sprintf "store %s" (Memoryop.to_string op)

(** Converts a control instruction to its string representation *)
let rec control_to_string ?sep:(sep : string = "\n") ?indent:(i : int = 0) ?annot_str:(annot_to_string : 'a -> string = fun _ -> "") (instr : 'a control)  : string =
  match instr with
  | Call (_, v) -> Printf.sprintf "call %s" (Int32.to_string v)
  | CallIndirect (_, v) -> Printf.sprintf "call_indirect %s" (Int32.to_string v)
  | Br b -> Printf.sprintf "br %s" (Int32.to_string b)
  | BrIf b -> Printf.sprintf "brif %s" (Int32.to_string b)
  | BrTable (t, b) -> Printf.sprintf "br_table %s %s" (String.concat ~sep:" " (List.map t ~f:Int32.to_string)) (Int32.to_string b)
  | Return -> "return"
  | Unreachable -> "unreachable"
  | Block (_, _, instrs) -> Printf.sprintf "block%s%s" sep (list_to_string instrs annot_to_string ~indent:(i+2) ~sep:sep)
  | Loop (_, _, instrs) -> Printf.sprintf "loop%s%s" sep (list_to_string instrs annot_to_string ~indent:(i+2) ~sep:sep)
  | If (_, _, instrs1, instrs2) -> Printf.sprintf "if%s%s%selse%s%s" sep
                               (list_to_string instrs1 annot_to_string ~indent:(i+2) ~sep:sep) sep sep
                               (list_to_string instrs2 annot_to_string ~indent:(i+2) ~sep:sep)
  | Merge -> "merge"

(** Converts an instruction to its string representation *)
and to_string ?sep:(sep : string = "\n") ?indent:(i : int = 0) ?annot_str:(annot_to_string : 'a -> string = fun _ -> "") (instr : 'a t) : string =
  Printf.sprintf "%s:%s%s" (Label.to_string (label instr)) (String.make i ' ')
    (match instr with
     | Data instr -> data_to_string instr.instr
     | Control instr -> control_to_string instr.instr ~annot_str:annot_to_string ~sep:sep ~indent:i)
and list_to_string ?indent:(i : int = 0) ?sep:(sep : string = ", ") (l : 'a t list) (annot_to_string : 'a -> string) : string =
  String.concat ~sep:sep (List.map l ~f:(fun instr -> to_string instr ~annot_str:annot_to_string ?sep:(Some sep) ?indent:(Some i)))

(** Converts a control expression to a shorter string *)
let control_to_short_string (instr : 'a control) : string =
  match instr with
  | Block _ -> "block"
  | Loop _ -> "loop"
  | If _ -> "if"
  | _ -> control_to_string instr ~annot_str:(fun _ -> "")

(** Converts an instruction to its mnemonic *)
let to_mnemonic (instr : 'a t) : string = match instr with
  | Data d -> begin match d.instr with
      | Nop -> "nop"
      | Drop -> "drop"
      | Select -> "select"
      | MemorySize -> "memory.size"
      | MemoryGrow -> "memory.grow"
      | Const v -> Printf.sprintf "%s.const" (Type.to_string (Prim_value.typ v))
      | Unary op -> Unop.to_mnemonic op
      | Binary op -> Binop.to_mnemonic op
      | Compare op -> Relop.to_mnemonic op
      | Test op -> Testop.to_mnemonic op
      | Convert op -> Convertop.to_mnemonic op
      | LocalGet _ -> "local.get"
      | LocalSet _ -> "local.set"
      | LocalTee _ -> "local.tee"
      | GlobalGet _ -> "global.get"
      | GlobalSet _ -> "global.set"
      | Load _ -> "load"
      | Store _ -> "store"
    end
  | Control c -> begin match c.instr with
      | Block (_, _, _) -> "block"
      | Loop (_, _, _) -> "loop"
      | If (_, _, _, _) -> "if"
      | Call (_, _) -> "call"
      | CallIndirect (_, _) -> "call_indirect"
      | Br _ -> "br"
      | BrIf _ -> "br_if"
      | BrTable (_, _) -> "br_table"
      | Return -> "return"
      | Unreachable -> "unreachable"
      | Merge -> "merge"
    end

(** Create an instruction from a WebAssembly instruction *)
let rec of_wasm (m : Wasm.Ast.module_) (new_label : unit -> Label.t) (i : Wasm.Ast.instr) : unit t =
  (* Construct a labelled data instruction *)
  let data_labelled ?label:(lab : Label.t option) (instr : data) : unit t =
    let label = match lab with
      | Some l -> l
      | None -> new_label () in
    Data { instr; label; annotation_before = (); annotation_after = (); } in
  (* Construct a labelled control instruction *)
  let control_labelled ?label:(lab : Label.t option) (instr : 'a control) : 'a t =
    let label = match lab with
      | Some l -> l
      | None -> new_label () in
    Control { instr; label; annotation_before = (); annotation_after = (); } in
  match i.it with
  | Nop -> data_labelled Nop
  | Drop -> data_labelled Drop
  | Block (st, instrs) ->
    let block_type = Wasm_helpers.type_of_block st in
    let (arity_in, arity_out) = Wasm_helpers.arity_of_block st in
    assert (arity_in = 0); (* what does it mean to have arity_in > 0? *)
    assert (arity_out <= 1);
    let label = new_label () in
    let body = seq_of_wasm m new_label instrs in
    control_labelled ~label:label (Block (block_type, (arity_in, arity_out), body))
  | Const lit ->
    data_labelled (Const (Prim_value.of_wasm lit.it))
  | Binary bin ->
    data_labelled (Binary (Binop.of_wasm bin))
  | Compare rel ->
    data_labelled (Compare (Relop.of_wasm rel))
  | LocalGet l ->
    data_labelled (LocalGet l.it)
  | LocalSet l ->
    data_labelled (LocalSet l.it)
  | LocalTee l ->
    data_labelled (LocalTee l.it)
  | BrIf label ->
    control_labelled (BrIf label.it)
  | Br label ->
    control_labelled (Br label.it)
  | BrTable (table, label) ->
    control_labelled (BrTable (List.map table ~f:(fun v -> v.it), label.it))
  | Call f ->
    let (arity_in, arity_out) = Wasm_helpers.arity_of_fun m f in
    assert (arity_out <= 1);
    control_labelled (Call ((arity_in, arity_out), f.it))
  | Return ->
    control_labelled (Return)
  | Unreachable ->
    control_labelled (Unreachable)
  | Select ->
    data_labelled (Select)
  | Loop (st, instrs) ->
    let (arity_in, arity_out) = Wasm_helpers.arity_of_block st in
    assert (arity_in = 0); (* what does it mean to have arity_in > 0 for a loop? *)
    assert (arity_out <= 1); (* TODO: support any arity out? *)
    let label = new_label () in
    let body = seq_of_wasm m new_label instrs in
    control_labelled ~label:label (Loop (Wasm_helpers.type_of_block st, (arity_in, arity_out), body))
  | If (st, instrs1, instrs2) ->
    let (arity_in, arity_out) = Wasm_helpers.arity_of_block st in
    let label = new_label () in
    let body1 = seq_of_wasm m new_label instrs1 in
    let body2 = seq_of_wasm m new_label instrs2 in
    control_labelled ~label:label (If (Wasm_helpers.type_of_block st, (arity_in, arity_out), body1, body2))
  | CallIndirect f ->
    let (arity_in, arity_out) = Wasm_helpers.arity_of_fun_type m f in
    assert (arity_out <= 1);
    control_labelled (CallIndirect ((arity_in, arity_out), f.it))
  | GlobalGet g ->
    data_labelled (GlobalGet g.it)
  | GlobalSet g ->
    data_labelled (GlobalSet g.it)
  | Load op ->
    data_labelled (Load (Memoryop.of_wasm_load op))
  | Store op ->
    data_labelled (Store (Memoryop.of_wasm_store op))
  | MemorySize -> data_labelled (MemorySize)
  | MemoryGrow -> data_labelled MemoryGrow
  | Test op ->
    data_labelled (Test (Testop.of_wasm op))
  | Convert op ->
    data_labelled (Convert (Convertop.of_wasm op))
  | Unary op ->
    data_labelled (Unary (Unop.of_wasm op))

(** Creates a sequence of instructions from their Wasm representation *)
and seq_of_wasm (m : Wasm.Ast.module_) (new_label : unit -> Label.t) (is : Wasm.Ast.instr list) : unit t list =
  List.map is ~f:(of_wasm m new_label)

let rec map_annotation (i : 'a t) ~(f : 'a t -> 'b * 'b) : 'b t =
  match i with
  | Data d -> Data (map_annotation_data d ~f:f)
  | Control c -> Control (map_annotation_control c ~f:f)
and map_annotation_data (i : (data, 'a) labelled) ~(f : 'a t -> 'b * 'b) : (data, 'b) labelled =
  let (annotation_before, annotation_after) = f (Data i) in
  { i with annotation_before; annotation_after }
and map_annotation_control (i : ('a control, 'a) labelled) ~(f : 'a t ->  'b * 'b) : ('b control, 'b) labelled =
  let (annotation_before, annotation_after) = f (Control i) in
  { i with annotation_before; annotation_after;
           instr = match i.instr with
             | Block (bt, arity, instrs) -> Block (bt, arity, List.map instrs ~f:(map_annotation ~f:f))
             | Loop (bt, arity, instrs) -> Loop (bt, arity, List.map instrs ~f:(map_annotation ~f:f))
             | If (bt, arity, then_, else_) -> If (bt, arity,
                                               List.map then_ ~f:(map_annotation ~f:f),
                                               List.map else_ ~f:(map_annotation ~f:f))
             | Call (arity, f) -> Call (arity, f)
             | CallIndirect (arity, f) -> CallIndirect (arity, f)
             | Br n -> Br n
             | BrIf n -> BrIf n
             | BrTable (l, n) -> BrTable (l, n)
             | Return -> Return
             | Unreachable -> Unreachable
             | Merge -> Merge}

let clear_annotation (i : 'a t) : unit t =
  map_annotation i ~f:(fun _ -> (), ())
let clear_annotation_data (i : (data, 'a) labelled) : (data, unit) labelled =
  map_annotation_data i ~f:(fun _ -> (), ())
let clear_annotation_control (i : ('a control, 'a) labelled) : (unit control, unit) labelled =
  map_annotation_control i ~f:(fun _ -> (), ())

let annotation_before (i : 'a t) : 'a =
  match i with
  | Data d -> d.annotation_before
  | Control c -> c.annotation_before

let annotation_after (i : 'a t) : 'a =
  match i with
  | Data d -> d.annotation_after
  | Control c -> c.annotation_after

let rec all_labels (i : 'a t) : Label.Set.t =
  match i with
  | Data d -> Label.Set.singleton d.label
  | Control c -> Label.Set.add (begin match c.instr with
      | Block (_, _, instrs)
      | Loop (_, _, instrs) -> List.fold_left instrs ~init:Label.Set.empty ~f:(fun acc i ->
          Label.Set.union acc (all_labels i))
      | If (_, _, instrs1, instrs2) ->
        List.fold_left (instrs1 @ instrs2) ~init:Label.Set.empty ~f:(fun acc i ->
          Label.Set.union acc (all_labels i))
      | _ -> Label.Set.empty
    end) c.label

(** The input arity of an expression, i.e., how many values it expects on the stack *)
let rec in_arity (i : 'a t) : int =
  match i with
  | Data d -> in_arity_data d
  | Control c -> in_arity_control c
and in_arity_data (i : (data, 'a) labelled) : int =
  match i.instr with
  | Nop -> 0
  | Drop -> 1
  | Select -> 3
  | MemorySize -> 0
  | MemoryGrow -> 1
  | Const _ -> 1
  | Unary _ -> 1
  | Binary _ -> 2
  | Compare _ -> 2
  | Test _ -> 1
  | Convert _ -> 1
  | LocalGet _ -> 0
  | LocalSet _ -> 1
  | LocalTee _ -> 1
  | GlobalGet _ -> 0
  | GlobalSet _ -> 1
  | Load _ -> 1
  | Store _ -> 2
and in_arity_control (i : ('a control, 'a) labelled) : int =
  match i.instr with
  | Block (_, (n, _), _) -> n
  | Loop (_, (n, _), _) -> n
  | If (_, (n, _), _, _) -> n
  | Call ((n, _), _) -> n
  | CallIndirect ((n, _), _) -> n
  | Br _ -> 0
  | BrIf _ -> 1
  | BrTable (_, _) -> 1
  | Return -> 0 (* this actually depends on the function, but strictly speaking, return does not expect anything *)
  | Unreachable -> 0
  | Merge -> 0

let instructions_contained_in (i : 'a t) : 'a t list = match i with
  | Data _ -> []
  | Control c -> match c.instr with
    | Block (_, _, instrs)
    | Loop (_, _, instrs) -> instrs
    | If (_, _, instrs1, instrs2) -> instrs1 @ instrs2
    | _ -> []
