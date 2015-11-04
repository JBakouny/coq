(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2014     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* Created under Benjamin Werner account by Bruno Barras to implement
   a call-by-value conversion algorithm and a lazy reduction machine
   with sharing, Nov 1996 *)
(* Addition of zeta-reduction (let-in contraction) by Hugo Herbelin, Oct 2000 *)
(* Irreversibility of opacity by Bruno Barras *)
(* Cleaning and lightening of the kernel by Bruno Barras, Nov 2001 *)
(* Equal inductive types by Jacek Chrzaszcz as part of the module
   system, Aug 2002 *)

open Util
open Names
open Term
open Univ
open Declarations
open Environ
open Closure
open Esubst

let unfold_reference ((ids, csts), infos) k =
  match k with
    | VarKey id when not (Idpred.mem id ids) -> None
    | ConstKey cst when not (Cpred.mem cst csts) -> None
    | _ -> unfold_reference infos k

let rec is_empty_stack = function
    [] -> true
  | Zupdate _::s -> is_empty_stack s
  | Zshift _::s -> is_empty_stack s
  | _ -> false

(* Compute the lift to be performed on a term placed in a given stack *)
let el_stack el stk =
  let n =
    List.fold_left
      (fun i z ->
        match z with
            Zshift n -> i+n
          | _ -> i)
      0
      stk in
  el_shft n el

let compare_stack_shape stk1 stk2 =
  let rec compare_rec bal stk1 stk2 =
  match (stk1,stk2) with
      ([],[]) -> bal=0
    | ((Zupdate _|Zshift _)::s1, _) -> compare_rec bal s1 stk2
    | (_, (Zupdate _|Zshift _)::s2) -> compare_rec bal stk1 s2
    | (Zapp l1::s1, _) -> compare_rec (bal+Array.length l1) s1 stk2
    | (_, Zapp l2::s2) -> compare_rec (bal-Array.length l2) stk1 s2
    | (ZcaseT(c1,_,_,_)::s1, ZcaseT(c2,_,_,_)::s2) ->
        bal=0 (* && c1.ci_ind  = c2.ci_ind *) && compare_rec 0 s1 s2
    | (Zfix(_,a1)::s1, Zfix(_,a2)::s2) ->
        bal=0 && compare_rec 0 a1 a2 && compare_rec 0 s1 s2
    | (_,_) -> false in
  compare_rec 0 stk1 stk2

type lft_constr_stack_elt =
    Zlapp of (lift * fconstr) array
  | Zlfix of (lift * fconstr) * lft_constr_stack
  | Zlcase of case_info * lift * fconstr * fconstr array
and lft_constr_stack = lft_constr_stack_elt list

let rec zlapp v = function
    Zlapp v2 :: s -> zlapp (Array.append v v2) s
  | s -> Zlapp v :: s

let pure_stack lfts stk =
  let rec pure_rec lfts stk =
    match stk with
        [] -> (lfts,[])
      | zi::s ->
          (match (zi,pure_rec lfts s) with
              (Zupdate _,lpstk)  -> lpstk
            | (Zshift n,(l,pstk)) -> (el_shft n l, pstk)
            | (Zapp a, (l,pstk)) ->
                (l,zlapp (Array.map (fun t -> (l,t)) a) pstk)
            | (Zfix(fx,a),(l,pstk)) ->
                let (lfx,pa) = pure_rec l a in
                (l, Zlfix((lfx,fx),pa)::pstk)
            | (ZcaseT(ci,p,br,e),(l,pstk)) ->
	       (* We really should avoid this Array.map (ind with many cstrs!) *)
                (l,Zlcase(ci,l,mk_clos e p,Array.map (mk_clos e) br)::pstk)) in
  snd (pure_rec lfts stk)

(* More on comparing stack shapes *)

type 'a stack_match =
  | Match of 'a
  | Prefix
  | Differ of ((stack*stack)*(stack*stack))

let rec eq_stk_elt_shape fmind = function
  | Zapp l1, Zapp l2 -> Array.length l1=Array.length l2
  | ZcaseT(ci1,_,_,_), ZcaseT(ci2,_,_,_) ->
    fmind ci1.ci_ind ci2.ci_ind
  | Zfix(_,par1), Zfix(_,par2) -> 
    (match shape_share fmind (par1,par2) with
    | Match _ -> true
    | _ -> false)
  | _ -> false

