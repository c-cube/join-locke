
(* This file is free software, part of frog-utils. See file "license" for more details. *)

open Result
open FrogDB

module W = FrogWeb
module H = W.Html
module R = W.Record
module E = FrogMisc.Err

module Res = FrogRes
module Prover = FrogProver
module Problem = FrogProblem

let fpf = Format.fprintf

type raw_result = {
  (* Prover and problem *)
  prover : Prover.t;
  problem: Problem.t;

  (* High-level result *)
  res: Res.t;

  (* Raw output *)
  errcode: int;
  stdout: string;
  stderr: string;

  (* Time used *)
  rtime : float;
  utime : float;
  stime : float;
} [@@deriving yojson]

let maki_raw_res =
  Maki_yojson.make_err "raw_res"
    ~to_yojson:raw_result_to_yojson
    ~of_yojson:raw_result_of_yojson

(* Start processes *)
type env = (string * string) array

let extract_res_ ~prover stdout stderr errcode =
  (* find if [re: re option] is present in [stdout] *)
  let find_opt_ re = match re with
    | None -> false
    | Some re ->
      Re.execp (Re_posix.compile_pat re) stdout ||
      Re.execp (Re_posix.compile_pat re) stderr
  in
  if errcode = 0 && find_opt_ prover.Prover.sat then Res.Sat
  else if errcode = 0 && find_opt_ prover.Prover.unsat then Res.Unsat
  else if (find_opt_ prover.Prover.timeout || find_opt_ prover.Prover.unknown)
  then Res.Unknown
  else Res.Error

let run_cmd ?env ~timeout ~memory ~prover ~file () =
  Lwt_log.ign_debug_f "timeout: %d, memory: %d" timeout memory;
  let cmd = FrogProver.make_command ?env prover ~timeout ~memory ~file in
  let cmd = ["/bin/sh"; "-c"; cmd] in
  "/bin/sh", Array.of_list cmd

let run_proc ?env ~timeout ~memory ~prover ~pb () =
  let file = pb.FrogProblem.name in
  let cmd = run_cmd ?env ~timeout ~memory ~prover ~file () in
  let start = Unix.gettimeofday () in
  (* slightly extended timeout *)
  Lwt_process.with_process_full cmd
    (fun p ->
       let killed = ref false in
       (* Setup alarm to enforce timeout *)
       let pid = p#pid in
       let al = Lwt_timeout.create (timeout + 1)
           (fun () -> killed := true; Unix.kill pid Sys.sigkill) in
       Lwt_timeout.start al;
       (* Convenience function to get error code *)
       let res =
         let res_errcode =
           Lwt.map
             (function
               | Unix.WEXITED e
               | Unix.WSIGNALED e
               | Unix.WSTOPPED e -> e)
             p#status
         in
         (* Wait for the process to end, then get all output *)
         try%lwt
           let%lwt () = Lwt_io.close p#stdin in
           let out = Lwt_io.read p#stdout in
           let err = Lwt_io.read p#stderr in
           let%lwt errcode = res_errcode in
           Lwt_log.ign_debug_f "errcode: %d\n" errcode;
           Lwt_timeout.stop al;
           (* Compute time used by the prover *)
           let rtime = Unix.gettimeofday () -. start in
           let%lwt rusage = p#rusage in
           let utime = rusage.Lwt_unix.ru_utime in
           let stime = rusage.Lwt_unix.ru_stime in
           (* now finish reading *)
           Lwt_log.ign_debug_f "reading...\n";
           let%lwt stdout = out in
           let%lwt stderr = err in
           Lwt_log.ign_debug_f "closing...\n";
           let%lwt _ = p#close in
           Lwt_log.ign_debug_f "done closing & reading, return\n";
           let res =
             if !killed then FrogRes.Unknown
             else extract_res_ ~prover stdout stderr errcode
           in
           Lwt.return {
             problem = pb; prover; res;
             stdout; stderr; errcode;
             rtime; utime; stime; }
         with e ->
           Lwt_timeout.stop al;
           let%lwt errcode = res_errcode in
           let rtime = Unix.gettimeofday () -. start in
           let stderr = Printexc.to_string e in
           Lwt_log.ign_debug_f ~exn:e "error while running %s"
             ([%show: (string * string array)] cmd);
           Lwt.return {
             problem = pb; prover;
             res = FrogRes.Error;
             stdout = ""; stderr; errcode;
             rtime; utime = 0.; stime = 0.; }
       in
       res
    )


(* DB management *)
let db_init t =
  FrogDB.exec t
    "CREATE TABLE IF NOT EXISTS results (
      prover STRING, problem STRING, res STRING,
      stdout STRING, stderr STRING, errcode INTEGER,
      rtime REAL, utime REAL, stime REAL)"
    (fun _ -> ())

let import db (r:FrogDB.row) =
  let module D = FrogDB.D in
  match r with
    | [| D.BLOB prover_hash
       ; D.BLOB problem_hash
       ; D.BLOB res_s
       ; D.BLOB stdout
       ; D.BLOB stderr
       ; D.INT errcode
       ; D.FLOAT rtime
       ; D.FLOAT utime
       ; D.FLOAT stime
      |] ->
      begin match FrogProver.find db prover_hash with
        | Some prover ->
          begin match FrogProblem.find db problem_hash with
            | Some problem ->
              let res = FrogRes.of_string res_s in
              let errcode = Int64.to_int errcode in
              Some { prover; problem; res; stdout; stderr;
                     errcode; rtime; utime; stime; }
            | None -> None
          end
        | None -> None
      end
    | _ -> assert false

