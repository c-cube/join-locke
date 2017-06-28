
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(* run tests, or compare results *)

open Result
open Frog
open Frog_server
module T = Test_run
module E = Misc.LwtErr

(** {2 Run} *)
module Run = struct
  (* callback that prints a result *)
  let nb_sec_minute = 60
  let nb_sec_hour = 60 * nb_sec_minute
  let nb_sec_day = 24 * nb_sec_hour

  let time_string f =
    let n = int_of_float f in
    let aux n div = n / div, n mod div in
    let n_day, n = aux n nb_sec_day in
    let n_hour, n = aux n nb_sec_hour in
    let n_min, n = aux n nb_sec_minute in
    let print_aux s n = if n <> 0 then (string_of_int n) ^ s else "" in
    (print_aux "d" n_day) ^
    (print_aux "h" n_hour) ^
    (print_aux "m" n_min) ^
    (string_of_int n) ^ "s"

  let progress_dynamic len =
    let start = Unix.gettimeofday () in
    let count = ref 0 in
    function res ->
      let time_elapsed = Unix.gettimeofday () -. start in
      incr count;
      let len_bar = 50 in
      let bar = String.init len_bar
          (fun i -> if i * !len <= len_bar * !count then '#' else '-') in
      let percent = if !len=0 then 100 else (!count * 100) / !len in
      Format.printf "... %5d/%d | %3d%% [%6s: %s]@?"
        !count !len percent (time_string time_elapsed) bar;
      if !count = !len then Format.printf "@."

  let progress ?(dyn=false) n =
    let pp_bar = progress_dynamic n in
    (function res ->
       if dyn then Format.printf "\r";
       Test_run.print_result res;
       if dyn then pp_bar res;
       Lwt.return_unit)

  (* run provers on the given dir, return a list [prover, dir, results] *)
  let test_dir ?dyn ?ipc ?caching ?db snapshot config : unit E.t =
    let open E.Infix in
    let len = ref 0 in
    let pp = ref (fun _ -> Lwt.return_unit) in
    let nprover = List.length config.T.provers in
    let on_dir d l =
      len := List.length l * nprover;
      pp := progress ?dyn len;
      Format.printf "run %d tests in %s@." !len d.T.directory;
      Lwt.return_unit
    in
    let on_solve = fun r -> !pp r in
    (* solve *)
    Test_run.run ?caching ~on_dir ~on_solve config
    |> E.add_ctxf "running %d tests" !len

  let mk_config ?j ?timeout ?memory ?provers ?profile config dirs =
    let open E.Infix in
    begin
      Lwt.return (Test_run.mk_config ?profile config dirs)
      |> E.add_ctxf "parsing config for files [@[%a@]]" (Misc.Fmt.pp_list Format.pp_print_string) dirs
    end >|= fun config ->
    let j = CCOpt.get_or ~default:config.T.j j in
    let timeout = CCOpt.get_or ~default:config.T.timeout timeout in
    let memory = CCOpt.get_or ~default:config.T.memory memory in
    let provers = match provers with
      | None | Some [] -> config.T.provers
      | Some l -> List.filter (fun pv -> List.mem pv.Prover.name l) config.T.provers
    in
    { config with T.j; timeout; memory; provers; }

  (* lwt main *)
  let main ?dyn ?meta ?caching ?db ~port ~with_lock config =
    let open E.Infix in
    (* create snapshot *)
    let snapshot = Snapshot.make ?meta () in
    (* build problem set (exclude config file!) *)
    let task_with_conn ipc = test_dir ?dyn ?ipc ?caching ?db snapshot config in
    if with_lock
    then IPC_client.connect_and_acquire port
        ~info:"frogtest" ~tags:(CCOpt.to_list meta)
        (fun (c,_) -> task_with_conn (Some c))
    else (* IPC_client.connect_or_spawn port task_with_conn *)
      task_with_conn None

end

(*
(** {2 Display Run} *)
module Display = struct
  let main (name:string option)(provers:string list option)(dir:string list) =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage name >>= fun res ->
    let res = T.Top_result.filter ~provers ~dir res in
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
  let main (name:string option)(provers:string list option)(dir:string list) =
    let open E in
    let storage = Storage.make [] in
    Test_run.find_or_last ~storage name >>= fun res ->
    let res = T.Top_result.filter ~provers ~dir res in
    let b = T.Bench.make res in
    Format.printf "%a@." T.Bench.pp b;
    E.return ()
end

(** {2 Sample} *)
module Sample = struct
  open E.Infix

  let run ~n dirs =
    Lwt_list.map_p
      (fun d -> Problem_run.of_dir ~filter:(fun _ -> true) d)
      dirs |> E.ok
    >|= List.flatten
    >|= Array.of_list
    >>= fun files ->
    let len = Array.length files in
    begin
      if len < n
      then E.failf "not enough files (need %d, got %d)" n len
      else E.return ()
    end
    >>= fun () ->
    (* sample the list *)
    let sample_idx =
      CCRandom.sample_without_replacement
        ~compare:CCInt.compare n (CCRandom.int len)
      |> CCRandom.run ?st:None
    in
    let sample = List.map (Array.get files) sample_idx in
    (* print sample *)
    List.iter (Printf.printf "%s\n%!") sample;
    Lwt.return (Ok ())
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
*)