and shape_share fmind (s1,s2) =
  (* acc1 and acc2 have same shape; s1 and s2 in reverse order *)
  let rec eq_stack_shape_rev bal (acc1,acc2) = function
    | (Zshift _|Zupdate _ as i1)::s1, s2 ->
      eq_stack_shape_rev bal (i1::acc1,acc2) (s1,s2)
    | s1, (Zshift _|Zupdate _ as i2)::s2 ->
      eq_stack_shape_rev bal (acc1,i2::acc2) (s1,s2)
    | [],[] -> Match ()
    | (Zapp l1 as i1)::s1, (Zapp l2 as i2) :: s2 ->
      if bal + Array.length l1 < Array.length l2 then
	eq_stack_shape_rev (bal+Array.length l1) (i1::acc1,acc2) (s1,i2::s2)
      else if bal + Array.length l1 > Array.length l2 then
	eq_stack_shape_rev (bal-Array.length l2) (acc1,i2::acc2) (i1::s1,s2)
      else
	eq_stack_shape_rev 0 (i1::acc1,i2::acc2) (i1::s1,s2)
    | [], _ -> assert (bal<=0); Prefix
    | _, [] -> assert (bal>=0); Prefix 
    | ZcaseT(ci1,_,_,_), ZcaseT(ci2,_,_,_) when fmind ci1.ci_ind ci2.ci_ind ->
      assert (bal=0);
      eq_stack_shape_rev 0 (i1::acc1,i2::acc2) (i1::s1,s2)


  | Zfix(_,par1), Zfix(_,par2) -> 
    (match shape_share fmind (par1,par2) with
    | Match _ -> true
    | _ -> false)
	eq_stack_shape_rev (i1::acc1,i2::acc2) (s1,s2)

when
	(Array.length l2 < Array.length l1 && is_empty_stack s2) ||
	  (Array.length l1 < Array.length l2 && is_empty_stack s1) ->
      Prefix
    | i1::s1, i2::s2 ->
      if eq_stk_elt_shape fmind (i1,i2) then
	eq_stack_shape_rev (i1::acc1,i2::acc2) (s1,s2)
      else Differ((List.rev (i1::s1),acc1), (List.rev (i2::s2),acc2))
    (* one stack is a (shape) prefix of the other one: cannot conclude *)
    | s1,s2 -> Prefix in
  (* Compare stack shapes outside-in *)
  eq_stack_shape_rev ([],[]) (List.rev s1, List.rev s2)


(****************************************************************************)
(*                   Reduction Functions                                    *)
(****************************************************************************)

let whd_betaiota t =
  whd_val (create_clos_infos betaiota empty_env) (inject t)

let nf_betaiota t =
  norm_val (create_clos_infos betaiota empty_env) (inject t)

let whd_betaiotazeta x =
  match kind_of_term x with
    | (Sort _|Var _|Meta _|Evar _|Const _|Ind _|Construct _|
       Prod _|Lambda _|Fix _|CoFix _) -> x
    | _ -> whd_val (create_clos_infos betaiotazeta empty_env) (inject x)

let whd_betadeltaiota env t =
  match kind_of_term t with
    | (Sort _|Meta _|Evar _|Ind _|Construct _|
       Prod _|Lambda _|Fix _|CoFix _) -> t
    | _ -> whd_val (create_clos_infos betadeltaiota env) (inject t)

let whd_betadeltaiota_nolet env t =
  match kind_of_term t with
    | (Sort _|Meta _|Evar _|Ind _|Construct _|
       Prod _|Lambda _|Fix _|CoFix _|LetIn _) -> t
    | _ -> whd_val (create_clos_infos betadeltaiotanolet env) (inject t)

(* Beta *)

let beta_appvect c v =
  let rec stacklam env t stack =
    match kind_of_term t, stack with
        Lambda(_,_,c), arg::stacktl -> stacklam (arg::env) c stacktl
      | _ -> applist (substl env t, stack) in
  stacklam [] c (Array.to_list v)

let betazeta_appvect n c v =
  let rec stacklam n env t stack =
    if n = 0 then applist (substl env t, stack) else
    match kind_of_term t, stack with
        Lambda(_,_,c), arg::stacktl -> stacklam (n-1) (arg::env) c stacktl
      | LetIn(_,b,_,c), _ -> stacklam (n-1) (b::env) c stack
      | _ -> anomaly "Not enough lambda/let's" in
  stacklam n [] c (Array.to_list v)

(********************************************************************)
(*                         Conversion                               *)
(********************************************************************)

