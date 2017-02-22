
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(* run tests, or compare results *)

open Result
open Frog
open Frog_server
module T = Test
module E = Misc.LwtErr
module W = Web

(** {2 Run} *)
module Run = struct
  (* callback that prints a result *)
  let on_solve res =
    let module F = Misc.Fmt in
    let p_res = Event.analyze_p res in
    let pp_res out () =
      let str, c = match Problem.compare_res res.Event.problem p_res with
        | `Same -> "ok", `Green
        | `Improvement -> "ok (improved)", `Blue
        | `Disappoint -> "disappoint", `Yellow
        | `Mismatch -> "bad", `Red
      in
      Format.fprintf out "%a" (F.in_bold_color c Format.pp_print_string) str
    in
    let prover = res.Event.program in
    let prover_name = Filename.basename prover.Prover.name in
    let pb_name = res.Event.problem.Problem.name in
    Lwt_log.ign_debug_f "result for `%s` with %s: %s"
       prover_name pb_name (Res.to_string p_res);
    Format.printf "%-20s%-50s %a@." prover_name (pb_name ^ " :") pp_res ();
    Lwt.return_unit

  (* run provers on the given dir, return a list [prover, dir, results] *)
  let test_dir ?j ?timeout ?memory ?caching ?provers ~config ~problem_pat dir
    : T.Top_result.t E.t =
    let open E in
    Format.printf "testing dir `%s`...@." dir;
    ProblemSet.of_dir
      ~default_expect:config.T.Config.default_expect
      ~filter:(Re.execp problem_pat)
      dir
    >>= fun pbs ->
    Format.printf "run %d tests in %s@." (ProblemSet.size pbs) dir;
    (* solve *)
    let main =
      E.ok (Test_run.run ?j ?timeout ?memory ?caching ?provers
          ~on_solve ~config pbs)
    in
    main
    >>= fun results ->
    Prover.Map_name.iter
      (fun p r ->
         Format.printf "@[<2>%s on `%s`:@ @[<hv>%a@]@]@."
           (Prover.name p) dir T.Analyze.print r)
      (Lazy.force results.T.analyze);
    E.return results

  let check_res (results:T.top_result) : unit E.t =
    let lazy map = results.T.analyze in
    if Prover.Map_name.for_all (fun _ r -> T.Analyze.is_ok r) map
    then E.return ()
    else
      E.fail (Format.asprintf "%d failure(s)" (
          Prover.Map_name.fold
            (fun _ r n -> n + T.Analyze.num_failed r)
            map 0))

  (* lwt main *)
  let main ?j ?timeout ?memory ?caching ?junit ?provers ?meta ~save ~config dirs () =
    let open E in
    (* parse config *)
    Lwt.return (Test_run.config_of_config config)
    >>= fun config ->
    (* pick default directory if needed *)
    let dirs = match dirs with
      | _::_ -> dirs
      | [] -> config.T.Config.default_dirs
    in
    let storage = Storage.make [] in
    (* build problem set (exclude config file!) *)
    let problem_pat = Re_posix.compile_pat config.T.Config.problem_pat in
    E.map_s
      (test_dir ?j ?timeout ?memory ?caching ?provers ~config ~problem_pat)
      dirs
    >|= T.Top_result.merge_l
    >>= fun (results:T.Top_result.t) ->
    begin match save with
      | "none" -> E.return ()
      | "" ->
        (* default *)
        let snapshot = Event.Snapshot.make ?meta results.T.events in
        let uuid_s = Uuidm.to_string snapshot.Event.uuid in
        let%lwt () = Lwt_io.printlf "save with UUID `%s`" uuid_s in
        Storage.save_json storage uuid_s (Event.Snapshot.to_yojson snapshot)
        |> E.ok
      | file ->
        T.Top_result.to_file ~file results
    end >>= fun () ->
    begin match junit with
      | None -> ()
      | Some file ->
        Lwt_log.ign_info_f "write results in Junit to file `%s`" file;
        let suites =
          Lazy.force results.T.analyze
          |> Prover.Map_name.to_list
          |> List.map (fun (_,a) -> JUnit_wrapper.test_analyze a) in
        JUnit_wrapper.junit_to_file suites file;
    end;
    (* now fail if results were bad *)
    check_res results
