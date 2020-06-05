open Core_kernel
open Wasm

module T = struct
  (** Data instructions *)
  type data =
    | Nop
    | Drop
    | Select
    | MemorySize
    | Const of Value.t
    | Binary of Binop.t
    | Compare of Relop.t
    | Test of Testop.t
    | LocalGet of Var.t
    | LocalSet of Var.t
    | LocalTee of Var.t
    | GlobalGet of Var.t
    | GlobalSet of Var.t
    | Load of Memoryop.t
    | Store of Memoryop.t
  (** Control instructions *)
  and control =
    | Block of t list
    | Loop of t list
    | If of (t list * t list)
    | Call of Var.t
    | CallIndirect of Var.t
    | Br of Var.t
    | BrIf of Var.t
    | Return
    | Unreachable
  (** All instructions *)
  and instr =
    | Data of data
    | Control of control
  and t = {
    instr : instr;
    vstack : string list;
  }
  [@@deriving sexp, compare]
end
include T

exception UnsupportedInstruction of t

let data_to_string (instr : data) : string =
  match instr with
     | Nop -> "nop"
     | Drop -> "drop"
     | Select -> "select"
     | MemorySize -> "memory_size"
     | Const v -> Printf.sprintf "const %s" (Value.to_string v)
     | Binary b -> Printf.sprintf "binary %s" (Binop.to_string b)
     | Compare r -> Printf.sprintf "compare %s" (Relop.to_string r)
     | Test t -> Printf.sprintf "test %s" (Testop.to_string t)
     | LocalGet v -> Printf.sprintf "local.get %d" v
     | LocalSet v -> Printf.sprintf "local.set %d" v
     | LocalTee v -> Printf.sprintf "local.tee %d" v
     | GlobalGet v -> Printf.sprintf "global.get %d" v
     | GlobalSet v -> Printf.sprintf "global.set %d" v
     | Load op -> Printf.sprintf "load %s" (Memoryop.to_string op)
     | Store op -> Printf.sprintf "store %s" (Memoryop.to_string op)
let rec control_to_string ?sep:(sep : string = "\n") ?indent:(i : int = 0) (instr : control) : string =
  match instr with
  | Call v -> Printf.sprintf "call %d" v
  | CallIndirect v -> Printf.sprintf "call_indirect %d" v
  | Br b -> Printf.sprintf "br %d" b
  | BrIf b -> Printf.sprintf "brif %d" b
  | Return -> "return"
  | Unreachable -> "unreachable"
  | Block instrs -> Printf.sprintf "block%s%s" sep (list_to_string instrs ~indent:(i+2) ~sep:sep)
  | Loop instrs -> Printf.sprintf "loop%s%s" sep (list_to_string instrs ~indent:(i+2) ~sep:sep)
  | If (instrs1, instrs2) -> Printf.sprintf "if%s%s%selse%s%s" sep
                               (list_to_string instrs1 ~indent:(i+2) ~sep:sep) sep sep
                               (list_to_string instrs2 ~indent:(i+2) ~sep:sep)
and to_string ?sep:(sep : string = "\n") ?indent:(i : int = 0) (instr : t) : string =
  Printf.sprintf "%s%s" (String.make i ' ')
    (match instr.instr with
     | Data instr -> data_to_string instr
     | Control instr -> control_to_string instr ~sep:sep ~indent:i)
and list_to_string ?indent:(i : int = 0) ?sep:(sep : string = ", ") (l : t list) : string =
  String.concat ~sep:sep (List.map l ~f:(to_string ?sep:(Some sep) ?indent:(Some i)))

let control_to_short_string (instr : control) : string =
  match instr with
  | Call v -> Printf.sprintf "call %d" v
  | CallIndirect v -> Printf.sprintf "call_indirect %d" v
  | Br b -> Printf.sprintf "br %d" b
  | BrIf b -> Printf.sprintf "brif %d" b
  | Return -> "return"
  | Unreachable -> "unreachable"
  | Block _ -> "block"
  | Loop _ -> "loop"
  | If (_, _) -> "if"

let vstack_pop (vstack : string list) : string list = match vstack with
  | [] -> failwith "incorrect vstack manipulation when parsing instructions"
  | _ :: rest -> rest

let arity_of_block (bt : Ast.block_type) : int * int = match bt with
  | Ast.VarBlockType v -> failwith (Printf.sprintf "TODO: arity_of_block: var %s" (Int32.to_string v.it))
  | Ast.ValBlockType None -> (0, 0)
  | Ast.ValBlockType (Some _t) -> (0, 1) (* TODO: double check that this is what is intended *)

let arity_of_fun_type (m : Ast.module_) (ft : Ast.var) : int * int =
    match Ast.func_type_for m ft with
      | FuncType (i, o) ->
        List.length i, List.length o

let nimports (m : Ast.module_) : int =
  List.count m.it.imports ~f:(fun import -> match import.it.idesc.it with
      | FuncImport _ -> true
      | _ -> false)

let arity_of_fun (m : Ast.module_) (f : Ast.var) : int * int =
  let n = Int32.of_int_exn (nimports m) in
  if Int32.(f.it < n) then
    (* imported function, arity is in import desc *)
    match (Lib.List32.nth m.it.imports f.it).it.idesc.it with
    | FuncImport v -> arity_of_fun_type m v
    | _ -> failwith "not supported"
  else
    (* defined function, get arity from function list *)
    arity_of_fun_type m (Lib.List32.nth m.it.funcs Int32.(f.it - n)).it.ftype

