
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(** {1 Run Tests} *)

open Result
open Frog
open Lwt.Infix

type 'a or_error = 'a Misc.Err.t
type path = string

module C = Test.Config
module T = Test
module E = Misc.LwtErr

let expect_of_config config = function
  | None -> C.Auto
  | Some s ->
    begin match Misc.Str.split ~by:':' s with
      | "program", p ->
        C.Program (ProverSet.find_config config p)
      | _ -> C.Res (Res.of_string s)
      | exception Not_found -> C.Res (Res.of_string s)
    end

let config_of_config config dirs =
  try
    let c = Config.get_table config "test" in
    let j = Config.get_int ~default:1 c "parallelism" in
    let timeout = Config.get_int ~default:5 c "timeout" in
    let memory = Config.get_int ~default:1000 c "memory" in
    let problem_pat = Config.get_string ~default:"" c "problems" in
    let l =
      match dirs with
      | [] -> Config.get_string_list ~default:[] c "dir"
      | _ -> dirs
    in
    let problems = List.map (fun s ->
        match Config.get_table c s with
        | t ->
          let dir = Config.get_string ~default:s t "directory" in
          let pat = Config.get_string ~default:problem_pat t "problems" in
          let expect =
            let open CCOpt.Infix in
            (Config.get_string_opt t "expect"
             <+> Config.get_string_opt c "expect"
             <+> Config.get_string_opt config "expect")
            |> expect_of_config config
          in
          { C.directory = dir; pattern = pat; expect = expect; }
        | exception (Config.FieldNotFound _ | TomlTypes.Table.Key.Bad_key _) ->
          let expect =
            let open CCOpt.Infix in
             (Config.get_string_opt c "expect"
             <+> Config.get_string_opt config "expect")
            |> expect_of_config config
          in
          { C.directory = s; pattern = problem_pat; expect; }
      ) l in
    let provers = Config.get_string_list c "provers" in
    let provers = List.map (ProverSet.find_config config) provers in
    Misc.Err.return { C.j; timeout; memory; provers; problems; }
  with
  | Config.Error e ->
    Misc.Err.fail e
  | e -> Misc.Err.fail (Printexc.to_string e)

let config_of_file file =
  Lwt_log.ign_debug_f "parse config file `%s`..." file;
  try
    let main = Config.parse_files [file] Config.empty in
    config_of_config main []
  with
  | Config.Error e ->
    Misc.Err.fail e
  | e -> Misc.Err.fail (Printexc.to_string e)

(* run one particular test *)
let run_pb_ ~config prover pb =
  Lwt_log.ign_debug_f "running %-15s/%-30s..."
    (Filename.basename prover.Prover.binary) pb.Problem.name;
  (* spawn process *)
  let%lwt result = Run.run_prover
      ~timeout:config.C.timeout
      ~memory:config.C.memory
      ~prover ~pb ()
  in
  Lwt_log.ign_debug_f "output for %s/%s: `%s`, `%s`, errcode %d"
    prover.Prover.binary pb.Problem.name
    result.Event.raw.Event.stdout
    result.Event.raw.Event.stderr
    result.Event.raw.Event.errcode;
  Lwt.return result

