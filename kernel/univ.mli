(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(** Universes. *)

type universe_level
type universe

module UniverseLSet : Set.S with type elt = universe_level

type universe_set = UniverseLSet.t
val empty_universe_set : universe_set

type universe_list = universe_level list
val empty_universe_list : universe_list

type 'a puniverses = 'a * universe_list
val out_punivs : 'a puniverses -> 'a

(** The universes hierarchy: Type 0- = Prop <= Type 0 = Set <= Type 1 <= ... 
   Typing of universes: Type 0-, Type 0 : Type 1; Type i : Type (i+1) if i>0 *)

val type0m_univ : universe  (** image of Prop in the universes hierarchy *)
val type0_univ : universe  (** image of Set in the universes hierarchy *)
val type1_univ : universe  (** the universe of the type of Prop/Set *)

val make_universe_level : Names.dir_path * int -> universe_level
val make_universe : universe_level -> universe
val make_univ : Names.dir_path * int -> universe

val is_type0_univ : universe -> bool
val is_type0m_univ : universe -> bool
val is_univ_variable : universe -> bool

val universe_level : universe -> universe_level option
val compare_levels : universe_level -> universe_level -> int
val eq_levels : universe_level -> universe_level -> bool

(** The type of a universe *)
val super : universe -> universe

(** The max of 2 universes *)
val sup   : universe -> universe -> universe

(** {6 Graphs of universes. } *)

type universes

type check_function = universes -> universe -> universe -> bool
val check_leq : check_function
val check_eq : check_function

(** The empty graph of universes *)
val initial_universes : universes
val is_initial_universes : universes -> bool

(** {6 Constraints. } *)

type constraints

(** A value with universe constraints. *)
type 'a constrained = 'a * constraints

(** A list of universes with universe constraints,
    representiong local universe variables and constraints *)
type universe_context = universe_list constrained

(** A set of universes with universe constraints.
    We linearize the set to a list after typechecking. 
    Beware, representation could change.
*)
type universe_context_set = universe_set constrained

(** A value in a universe context (resp. context set). *)
type 'a in_universe_context = 'a * universe_context
type 'a in_universe_context_set = 'a * universe_context_set

(** A universe substitution, note that no algebraic universes are
    involved *)
type universe_subst = (universe_level * universe_level) list

(** Constraints *)
val empty_constraint : constraints
val is_empty_constraint : constraints -> bool
val union_constraints : constraints -> constraints -> constraints

(** Constrained *)
val constraints_of : 'a constrained -> constraints

(** Universe contexts (as lists) *)
val empty_universe_context : universe_context
val is_empty_universe_context : universe_context -> bool
val fresh_universe_instance : ?dp:Names.dir_path -> universe_context -> universe_list


(** Universe contexts (as sets) *)
val empty_universe_context_set : universe_context_set
val singleton_universe_context_set : universe_level -> universe_context_set
val is_empty_universe_context_set : universe_context_set -> bool
val union_universe_context_set : universe_context_set -> universe_context_set -> 
  universe_context_set
val add_constraints_ctx : universe_context_set -> constraints -> universe_context_set

(** [check_context_subset s s'] checks that [s] is implied by [s'] as a set of constraints. *)
val check_context_subset : universe_context_set -> universe_context -> bool

(** Arbitrary choice of linear order of the variables 
    and normalization of the constraints *)
val context_of_universe_context_set : universe_context_set -> universe_context

(** Make a universe level substitution: the list must match the context variables. *)
val make_universe_subst : universe_list -> universe_context -> universe_subst

(** Get the instantiated graph. *)
val instantiate_univ_context : universe_subst -> universe_context -> constraints

(** Build a fresh instance for a given context, its associated substitution and 
    the instantiated constraints. *)

val fresh_instance_from_context : ?dp:Names.dir_path -> universe_context -> 
  (universe_list * universe_subst) constrained

val fresh_instance_from : ?dp:Names.dir_path -> universe_context -> 
  universe_list in_universe_context_set

(** Substitution of universes. *)
val subst_univs_level : universe_subst -> universe_level -> universe_level
val subst_univs_universe : universe_subst -> universe -> universe
val subst_univs_constraints : universe_subst -> constraints -> constraints

(** Raises universe inconsistency if not compatible. *)
val check_consistent_constraints : universe_context_set -> constraints -> unit

type constraint_function = universe -> universe -> constraints -> constraints

val enforce_leq : constraint_function
val enforce_eq : constraint_function
val enforce_eq_level : universe_level -> universe_level -> constraints -> constraints

(** {6 ... } *)
(** Merge of constraints in a universes graph.
  The function [merge_constraints] merges a set of constraints in a given
  universes graph. It raises the exception [UniverseInconsistency] if the
  constraints are not satisfiable. *)

type constraint_type = Lt | Le | Eq

(** Type explanation is used to decorate error messages to provide
  useful explanation why a given constraint is rejected. It is composed
  of a path of universes and relation kinds [(r1,u1);..;(rn,un)] means
   .. <(r1) u1 <(r2) ... <(rn) un (where <(ri) is the relation symbol
  denoted by ri, currently only < and <=). The lowest end of the chain
  is supposed known (see UniverseInconsistency exn). The upper end may
  differ from the second univ of UniverseInconsistency because all
  universes in the path are canonical. Note that each step does not
  necessarily correspond to an actual constraint, but reflect how the
  system stores the graph and may result from combination of several
  constraints...
*)
type explanation = (constraint_type * universe) list

exception UniverseInconsistency of
    constraint_type * universe * universe * explanation

val merge_constraints : constraints -> universes -> universes
val normalize_universes : universes -> universes
val sort_universes : universes -> universes

(** {6 Support for sort-polymorphism } *)

val fresh_local_univ : unit -> universe

val solve_constraints_system : universe option array -> universe array ->
  universe array

val subst_large_constraint : universe -> universe -> universe -> universe

val subst_large_constraints :
  (universe * universe) list -> universe -> universe

val no_upper_constraints : universe -> constraints -> bool

(** Is u mentionned in v (or equals to v) ? *)

val univ_depends : universe -> universe -> bool

(** {6 Pretty-printing of universes. } *)

val pr_uni_level : universe_level -> Pp.std_ppcmds
val pr_uni : universe -> Pp.std_ppcmds
val pr_universes : universes -> Pp.std_ppcmds
val pr_constraints : constraints -> Pp.std_ppcmds
val pr_universe_list : universe_list -> Pp.std_ppcmds
val pr_universe_set : universe_set -> Pp.std_ppcmds
val pr_universe_context : universe_context -> Pp.std_ppcmds
val pr_universe_context_set : universe_context_set -> Pp.std_ppcmds

(** {6 Dumping to a file } *)

val dump_universes :
  (constraint_type -> string -> string -> unit) ->
  universes -> unit

(** {6 Hash-consing } *)

val hcons_univlevel : universe_level -> universe_level
val hcons_univ : universe -> universe
val hcons_constraints : constraints -> constraints
val hcons_universe_set : universe_set -> universe_set
val hcons_universe_context : universe_context -> universe_context
val hcons_universe_context_set : universe_context_set -> universe_context_set 

(******)
