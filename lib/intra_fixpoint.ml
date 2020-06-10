open Core_kernel
open Helpers

(** The results of an intra analysis are a mapping from block ids to their in and out values *)
type intra_results = (Transfer.result * Transfer.result) IntMap.t

(** Analyzes a CFG. Returns the final state after computing the transfer of the entire function *)
let analyze
    (cfg : Cfg.t) (* The CFG to analyze *)
    (summaries : Summary.t IntMap.t) (* The current summaries *)
    (module_ : Wasm_module.t) : (* The overall module, needed to access types, tables, etc. *)
  intra_results
  =
  let bottom = Transfer.Uninitialized in
  let init = Domain.init cfg module_.nglobals in
  let data = ref (IntMap.of_alist_exn (List.map (IntMap.keys cfg.basic_blocks)
                                         ~f:(fun idx ->
                                             (idx, (bottom, bottom))))) in
  (* Handles exit block properly: if we reach the exit block, we need to model a "return" instruction on paths that have not done so explicitly *)
  let handle_exit (block_idx : int) (s : Domain.state) : Domain.state =
    if block_idx = cfg.exit_block && (List.length cfg.return_types = 1) then
      (* It is the exit block, and it has a return value *)
      if List.is_empty s.vstack then
        (* The vstack is already empty, we don't need to do anything (there was a return instr already) *)
        s
      else
        (* The vstack is not empty, its top value should be returned *)
        let v, vstack = Vstack.pop s.vstack in
        assert Stdlib.(vstack = []); (* make sure there are no other values on the stack *)
        (* Now we add the constraint ret = v *)
        let ret = Domain.return_name cfg.idx in
        Domain.add_constraint { s with vstack = [] } ret v
    else
      (* not the exit block, nothing to do *)
      s
  in
  (* Merges the entry states before analyzing the given block *)
  let merge_flows (block : Basic_block.t) (states : Domain.state list) : Domain.state =
    match states with
    | [] -> (* no in state, use init *)
      init
    | s :: [] -> (* single state *)
      handle_exit block.idx s
    | _ ->
      (* multiple states, block should be a control-flow merge *)
      begin match block.content with
        | ControlMerge (_vstack', (locals, globals, ret)) ->
          (* for each state in states *)
          let states' = List.map states ~f:(fun s ->
              (* replace the top of the stack if necessary *)
              let vstack = match ret with
                | Some v -> v :: (List.drop s.vstack 1)
                | None -> s.vstack in
              (* add constraints for locals and globals *)
              let constraints = List.mapi locals ~f:(fun i l -> (l, List.nth_exn s.locals i)) @
                                List.mapi globals ~f:(fun i g -> (g, List.nth_exn s.globals i)) in
              Domain.add_constraints
                  { s with locals = locals; globals = globals; vstack = vstack }
                  constraints) in
          (* now join all the states: their vstack, locals and globals should be
             the same, only their memory might differ, but joining memory is
             handled in memory.ml by computing the most general memory *)
          List.reduce_exn states' ~f:Domain.join
        | _ when block.idx = cfg.exit_block ->
          (* The exit block can have multiple input states, they just need to be joined *)
          (* TODO: ideally, we should handle this as a control merge block *)
          List.reduce_exn (List.map states ~f:(handle_exit block.idx)) ~f:Domain.join
        | _ -> failwith (Printf.sprintf "Invalid block with multiple input states: %d" block.idx)
      end
  in
  (* Analyzes one block, returning the pre and post states *)
  let analyze_block (block_idx : int) : Domain.state * Transfer.result =
      (* The block to analyze *)
      let block = Cfg.find_block_exn cfg block_idx in
      let predecessors = Cfg.predecessors cfg block_idx in
      (* in_state is the join of all the the out_state of the predecessors.
         Special case: if the out_state of a predecessor is not a simple one, that means we are the target of a break.
         If this is the case, we pick the right branch, according to the edge data *)
      let pred_states = (List.map predecessors ~f:(fun (idx, d) -> match (snd (IntMap.find_exn !data idx), d) with
          | Simple s, _ -> s
          | Branch (t, _), Some true -> t
          | Branch (_, f), Some false -> f
          | _ -> failwith "should not happen")) in
      let in_state = merge_flows block pred_states in
      Printf.printf "pred states: %d" (List.length pred_states);
(*      match pred_states with
      | [] -> init
      let in_state = match (List.fold_left pred_states ~init:bottom ~f:(fun acc res ->
          Transfer.join_result acc (match res with
              | (Branch (t, _), Some true) -> Simple (handle_exit block_idx t)
              | (Branch (_, f), Some false) -> Simple (handle_exit block_idx f)
              | (Branch _, None) -> failwith "should not happen"
              | (Simple s, _) -> Simple (handle_exit block_idx s)
              | (s, _) -> s)))
        with
        | Simple r -> r
        | Uninitialized -> init
        | _ -> failwith "should not happen" in *)
      (* We analyze it *)
      let result = Transfer.transfer block in_state summaries module_ cfg in
(* moved up top
      if block_idx = cfg.exit_block && (List.length cfg.return_types = 1) then
          (* If it is the exit block and there is a return value, we add the extra constraint that ret = the top of the stack, and we clear the stack *)
        (in_state, match result with
          | Simple s ->
            let (v, vstack) = Vstack.pop s.vstack in
            assert Stdlib.(vstack = []);
            let ret = Domain.return_name cfg.idx in
            Simple (Domain.add_constraint { s with vstack = [] } ret v)
          | Uninitialized -> failwith "should not happen"
          | Branch _ -> failwith "should not happen")
      else *)
        (in_state, result)
  in
  let rec fixpoint (worklist : IntSet.t) (iteration : int) : unit =
    if IntSet.is_empty worklist then
      () (* No more elements to consider. We can stop here *)
    else
      let block_idx = IntSet.min_elt_exn worklist in
      let (in_state, out_state) = analyze_block block_idx in
      (* Has out state changed? *)
      let previous_out_state = snd (IntMap.find_exn !data block_idx) in
      match previous_out_state with
      | st when Transfer.compare_result out_state st = 0 ->
        (* Didn't change, we can safely ignore the successors *)
        (* TODO: make sure that this is true. If not, maybe we just have to put all blocks on the worklist for the first iteration(s) *)
        fixpoint (IntSet.remove worklist block_idx) (iteration+1)
      | _ ->
        (* Update the out state in the analysis results.
           We join with the previous results *)
        let new_out_state = Transfer.join_result out_state previous_out_state in
        data := IntMap.set !data ~key:block_idx ~data:(Simple in_state, new_out_state);
        (* And recurse by adding all successors *)
        let successors = Cfg.successors cfg block_idx in
        fixpoint (IntSet.union (IntSet.remove worklist block_idx) (IntSet.of_list successors)) (iteration+1)
  in
  (* Performs narrowing by re-analyzing once each block *)
  let rec _narrow (blocks : int list) : unit = match blocks with
    | [] -> ()
    | block_idx :: blocks ->
      Printf.printf "narrowing block %d\n" block_idx;
      let (in_state, out_state) = analyze_block block_idx in
      data := IntMap.set !data ~key:block_idx ~data:(Simple in_state, out_state);
      _narrow blocks
  in
  fixpoint (IntSet.singleton cfg.entry_block) 1;
  (* _narrow (IntMap.keys cfg.basic_blocks); *)
  !data

(* Extract the out state from intra-procedural results *)
let out_state (cfg : Cfg.t) (results : (Transfer.result * Transfer.result) IntMap.t) : Domain.state =
    match snd (IntMap.find_exn results cfg.exit_block) with
  | Simple s -> s
  | _ -> failwith "Multiple exits for function?"
