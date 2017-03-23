
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(** {1 IRC bot plugin} *)

open Frog
open Frog_server

module E = Misc.Err
module EL = Misc.LwtErr
module C = Calculon

(* state *)
type state = {
  c: IPC_client.t;
  send_stop: unit Lwt.u; (* to disconnect *)
}

let default_port = IPC_daemon.default_port

let connect port : state E.t Lwt.t =
  let open EL.Infix in
  let stop, send_stop = Lwt.wait () in
  let res, send_res = Lwt.wait () in
  Lwt.async (fun () ->
    IPC_client.connect_or_spawn port
      (fun c ->
         Lwt.wakeup send_res c;
         stop));
  let%lwt c = res in
  EL.return {c; send_stop}

let cmd_status (st:state): C.Command.t =
  let module M = IPC_message in
  let n_tot = ref 0 in
  let n_cur = ref 0 in
  (* update registers *)
  IPC_client.on_msg st.c
    (fun msg ->
       begin match msg with
         | M.Start_bench n -> n_cur := 0; n_tot := n
         | M.Finish_bench -> n_tot := 0
         | M.Event (Event.Prover_run _) -> incr n_cur
         | _ -> ()
       end; `Continue);
  (* the command itself *)
  C.Command.make_simple
    ~prefix:"status" ~descr:"status of query" ~prio:10
    (fun _ _ ->
       if !n_tot > 0 then (
         let s = Printf.sprintf "[%d/%d]" !n_cur !n_tot in
         Lwt.return_some s
       ) else Lwt.return_none)

let maybe_str = function
  | None -> "<none>"
  | Some s -> s

let cmd_froglock (st:state) : C.Command.t =
  let module M = IPC_message in
  C.Command.make_simple_l
    ~prefix:"lock_status" ~descr:"status of froglock" ~prio:10
    (fun _ _ ->
       let%lwt res = IPC_client.get_status st.c in
       begin match res with
         | {M.max_cores=_; current; waiting} ->
           let msg_waiting =
             if waiting=[] then []
             else [Printf.sprintf "[%d waiting jobs]" (List.length waiting)]
           and msg_current =
             let now = Unix.gettimeofday() in
             List.map
               (fun c ->
                  let time = now -. c.M.current_start in
                  let job = c.M.current_job in
                  Printf.sprintf
                    "current job (cores %d, pid %d, \
                     issued %.2fs ago, running for %.2fs): %s"
                    job.M.cores
                    job.M.pid
                    (now -. job.M.query_time)
                    time (maybe_str job.M.info))
               current
           in
           Lwt.return (msg_current @ msg_waiting)
       end)

let plugin ?(port=default_port) () : C.Plugin.t =
  C.Plugin.stateful ~name:"frogirc"
    ~to_json:(fun _ -> None)
    ~of_json:(fun actions _ -> connect port)
    ~commands:(fun st -> [ cmd_status st; cmd_froglock st; ])
    ()