(** {2 Main: Parse CLI} *)

let config_term =
  let open Cmdliner in
  let aux config debug =
    if debug then (
      Maki_log.set_level 5;
      Lwt_log.add_rule "*" Lwt_log.Debug;
    );
    let config = Config.interpolate_home config in
    begin match Config.parse_file config with
      | Ok x -> `Ok x
      | Error e -> `Error (false, e)
    end
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
  let aux dyn port dirs config profile j timeout memory
      with_lock nocaching meta save provers =
    let caching = not nocaching in
    Lwt_main.run
      (Run.main ~dyn ~port ?j ?timeout ?memory ?provers ~with_lock
         ~caching ~meta ~save ?profile ~config dirs ())
  in
  let config = config_term
  and dyn =
    Arg.(value & flag & info ["progress"] ~doc:"print progress bar")
  and j =
    Arg.(value & opt (some int) None & info ["j"] ~doc:"parallelism level")
  and profile =
    Arg.(value & opt (some string) None & info ["profile"] ~doc:"pick test profile (default 'test')")
  and timeout =
    Arg.(value & opt (some int) None & info ["t"; "timeout"] ~doc:"timeout (in s)")
  and memory =
    Arg.(value & opt (some int) None & info ["m"; "memory"] ~doc:"memory (in MB)")
  and meta =
    Arg.(value & opt string "" & info ["meta"] ~doc:"additional metadata to save")
  and with_loc =
    Arg.(value & opt bool true & info ["lock"] ~doc:"require a lock")
  and nocaching =
    Arg.(value & flag & info ["no-caching"] ~doc:"toggle caching")
  and doc =
    "test a program on every file in a directory"
  and save =
    Arg.(value & opt string "" & info ["save"] ~doc:"JSON file to save results in")
  and dir =
    Arg.(value & pos_all string [] &
         info [] ~docv:"DIR" ~doc:"target directories (containing tests)")
  and port =
    let doc = "Local port for the lock daemon" in
    Arg.(value & opt int IPC_daemon.default_port & info ["port"] ~docv:"PORT" ~doc)
  and provers =
    Arg.(value & opt (some (list string)) None & info ["p"; "provers"] ~doc:"select provers")
  in
  Term.(pure aux $ dyn $ port $ dir $ config $ profile $ j $ timeout $ memory $ with_loc
        $ nocaching $ meta $ save $ provers),
  Term.info ~doc "run"

let snapshot_name_term : string option Cmdliner.Term.t =
  let open Cmdliner in
  Arg.(value & pos 0 (some string) None
       & info [] ~docv:"FILE" ~doc:"file/name containing results (default: last)")

(* sub-command to display a file *)
let term_display =
  let open Cmdliner in
  let aux name provers dir = Lwt_main.run (Display.main name provers dir) in
  let name_ =
    Arg.(value & pos 0 (some string) None & info []
           ~docv:"FILE" ~doc:"file containing results (default: last)")
  and dir =
    Arg.(value & pos_right 0 string [] &
         info [] ~docv:"DIR" ~doc:"target directories (containing tests)")
  and provers =
    Arg.(value & opt (some (list string)) None & info ["p"; "provers"] ~doc:"select provers")
  and doc = "display test results from a file" in
  Term.(pure aux $ name_ $ provers $ dir), Term.info ~doc "display"

(* sub-command to display a file as a benchmark *)
let term_bench =
  let open Cmdliner in
  let aux name provers dir = Lwt_main.run (Display_bench.main name provers dir) in
  let provers =
    Arg.(value & opt (some (list string)) None & info ["p"; "provers"] ~doc:"select provers")
  and dir =
    Arg.(value & pos_right 0 string [] &
         info [] ~docv:"DIR" ~doc:"target directories (containing tests)")
  and name_ =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"FILE"
           ~doc:"file containing results (default: last)")
  and doc = "display test results from a file" in
  Term.(pure aux $ name_ $ provers $ dir), Term.info ~doc "bench"

(* sub-command to sample a directory *)
let term_sample =
  let open Cmdliner in
  let aux n dir = Lwt_main.run (Sample.run ~n dir) in
  let dir =
    Arg.(value & pos_all string [] &
         info [] ~docv:"DIR" ~doc:"target directories (containing tests)")
  and n =
    Arg.(value & opt int 1 & info ["n"] ~docv:"N" ~doc:"number of files to sample")
  and doc = "sample N files in the directories" in
  Term.(pure aux $ n $ dir), Term.info ~doc "sample"

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
           term_summary; term_bench; term_delete;
           term_sample; ]

let () =
  match parse_opt () with
  | `Version | `Help | `Error `Parse | `Error `Term | `Error `Exn -> exit 2
  | `Ok (Ok ()) -> ()
  | `Ok (Error e) ->
    print_endline ("error: " ^ e);
    exit 1