let find db prover problem =
  FrogDB.exec_a db
    "SELECT prover, problem, res,
            stdout, stderr, errcode,
            rtime, utime, stime
      FROM results
      WHERE prover=? AND problem=?"
    [| FrogDB.D.string prover; FrogDB.D.string problem |]
    (fun c -> match FrogDB.Cursor.head c with
       | Some r -> import db r
       | None -> None)

let db_add db t =
  let module D = FrogDB.D in
  let () = FrogProver.db_add db t.prover in
  let () = FrogProblem.db_add db t.problem in
  let prover_hash = FrogProver.hash t.prover in
  let problem_hash = FrogProblem.hash t.problem in
  FrogDB.exec_a db
    "INSERT INTO results VALUES (?,?,?,?,?,?,?,?,?)"
    [| D.BLOB prover_hash
     ; D.BLOB problem_hash
     ; D.BLOB (FrogRes.to_string t.res)
     ; D.BLOB t.stdout
     ; D.BLOB t.stderr
     ; D.int t.errcode
     ; D.FLOAT t.rtime
     ; D.FLOAT t.utime
     ; D.FLOAT t.stime
    |]
    (fun _ -> ())

(* display the raw result *)
let to_html_raw_result_name uri_of_raw r =
  H.a ~href:(uri_of_raw r) (FrogRes.to_html r.res)

let to_html_raw_result uri_of_prover uri_of_problem r =
  R.start
  |> R.add "prover"
    (H.a ~href:(uri_of_prover r.prover) (FrogProver.to_html_name r.prover))
  |> R.add "problem"
    (H.a ~href:(uri_of_problem r.problem) (Problem.to_html_name r.problem))
  |> R.add "result" (Res.to_html r.res)
  |> R.add_int "errcode" r.errcode
  |> R.add_string "real time" (Printf.sprintf "%.3f" r.rtime)
  |> R.add_string "user time" (Printf.sprintf "%.3f" r.utime)
  |> R.add_string "system time" (Printf.sprintf "%.3f" r.stime)
  |> R.add "stdout" (W.pre (H.string r.stdout))
  |> R.add "stderr" (W.pre (H.string r.stderr))
  |> R.close

let to_html_db uri_of_prover uri_of_pb uri_of_raw db =
  let pbs = List.map (fun x -> `Pb x) @@ List.sort
      (fun p p' -> compare p.FrogProblem.name p'.FrogProblem.name)
      (FrogProblem.find_all db) in
  let provers = List.sort
      (fun p p' -> compare p.FrogProver.binary p'.FrogProver.binary)
      (FrogProver.find_all db) in
  H.Create.table (`Head :: pbs) ~flags:[H.Create.Tags.Headings_fst_row]
    ~row:(function
        | `Head ->
          H.string "Problem" ::
          H.string "Expected" :: (
            List.map (fun x ->
                H.a ~href:(uri_of_prover x) (FrogProver.to_html_fullname x)
              ) provers)
        | `Pb pb ->
          H.a ~href:(uri_of_pb pb) (FrogProblem.to_html_name pb) ::
          FrogRes.to_html pb.FrogProblem.expected ::
          List.map (
            fun prover ->
              match find db (FrogProver.hash prover) (FrogProblem.hash pb) with
              | Some raw -> to_html_raw_result_name uri_of_raw raw
              | None -> H.string "<none>"
          ) provers
      )

let k_add = W.HMap.Key.create ("add_result", fun _ -> Sexplib.Sexp.Atom "")

let add_server s =
  let open Opium.Std in
  let uri_of_problem = W.Server.get s Problem.k_uri in
  let uri_of_prover = W.Server.get s Prover.k_uri in
  (* find raw result *)
  let handle_res req =
    let prover = param req "prover" in
    let pb = param req "problem" in
    begin match find (W.Server.db s) prover pb with
      | Some res ->
        W.Server.return_html
          (W.Html.list [
              W.Html.h2 (W.Html.string "Raw Result");
              to_html_raw_result uri_of_prover uri_of_problem res;
            ])
      | None ->
        let code = Cohttp.Code.status_of_code 404 in
        let h = H.string ("could not find result") in
        W.Server.return_html ~code h
    end
  (* display all the results *)
  and handle_main _ =
    let uri_of_raw_res r = Uri.make
        ~path:(Printf.sprintf "/raw/%s/%s"
                 (FrogProver.hash r.prover) (FrogProblem.hash r.problem)) () in
    let h = to_html_db uri_of_prover uri_of_problem uri_of_raw_res (W.Server.db s) in
    W.Server.return_html ~title:"Results"
      (W.Html.list [ W.Html.h2 (W.Html.string "Results"); h])
  and on_add r = db_add (W.Server.db s) r in
  W.Server.set s k_add on_add;
  W.Server.add_route s ~descr:"current results" "/results" handle_main;
  W.Server.add_route s "/raw/:prover/:problem" handle_res;
  ()
