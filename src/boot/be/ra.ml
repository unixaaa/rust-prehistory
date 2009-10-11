open Il;;
open Common;;

type ctxt =
    {
      ctxt_sess: Session.sess;
      ctxt_n_vregs: int;
      ctxt_abi: Abi.abi;
      mutable ctxt_quads: Il.quads;
      mutable ctxt_next_spill: int;
      mutable ctxt_next_label: int;
      (* More state as necessary. *)
    }
;;

let new_ctxt
    (sess:Session.sess)
    (quads:Il.quads)
    (vregs:int)
    (abi:Abi.abi)
    : ctxt =
  {
    ctxt_sess = sess;
    ctxt_quads = quads;
    ctxt_n_vregs = vregs;
    ctxt_abi = abi;
    ctxt_next_spill = 0;
    ctxt_next_label = 0;
  }
;;

let log (cx:ctxt) =
  Session.log "ra"
    cx.ctxt_sess.Session.sess_log_ra
    cx.ctxt_sess.Session.sess_log_out
;;

let iflog (cx:ctxt) (thunk:(unit -> unit)) : unit =
  if cx.ctxt_sess.Session.sess_log_ra
  then thunk ()
  else ()
;;

let next_spill (cx:ctxt) : int =
  let i = cx.ctxt_next_spill in
    cx.ctxt_next_spill <- i + 1;
    i
;;

let next_label (cx:ctxt) : string =
  let i = cx.ctxt_next_label in
    cx.ctxt_next_label <- i + 1;
    (".L" ^ (string_of_int i))
;;

exception Ra_error of string ;;

let convert_labels (cx:ctxt) : unit =
  let new_labels = ref [] in
  let qp_code (qp:Il.quad_processor) (c:Il.code) : Il.code =
    match c with
        Il.CodeLabel lab ->
          let fix =
            match cx.ctxt_quads.(lab).quad_fixup with
                None ->
                  let fix = new_fixup (next_label cx) in
                    begin
                      new_labels := (lab, fix) :: (!new_labels);
                      fix
                    end
              | Some f -> f
          in
            Il.CodeAddr (Il.Pcrel (fix, None))
      | _ -> c
  in
  let qp = { Il.identity_processor
             with Il.qp_code = qp_code }
  in
    Il.rewrite_quads qp cx.ctxt_quads;
    List.iter (fun (i, fix) ->
                 cx.ctxt_quads.(i) <- { cx.ctxt_quads.(i)
                                        with Il.quad_fixup = Some fix })
      (!new_labels)
;;

let convert_pre_spills
    (cx:ctxt)
    (mkspill:(Il.spill -> Il.addr))
    : int =
  let n = ref 0 in
  let qp_addr (qp:Il.quad_processor) (a:Il.addr) : Il.addr =
    match a with
        Il.Spill i ->
          begin
            if i+1 > (!n)
            then n := i+1;
            mkspill i
          end
      | _ -> qp.Il.qp_addr qp a
  in
  let qp = Il.identity_processor in
  let qp = { qp with
               Il.qp_addr = qp_addr  }
  in
    begin
      Il.rewrite_quads qp cx.ctxt_quads;
      !n
    end
;;

let kill_quad (i:int) (cx:ctxt) : unit =
  cx.ctxt_quads.(i) <-
    { Il.deadq with
        Il.quad_fixup = cx.ctxt_quads.(i).Il.quad_fixup }
;;

let kill_redundant_moves (cx:ctxt) : unit =
  let process_quad i q =
    match q.Il.quad_body with
        Il.Unary u when
          ((Il.is_mov u.Il.unary_op) &&
             (Il.Cell u.Il.unary_dst) = u.Il.unary_src) ->
            kill_quad i cx
      | _ -> ()
  in
    Array.iteri process_quad cx.ctxt_quads
;;

let quad_jump_target_labels (q:quad) : Il.label list =
  match q.Il.quad_body with
      Il.Call { Il.call_targ = Il.CodeLabel lab } -> [ lab ]
    | Il.Jmp { Il.jmp_targ = Il.CodeLabel lab } -> [ lab ]
    | _ -> []
