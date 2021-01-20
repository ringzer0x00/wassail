open Core_kernel
open Helpers

module T = struct
  (** A tree representation with some utilities *)
  type t = {
    children: IntSet.t IntMap.t; (* Representation of the tree in a forward manner: edges from a node to children *)
    parent: int IntMap.t;  (* Representation of the tree in a backward manner: edge from a node to its parent *)
    entry : int; (* The entry node of the tree *)
    nodes : IntSet.t; (* All nodes of the tree *)
  }
  [@@deriving equal, compare]

  (** Converts the tree to its string representation *)
  let to_string (tree : t) : string =
    IntMap.to_string tree.children IntSet.to_string
end
include T
include Test.Helpers(T)

(** Return the children of a node in the tree *)
let children (tree : t) (node : int) : IntSet.t =
  match IntMap.find tree.children node with
  | Some c -> c
  | None -> failwith (Printf.sprintf "No children found in tree %s, node %d" (to_string tree) node)

(** Compute the reverse representation of a tree, from a map of nodes to their children to a map of nodes to their (only) parent *)
let revert_tree_representation (entry : int) (tree : IntSet.t IntMap.t) : int IntMap.t =
  let rec visit (rtree : int IntMap.t) (node : int) =
    let children = match IntMap.find tree node with Some c -> c | None -> failwith "no children found when reverting tree computation" in
    let rtree_with_children = IntSet.fold children ~init:rtree ~f:(fun rtree child ->
        IntMap.add_exn rtree ~key:child ~data:node) in
    IntSet.fold children ~init:rtree_with_children ~f:visit
  in
  visit IntMap.empty entry

(** Constructs a tree from its representation as a map (encoded as a list) from nodes to their children *)
let of_children_map (entry : int) (children_map : (int * int list) list) : t =
  let check_validity_of_children_map = true in
  (* First check that the children map is correctly constructed *)
  if check_validity_of_children_map then begin
    (* - Every node that is listed as a children is also listed as having children (a node without children has an empty list of children *)
    let all_keys = IntSet.of_list (List.map children_map ~f:fst) in
    let all_children = List.fold_left children_map ~init:IntSet.empty ~f:(fun acc (_, cs) -> IntSet.union acc (IntSet.of_list cs)) in
    if not (IntSet.for_all all_children ~f:(fun c -> IntSet.mem all_keys c)) then
      failwith (Printf.sprintf "of_children_map: invalid tree spec  where not all nodes are specified: %s" (String.concat ~sep:" | " (List.map children_map ~f:(fun (p, cs) -> Printf.sprintf "%d -> %s" p (String.concat ~sep:"," (List.map cs ~f:string_of_int))))));
    (* - Every node is the children of only one node. We actually check that when concatenating all children, every element is unique. *)
    let all_children_l = List.fold_left children_map ~init:[] ~f:(fun acc (_, cs) -> cs @ acc) in
    if not ((IntSet.length all_children) = List.length all_children_l) then
      (* if both sizes are the same, then the list only contains unique elements *)
      failwith (Printf.sprintf "of_children_map: invalid tree spec where some children have multiple parents: %s" (String.concat ~sep:" | " (List.map children_map ~f:(fun (p, cs) -> Printf.sprintf "%d -> %s" p (String.concat ~sep:"," (List.map cs ~f:string_of_int))))));
  end;
  let children = IntMap.map (IntMap.of_alist_exn children_map) ~f:IntSet.of_list in
  { children;
    parent = revert_tree_representation entry children;
    entry;
    nodes = IntSet.of_list (IntMap.keys children) }

(** Extract the parent of a node in constant time *)
let parent (tree : t) (node : int) : int option =
  if node = tree.entry then
    None
  else IntMap.find tree.parent node

(** Just like parent, but throws an exception if there is no parent *)
let parent_exn (tree : t) (node : int) : int = match parent tree node with
  | Some p -> p
  | None -> failwith "Node has no parent"

(** Changes the parent of a node *)
let set_parent (tree : t) (node : int) (new_parent : int) : t =
  let disconnected_from_old_parent = match parent tree node with
    | Some old_parent -> IntMap.update tree.children old_parent ~f:(function
        | Some children -> IntSet.remove children node
        | None -> IntSet.empty)
    | None -> tree.children in
  { tree with parent = IntMap.update tree.parent node ~f:(fun _ -> new_parent);
              children = IntMap.update disconnected_from_old_parent new_parent ~f:(function
                  | Some children -> IntSet.add children node
                  | None -> IntSet.singleton node) }

(** Helper function used internally to fold over ancestors of a given node *)
let fold_ancestors (tree : t) (node : int) (init : 'a) (f : 'a -> int -> 'a) : 'a =
  let rec loop (node : int) (acc : 'a) : 'a =
    match parent tree node with
    | Some p -> loop p (f acc p)
    | None when node = tree.entry -> acc
    | None -> failwith (Printf.sprintf "fold_ancestors: missing parent link in tree? node %d has no parent" node) in
  loop node init

(** Computes the nearest common ancestor of two nodes in a tree *)
let nca (tree : t) (node1 : int) (node2 : int) : int option =
  if node1 = node2 then
    Some node2
  else
    (* Compute ancestors of node1 (including node1) *)
    let n1_ancestors = IntSet.add (fold_ancestors tree node1 IntSet.empty IntSet.add) node1 in
    if IntSet.mem n1_ancestors node2 then
      (* either n2 is in the ancestor of n1, then it is clearly the nca *)
      Some node2
    else
      (* othewsie, go over the ancestors of n1: we look for the first common
         ancestor, starting from node2 *)
      fold_ancestors tree node2 None (fun acc n ->
          match acc with
          | Some _ -> acc (* ancestor already found *)
          | None when IntSet.mem n1_ancestors n ->
            Some n (* nearest common ancestor found *)
          | None -> acc)

module Test = struct
  let%test "revert tree computation" =
    let entry : int = 0 in
    let tree : IntSet.t IntMap.t = IntMap.map ~f:IntSet.of_list (IntMap.of_alist_exn [(0, [1; 2]); (1, [3; 4]); (2, [5]); (3, []); (4, []); (5, [])]) in
    let actual = revert_tree_representation entry tree in
    let expected : int IntMap.t = IntMap.of_alist_exn [(1, 0); (3, 1); (4, 1); (2, 0); (5, 2)] in
    IntMap.equal Int.(=) actual expected

  let%test "rtree nearest common ancestor"=
    let tree : t = of_children_map 0 [(0, [1; 2]); (1, [3; 4]); (2, [5]); (3, []); (4, []); (5, [])] in
    (match nca tree 3 1 with Some 1 -> true | _ -> false) &&
    (match nca tree 3 4 with Some 1 -> true | _ -> false) &&
    (match nca tree 0 4 with Some 0 -> true | _ -> false)
end
