
(*
copyright (c) 2013-2014, simon cruanes
all rights reserved.

redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)


(** {1 Call a command on each result of frogmap} *)

open Frog
open Frog_server

module S = FrogMapState

(* what kind of input to give to the command, for every result? *)
type format_in =
  | OutOnly  (* pass result.res_out to command *)
  | Prelude  (* pass result.res_out + prelude with other data *)
  | AsArg    (* do not use cmd.stdin, but give result.res_out as CLI arg *)

type cmd =
  | Shell of string
  | Exec of string * string list
  [@@deriving show]

type params = {
  format_in : format_in;
  cmd : cmd;
  filename : string;
}

(* print metadata of result on the given chan *)
let print_prelude oc res =
  let%lwt () = Lwt_io.fprintf oc "# argument: %s\n" res.S.res_arg in
  Lwt_io.fprintf oc "# time: %.2f\n" res.S.res_rtime

let escape_quote s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '\'' -> Buffer.add_string buf "\'"
      | c -> Buffer.add_char buf c
    ) s;
  Buffer.contents buf

(* run command on the given result *)
let run_cmd params res =
  let cmd = match params.cmd with
    | Shell c ->
      let c' = match params.format_in with
        | AsArg -> c ^ " " ^ res.S.res_out
        | _ -> c
      in
      Lwt_process.shell ("set -e; set -o pipefail; " ^ escape_quote c')
    | Exec (p, args)  ->
      let args = match params.format_in with
        | AsArg -> args @ [res.S.res_out]
        | _ -> args
      in
      (p, Array.of_list (p::args))
  in
  (* give additional info through parameters *)
  let env = Unix.environment () |> Array.to_list in
  let env =
    [ "FROG_ERRCODE=" ^ res.S.res_err
    ; "FROG_TIME=" ^ string_of_float res.S.res_rtime
    ; "FROG_ERR=" ^ res.S.res_err
    ; "FROG_OUT=" ^ res.S.res_out
    ; "FROG_ARG=" ^ res.S.res_arg
    ] @ env
    |> Array.of_list
  in
  Lwt_log.ign_debug_f "run sub-process %s" ([%show: string*string array] cmd);
  (* spawn process *)
  try%lwt
    Lwt_process.with_process_out
      ~stdout:`Keep ~stderr:`Keep ~env cmd
      (fun p ->
        let%lwt () = match params.format_in with
        | OutOnly ->
            Lwt_io.write p#stdin res.S.res_out
        | Prelude ->
            let%lwt () = print_prelude p#stdin res in
            Lwt_io.write p#stdin res.S.res_out
        | AsArg -> Lwt.return_unit
        in
        let%lwt () = Lwt_io.close p#stdin
        and _ = p#status in
        Lwt_log.ign_debug "process finished";
        Lwt.return_unit
      )
  with e ->
    Lwt_io.eprintlf "error on command %s: %s"
      (show_cmd params.cmd) (Printexc.to_string e)

(* print some statistics *)
let show_stats filename =
  let%lwt (job, map) = S.read_state filename in
  let%lwt() = Lwt_io.printlf "job: run '%s' on %d arguments"
    job.S.cmd (List.length job.S.arguments) in
  (* compute basic statistics *)
  let foi = float_of_int in
  let num, sum_len_out = S.StrMap.fold
    (fun _ res (num,sum_len_out) ->
      num + 1, sum_len_out + String.length res.S.res_out
    ) map (0,0)
  in
  Lwt_io.printlf
    "%d arguments dealt with, total length of outputs %d (avg output len %.2f)"
    num sum_len_out (if num=0 then 0. else foi sum_len_out /. foi num)

let main params =
  FrogMapState.fold_state_s
    (fun () res ->
       run_cmd params res
    ) (fun _job -> Lwt.return_unit)
    params.filename

(** {2 Main} *)
let format_in_list = [
  "out", OutOnly;
  "prelude", Prelude;
  "cli", AsArg;
]
let format_conv = Cmdliner.Arg.enum format_in_list

let input_file =
  let open Cmdliner in
  let doc = "Result file (typically, the output of frogmap)."in
  Arg.(required & pos 0 (some file) None & info [] ~docv:"FILE" ~doc)

let stats_term =
  let doc = "Print statistics about the file." in
  Cmdliner.Term.(pure show_stats $ input_file),
  Cmdliner.Term.info ~doc "stats"

let opts =
  let open Cmdliner in
  let aux debug format_in filename cmd =
    if debug then Lwt_log.add_rule "*" Lwt_log.Debug;
    { format_in; cmd; filename }
  in
  let format_in =
    let doc = "Choose the input format with which to give info about the result to the command.
               $(docv) may be " ^ (Arg.doc_alts_enum format_in_list) ^ ". See frogiter --help
               for more explanations."
    in
    Arg.(value & opt format_conv OutOnly & info ["f"; "format"] ~doc)
  in
  let debug =
    let doc = "Enable debug" in
    Arg.(value & flag & info ["d"; "debug"] ~doc)
  in
  Term.(pure aux $ debug $ format_in)

(*
let shell_term =
  let open Cmdliner in
  let cmd arg = Shell arg in
  let arg =
    let doc = "Command to be used" in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"CMD" ~doc)
  in
  let doc = "Invoke command in a shell" in
  Term.(pure main $ (opts $ input_file $ (pure cmd $ arg))),
  Term.info ~doc "shell"
*)