;;

let quad_used_vregs (q:quad) : Il.vreg list =
  let vregs = ref [] in
  let qp_reg qp r =
    match r with
        Il.Vreg v -> (vregs := (v :: (!vregs)); r)
      | _ -> r
  in
  let qp_cell_write qp c =
    match c with
        Il.Reg _ -> c
      | Il.Mem (a, b) -> Il.Mem (qp.qp_addr qp a, b)
  in
  let qp = { Il.identity_processor with
               Il.qp_reg = qp_reg;
               Il.qp_cell_write = qp_cell_write }
  in
    ignore (Il.process_quad qp q);
    !vregs
;;

let quad_defined_vregs (q:quad) : Il.vreg list =
  let vregs = ref [] in
  let qp_cell_write qp c =
    match c with
        Il.Reg (Il.Vreg v, _) -> (vregs := (v :: (!vregs)); c)
      | _ -> c
  in
  let qp = { Il.identity_processor with
               Il.qp_cell_write = qp_cell_write }
  in
    ignore (Il.process_quad qp q);
    !vregs
;;

let quad_is_unconditional_jump (q:quad) : bool =
  match q.Il.quad_body with
      Il.Jmp { jmp_op = Il.JMP } -> true
    | Il.Ret -> true
    | _ -> false
;;

let calculate_live_bitvectors
    (cx:ctxt)
    : ((Bitv.t array) * (Bitv.t array)) =

  let quads = cx.ctxt_quads in
  let n_quads = Array.length quads in
  let n_vregs = cx.ctxt_n_vregs in
  let new_bitv _ = Bitv.create n_vregs false in
  let (live_in_vregs:Bitv.t array) = Array.init n_quads new_bitv in
  let (live_out_vregs:Bitv.t array) = Array.init n_quads new_bitv in
  let bitvs_equal a b = ((Bitv.to_list a) = (Bitv.to_list b)) in

  let outer_changed = ref true in
    while !outer_changed do
      outer_changed := false;
      for i = 0 to n_quads - 1 do
        live_in_vregs.(i) <- new_bitv ();
        live_out_vregs.(i) <- new_bitv ()
      done;
      let inner_changed = ref true in
        while !inner_changed do
          inner_changed := false;
          iflog cx (fun _ -> log cx "iterating live bitvector calculation");
          for i = n_quads - 1 downto 0 do
            let quad = quads.(i) in
            let live_in = live_in_vregs.(i) in
            let live_in_saved = Bitv.copy live_in in
            let live_out = live_out_vregs.(i) in
            let live_out_saved = Bitv.copy live_out in

            let union bv1 bv2 = Bitv.iteri_true (fun i -> Bitv.set bv1 i true) bv2 in

            let defined = new_bitv() in

              List.iter (fun i -> Bitv.set live_in i true) (quad_used_vregs quad);
              List.iter (fun i -> Bitv.set defined i true) (quad_defined_vregs quad);

              for i = 0 to (n_vregs - 1)
              do
                if Bitv.get live_out i && not (Bitv.get defined i)
                then Bitv.set live_in i true
                else ()
              done;

              (* Union in all our jump targets. *)
              List.iter (fun i -> union live_out live_in_vregs.(i)) (quad_jump_target_labels quad);

              (* Union in our block successor if we have one *)
              if i < (n_quads - 1) && (not (quad_is_unconditional_jump quad))
              then union live_out live_in_vregs.(i+1)
              else ();

              (* Possibly update matters. *)
              if bitvs_equal live_in live_in_saved &&
                bitvs_equal live_out live_out_saved
              then ()
              else
                begin
                  live_in_vregs.(i) <- live_in;
                  live_out_vregs.(i) <- live_out;
                  inner_changed := true
                end
          done
        done;
        let kill_mov_to_dead_target i q =
          match q.Il.quad_body with
              Il.Unary { Il.unary_op=uop;
                         Il.unary_dst=Il.Reg (Il.Vreg v, _) }
                when
                  ((Il.is_mov uop) &&
                     not (Bitv.get live_out_vregs.(i) v)) ->
                  begin
                    kill_quad i cx;
                    outer_changed := true;
                  end
            | _ -> ()
        in
          Array.iteri kill_mov_to_dead_target quads
    done;
    iflog cx
      begin
        fun _ ->
          log cx "finished calculating live bitvectors";
          log cx "=========================";
          for q = 0 to n_quads - 1 do
            let buf = Buffer.create 128 in
            let live_vregs = (Bitv.bw_or
                                live_in_vregs.(q)
                                live_out_vregs.(q))
            in
              for v = 0 to (Bitv.length live_vregs) - 1
              do
                if Bitv.get live_vregs v
                then Printf.bprintf buf " %-2d" v
                else Buffer.add_string buf "   "
              done;
              log cx "[%6d] live vregs: %s" q (Buffer.contents buf)
          done;
          log cx "========================="
      end;
    (live_in_vregs, live_out_vregs)
