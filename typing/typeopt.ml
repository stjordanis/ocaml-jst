(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1998 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Auxiliaries for type-based optimizations, e.g. array kinds *)

open Path
open Types
open Asttypes
open Typedtree
open Lambda

let scrape_ty env ty =
  let ty = Ctype.expand_head_opt env (Ctype.correct_levels ty) in
  match ty.desc with
  | Tconstr (p, _, _) ->
      begin match Env.find_type p env with
      | {type_unboxed = {unboxed = true; _}; _} ->
        begin match Typedecl.get_unboxed_type_representation env ty with
        | None -> ty
        | Some ty2 -> ty2
        end
      | _ -> ty
      | exception Not_found -> ty
      end
  | _ -> ty

let scrape env ty =
  (scrape_ty env ty).desc

let is_function_type env ty =
  match scrape env ty with
  | Tarrow (_, lhs, rhs, _) -> Some (lhs, rhs)
  | _ -> None

let is_base_type env ty base_ty_path =
  match scrape env ty with
  | Tconstr(p, _, _) -> Path.same p base_ty_path
  | _ -> false

let maybe_pointer_type env ty =
  let ty = scrape_ty env ty in
  if Ctype.maybe_pointer_type env ty then
    Pointer
  else
    Immediate

let maybe_pointer exp = maybe_pointer_type exp.exp_env exp.exp_type

type classification =
  | Int
  | Float
  | Lazy
  | Addr  (* anything except a float or a lazy *)
  | Any

let classify env ty =
  let ty = scrape_ty env ty in
  if maybe_pointer_type env ty = Immediate then Int
  else match ty.desc with
  | Tvar _ | Tunivar _ ->
      Any
  | Tconstr (p, _args, _abbrev) ->
      if Path.same p Predef.path_float then Float
      else if Path.same p Predef.path_lazy_t then Lazy
      else if Path.same p Predef.path_string
           || Path.same p Predef.path_bytes
           || Path.same p Predef.path_array
           || Path.same p Predef.path_nativeint
           || Path.same p Predef.path_int32
           || Path.same p Predef.path_int64 then Addr
      else begin
        try
          match (Env.find_type p env).type_kind with
          | Type_abstract ->
              Any
          | Type_record _ | Type_variant _ | Type_open ->
              Addr
        with Not_found ->
          (* This can happen due to e.g. missing -I options,
             causing some .cmi files to be unavailable.
             Maybe we should emit a warning. *)
          Any
      end
  | Tarrow _ | Ttuple _ | Tpackage _ | Tobject _ | Tnil | Tvariant _ ->
      Addr
  | Tlink _ | Tsubst _ | Tpoly _ | Tfield _ ->
      assert false

let array_type_kind env ty =
  match scrape env ty with
  | Tconstr(p, [elt_ty], _) | Tpoly({desc = Tconstr(p, [elt_ty], _)}, _)
    when Path.same p Predef.path_array ->
      begin match classify env elt_ty with
      | Any -> if Config.flat_float_array then Pgenarray else Paddrarray
      | Float -> if Config.flat_float_array then Pfloatarray else Paddrarray
      | Addr | Lazy -> Paddrarray
      | Int -> Pintarray
      end
  | Tconstr(p, [], _) | Tpoly({desc = Tconstr(p, [], _)}, _)
    when Path.same p Predef.path_floatarray ->
      Pfloatarray
  | _ ->
      (* This can happen with e.g. Obj.field *)
      Pgenarray

let array_kind exp = array_type_kind exp.exp_env exp.exp_type

let array_pattern_kind pat = array_type_kind pat.pat_env pat.pat_type

let bigarray_decode_type env ty tbl dfl =
  match scrape env ty with
  | Tconstr(Pdot(Pident mod_id, type_name), [], _)
    when Ident.name mod_id = "Stdlib__Bigarray" ->
      begin try List.assoc type_name tbl with Not_found -> dfl end
  | _ ->
      dfl

let kind_table =
  ["float32_elt", Pbigarray_float32;
   "float64_elt", Pbigarray_float64;
   "int8_signed_elt", Pbigarray_sint8;
   "int8_unsigned_elt", Pbigarray_uint8;
   "int16_signed_elt", Pbigarray_sint16;
   "int16_unsigned_elt", Pbigarray_uint16;
   "int32_elt", Pbigarray_int32;
   "int64_elt", Pbigarray_int64;
   "int_elt", Pbigarray_caml_int;
   "nativeint_elt", Pbigarray_native_int;
   "complex32_elt", Pbigarray_complex32;
   "complex64_elt", Pbigarray_complex64]

let layout_table =
  ["c_layout", Pbigarray_c_layout;
   "fortran_layout", Pbigarray_fortran_layout]

let bigarray_type_kind_and_layout env typ =
  match scrape env typ with
  | Tconstr(_p, [_caml_type; elt_type; layout_type], _abbrev) ->
      (bigarray_decode_type env elt_type kind_table Pbigarray_unknown,
       bigarray_decode_type env layout_type layout_table
                            Pbigarray_unknown_layout)
  | _ ->
      (Pbigarray_unknown, Pbigarray_unknown_layout)