let term =
  let open Cmdliner in
  let aux shell cmds =
    if shell then
      Shell (String.concat " " cmds)
    else match cmds with
      | cmd :: args -> Exec (cmd, args)
      | [] -> assert false
  in
  let shell =
    let doc = "Invoke command in a shell instead." in
    Arg.(value & flag & info ["c"; "shell"] ~doc)
  in
  let cmds =
    let doc = "Command (with arguments) to run on every output result in argument file" in
    Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"CMD" ~doc)
  in
  let doc = "Call the command on every result in file, piping the result's output into the command's input" in
  let man = [
    `S "SYNOPSIS";
    `I ("$(b,frogiter COMMAND)", "Call one of the commands");
    `I ("$(b,frogiter [OPTIONS] -- FILE CMD [CMD [CMD ...]])", "Call the command on every result output in the file.");
    `S "DESCRIPTION";
    `P "This commands allows to run bash commands on every results in an output file produced by
        the '$(b,frogmap)' command.";
    `S "COMMANDS";
    `S "OPTIONS";
    `S "RESULTS FORMAT";
    `P "There are three input format available for
        the command given to frogiter (which we will call the processor command), in order to get the
        output of the commands that were run with frogmap (which we will call the mapped command).";
    `I ("$(b,out)", "The result outputted by the mapped command on stdout is given to
                     the processor command through its stdin.");
    `I ("$(b,cli)", "The result outputted by the mapped command is given to the processor command
                     as CLI argument.");
    `I ("$(b,prelude)", "Gives to the processor command the following lines on stdin :
                         '# argument: <mapped command args>', '# time: <mapped command time>' and
                         the complete output of the mapped command (which may span multiple lines).");
    `S "ENVIRONMENT VARIABLES";
    `P "The following environment variables will be set up prior to calling the processor command.";
    `I ("$(b,FROG_OUT)", "the mapped command's result on stdout.");
    `I ("$(b,FROG_ERR)", "the mapped command's result on stderr.");
    `I ("$(b,FROG_ARG)", "the argument of the mapped command (i.e the element
                     of the mapped list on which the mapped command was applied)");
    `I ("$(b,FROG_TIME)", "number of seconds the mapped command took to complete");
    `I ("$(b,FROG_ERRCODE)", "the exit code of the mapped function");
  ] in
  Term.(pure main $ (opts $ input_file $ (pure aux $ shell $ cmds))),
  Term.info ~man ~doc "frogiter"

let () =
  match Cmdliner.Term.eval_choice term [stats_term] with
  | `Version | `Help | `Error `Parse | `Error `Term | `Error `Exn -> exit 2
  | `Ok res -> Lwt_main.run res