;;


let is_end_of_basic_block (q:quad) : bool =
  match q.Il.quad_body with
      Il.Jmp _ -> true
    | Il.Ret -> true
    | _ -> false
;;

let is_beginning_of_basic_block (q:quad) : bool =
  match q.Il.quad_fixup with
      None -> false
    | Some _ -> true
;;

let dump_quads cx =
  let f = cx.ctxt_abi.Abi.abi_str_of_hardreg in
  let len = (Array.length cx.ctxt_quads) - 1 in
  let ndigits_of n = (int_of_float (log10 (float_of_int n))) in
  let padded_num n maxnum =
    let ndigits = ndigits_of n in
    let maxdigits = ndigits_of maxnum in
    let pad = String.make (maxdigits - ndigits) ' ' in
      Printf.sprintf "%s%d" pad n
  in
  let padded_str str maxlen =
    let pad = String.make (maxlen - (String.length str)) ' ' in
      Printf.sprintf "%s%s" pad str
  in
  let maxlablen = ref 0 in
  for i = 0 to len
  do
    let q = cx.ctxt_quads.(i) in
    match q.quad_fixup with
        None -> ()
      | Some f -> maxlablen := max (!maxlablen) ((String.length f.fixup_name) + 1)
  done;
  for i = 0 to len
  do
    let q = cx.ctxt_quads.(i) in
    let qs = (string_of_quad f q) in
    let lab = match q.quad_fixup with
        None -> ""
      | Some f -> f.fixup_name ^ ":"
    in
      log cx "[%s] %s %s" (padded_num i len) (padded_str lab (!maxlablen)) qs
  done
;;

let list_to_str list eltstr =
  (String.concat "," (List.map eltstr (List.sort compare list)))
;;


let collect_vreg_bits
    (cx:ctxt)
    (vreg_to_bits:(Il.vreg,Il.bits) Hashtbl.t)
    : unit =
  let qp_cell qp c =
    match c with
        Reg (Vreg v, b) ->
          begin
            if Hashtbl.mem vreg_to_bits v
            then
              let bits = Hashtbl.find vreg_to_bits v in
                assert (bits = b)
            else
              Hashtbl.replace vreg_to_bits v b;
            c
          end
      | _ -> c
  in
  let qp = { Il.identity_processor with
               Il.qp_cell_read = qp_cell;
               Il.qp_cell_write = qp_cell }
  in
    Il.visit_quads qp cx.ctxt_quads
;;