let value_kind env ty =
  let rec loop env ~visited ~fuel ty : Lambda.value_kind =
    match scrape env ty with
    | Tconstr(p, _, _) when Path.same p Predef.path_int ->
      Pintval
    | Tconstr(p, _, _) when Path.same p Predef.path_char ->
      Pintval
    | Tconstr(p, _, _) when Path.same p Predef.path_float ->
      Pfloatval
    | Tconstr(p, _, _) when Path.same p Predef.path_int32 ->
      Pboxedintval Pint32
    | Tconstr(p, _, _) when Path.same p Predef.path_int64 ->
      Pboxedintval Pint64
    | Tconstr(p, _, _) when Path.same p Predef.path_nativeint ->
      Pboxedintval Pnativeint
    | Tconstr(p, _, _) ->
      if Numbers.Int.Set.mem ty.id visited || fuel <= 0 then
        Pgenval
      else begin
        let visited = Numbers.Int.Set.add ty.id visited in
        let fuel = fuel - 1 in
        match (Env.find_type p env).type_kind with
        | exception Not_found ->
          Pgenval
        | Type_variant constructors ->
          let is_constant (constructor : Types.constructor_declaration) =
            match constructor.cd_args with
            | Cstr_tuple [] -> true
            | _ -> false
          in
          if List.for_all is_constant constructors then
            Pintval
          else begin match constructors with
            | [ constructor ] ->
              let is_mutable, fields =
                match constructor.cd_args with
                | Cstr_tuple fields ->
                  false, List.map (loop env ~visited ~fuel) fields
                | Cstr_record labels ->
                  List.fold_left_map
                    (fun is_mutable (label:Types.label_declaration) ->
                       let is_mutable =
                         match label.ld_mutable with
                         | Mutable -> true
                         | Immutable -> is_mutable
                       in
                       is_mutable, loop env ~visited ~fuel label.ld_type)
                    false labels
              in
              if is_mutable then
                Pgenval
              else
                Pblock { tag = 0; fields }
            | _ ->
              Pgenval
          end
        | Type_record (labels, record_representation) ->
          let is_mutable, fields =
            List.fold_left_map
              (fun is_mutable (label:Types.label_declaration) ->
                 let is_mutable =
                   match label.ld_mutable with
                   | Mutable -> true
                   | Immutable -> is_mutable
                 in
                 is_mutable, loop env ~visited ~fuel label.ld_type)
              false labels
          in
          if is_mutable then
            Pgenval
          else begin match record_representation with
            | Record_regular ->
              Pblock { tag = 0; fields }
            | Record_float ->
              Pblock { tag = Obj.double_array_tag;
                       fields = List.map (fun _ -> Pfloatval) fields }
            | Record_inlined tag ->
              Pblock { tag; fields }
            | Record_unboxed _ ->
              begin match fields with
              | [field] -> field
              | [] | _::_ ->
                Misc.fatal_error "Records that are [Record_unboxed] should \
                  have exactly one field"
              end
            | Record_extension _ ->
              Pgenval
          end
        | Type_abstract | Type_open -> Pgenval
      end
    | Ttuple fields ->
      if Numbers.Int.Set.mem ty.id visited || fuel <= 0 then
        Pgenval
      else begin
        let visited = Numbers.Int.Set.add ty.id visited in
        let fuel = fuel - 1 in
        let fields = List.map (loop env ~visited ~fuel) fields in
        Pblock { tag = 0; fields }
      end
    | _ ->
      Pgenval
  in
  let max_depth = 2 in
  loop env ~visited:Numbers.Int.Set.empty ~fuel:max_depth ty

let function_return_value_kind env ty =
  match is_function_type env ty with
  | Some (_lhs, rhs) -> value_kind env rhs
  | None -> Pgenval

(** Whether a forward block is needed for a lazy thunk on a value, i.e.
    if the value can be represented as a float/forward/lazy *)
let lazy_val_requires_forward env ty =
  match classify env ty with
  | Any | Lazy -> true
  | Float -> Config.flat_float_array
  | Addr | Int -> false

(** The compilation of the expression [lazy e] depends on the form of e:
    constants, floats and identifiers are optimized.  The optimization must be
    taken into account when determining whether a recursive binding is safe. *)
let classify_lazy_argument : Typedtree.expression ->
                             [`Constant_or_function
                             |`Float_that_cannot_be_shortcut
                             |`Identifier of [`Forward_value|`Other]
                             |`Other] =
  fun e -> match e.exp_desc with
    | Texp_constant
        ( Const_int _ | Const_char _ | Const_string _
        | Const_int32 _ | Const_int64 _ | Const_nativeint _ )
    | Texp_function _
    | Texp_construct (_, {cstr_arity = 0}, _) ->
       `Constant_or_function
    | Texp_constant(Const_float _) ->
       if Config.flat_float_array
       then `Float_that_cannot_be_shortcut
       else `Constant_or_function
    | Texp_ident _ when lazy_val_requires_forward e.exp_env e.exp_type ->
       `Identifier `Forward_value
    | Texp_ident _ ->
       `Identifier `Other
    | _ ->
       `Other

let rec value_kind_union (k1 : Lambda.value_kind) (k2 : Lambda.value_kind) =
  match k1, k2 with
  | Pblock { tag = tag1; fields = fields1 }, Pblock { tag = tag2; fields = fields2 }
    when tag1 = tag2 && List.length fields1 = List.length fields2 ->
    Pblock { tag = tag1; fields = List.map2 value_kind_union fields1 fields2 }
  | _, _ ->
    if Lambda.equal_value_kind k1 k2 then k1
    else Pgenval