end

(** {2 Display Run} *)
module Display = struct
  let main (file:string option) =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage file >>= fun res ->
    Format.printf "%a@." T.Top_result.pp res;
    E.return ()
end

(** {2 CSV Run} *)
module CSV = struct
  let main (file:string option) (out:string option) =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage file >>= fun res ->
    begin match out with
      | None ->
        print_endline (T.Top_result.to_csv_string res)
      | Some file ->
        T.Top_result.to_csv_file file res
    end;
    E.return ()
end

(** {2 Compare Run} *)
module Compare = struct
  let main ~file1 ~file2 () =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_results ~storage file1 >>= fun res1 ->
    Test_run.find_results ~storage file2 >>= fun res2 ->
    let cmp = T.Top_result.compare res1 res2 in
    Format.printf "%a@." T.Top_result.pp_comparison cmp;
    E.return ()
end

(** {2 Display+ Compare} *)
module Display_bench = struct
  let main (file:string option) =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage file >>= fun res ->
    let b = T.Bench.make res in
    Format.printf "%a@." T.Bench.pp b;
    E.return ()
end

(** {2 List} *)
module List_run = struct
  let pp_snap_summary out (s:Event.Meta.t): unit =
    let provers = Event.Meta.provers s |> Prover.Set.elements in
    let len = Event.Meta.length s in
    Format.fprintf out "@[<h>uuid: %s time: %a num: %d provers: [@[<h>%a@]]@]"
      (Uuidm.to_string (Event.Meta.uuid s))
      ISO8601.Permissive.pp_datetime (Event.Meta.timestamp s) len
      (Misc.Fmt.pp_list ~start:"" ~stop:"" ~sep:"," Prover.pp_name) provers

  let main () =
    let open E in
    let storage = Storage.make [] in
    Event_storage.list_meta storage >>= fun l ->
    (* sort: most recent first *)
    let l =
      List.sort (fun s1 s2 -> compare s2.Event.s_timestamp s1.Event.s_timestamp) l
    in
    Format.printf "@[<v>%a@]@."
      (Misc.Fmt.pp_list ~start:"" ~stop:"" ~sep:"" pp_snap_summary) l;
    E.return ()
end

(** {2 Global Summary}

    Summary of a snapshot compared to other ones with similar provers and
    files *)
module Summary_run = struct
  let main (name:string option) : _ E.t =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage name >>= fun main_res ->
    Test_run.all_results storage >>= fun l ->
    let summary = Test.Summary.make main_res l in
    Format.printf "@[<v>%a@]@." Test.Summary.print summary;
    E.return ()
end

(** {2 Deletion of snapshots} *)
module Delete_run = struct
  let main (names:string list) : unit E.t =
    let open E in
    let storage = Storage.make [] in
    E.map_s (fun file -> Storage.delete storage file) names >|= fun _ -> ()
end

module Plot_run = struct
  (* Plot functions *)
  let main ~config params (name:string option) : unit E.t =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage name >>= fun main_res ->
    Test_run.Plot_res.draw_file params main_res;
    E.return ()
end

(** {2 Main: Parse CLI} *)

let config_term =
  let open Cmdliner in
  let aux config debug =
    if debug then (
      Maki_log.set_level 5;
      Lwt_log.add_rule "*" Lwt_log.Debug;
    );
    let config = Config.interpolate_home config in
    try
      `Ok (Config.parse_files [config] Config.empty)
    with Config.Error msg ->
      `Error (false, msg)
  in
  let arg =
    Arg.(value & opt string "$home/.frogutils.toml" &
         info ["c"; "config"] ~doc:"configuration file (in target directory)")
  and debug =
    let doc = "Enable debug (verbose) output" in
    Arg.(value & flag & info ["d"; "debug"] ~doc)
  in
  Term.(ret (pure aux $ arg $ debug))