let rec of_wasm (m : Ast.module_) (i : Ast.instr) (vstack : string list) : t =
  let v = Source.string_of_region i.at in
  match i.it with
  | Ast.Nop -> { instr = Data Nop; vstack = vstack }
  | Ast.Drop -> { instr = Data Drop; vstack = List.drop vstack 1  }
  | Ast.Block (st, instrs) ->
    let (arity_in, arity_out) = arity_of_block st in
    Printf.printf "block arity: %d, %d\n" arity_in arity_out;
    (* TODO: maybe we should pop arity_out and push again, or do that in br? *)
    let (body, vstack) = seq_of_wasm m instrs vstack in
    { instr = Control (Block body); vstack = vstack }
  | Ast.Const lit ->
    { instr = Data (Const (Value.of_wasm lit.it)); vstack = v :: vstack }
  | Ast.Binary bin ->
    { instr = Data (Binary (Binop.of_wasm bin)); vstack = v :: (List.drop vstack 2) }
  | Ast.Compare rel ->
    { instr = Data (Compare (Relop.of_wasm rel)); vstack = v :: (List.drop vstack 2) }
  | Ast.LocalGet l ->
    { instr = Data (LocalGet (Var.of_wasm l)); vstack = v :: vstack }
  | Ast.LocalSet l ->
    { instr = Data (LocalSet (Var.of_wasm l)); vstack = List.drop vstack 1 }
  | Ast.LocalTee l ->
    { instr = Data (LocalTee (Var.of_wasm l)); vstack = vstack }
  | Ast.BrIf label ->
    { instr = Control (BrIf (Var.of_wasm label)); vstack = List.drop vstack 1 }
  | Ast.Br label ->
    { instr = Control (Br (Var.of_wasm label)); vstack = vstack }
  | Ast.Call f ->
    let (arity_in, arity_out) = arity_of_fun m f in
    Printf.printf "call %s, arity: (%d, %d)" (Int32.to_string f.it) arity_in arity_out;
    assert (arity_out <= 1);
    { instr = Control (Call (Var.of_wasm f)); vstack = (if arity_out = 0 then [] else [v]) @ List.drop vstack arity_in }
  | Ast.Return ->
    { instr = Control Return; vstack = vstack } (* TODO: in practice, return only keeps the necessary number of values on the vstack *)
  | Ast.Unreachable ->
    { instr = Control Unreachable; vstack = vstack }
  | Ast.Select ->
    { instr = Data Select; vstack = v :: (List.drop vstack 3) }
  | Ast.Loop (st, instrs) ->
    let (arity_in, arity_out) = arity_of_block st in
    Printf.printf "loop arity: %d, %d\n" arity_in arity_out;
    assert (arity_out <= 1); (* TODO: support any arity out? *)
    let (body, _) = seq_of_wasm m instrs vstack in
    { instr = Control (Loop body); vstack = (if arity_out = 0 then [] else [v]) @ List.drop vstack arity_in }
  | Ast.If (st, instrs1, instrs2) ->
    let (arity_in, arity_out) = arity_of_block st in
    assert (arity_out <= 1);
    let (body1, _) = seq_of_wasm m instrs1 vstack in
    let (body2, _) = seq_of_wasm m instrs2 vstack in
    { instr = Control (If (body1, body2)); vstack = (if arity_out = 0 then [] else [v]) @ List.drop vstack arity_in }
  | Ast.BrTable (_vs, _v) -> failwith "br_table unsupported"
  | Ast.CallIndirect f ->
    let (arity_in, arity_out) = arity_of_fun_type m f in
    assert (arity_out <= 1);
    { instr = Control (CallIndirect (Var.of_wasm f)); vstack = (if arity_out = 0 then [] else [v]) @ List.drop vstack arity_in }
  | Ast.GlobalGet g ->
    { instr = Data (GlobalGet (Var.of_wasm g)); vstack = v :: vstack }
  | Ast.GlobalSet g ->
    { instr = Data (GlobalSet (Var.of_wasm g)); vstack = List.drop vstack 1 }
  | Ast.Load op ->
    { instr = Data (Load (Memoryop.of_wasm_load op)); vstack = v :: (List.drop vstack 1) }
  | Ast.Store op ->
    { instr = Data (Store (Memoryop.of_wasm_store op)); vstack = List.drop vstack 2 }
  | Ast.MemorySize ->
    { instr = Data MemorySize; vstack = v :: vstack }
  | Ast.MemoryGrow -> failwith "memory_grow unsupported"
  | Ast.Test op ->
    { instr = Data (Test (Testop.of_wasm op)); vstack = v :: (List.drop vstack 1) }
  | Ast.Convert _op -> failwith "convert unsupported"
  | Ast.Unary _op -> failwith "unary unsupported"
and seq_of_wasm (m : Ast.module_) (is : Ast.instr list) (vstack : string list) : t list * string list =
  let (instrs, vstack) = List.fold_left is
    ~init:([], vstack)
    ~f:(fun (instrs, vstack) instr ->
        let i = of_wasm m instr vstack in
        (i :: instrs, i.vstack)) in
    List.rev instrs, vstack