(* Conversion utility functions *)
type 'a conversion_function = env -> 'a -> 'a -> Univ.constraints
type 'a trans_conversion_function = transparent_state -> env -> 'a -> 'a -> Univ.constraints

exception NotConvertible
exception NotConvertibleVect of int
exception NotConvertibleStack of ((stack*stack)*(stack*stack))

let raw_compare_stacks f fmind lft1 stk1 lft2 stk2 cuniv =
  let rec cmp_rec pstk1 pstk2 cuniv =
    match (pstk1,pstk2) with
      | (z1::s1, z2::s2) ->
	 (* Compare z1 and z2 *before* s1 and s2 (because stacks
            tend to differ more often in their head) *)
          let cu1 =
            match (z1,z2) with
            | (Zlapp a1,Zlapp a2) -> array_fold_right2 f a1 a2 cuniv
            | (Zlfix(fx1,a1),Zlfix(fx2,a2)) ->
                let cu2 = f fx1 fx2 cuniv in
                cmp_rec a1 a2 cu2
            | (Zlcase(ci1,l1,p1,br1),Zlcase(ci2,l2,p2,br2)) ->
                if not (fmind ci1.ci_ind ci2.ci_ind) then
		  raise NotConvertible;
		let cu2 =
                  array_fold_right2 (fun c1 c2 -> f (l1,c1) (l2,c2)) br1 br2 cuniv in
		f (l1,p1) (l2,p2) cu2
            | _ -> assert false in
	  cmp_rec s1 s2 cu1
      | _ -> cuniv in
  cmp_rec (pure_stack lft1 stk1) (pure_stack lft2 stk2) cuniv

let compare_stacks f fmind lft1 stk1 lft2 stk2 cuniv =
  if compare_stack_shape stk1 stk2 then
    raw_compare_stacks f fmind lft1 stk1 lft2 stk2 cuniv
  else raise NotConvertible