(* sub-command for running tests *)
let term_run =
  let open Cmdliner in
  let aux dirs config j timeout memory nocaching meta save provers junit =
    let caching = not nocaching in
    Lwt_main.run
      (Run.main ?j ?timeout ?memory ?junit ?provers ~caching ~meta ~save ~config dirs ())
  in
  let config = config_term
  and j =
    Arg.(value & opt (some int) None & info ["j"] ~doc:"parallelism level")
  and timeout =
    Arg.(value & opt (some int) None & info ["t"; "timeout"] ~doc:"timeout (in s)")
  and memory =
    Arg.(value & opt (some int) None & info ["m"; "memory"] ~doc:"memory (in MB)")
  and meta =
    Arg.(value & opt string "" & info ["meta"] ~doc:"additional metadata to save")
  and nocaching =
    Arg.(value & flag & info ["no-caching"] ~doc:"toggle caching")
  and doc =
    "test a program on every file in a directory"
  and junit =
    Arg.(value & opt (some string) None & info ["junit"] ~doc:"junit output file")
  and save =
    Arg.(value & opt string "" & info ["save"] ~doc:"JSON file to save results in")
  and dir =
    Arg.(value & pos_all string [] &
         info [] ~docv:"DIR" ~doc:"target directories (containing tests)")
  and provers =
    Arg.(value & opt (some (list string)) None & info ["p"; "provers"] ~doc:"select provers")
  in
  Term.(pure aux $ dir $ config $ j $ timeout $ memory
    $ nocaching $ meta $ save $ provers $ junit),
  Term.info ~doc "run"

let snapshot_name_term : string option Cmdliner.Term.t =
  let open Cmdliner in
  Arg.(value & pos 0 (some string) None
       & info [] ~docv:"FILE" ~doc:"file/name containing results (default: last)")

(* sub-command to display a file *)
let term_display =
  let open Cmdliner in
  let aux file = Lwt_main.run (Display.main file) in
  let file =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"FILE" ~doc:"file containing results (default: last)")
  and doc = "display test results from a file" in
  Term.(pure aux $ file), Term.info ~doc "display"

(* sub-command to display a file as a benchmark *)
let term_bench =
  let open Cmdliner in
  let aux file = Lwt_main.run (Display_bench.main file) in
  let file =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"FILE"
           ~doc:"file containing results (default: last)")
  and doc = "display test results from a file" in
  Term.(pure aux $ file), Term.info ~doc "bench"

(* sub-command to display a file *)
let term_csv =
  let open Cmdliner in
  let aux file out = Lwt_main.run (CSV.main file out) in
  let file =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"FILE" ~doc:"file containing results (default: last)")
  and out =
    Arg.(value & opt (some string) None & info ["o"; "output"]
           ~docv:"OUT" ~doc:"file into which to print (default: stdout)")
  and doc = "dump results as CSV" in
  (* TODO: out should be "-o" option *)
  Term.(pure aux $ file $ out), Term.info ~doc "csv"

(* sub-command to compare two files *)
let term_compare =
  let open Cmdliner in
  let aux file1 file2 = Lwt_main.run (Compare.main ~file1 ~file2 ()) in
  let file1 = Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE1" ~doc:"first file")
  and file2 = Arg.(required & pos 1 (some string) None & info [] ~docv:"FILE2" ~doc:"second file")
  and doc = "compare two result files" in
  Term.(pure aux $ file1 $ file2), Term.info ~doc "compare"

let term_list =
  let open Cmdliner in
  let aux () = Lwt_main.run (List_run.main ()) in
  let doc = "compare two result files" in
  Term.(pure aux $ pure ()), Term.info ~doc "list snapshots"

