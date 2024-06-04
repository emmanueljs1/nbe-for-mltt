module D = Domain
module Syn = Syntax
type env_entry =
    Term of {term : D.t; tp : D.t}
  | TopLevel of {term : D.t; tp : D.t}
type env = env_entry list

let add_term ~term ~tp env = Term {term; tp} :: env

type error =
    Cannot_synth_term of Syn.t
  | Type_mismatch of D.t * D.t
  | Expecting_universe of D.t
  | Misc of string

let pp_error = function
  | Cannot_synth_term t -> "Cannot synthesize the type of:\n" ^ Syn.pp t
  | Type_mismatch (t1, t2) -> "Cannot equate\n" ^ D.pp t1 ^ " with\n" ^ D.pp t2
  | Expecting_universe d -> "Expected some universe but found\n" ^ D.pp d
  | Misc s -> s

exception Type_error of error

let tp_error e = raise (Type_error e)

let env_to_sem_env =
  List.map
    (function
      | TopLevel {term; _} -> term
      | Term {term; _} -> term)

let get_var env n = match List.nth env n with
  | Term {term = _; tp} -> tp
  | TopLevel {tp; _} -> tp

let assert_subtype size t1 t2 =
  if Nbe.check_tp ~subtype:true size t1 t2
  then ()
  else tp_error (Type_mismatch (t1, t2))

let rec check ~env ~size ~term ~tp =
  match term with
  | Syn.Let (def, body) ->
    let def_tp = synth ~env ~size ~term:def in
    let def_val = Nbe.eval def (env_to_sem_env env) in
    check ~env:(add_term ~term:def_val ~tp:def_tp env) ~size:(size + 1) ~term:body ~tp
  | Nat ->
    begin
      match tp with
      | D.Uni _ -> ()
      | t -> tp_error (Expecting_universe t)
    end
  | Pi (l, r) | Sig (l, r) ->
    begin
      match tp with
      | D.Uni _ ->
        begin
          check ~env ~size ~term:l ~tp;
          let l_sem = Nbe.eval l (env_to_sem_env env) in
          let var = D.mk_var l_sem size in
          check ~env:(add_term ~term:var ~tp:l_sem env) ~size ~term:r ~tp
        end
      | _ -> tp_error (Expecting_universe tp)
    end
  | Lam body ->
    begin
      match tp with
      | D.Pi (arg_tp, clos) ->
        let var = D.mk_var arg_tp size in
        let dest_tp = Nbe.do_clos clos var in
        check ~env:(add_term ~term:var ~tp:arg_tp env) ~size:(size + 1) ~term:body ~tp:dest_tp;
      | t -> tp_error (Misc ("Expecting Pi but found\n" ^ D.pp t))
    end
  | Pair (left, right) ->
    begin
      match tp with
      | D.Sig (left_tp, right_tp) ->
        check ~env ~size ~term:left ~tp:left_tp;
        let left_sem = Nbe.eval left (env_to_sem_env env) in
        check ~env ~size ~term:right ~tp:(Nbe.do_clos right_tp left_sem)
      | t -> tp_error (Misc ("Expecting Sig but found\n" ^ D.pp t))
    end
  | Uni i ->
    begin
      match tp with
      | Uni j when i < j -> ()
      | t ->
        let msg =
          "Expecting universe over " ^ string_of_int i ^ " but found\n" ^ D.pp t in
        tp_error (Misc msg)
    end
  | term -> assert_subtype size (synth ~env ~size ~term) tp

and synth ~env ~size ~term =
  match term with
  | Syn.Var i -> get_var env i
  | Syn.Let (def, body) ->
    let def_tp = synth ~env ~size ~term:def in
    let def_val = Nbe.eval def (env_to_sem_env env) in
    synth ~env:(add_term ~term:def_val ~tp:def_tp env) ~size:(size + 1) ~term:body
  | Check (term, tp') ->
    check_tp ~env ~size ~term:tp';
    let tp = Nbe.eval tp' (env_to_sem_env env) in
    check ~env ~size ~term ~tp;
    tp
  | Zero -> D.Nat
  | Suc term -> check ~env ~size ~term ~tp:Nat; D.Nat
  | Fst p ->
    begin
      match synth ~env ~size ~term:p with
      | Sig (left_tp, _) -> left_tp
      | t -> tp_error (Misc ("Expecting Sig but found\n" ^ D.pp t))
    end
  | Snd p ->
    begin
      match synth ~env ~size ~term:p with
      | Sig (_, right_tp) ->
        let proj = Nbe.eval (Fst p) (env_to_sem_env env) in
        Nbe.do_clos right_tp proj
      | t -> tp_error (Misc ("Expecting Sig but found\n" ^ D.pp t))
    end
  | Ap (f, a) ->
    begin
      match synth ~env ~size ~term:f with
      | Pi (src, dest) ->
        check ~env ~size ~term:a ~tp:src;
        let a_sem = Nbe.eval a (env_to_sem_env env) in
        Nbe.do_clos dest a_sem
      | t -> tp_error (Misc ("Expecting Pi but found\n" ^ D.pp t))
    end
  | NRec (mot, zero, suc, n) ->
    check ~env ~size ~term:n ~tp:Nat;
    let var = D.mk_var Nat size in
    check_tp ~env:(add_term ~term:var ~tp:Nat env) ~size:(size + 1) ~term:mot;
    let sem_env = env_to_sem_env env in
    let zero_tp = Nbe.eval mot (Zero :: sem_env) in
    let ih_tp = Nbe.eval mot (var :: sem_env) in
    let ih_var = D.mk_var ih_tp (size + 1) in
    let suc_tp = Nbe.eval mot (Suc var :: sem_env) in
    check ~env ~size ~term:zero ~tp:zero_tp;
    check
      ~env:(add_term ~term:var ~tp:Nat env |> add_term ~term:ih_var ~tp:ih_tp)
      ~size:(size + 2)
      ~term:suc
      ~tp:suc_tp;
    Nbe.eval mot (Nbe.eval n sem_env :: sem_env)
  | _ -> tp_error (Cannot_synth_term term)

and check_tp ~env ~size ~term =
  match term with
  | Syn.Nat -> ()
  | Uni _ -> ()
  | Pi (l, r) | Sig (l, r) ->
    check_tp ~env ~size ~term:l;
    let l_sem = Nbe.eval l (env_to_sem_env env) in
    let var = D.mk_var l_sem size in
    check_tp ~env:(add_term ~term:var ~tp:l_sem env) ~size:(size + 1) ~term:r
  | Let (def, body) ->
    let def_tp = synth ~env ~size ~term:def in
    let def_val = Nbe.eval def (env_to_sem_env env) in
    check_tp ~env:(add_term ~term:def_val ~tp:def_tp env) ~size:(size + 1) ~term:body
  | term ->
    begin
      match synth ~env ~size ~term with
      | D.Uni _ -> ()
      | t -> tp_error (Expecting_universe t)
    end