let run_pb ?(caching=true) ?limit ~config prover pb : _ E.t =
  let module V = Maki.Value in
  Maki.call
    ?limit
    ~bypass:(not caching)
    ~lifetime:(`KeepFor Maki.Time.(days 2))
    ~deps:[V.pack V.int config.C.timeout;
           V.pack V.int config.C.memory;
           V.pack Maki_wrapper.prover prover;
           V.pack Maki_wrapper.problem pb]
    ~op:Run.maki_result
    ~name:"frogtest.run_pb"
    (fun () -> run_pb_ ~config prover pb)
  |> E.of_exn

let nop_ _ = Lwt.return_unit

let print_result (res:Test.result): unit =
  let module F = Misc.Fmt in
  let p_res = Event.analyze_p res in
  let pp_res out () =
    let str, c = match Problem.compare_res res.Event.problem p_res with
      | `Same -> "ok", `Green
      | `Improvement -> "ok (improved)", `Blue
      | `Disappoint -> "disappoint", `Cyan
      | `Error -> "error", `Yellow
      | `Mismatch -> "bad", `Red
    in
    Format.fprintf out "%a" (F.in_bold_color c Format.pp_print_string) str
  in
  let prover = res.Event.program in
  let prover_name = Filename.basename prover.Prover.name in
  let pb_name = res.Event.problem.Problem.name in
  Lwt_log.ign_debug_f "result for `%s` with %s: %s (%.1fs)"
    prover_name pb_name (Res.to_string p_res) res.Event.raw.Event.rtime;
  Format.printf "%-20s%-50s %a (%.1fs)@." prover_name (pb_name ^ " :")
    pp_res () res.Event.raw.Event.rtime;
  ()

let run ?(on_solve = nop_) ?(on_done = nop_)
    ?(caching=true) ?j ?timeout ?memory ~provers ~expect ~config (set:path list)
    : Test.top_result E.t =
  let open E.Infix in
  let config = C.update ?j ?timeout ?memory config in
  let j = CCOpt.get_or j ~default:config.C.j in
  let limit = Maki.Limit.create j in
  E.map_p
    (fun pb_path ->
       (* transform into problem *)
       let%lwt pb =
         Maki.Limit.acquire limit
           (fun () ->
              let find_expect = Problem_run.find_expect ~expect in
              Problem_run.make ~find_expect pb_path)
         |> Misc.LwtErr.to_exn
       in
       (* run provers *)
       E.map_p
         (fun prover ->
            run_pb ~caching ~limit ~config prover pb >>= fun result ->
            let%lwt () = on_solve result in (* callback *)
            E.return result
            |> E.add_ctxf "running `%a` on %a"
              Prover.pp_name prover Problem.print pb)
         provers)
    set
  >>= fun res ->
  let res = List.flatten res in
  let r = T.Top_result.make (List.map Event.mk_prover res) in
  let%lwt () = on_done r in
  E.return r

let find_results ?storage str =
  match storage with
    | None -> T.Top_result.of_file str
    | Some storage ->
      let open E in
      let%lwt res1 =
        Event_storage.find_snapshot storage str
        >|= T.Top_result.of_snapshot
      in
      match res1 with
        | Ok x -> E.return x
        | Error _ ->
          T.Top_result.of_file str

let all_results storage =
  let open E in
  Event_storage.list_snapshots storage >>= fun l ->
  E.map_s (fun snap -> T.Top_result.of_snapshot snap |> E.return) l

let last_result storage =
  let open E in
  all_results storage >>= function
  | [] -> E.fail "last_result failed: no result found in storage"
  | x :: l ->
    let best =
      List.fold_left
        (fun best t -> if best.T.timestamp < t.T.timestamp then t else best)
        x l
    in
    E.return best

let find_or_last ?storage str_opt = match str_opt, storage with
  | Some f, _ -> find_results ?storage f
  | None, Some storage -> last_result storage
  | None, None -> E.fail "cannot find last result"

module Plot_res = struct
  type data =
    | Unsat_time
    | Sat_time
    | Both_time

  type legend =
    | Prover

  type drawer =
    | Simple of bool (* should we sort the list ? *)
    | Cumul of bool * int * int (* sort, filter, count *)

  type params = {
    graph : Plot.graph_config;
    data : data;
    legend : legend;
    drawer : drawer;
    out_file : string;
    out_format : string;
  }

  let draw params (r:Test.top_result): Plot.drawer =
    let lazy map = r.Test.analyze in
    let datas =
      Prover.Map_name.to_list map
      |> List.map
        (fun (prover,analyze) ->
           let name = match params.legend with
             | Prover -> Prover.name prover
           and points =
             T.MStr.to_list analyze.T.Analyze.raw
             |> Misc.List.filter_map
               (fun (_file,r) ->
                  let res = Event.analyze_p r in
                  let ok = match res, params.data with
                    | Res.Unsat, (Unsat_time | Both_time) -> true
                    | Res.Sat, (Sat_time | Both_time) -> true
                    | _ -> false
                  in
                  if ok then Some r.Event.raw.Event.rtime else None)
           in
           points, name
        )
    in
    let single_drawer = match params.drawer with
      | Simple sort -> Plot.float_list ~sort
      | Cumul (sort, filter, count) -> Plot.float_sum ~sort ~filter ~count
    in
    Plot.list @@ List.map single_drawer datas

  let draw_file params r =
    let d = draw params r in
    Plot.draw_on_graph params.graph ~fmt:params.out_format
      ~file:params.out_file d
end
