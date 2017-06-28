
(* This file is free software, part of frog-utils. See file "license" for more details. *)

open Frog
open Result

type path = string
type t = Problem.t

type expect =
  | Auto
  | Res of Res.t
  | Program of Prover.t

(* regex + mark *)
let m_unsat_, unsat_ = Re.(str "unsat" |> no_case |> mark)
let m_sat_, sat_ = Re.(str "sat" |> no_case |> mark)
let m_unknown_, unknown_ = Re.(str "unknown" |> no_case |> mark)
let m_timeout_, timeout__ = Re.(str "timeout" |> no_case |> mark)
let m_error_, error_ = Re.(alt [str "error"; str "fail"] |> no_case |> mark)

(* "^ #expect: (unsat|sat|unknown|error)", basically *)
let re_expect_ =
  Re.(seq
        [ alt (List.map no_case [str "expect:"; str "expected:"]) ; rep blank;
          alt [unsat_; sat_; unknown_; error_] ]
      |> compile
     )

(* what is expected? *)
let find_expected_ ?default file =
  let content = CCIO.with_in file CCIO.read_all in
  match Re.exec_opt re_expect_ content with
  | Some g ->
    if Re.marked g m_unsat_ then CCResult.return Res.Unsat
    else if Re.marked g m_sat_ then CCResult.return Res.Sat
    else if Re.marked g m_unknown_ then CCResult.return Res.Unknown
    else if Re.marked g m_timeout_ then CCResult.return Res.Timeout
    else if Re.marked g m_error_ then CCResult.return Res.Error
    else CCResult.fail "could not parse the content of the `expect:` field"
  | None ->
    begin match default with
      | Some r -> CCResult.return r
      | None -> CCResult.fail "could not find the `expect:` field"
    end

let find_expect ~expect file : (Res.t, string) result =
  begin match expect with
    | Auto -> find_expected_ ?default:None file
    | Res r -> find_expected_ ~default:r file
    | Program prover ->
      let pb = Problem.make file Res.Unknown in
      let event = Run.run_prover ~timeout:1 ~memory:1_000 ~prover ~pb () in
      CCResult.return (Event.analyze_p event)
  end

let make ~find_expect file =
  let open CCResult.Infix in
  Lwt_log.ign_debug_f "convert `%s` into problem..." file;
  find_expect file |> CCResult.add_ctxf "parsing expected result of `%s`" file
  >>= fun res ->
  let pb = Problem.make file res in
  CCResult.return pb

let of_dir ~filter d =
  Misc_unix.File.walk d
  |> Misc.List.filter_map
    (fun (kind,f) -> match kind with
       | `File when filter f -> Some f
       | _ -> None)
  |> Lwt.return

(*
module Set = struct
  type t = Problem.problem_set

  let size = List.length

  let make ~find_expect l =
    let pool = Lwt_pool.create 30 (fun () -> Lwt.return_unit) in
    let%lwt l =
      Lwt_list.map_p
        (fun file ->
           Lwt_pool.use pool
             (fun () -> make ~find_expect file))
        l
    in
    let l = Misc.Err.seq_list l in
    (* sort by alphabetic order *)
    let l = Misc.Err.(l >|= List.sort Problem.compare_name) in
    Lwt.return l

  let of_dir ~expect ~filter d =
    let%lwt l = of_dir ~filter d in
    make ~find_expect:(find_expect ~expect) l

  let print out set =
    Format.fprintf out "@[<hv>%a@]" (Format.pp_print_list Problem.print) set
end
*)