(* Simple local register allocator. Nothing fancy. *)
let reg_alloc (sess:Session.sess) (quads:Il.quads) (vregs:int) (abi:Abi.abi) (framesz:int64) =
  try
    let cx = new_ctxt sess quads vregs abi in
    let _ =
      iflog cx
        begin
          fun _ ->
            log cx "un-allocated quads:";
            dump_quads cx
        end
    in

    (* Work out pre-spilled slots and allocate 'em. *)
    let spill_slot (s:Il.spill) = abi.Abi.abi_spill_slot framesz s in
    let n_pre_spills = convert_pre_spills cx spill_slot in

    let (live_in_vregs, live_out_vregs) = calculate_live_bitvectors cx in
    let inactive_hregs = ref [] in (* [hreg] *)
    let active_hregs = ref [] in (* [hreg] *)
    let dirty_vregs = Hashtbl.create 0 in (* vreg -> () *)
    let hreg_to_vreg = Hashtbl.create 0 in  (* hreg -> vreg *)
    let vreg_to_hreg = Hashtbl.create 0 in (* vreg -> hreg *)
    let vreg_to_bits = Hashtbl.create 0 in (* vreg -> Bits *)
    let vreg_to_spill = Hashtbl.create 0 in (* vreg -> spill *)
    let vreg_bits v =
      if Hashtbl.mem vreg_to_bits v
      then Hashtbl.find vreg_to_bits v
      else abi.Abi.abi_word_bits
    in
    let vreg_spill_cell v =
      Il.Mem ((spill_slot (Hashtbl.find vreg_to_spill v)),
              (vreg_bits v))
    in
    let newq = ref [] in
    let fixup = ref None in
    let prepend q =
      newq := {q with quad_fixup = !fixup} :: (!newq);
      fixup := None
    in
    let hr h = Il.Reg (Il.Hreg h, abi.Abi.abi_word_bits) in
    let hr_str = cx.ctxt_abi.Abi.abi_str_of_hardreg in
    let clean_hreg i hreg =
      if (Hashtbl.mem hreg_to_vreg hreg) &&
        (hreg < cx.ctxt_abi.Abi.abi_n_hardregs)
      then
        let vreg = Hashtbl.find hreg_to_vreg hreg in
          if Hashtbl.mem dirty_vregs vreg
          then
            begin
              Hashtbl.remove dirty_vregs vreg;
              if (Bitv.get (live_out_vregs.(i)) vreg)
              then
                let spill_idx =
                  if Hashtbl.mem vreg_to_spill vreg
                  then Hashtbl.find vreg_to_spill vreg
                  else
                    begin
                      let s = next_spill cx in
                        Hashtbl.replace vreg_to_spill vreg s;
                        s
                    end
                in
                let spill_addr = spill_slot spill_idx in
                let spill_cell = Il.Mem (spill_addr, (vreg_bits vreg)) in
                  log cx "spilling <%d> from %s to %s"
                    vreg (hr_str hreg) (string_of_addr hr_str spill_addr);
                  prepend (Il.mk_quad (Il.umov spill_cell (Il.Cell (hr hreg))));
              else ()
            end
          else ()
      else ()
    in
    let inactivate_hreg hreg =
      if (Hashtbl.mem hreg_to_vreg hreg) &&
        (hreg < cx.ctxt_abi.Abi.abi_n_hardregs)
      then
        let vreg = Hashtbl.find hreg_to_vreg hreg in
          Hashtbl.remove vreg_to_hreg vreg;
          Hashtbl.remove hreg_to_vreg hreg;
          active_hregs := List.filter (fun x -> x != hreg) (!active_hregs);
          inactive_hregs := hreg :: (!inactive_hregs);
      else ()
    in
    let spill_specific_hreg i hreg =
      clean_hreg i hreg;
      inactivate_hreg hreg
    in
    let spill_some_hreg i =
      match !active_hregs with
          [] -> raise (Ra_error ("spilling with no active hregs"));
        | h::hs ->
            begin
              spill_specific_hreg i h;
              h
            end
    in
    let spill_all_regs i =
      while (!active_hregs) != []
      do
        let _ = spill_some_hreg i in
          ()
      done
    in
    let reload vreg hreg =
      if Hashtbl.mem vreg_to_spill vreg
      then
        prepend (Il.mk_quad
                   (Il.umov
                      (hr hreg)
                      (Il.Cell (vreg_spill_cell vreg))))
      else ()
    in

    let use_vreg def i vreg =
      if Hashtbl.mem vreg_to_hreg vreg
      then Hashtbl.find vreg_to_hreg vreg
      else
        let hreg =
          match !inactive_hregs with
              [] -> spill_some_hreg i
            | x::_ -> x
        in
          inactive_hregs := List.filter (fun x -> x != hreg) (!inactive_hregs);
          active_hregs := (!active_hregs) @ [hreg];
          Hashtbl.replace hreg_to_vreg hreg vreg;
          Hashtbl.replace vreg_to_hreg vreg hreg;
          if def
          then ()
          else
            reload vreg hreg;
          hreg
    in
    let qp_reg def i qp r =
      match r with
          Il.Hreg h -> (spill_specific_hreg i h; r)
        | Il.Vreg v -> (Il.Hreg (use_vreg def i v))
    in
    let qp_cell def i qp c =
      match c with
          Il.Reg (r, b) -> Il.Reg (qp_reg def i qp r, b)
        | Il.Mem  (a, b) ->
            let qp = { qp with Il.qp_reg = qp_reg false i } in
              Il.Mem (qp.qp_addr qp a, b)
    in
    let qp i = { Il.identity_processor with
                   Il.qp_cell_read = qp_cell false i;
                   Il.qp_cell_write = qp_cell true i }
    in
      cx.ctxt_next_spill <- n_pre_spills;
      convert_labels cx;
      collect_vreg_bits cx vreg_to_bits;
      for i = 0 to cx.ctxt_abi.Abi.abi_n_hardregs - 1
      do
        inactive_hregs := i :: (!inactive_hregs)
      done;
      for i = 0 to (Array.length cx.ctxt_quads) - 1
      do
        let quad = cx.ctxt_quads.(i) in
        let clobbers = cx.ctxt_abi.Abi.abi_clobbers quad in
        let used = quad_used_vregs quad in
        let defined = quad_defined_vregs quad in
          begin
            if List.exists (fun def -> List.mem def clobbers) defined
            then raise (Ra_error ("clobber and defined sets overlap"));
            iflog cx
              begin
                fun _ ->
                  let hr (v:int) : string =
                    if Hashtbl.mem vreg_to_hreg v
                    then hr_str (Hashtbl.find vreg_to_hreg v)
                    else "??"
                  in
                  let vr_str (v:int) : string = Printf.sprintf "v%d=%s" v (hr v) in
                  let lstr lab ls fn =
                    if List.length ls = 0
                    then ()
                    else log cx "\t%s: [%s]" lab (list_to_str ls fn)
                  in
                    log cx "processing quad %d = %s" i (string_of_quad hr_str quad);
                    (lstr "dirt" (htab_keys dirty_vregs) vr_str);
                    (lstr "clob" clobbers hr_str);
                    (lstr "in" (Bitv.to_list live_in_vregs.(i)) vr_str);
                    (lstr "out" (Bitv.to_list live_out_vregs.(i)) vr_str);
                    (lstr "use" used vr_str);
                    (lstr "def" defined vr_str);
              end;
            List.iter (clean_hreg i) clobbers;
            if is_beginning_of_basic_block quad
            then
              begin
                spill_all_regs i;
                fixup := quad.quad_fixup;
                prepend (Il.process_quad (qp i) quad)
              end
            else
              begin
                fixup := quad.quad_fixup;
                let newq = (Il.process_quad (qp i) quad) in
                  begin
                    if is_end_of_basic_block quad
                    then spill_all_regs i
                    else ()
                  end;
                  prepend newq
              end
          end;
          List.iter inactivate_hreg clobbers;
          List.iter (fun i -> Hashtbl.replace dirty_vregs i ())
            (quad_defined_vregs quad);
      done;
      cx.ctxt_quads <- Array.of_list (List.rev (!newq));
      kill_redundant_moves cx;

      iflog cx
        begin
          fun _ ->
            log cx "frame size: %Ld" framesz;
            log cx "spills: %d pre-spilled, %d total" n_pre_spills cx.ctxt_next_spill;
            log cx "register-allocated quads:";
            dump_quads cx;
        end;

      (cx.ctxt_quads, cx.ctxt_next_spill)

  with
      Ra_error s ->
        Session.fail sess "RA Error: %s" s;
        (quads, 0)

;;


(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C ../.. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)
