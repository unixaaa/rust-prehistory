(*
 * LLVM translator.
 *)

open Common;;

let trans_crate
    (sem_cx:Semant.ctxt)
    (llctx:Llvm.llcontext)
    (sess:Session.sess)
    (crate:Ast.crate)
    : Llvm.llmodule =

  (* Translation of our node_ids into LLVM identifiers, which are strings. *)
  let next_anon_llid = ref 0 in
  let num_llid num klass = Printf.sprintf "%s%d" klass num in
  let anon_llid klass =
    let llid = num_llid !next_anon_llid klass in
    next_anon_llid := !next_anon_llid + 1;
    llid
  in
  let node_llid (node_id_opt:node_id option) : (string -> string) =
    match node_id_opt with
        None -> anon_llid
      | Some (Node num) -> num_llid num
  in

  (*
   * Returns a bogus value for use in stub code that hasn't been implemented
   * yet.
   *
   * TODO: On some joyous day, remove me.
   *)
  let bogus = Llvm.const_null (Llvm.i32_type llctx) in
  let bogus_ptr = Llvm.const_null (Llvm.pointer_type (Llvm.i32_type llctx)) in

  let nil = Llvm.undef (Llvm.void_type llctx) in

  let ty_of = Hashtbl.find sem_cx.Semant.ctxt_all_item_types in

  let filename = Session.filename_of sess.Session.sess_in in
  let llmod = Llvm.create_module llctx filename in

  let trans_mach_ty (mty:ty_mach) : Llvm.lltype =
    let tycon =
      match mty with
          TY_u8 | TY_s8 -> Llvm.i8_type
        | TY_u16 | TY_s16 -> Llvm.i16_type
        | TY_u32 | TY_s32 -> Llvm.i32_type
        | TY_u64 | TY_s64 -> Llvm.i64_type
        | TY_f32 -> Llvm.float_type
        | TY_f64 -> Llvm.double_type
    in
    tycon llctx
  in

  let rec trans_ty (ty:Ast.ty) : Llvm.lltype =
    match ty with
        Ast.TY_any -> Llvm.opaque_type llctx
      | Ast.TY_nil -> Llvm.void_type llctx
      | Ast.TY_bool -> Llvm.i1_type llctx
      | Ast.TY_mach mty -> trans_mach_ty mty
      | Ast.TY_int -> Llvm.i32_type llctx (* FIXME: bignums? *)
      | Ast.TY_char -> Llvm.i32_type llctx
      | Ast.TY_str -> Llvm.pointer_type (Llvm.i8_type llctx)
      | Ast.TY_fn
            ({ Ast.sig_input_slots = ins; Ast.sig_output_slot = out }, _) ->
          let out_llty = trans_slot None out in
          let in_lltys = Array.map (trans_slot None) ins in
          Llvm.function_type out_llty in_lltys
      | Ast.TY_constrained (ty', _) -> trans_ty ty'
      | Ast.TY_tup _ | Ast.TY_vec _ | Ast.TY_rec _ | Ast.TY_tag _
            | Ast.TY_iso _ | Ast.TY_idx _ | Ast.TY_pred _ | Ast.TY_chan _
            | Ast.TY_port _ | Ast.TY_obj _ | Ast.TY_proc | Ast.TY_opaque _
            | Ast.TY_param _ | Ast.TY_named _ | Ast.TY_type ->
          Llvm.opaque_type llctx (* TODO *)

  (* Translates the type of a slot into the corresponding LLVM type. If the
   * id_opt parameter is specified, then the type will be fetched from the
   * context if it isn't stored with the slot. Otherwise, an untyped slot
   * produces an error. *)
  and trans_slot (id_opt:node_id option) (slot:Ast.slot) : Llvm.lltype =
    let ty =
      match (slot.Ast.slot_ty, id_opt) with
          (None, None) ->
            raise (Failure "llvm_trans: found untyped anonymous slot")
        | (None, Some id) -> ty_of id
        | (Some ty, _) -> ty
    in
    let base_llty = trans_ty ty in
    match slot.Ast.slot_mode with
        Ast.MODE_exterior _ | Ast.MODE_read_alias | Ast.MODE_write_alias ->
          Llvm.pointer_type base_llty
      | Ast.MODE_interior _ -> base_llty
  in

  let (llitems:(node_id, Llvm.llvalue) Hashtbl.t) = Hashtbl.create 0 in
  let declare_mod_item
      (name:Ast.ident)
      { node = { Ast.decl_item = (item:Ast.mod_item') }; id = id }
      : unit =
    match item with
        Ast.MOD_ITEM_fn _ ->
          let llfn = Llvm.declare_function name (trans_ty (ty_of id)) llmod in
          Hashtbl.add llitems id llfn
      | _ -> () (* TODO *)
  in

  let trans_fn
      ({
        Ast.fn_input_slots = (header_slots:Ast.header_slots);
        Ast.fn_body = (body:Ast.block)
      }:Ast.fn)
      (fn_id:node_id)
      : unit =
    let llfn = Hashtbl.find llitems fn_id in

    (* LLVM requires that functions be grouped into basic blocks terminated by
     * terminator instructions, while our AST is less strict. So we have to do
     * a little trickery here to wrangle the statement sequence into LLVM's
     * format. *)

    let new_block id_opt klass =
      let llblock = Llvm.append_block llctx (node_llid id_opt klass) llfn in
      let llbuilder = Llvm.builder_at_end llctx llblock in
      (llblock, llbuilder)
    in

    let build_ret llatom : (Llvm.llbuilder -> Llvm.llvalue) =
      if (Llvm.type_of llatom) == (Llvm.void_type llctx)
      then Llvm.build_ret_void
      else Llvm.build_ret llatom
    in

    (* Build up the slot-to-llvalue mapping, allocating space along the way. *)
    let slot_to_llvalue = Hashtbl.create 0 in
    let (_, llinitbuilder) = new_block None "init" in

    (* Allocate space for arguments (needed because arguments are lvalues in
     * Rust), and store them in the slot-to-llvalue mapping. *)
    let build_arg idx llargval =
      let ({ id = id }, ident) = header_slots.(idx) in
      Llvm.set_value_name ident llargval;
      let llarg =
        let llty = Llvm.type_of llargval in
        Llvm.build_alloca llty (ident ^ "_ptr") llinitbuilder
      in
      ignore (Llvm.build_store llargval llarg llinitbuilder);
      Hashtbl.add slot_to_llvalue id llarg
    in
    Array.iteri build_arg (Llvm.params llfn);

    (* Allocate space for all the blocks' slots. *)
    let init_block block_id =
      let init_slot (key:Ast.slot_key) (slot_id:node_id) : unit =
        let slot =
          match Hashtbl.find sem_cx.Semant.ctxt_all_defns slot_id with
              Semant.DEFN_slot slot -> slot
            | _ -> raise (Failure "defn of slot not actually a slot")
        in
        let name = Ast.sprintf_slot_key () key in
        let llty = trans_slot (Some slot_id) slot in
        let llptr = Llvm.build_alloca llty name llinitbuilder in
        Hashtbl.add slot_to_llvalue slot_id llptr
      in
      let slots_table = Hashtbl.find sem_cx.Semant.ctxt_block_slots block_id in
      Hashtbl.iter init_slot slots_table;
    in
    List.iter init_block (Hashtbl.find sem_cx.Semant.ctxt_frame_blocks fn_id);

    (* Translates a list of AST statements to a sequence of LLVM instructions.
     * The supplied "terminate" function appends the appropriate terminator
     * instruction to the instruction stream. It may or may not be called,
     * depending on whether the AST contains a terminating instruction
     * explicitly. *)
    let rec trans_stmts
        (id_opt:node_id option)
        (llbuilder:Llvm.llbuilder)
        (stmts:Ast.stmt list)
        (terminate:(Llvm.llbuilder -> unit))
        : unit =
      let trans_literal
          (lit:Ast.lit)
          : Llvm.llvalue =
        match lit with
            Ast.LIT_nil -> nil
          | Ast.LIT_bool value ->
            Llvm.const_int (Llvm.i1_type llctx) (if value then 1 else 0)
          | Ast.LIT_mach (mty, value, _) ->
            let llty = trans_mach_ty mty in
            Llvm.const_of_int64 llty value (mach_is_signed mty)
          | Ast.LIT_int (value, _) ->
            (* TODO: bignums? *)
            Llvm.const_of_int64 (Llvm.i32_type llctx) value true
          | Ast.LIT_char ch ->
            Llvm.const_int (Llvm.i32_type llctx) (Char.code ch)
          | Ast.LIT_custom _ -> bogus (* TODO *)
      in

      (* Translates an lval by reference into the appropriate pointer value. *)
      let trans_lval (lval:Ast.lval) : Llvm.llvalue =
        match lval with
            Ast.LVAL_base { id = base_id } ->
              let id =
                Hashtbl.find sem_cx.Semant.ctxt_lval_to_referent base_id
              in
              let referent = Hashtbl.find sem_cx.Semant.ctxt_all_defns id in
              begin
                match referent with
                    Semant.DEFN_slot _ -> Hashtbl.find slot_to_llvalue id
                  | Semant.DEFN_item _ -> Hashtbl.find llitems id
                  | _ -> bogus_ptr (* TODO *)
              end
          | Ast.LVAL_ext _ -> bogus_ptr (* TODO *)
      in

      let trans_atom (atom:Ast.atom) : Llvm.llvalue =
        match atom with
            Ast.ATOM_literal { node = lit } -> trans_literal lit
          | Ast.ATOM_lval lval ->
              Llvm.build_load (trans_lval lval) (anon_llid "tmp") llbuilder
      in

      let trans_binary_expr
          ((op:Ast.binop), (lhs:Ast.atom), (rhs:Ast.atom))
          : Llvm.llvalue =
        (* Evaluate the operands in the proper order. *)
        let (lllhs, llrhs) =
          match op with
              Ast.BINOP_or | Ast.BINOP_and | Ast.BINOP_eq | Ast.BINOP_ne
                  | Ast.BINOP_lt | Ast.BINOP_le | Ast.BINOP_ge | Ast.BINOP_gt
                  | Ast.BINOP_lsl | Ast.BINOP_lsr | Ast.BINOP_asr
                  | Ast.BINOP_add | Ast.BINOP_sub | Ast.BINOP_mul
                  | Ast.BINOP_div | Ast.BINOP_mod ->
                (trans_atom lhs, trans_atom rhs)
            | Ast.BINOP_send ->
                let llrhs = trans_atom rhs in
                let lllhs = trans_atom lhs in
                (lllhs, llrhs)
        in
        let llid = anon_llid "expr" in
        match op with
            Ast.BINOP_eq ->
              (* TODO: equality works on more than just integers *)
              Llvm.build_icmp Llvm.Icmp.Eq lllhs llrhs llid llbuilder

            (* TODO: signed/unsigned distinction, floating point *)
          | Ast.BINOP_add -> Llvm.build_add lllhs llrhs llid llbuilder
          | Ast.BINOP_sub -> Llvm.build_sub lllhs llrhs llid llbuilder
          | Ast.BINOP_mul -> Llvm.build_mul lllhs llrhs llid llbuilder
          | Ast.BINOP_div -> Llvm.build_sdiv lllhs llrhs llid llbuilder
          | Ast.BINOP_mod -> Llvm.build_srem lllhs llrhs llid llbuilder

          | _ -> bogus (* TODO *)
      in

      let trans_unary_expr _ = bogus in (* TODO *)

      let trans_expr (expr:Ast.expr) : Llvm.llvalue =
        match expr with
            Ast.EXPR_binary binexp -> trans_binary_expr binexp
          | Ast.EXPR_unary unexp -> trans_unary_expr unexp
          | Ast.EXPR_atom atom -> trans_atom atom
      in

      match stmts with
          [] -> terminate llbuilder
        | { node = head }::tail ->
            let trans_tail_with_builder llbuilder' : unit =
              trans_stmts id_opt llbuilder' tail terminate
            in
            let trans_tail () = trans_tail_with_builder llbuilder in
            let trans_tail_in_new_block () : Llvm.llbasicblock =
              let (llblock, llbuilder') = new_block None "bb" in
              trans_tail_with_builder llbuilder';
              llblock
            in

            match head with
                Ast.STMT_copy (dest, src) ->
                  let llsrc = trans_expr src in
                  let lldest = trans_lval dest in
                  ignore (Llvm.build_store llsrc lldest llbuilder);
                  trans_tail ()
              | Ast.STMT_if {
                  Ast.if_test = test;
                  Ast.if_then = if_then;
                  Ast.if_else = else_opt
                } ->
                  let llexpr = trans_expr test in
                  let llnext = trans_tail_in_new_block () in
                  let branch_to_next llbuilder' =
                    ignore (Llvm.build_br llnext llbuilder')
                  in
                  let llthen = trans_block if_then branch_to_next in
                  let llelse =
                    match else_opt with
                        None -> llnext
                      | Some if_else -> trans_block if_else branch_to_next
                  in
                  ignore (Llvm.build_cond_br llexpr llthen llelse llbuilder)
              | Ast.STMT_ret (_, atom_opt) ->
                  let llatom =
                    match atom_opt with
                        None -> nil
                      | Some atom -> trans_atom atom
                  in
                  ignore (build_ret llatom llbuilder)
              | _ -> trans_stmts id_opt llbuilder tail terminate

    (* Translates an AST block to one or more LLVM basic blocks and returns the
     * first basic block. The supplied callback is expected to add a
     * terminator instruction. *)
    and trans_block
        ({ node = (stmts:Ast.stmt array); id = id }:Ast.block)
        (terminate:Llvm.llbuilder -> unit)
        : Llvm.llbasicblock =
      let (llblock, llbuilder) = new_block (Some id) "bb" in
      trans_stmts (Some id) llbuilder (Array.to_list stmts) terminate;
      llblock
    in

    (* "Falling off the end" of a function needs to turn into an explicit
     * return instruction. *)
    let default_terminate llbuilder =
      let llfnty =
        Llvm.element_type (Llvm.type_of (Hashtbl.find llitems fn_id))
      in
      ignore (build_ret (Llvm.undef (Llvm.return_type llfnty)) llbuilder)
    in

    (* Build up the first body block, and link it to the end of the
     * initialization block. *)
    let llbodyblock = (trans_block body default_terminate) in
    ignore (Llvm.build_br llbodyblock llinitbuilder)
  in

  let trans_mod_item
      (_:Ast.ident)
      { node = { Ast.decl_item = (item:Ast.mod_item') }; id = id }
      : unit =
    match item with
        Ast.MOD_ITEM_fn fn -> trans_fn fn id
      | _ -> ()
  in

  try
    let crate' = crate.node in
    let items = crate'.Ast.crate_items in
    Hashtbl.iter declare_mod_item items;
    Hashtbl.iter trans_mod_item items;
    llmod
  with e -> Llvm.dispose_module llmod; raise e
;;

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)

