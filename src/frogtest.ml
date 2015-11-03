
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(* run tests *)

module T = FrogTest
module Prover = FrogProver
module E = FrogMisc.LwtErr

let timeout = ref 2
let config = ref "test.toml"
let dir = ref None

let set_dir d = match !dir with
  | None -> dir := Some d
  | Some _ -> failwith "give exactly one test directory"

(* callback that prints a result *)
let on_solve pb res =
  let module F = FrogMisc.Fmt in
  let pp_res out () =
    let str, c = match T.Problem.compare_res pb res with
      | `Same -> "ok", `Green
      | `Improvement -> "ok (improved)", `Blue
      | `Mismatch -> "bad", `Red
    in
    Format.fprintf out "%a" (F.in_bold_color c Format.pp_print_string) str
  in
  Format.printf "problem %-30s %a@." (pb.T.Problem.name ^ " :") pp_res ();
  Lwt.return_unit

(* lwt main *)
let main ~config ~dir () =
  let open E in
  (* parse config *)
  Lwt.return (T.Config.of_file (Filename.concat dir config))
  >>= fun config ->
  (* build problem set (exclude config file!) *)
  T.ProblemSet.of_dir ~filter:(Re.execp config.T.Config.problem_pat) dir
  >>= fun pb ->
  Format.printf "run %d tests@." (T.ProblemSet.size pb);
  (* solve *)
  E.ok (T.run ~on_solve ~config pb)
  >>= fun results ->
  Format.printf "%a@." T.Results.print results;
  if T.Results.is_ok results
  then E.return ()
  else
    E.fail (Format.asprintf "%d failure(s)" (T.Results.num_failed results))

let () =
  let options = Arg.align
  [ "-timeout", Arg.Set_int timeout, " timeout of prover, in seconds"
  ; "-config", Arg.Set_string config, " configuration file (in target directory)"
  ; "-debug", Arg.Unit FrogDebug.enable_debug, " enable debug"
  ] in
  Arg.parse options set_dir "frogtest [options] <dir>";
  let dir = match !dir with
    | None -> failwith "need a test directory"
    | Some d -> d
  in
  match Lwt_main.run (main ~config:!config ~dir ()) with
  | `Error e ->
      print_endline ("error: " ^ e);
      exit 1
  | `Ok () -> ()