let rec annot_with_lift lfts stk =
  match stk with
  | [] -> lfts,[]
  | zi::s ->
    let (lfts',s') = annot_with_lift lfts s in
    let lfts'' =
      match zi with
      | Zshift n -> el_shft n lfts'
      | _ -> lfts' in
    (lfts'',(lfts',zi)::s')

let raw_compare_stacks_share f fmind lft1 s1 lft2 s2 cu =
  let rec cmp_rec (acc1,acc2) (ofs1,ofs2) (stk1,stk2) cu =
    match stk1,stk2 with
      [],[] -> cu
    | (_,(Zshift _|Zupdate _ as i1))::s1, s2 ->
      cmp_rec (i1::acc1,acc2) (ofs1,ofs2) (s1,s2) cu
    | s1, (_,(Zshift _|Zupdate _ as i2))::s2 ->
      cmp_rec (acc1,i2::acc2) (ofs1,ofs2) (s1,s2) cu
    | (_,(Zapp v1 as i1))::s1, s2 when ofs1 >= Array.length v1 ->
      cmp_rec (i1::acc1,acc2) (0,ofs2) (s1,s2) cu
    | s1, (_,(Zapp v2 as i2))::s2 when ofs2 >= Array.length v2 ->
      cmp_rec (acc1,i2::acc2) (ofs1,0) (s1,s2) cu
    | ((lft1,Zapp v1)::s1, ((lft2,Zapp v2)::s2)) ->
      let fail() =
	let (vb1,va1) = array_chop (ofs1+1) v1 in
	let (vb2,va2) = array_chop (ofs2+1) v2 in
	raise (NotConvertibleStack
	  ((List.rev (Zapp vb1::acc1), append_stack va1 (List.map snd s1)),
	   (List.rev (Zapp vb2::acc2), append_stack va2 (List.map snd s2)))) in
      let cu1 =
	try f (lft1,v1.(ofs1)) (lft2,v2.(ofs2)) cu
	with NotConvertible|NotConvertibleVect _ -> fail() in
      cmp_rec (acc1,acc2) (ofs1+1,ofs2+1) (stk1,stk2) cu1
    | ((lft1,(ZcaseT(ci1,p1,br1,e1) as i1))::s1,
       (lft2,(ZcaseT(ci2,p2,br2,e2) as i2))::s2) ->
      let fail() =
	raise (NotConvertibleStack
	  ((List.rev(i1::acc1),List.map snd s1),
	   (List.rev(i2::acc2),List.map snd s2))) in
      let f' t1 t2 cu =
	try f (lft1,mk_clos e1 t1) (lft2,mk_clos e2 t2) cu
	with NotConvertible|NotConvertibleVect _ -> fail() in
      if not (fmind ci1.ci_ind ci2.ci_ind) then fail();
      let cu1 = f' p1 p2 cu in
      let cu2 = array_fold_right2 f' br1 br2 cu1 in
      cmp_rec (i1::acc1,i2::acc2) (ofs1,ofs2) (s1,s2) cu2
    | ((lft1,(Zfix(fx1,par1) as i1))::s1,
       (lft2,(Zfix(fx2,par2) as i2))::s2) ->
      let fail() =
	raise (NotConvertibleStack
	  ((List.rev(i1::acc1),List.map snd s1),
	   (List.rev(i2::acc2),List.map snd s2))) in
      let f' t1 t2 cu =
	try f (lft1,t1) (lft2,t2) cu
	with NotConvertible|NotConvertibleVect _ -> fail() in
      let cu1 = f' fx1 fx2 cu in
      let cu2 =
	try cmp_rec ([],[]) (0,0)
	      (snd (annot_with_lift lft1 par1),
	       snd (annot_with_lift lft2 par2)) cu1
	with NotConvertibleStack _ -> fail() in
      cmp_rec (i1::acc1,i2::acc2) (ofs1,ofs2) (s1,s2) cu2
    | _ -> assert false in
  (*  assert (shape_share fmind (s1,s2)=Match);*)
  try Match
	(cmp_rec ([],[]) (0,0)
	   (snd (annot_with_lift lft1 s1),
	    snd (annot_with_lift lft2 s2)) cu)
  with NotConvertibleStack diff -> Differ diff
					  
let compare_stacks_share f fmind lft1 s1 lft2 s2 cu =
  match shape_share fmind (s1,s2) with
  | Match _ -> raw_compare_stacks_share f fmind lft1 s1 lft2 s2 cu
  | Prefix -> Prefix
  | Differ diff -> Differ diff

(* Convertibility of sorts *)

(* The sort cumulativity is

    Prop <= Set <= Type 1 <= ... <= Type i <= ...

    and this holds whatever Set is predicative or impredicative
*)

type conv_pb =
  | CONV
  | CUMUL

let sort_cmp pb s0 s1 cuniv =
  match (s0,s1) with
    | (Prop c1, Prop c2) when pb = CUMUL ->
        if c1 = Null or c2 = Pos then cuniv   (* Prop <= Set *)
        else raise NotConvertible
    | (Prop c1, Prop c2) ->
        if c1 = c2 then cuniv else raise NotConvertible
    | (Prop c1, Type u) when pb = CUMUL -> assert (is_univ_variable u); cuniv
    | (Type u1, Type u2) ->
	assert (is_univ_variable u2);
	(match pb with
           | CONV -> enforce_eq u1 u2 cuniv
	   | CUMUL -> enforce_geq u2 u1 cuniv)
    | (_, _) -> raise NotConvertible


let conv_sort env s0 s1 = sort_cmp CONV s0 s1 empty_constraint

let conv_sort_leq env s0 s1 = sort_cmp CUMUL s0 s1 empty_constraint

let rec no_arg_available = function
  | [] -> true
  | Zupdate _ :: stk -> no_arg_available stk
  | Zshift _ :: stk -> no_arg_available stk
  | Zapp v :: stk -> Array.length v = 0 && no_arg_available stk
  | ZcaseT _ :: _ -> true
  | Zfix _ :: _ -> true

let rec no_nth_arg_available n = function
  | [] -> true
  | Zupdate _ :: stk -> no_nth_arg_available n stk
  | Zshift _ :: stk -> no_nth_arg_available n stk
  | Zapp v :: stk ->
      let k = Array.length v in
      if n >= k then no_nth_arg_available (n-k) stk
      else false
  | ZcaseT _ :: _ -> true
  | Zfix _ :: _ -> true

let rec no_case_available = function
  | [] -> true
  | Zupdate _ :: stk -> no_case_available stk
  | Zshift _ :: stk -> no_case_available stk
  | Zapp _ :: stk -> no_case_available stk
  | ZcaseT _ :: _ -> false
  | Zfix _ :: _ -> true

let in_whnf (t,stk) =
  match fterm_of t with
    | (FLetIn _ | FCaseT _ | FApp _ 
	  | FCLOS _ | FLIFT _ | FCast _) -> false
    | FLambda _ -> no_arg_available stk
    | FConstruct _ -> no_case_available stk
    | FCoFix _ -> no_case_available stk
    | FFix(((ri,n),(_,_,_)),_) -> no_nth_arg_available ri.(n) stk
    | (FFlex _ | FProd _ | FEvar _ | FInd _ | FAtom _ | FRel _) -> true
    | FLOCKED -> assert false

let rec whd_both infos (t1,stk1) (t2,stk2) =
  let st1' = whd_stack infos t1 stk1 in
  let st2' = whd_stack infos t2 stk2 in
  (* Now, whd_stack on term2 might have modified st1 (due to sharing),
       and st1 might not be in whnf anymore. If so, we iterate ccnv. *)
  if in_whnf st1' then (st1',st2') else whd_both infos st1' st2'

let rec consume_stack infos (t,stk) =
  match knr_step infos ?reds:(Some betadeltaiota) t stk with
  | Inl rdx, [] -> (* success *)
     true, knhr (rdx, [])
  | Inl rdx, stk' ->
     consume_stack infos (knhr (rdx, stk'))
  | Inr t', stk' ->
     false, (t',stk') (* failed to "consume" all the stack *)


let rec is_intro t =
  match fterm_of t with
  | (FCast(t,_,_)|FLIFT(_,t)) -> is_intro t
  | (FRel _|FAtom _|FFlex _|FInd _|FProd _|FEvar _ ) -> false
  | (FConstruct _|FFix _|FCoFix _|FLambda _ ) -> true
  | (FApp _|FCaseT _|FLetIn _|FCLOS _|FLOCKED _) -> assert false


let rec (@@) s1 s2 =
  match s1 with
    [] -> s2
  | [Zapp v] -> append_stack v s2
  | z::s1 -> z::(s1@@s2)

let consume_stack infos (t,stk) =
  let rec hnf_all (t,stk) =
    match knr_step infos ?reds:(Some betadeltaiota) t stk with
    | Inl rdx, stk' -> hnf_all (knhr (rdx, stk'))
    | Inr t', stk' -> (t',stk') in
  let it::rstk = List.rev stk in
  let stk = List.rev rstk in
  let (t',stk') = hnf_all (t,stk) in
  (is_intro t',(t',stk'@@[it]))

		     
(* Conversion between  [lft1]term1 and [lft2]term2 *)
let rec ccnv cv_pb l2r infos (lft1,term1) (lft2,term2) cuniv =
  eqappr cv_pb l2r infos (lft1, (term1,[])) (lft2, (term2,[])) cuniv

(* Conversion between [lft1](hd1 v1) and [lft2](hd2 v2) *)
and eqappr cv_pb l2r infos (lft1,st1) (lft2,st2) cuniv =
  Util.check_for_interrupt ();
  (* First head reduce both terms *)
  let ((hd1,v1),(hd2,v2)) = whd_both (snd infos) st1 st2 in
  let appr1 = (lft1,(hd1,v1)) and appr2 = (lft2,(hd2,v2)) in
  (* compute the lifts that apply to the head of the term (hd1 and hd2) *)
  let el1 = el_stack lft1 v1 in
  let el2 = el_stack lft2 v2 in
  match (fterm_of hd1, fterm_of hd2) with
    (* case of leaves *)
    | (FAtom a1, FAtom a2) ->
	(match kind_of_term a1, kind_of_term a2 with
	   | (Sort s1, Sort s2) ->
	       if not (is_empty_stack v1 && is_empty_stack v2) then
		 anomaly "conversion was given ill-typed terms (Sort)";
	       sort_cmp cv_pb s1 s2 cuniv
	   | (Meta n, Meta m) ->
               if n=m
	       then convert_stacks l2r infos lft1 lft2 v1 v2 cuniv
               else raise NotConvertible
	   | _ -> raise NotConvertible)
    | (FEvar ((ev1,args1),env1), FEvar ((ev2,args2),env2)) ->
        if ev1=ev2 then
          let u1 = convert_stacks l2r infos lft1 lft2 v1 v2 cuniv in
          convert_vect l2r infos el1 el2
            (Array.map (mk_clos env1) args1)
            (Array.map (mk_clos env2) args2) u1
        else raise NotConvertible

    (* 2 index known to be bound to no constant *)
    | (FRel n, FRel m) ->
        if reloc_rel n el1 = reloc_rel m el2
        then convert_stacks l2r infos lft1 lft2 v1 v2 cuniv
        else raise NotConvertible

    (* 2 constants, 2 local defined vars or 2 defined rels *)
    | (FFlex fl1, FFlex fl2) ->
       let oracle def1 def2 =
	 let (app1,app2) =
           if Conv_oracle.oracle_order l2r fl1 fl2 then
	     ((lft1, whd_stack (snd infos) def1 v1), appr2)
           else
	     (appr1, (lft2, whd_stack (snd infos) def2 v2)) in
	 eqappr cv_pb l2r infos app1 app2 cuniv in
       let sync_stacks ((ds1,s1),(ds2,s2)) =
	 (* To ensure consume_stack will make progress... *)
	 assert (ds1<>[] && ds2<>[]);
	 (* use oracle and try to consume only on one side? *)
	 let ok2,(t2',ds2') = consume_stack (snd infos) (hd2, ds2) in
	 let st2' = whd_stack (snd infos) t2' (ds2'@@s2) in
	 let ok1,(t1',ds1') = consume_stack (snd infos) (hd1, ds1) in
	 let st1' = whd_stack (snd infos) t1' (ds1'@@s1) in
	 if ok1||ok2 then eqappr cv_pb l2r infos (lft1,st1') (lft2,st2') cuniv
	 else raise NotConvertible in
       if eq_table_key fl1 fl2 then
	 match unfold_reference infos fl1 with
	 | Some def ->
	 (* try first intensional equality *)
	    (match compare_stacks_share (ccnv CONV l2r infos) eq_ind lft1 v1 lft2 v2 cuniv with
	     | Match cu -> cu
	     (* If one stack is a prefix of the other one, no obvious choice *)
	     | Prefix -> oracle def def
	     (* if stacks differ at one point, synchronize stacks *)
	     | Differ diff -> sync_stacks diff)
	 | None ->
	    convert_stacks l2r infos lft1 lft2 v1 v2 cuniv
       else
	 (match unfold_reference infos fl1, unfold_reference infos fl2 with
	  | Some def1, Some def2 ->
	     (match shape_share eq_ind (v1,v2) with
	      (* If one stack is a prefix of the other one (or equal),
	         no obvious choice *)
	      | (Match _|Prefix) -> oracle def1 def2
	      (* if stacks differ at one point, synchronize stacks *)
	      | Differ diff -> sync_stacks diff)
	  | Some def1, None ->
	     eqappr cv_pb l2r infos
		    (lft1,whd_stack (snd infos) def1 v1) appr2 cuniv
	  | None, Some def2 ->
	     eqappr cv_pb l2r infos
		    appr1 (lft2,whd_stack (snd infos) def2 v2) cuniv
	  | None, None -> raise NotConvertible)
    (* other constructors *)
    | (FLambda _, FLambda _) ->
        (* Inconsistency: we tolerate that v1, v2 contain shift and update but
           we throw them away *)
        if not (is_empty_stack v1 && is_empty_stack v2) then
	  anomaly "conversion was given ill-typed terms (FLambda)";
        let (_,ty1,bd1) = destFLambda mk_clos hd1 in
        let (_,ty2,bd2) = destFLambda mk_clos hd2 in
        let u1 = ccnv CONV l2r infos (el1,ty1) (el2,ty2) cuniv in
        ccnv CONV l2r infos (el_lift el1, bd1) (el_lift el2, bd2) u1

    | (FProd (_,c1,c2), FProd (_,c'1,c'2)) ->
        if not (is_empty_stack v1 && is_empty_stack v2) then
	  anomaly "conversion was given ill-typed terms (FProd)";
	(* Luo's system *)
        let u1 = ccnv CONV l2r infos (el1,c1) (el2,c'1) cuniv in
        ccnv cv_pb l2r infos (el_lift el1, c2) (el_lift el2, c'2) u1

    (* Eta-expansion on the fly *)
    | (FLambda _, _) ->
        if v1 <> [] then
	  anomaly "conversion was given unreduced term (FLambda)";
        let (_,_ty1,bd1) = destFLambda mk_clos hd1 in
	eqappr CONV l2r infos
	  (el_lift lft1, (bd1, [])) (el_lift lft2, (hd2, eta_expand_stack v2)) cuniv
    | (_, FLambda _) ->
        if v2 <> [] then
	  anomaly "conversion was given unreduced term (FLambda)";
        let (_,_ty2,bd2) = destFLambda mk_clos hd2 in
	eqappr CONV l2r infos
	  (el_lift lft1, (hd1, eta_expand_stack v1)) (el_lift lft2, (bd2, [])) cuniv

    (* only one constant, defined var or defined rel *)
    | (FFlex fl1, _)      ->
        (match unfold_reference infos fl1 with
           | Some def1 ->
	       eqappr cv_pb l2r infos (lft1, whd_stack (snd infos) def1 v1) appr2 cuniv
           | None -> raise NotConvertible)
    | (_, FFlex fl2)      ->
        (match unfold_reference infos fl2 with
           | Some def2 ->
	       eqappr cv_pb l2r infos appr1 (lft2, whd_stack (snd infos) def2 v2) cuniv
           | None -> raise NotConvertible)

    (* Inductive types:  MutInd MutConstruct Fix Cofix *)

    | (FInd ind1, FInd ind2) ->
        if eq_ind ind1 ind2
	then
          convert_stacks l2r infos lft1 lft2 v1 v2 cuniv
        else raise NotConvertible

    | (FConstruct (ind1,j1), FConstruct (ind2,j2)) ->
	if j1 = j2 && eq_ind ind1 ind2
	then
          convert_stacks l2r infos lft1 lft2 v1 v2 cuniv
        else raise NotConvertible

    | (FFix ((op1,(_,tys1,cl1)),e1), FFix((op2,(_,tys2,cl2)),e2)) ->
	(* TODO: compare stack shape first! *)
	if op1 = op2
	then
	  let n = Array.length cl1 in
          let fty1 = Array.map (mk_clos e1) tys1 in
          let fty2 = Array.map (mk_clos e2) tys2 in
          let fcl1 = Array.map (mk_clos (subs_liftn n e1)) cl1 in
          let fcl2 = Array.map (mk_clos (subs_liftn n e2)) cl2 in
	  let u1 = convert_vect l2r infos el1 el2 fty1 fty2 cuniv in
          let u2 =
            convert_vect l2r infos
	      (el_liftn n el1) (el_liftn n el2) fcl1 fcl2 u1 in
          convert_stacks l2r infos lft1 lft2 v1 v2 u2
        else raise NotConvertible

    | (FCoFix ((op1,(_,tys1,cl1)),e1), FCoFix((op2,(_,tys2,cl2)),e2)) ->
	(* TODO: compare stack shape first! *)
        if op1 = op2
        then
	  let n = Array.length cl1 in
          let fty1 = Array.map (mk_clos e1) tys1 in
          let fty2 = Array.map (mk_clos e2) tys2 in
          let fcl1 = Array.map (mk_clos (subs_liftn n e1)) cl1 in
          let fcl2 = Array.map (mk_clos (subs_liftn n e2)) cl2 in
          let u1 = convert_vect l2r infos el1 el2 fty1 fty2 cuniv in
          let u2 =
	    convert_vect l2r infos
	      (el_liftn n el1) (el_liftn n el2) fcl1 fcl2 u1 in
          convert_stacks l2r infos lft1 lft2 v1 v2 u2
        else raise NotConvertible

     (* Should not happen because both (hd1,v1) and (hd2,v2) are in whnf *)
     | ( (FLetIn _, _) | (FCaseT _,_) | (FApp _,_) | (FCLOS _,_) | (FLIFT _,_)
       | (_, FLetIn _) | (_,FCaseT _) | (_,FApp _) | (_,FCLOS _) | (_,FLIFT _)
       | (FLOCKED,_) | (_,FLOCKED) ) -> assert false

     (* In all other cases, terms are not convertible *)
     | _ -> raise NotConvertible

and convert_stacks l2r infos lft1 lft2 stk1 stk2 cuniv =
  compare_stacks (ccnv CONV l2r infos) eq_ind lft1 stk1 lft2 stk2 cuniv

and convert_vect l2r infos lft1 lft2 v1 v2 cuniv =
  let lv1 = Array.length v1 in
  let lv2 = Array.length v2 in
  if lv1 = lv2
  then
    let rec fold n univ =
      if n >= lv1 then univ
      else
        let u1 = ccnv CONV l2r infos (lft1,v1.(n)) (lft2,v2.(n)) univ in
        fold (n+1) u1 in
    fold 0 cuniv
  else raise NotConvertible

let clos_fconv trans cv_pb l2r evars env t1 t2 =
  let infos = trans, create_clos_infos ~evars betaiotazeta env in
  ccnv cv_pb l2r infos (el_id,inject t1) (el_id,inject t2) empty_constraint

let trans_fconv reds cv_pb l2r evars env t1 t2 =
  if eq_constr t1 t2 then empty_constraint
  else clos_fconv reds cv_pb l2r evars env t1 t2

let trans_conv_cmp ?(l2r=false) conv reds = trans_fconv reds conv l2r (fun _->None)
let trans_conv ?(l2r=false) ?(evars=fun _->None) reds = trans_fconv reds CONV l2r evars
let trans_conv_leq ?(l2r=false) ?(evars=fun _->None) reds = trans_fconv reds CUMUL l2r evars

let fconv = trans_fconv (Idpred.full, Cpred.full)

let conv_cmp ?(l2r=false) cv_pb = fconv cv_pb l2r (fun _->None)
let conv ?(l2r=false) ?(evars=fun _->None) = fconv CONV l2r evars
let conv_leq ?(l2r=false) ?(evars=fun _->None) = fconv CUMUL l2r evars

let conv_leq_vecti ?(l2r=false) ?(evars=fun _->None) env v1 v2 =
  array_fold_left2_i
    (fun i c t1 t2 ->
      let c' =
        try conv_leq ~l2r ~evars env t1 t2
        with NotConvertible -> raise (NotConvertibleVect i) in
      union_constraints c c')
    empty_constraint
    v1
    v2

(* option for conversion *)

let vm_conv = ref (fun cv_pb -> fconv cv_pb false (fun _->None))
let set_vm_conv f = vm_conv := f
let vm_conv cv_pb env t1 t2 =
  try
    !vm_conv cv_pb env t1 t2
  with Not_found | Invalid_argument _ ->
      (* If compilation fails, fall-back to closure conversion *)
      fconv cv_pb false (fun _->None) env t1 t2


let default_conv = ref (fun cv_pb ?(l2r=false) -> fconv cv_pb l2r (fun _->None))

let set_default_conv f = default_conv := f

let default_conv cv_pb ?(l2r=false) env t1 t2 =
  try
    !default_conv ~l2r cv_pb env t1 t2
  with Not_found | Invalid_argument _ ->
      (* If compilation fails, fall-back to closure conversion *)
      fconv cv_pb false (fun _->None) env t1 t2

let default_conv_leq = default_conv CUMUL
(*
let convleqkey = Profile.declare_profile "Kernel_reduction.conv_leq";;
let conv_leq env t1 t2 =
  Profile.profile4 convleqkey conv_leq env t1 t2;;

let convkey = Profile.declare_profile "Kernel_reduction.conv";;
let conv env t1 t2 =
  Profile.profile4 convleqkey conv env t1 t2;;
*)

(********************************************************************)
(*             Special-Purpose Reduction                            *)
(********************************************************************)

(* pseudo-reduction rule:
 * [hnf_prod_app env s (Prod(_,B)) N --> B[N]
 * with an HNF on the first argument to produce a product.
 * if this does not work, then we use the string S as part of our
 * error message. *)

let hnf_prod_app env t n =
  match kind_of_term (whd_betadeltaiota env t) with
    | Prod (_,_,b) -> subst1 n b
    | _ -> anomaly "hnf_prod_app: Need a product"

let hnf_prod_applist env t nl =
  List.fold_left (hnf_prod_app env) t nl

(* Dealing with arities *)

let dest_prod env =
  let rec decrec env m c =
    let t = whd_betadeltaiota env c in
    match kind_of_term t with
      | Prod (n,a,c0) ->
          let d = (n,None,a) in
	  decrec (push_rel d env) (add_rel_decl d m) c0
      | _ -> m,t
  in
  decrec env empty_rel_context

(* The same but preserving lets *)
let dest_prod_assum env =
  let rec prodec_rec env l ty =
    let rty = whd_betadeltaiota_nolet env ty in
    match kind_of_term rty with
    | Prod (x,t,c)  ->
        let d = (x,None,t) in
	prodec_rec (push_rel d env) (add_rel_decl d l) c
    | LetIn (x,b,t,c) ->
        let d = (x,Some b,t) in
	prodec_rec (push_rel d env) (add_rel_decl d l) c
    | Cast (c,_,_)    -> prodec_rec env l c
    | _               -> l,rty
  in
  prodec_rec env empty_rel_context

exception NotArity

let dest_arity env c =
  let l, c = dest_prod_assum env c in
  match kind_of_term c with
    | Sort s -> l,s
    | _ -> raise NotArity

let is_arity env c =
  try
    let _ = dest_arity env c in
    true
  with NotArity -> false