let drawer_term =
  let open Cmdliner in
  let open Test_run.Plot_res in
  let aux cumul sort filter count =
    if cumul then Cumul (sort, filter, count) else Simple sort
  in
  let cumul =
    let doc = "Plots the cumulative sum of the data" in
    Arg.(value & opt bool true & info ["cumul"] ~doc)
  in
  let sort =
    let doc = "Should the data be sorted before being plotted" in
    Arg.(value & opt bool true & info ["sort"] ~doc)
  in
  let filter =
    let doc = "Plots one in every $(docv) data point
              (ignored if not in cumulative plotting)" in
    Arg.(value & opt int 3 & info ["pspace"] ~doc)
  in
  let count =
    let doc = "Plots the last $(docv) data point in any case" in
    Arg.(value & opt int 5 & info ["count"] ~doc)
  in
  Term.(pure aux $ cumul $ sort $ filter $ count)

let plot_params_term =
  let open Cmdliner in
  let open Test_run.Plot_res in
  let aux graph data legend drawer out_file out_format =
    { graph; data; legend; drawer; out_file; out_format }
  in
  let to_cmd_arg l = Cmdliner.Arg.enum l, Cmdliner.Arg.doc_alts_enum l in
  let data_conv, data_help = to_cmd_arg
      [ "unsat_time", Unsat_time; "sat_time", Sat_time; "both_time", Both_time ] in
  let legend_conv, legend_help = to_cmd_arg [ "prover", Prover ] in
  let data =
    let doc = Format.sprintf "Decides which value to plot. $(docv) must be %s" data_help in
    Arg.(value & opt data_conv Both_time & info ["data"] ~doc)
  and legend =
    let doc = Format.sprintf
        "What legend to attach to each curve. $(docv) must be %s" legend_help
    in
    Arg.(value & opt legend_conv Prover & info ["legend"] ~doc)
  and out_file =
    let doc = "Output file for the plot" in
    Arg.(required & opt (some string) None & info ["o"; "out"] ~doc)
  and out_format =
    let doc = "Output format for the graph" in
    Arg.(value & opt string "PDF" & info ["format"] ~doc)
  in
  Term.(pure aux $ Plot.graph_args $ data $ legend $ drawer_term $ out_file $ out_format)

let term_plot =
  let open Cmdliner in
  let aux config params file = Lwt_main.run (Plot_run.main ~config params file) in
  let doc = "Plot graphs of prover's statistics" in
  let man = [
    `S "DESCRIPTION";
    `P "This tools takes results files from runs of '$(b,frogmap)' and plots graphs
        about the prover's statistics.";
    `S "OPTIONS";
    `S Plot.graph_section;
  ] in
  Term.(pure aux $ config_term $ plot_params_term $ snapshot_name_term),
  Term.info ~man ~doc "plot"

(* sub-command to compare a snapshot to the others *)
let term_summary =
  let open Cmdliner in
  let aux name = Lwt_main.run (Summary_run.main name) in
  let doc = "summary of results from a file, compared to the other snapshots" in
  Term.(pure aux $ snapshot_name_term), Term.info ~doc "summary"

let term_delete =
  let open Cmdliner in
  let aux name = Lwt_main.run (Delete_run.main name) in
  let file_name =
    Arg.(value & pos_all string []
         & info [] ~docv:"FILE" ~doc:"files/names containing results")
  and doc = "delete some snapshots" in
  Term.(pure aux $ file_name), Term.info ~doc "delete result(s)"

let parse_opt () =
  let open Cmdliner in
  let help =
    let doc = "Offers various utilities to test automated theorem provers." in
    let man = [
      `S "DESCRIPTION";
      `P "$(b,frogtest) is a set of utils to run tests, save their results,
          and compare different results obtained with distinct versions of
          the same tool";
      `S "COMMANDS";
      `S "OPTIONS"; (* TODO: explain config file *)
    ] in
    Term.(ret (pure (fun () -> `Help (`Pager, None)) $ pure ())),
    Term.info ~version:"dev" ~man ~doc "frogtest"
  in
  Cmdliner.Term.eval_choice
    help [ term_run; term_compare; term_display; term_csv; term_list;
           term_summary; term_plot; term_bench; term_delete; ]

let () =
  match parse_opt () with
  | `Version | `Help | `Error `Parse | `Error `Term | `Error `Exn -> exit 2
  | `Ok (Ok ()) -> ()
  | `Ok (Error e) ->
      print_endline ("error: " ^ e);
      exit 1
