
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(** {1 HTML Interface} *)

open Result
open Frog

module E = Misc.Err

type 'a or_error = 'a Misc.Err.t

type html = Html.t
type uri = Uri.t
type json = Yojson.Safe.json

(** {2 Serve}

    A small webserver that displays results as they are built, computes
    regressions between results, etc. *)
module Server = struct
  module H = Html
  open Opium.Std

  type t = {
    storage: Storage.t;
    mutable port: int;
    mutable app : App.t;
  }

  let create ?(port=8000) ~storage () =
    { storage; port; app=App.empty; }

  let storage t = t.storage

  let set_port t p = t.port <- p

  let meta_ = H.meta ~a:[H.a_charset "UTF-8"] ()

  let css_ = "
    body {
      width: 80%;
      margin-left : auto;
      margin-right: auto;
      background-color: #fafafa;
    }

    h1 { font-size: larger; }
    h2 { font-size: large; }

    div {
      padding: 5px;
    }

    pre.raw {
      margin: 0px;
      padding: 5px;
      background-color: lightgrey;
    }

    table {
      border: 1px solid black;
      border-collapse: collapse;
    }

    tr:hover {
      background-color: #f2f2f2;
    }

    td: nth-of-type(even) {
      background-color: #f2f2f2;
    }

    tr {
      border: 1px solid lightgrey;
    }

    td:nth-of-type(1) {
      border: 1ps solid lightgrey;
    }

    th, td {
      padding: 10px 20px;
      text-align: left;
      vertical-align: center;
    }
    "

  (* TODO: css *)
  let return_html ?title ?code (h:html) =
    let wrap_ ?(title="frog-utils") h =
      let hd =
        H.head
          (H.title (H.pcdata title))
          [ meta_;
            H.script ~a:[H.a_src "/js/frogwebclient.js"] (H.pcdata "");
            H.style [H.cdata_style css_];
          ]
      in
      H.html hd (H.body [H.div ~a:[H.a_id "main"] [h]])
      |> H.to_string
    in
    let h = wrap_ ?title h in
    App.respond' ?code (`Html h)

  let return_string ?code (s:string) = App.respond' ?code (`String s)

  let return_json ?code (j:json) = return_string ?code (Yojson.Safe.to_string j)

  let return_404 msg =
    let code = Cohttp.Code.status_of_code 404 in
    let h = Html.pcdata msg in
    return_html ~code h

  (* toplevel handler *)
  let main t _req = return_html (H.pcdata "")

  (* list all the snapshots *)
  let list_snapshots t _req =
    let%lwt l = Storage.find_files t.storage in
    let j = [%to_yojson: string list] l in
    return_json j

  let serve_snapshot t req =
    let uuid = param req "uuid" in
    let%lwt res =
      let open Misc.LwtErr in
      Storage.find_json t.storage uuid >>?=
      Event.Snapshot.of_yojson
    in
    match res with
      | Error msg ->
        return_404 ("could not find uuid " ^ uuid ^ " : " ^ msg)
      | Ok snap ->
        let l = snap.Event.events in
        let j = [%to_yojson: Event.t list] l in
        return_json j

  (* lookup problems by their path
     NOTE: could be a security issue if open to the net! *)
  let serve_problem t req =
    let uri = Request.uri req in
    match Uri.get_query_param uri "file" with
      | None -> return_404 "missing `file` parameter"
      | Some name ->
        if Sys.file_exists name
        then (
          (* read the problem itself *)
          Lwt_io.with_file ~mode:Lwt_io.input name
            Misc.File.read_all
          >>= fun content ->
          return_string content
        ) else
          return_404 (Printf.sprintf "could not find file `%s`" name)

  (* loop that serves the website *)
  let run t =
    Lwt_io.printlf "serve website on http://localhost:%d" t.port >>= fun () ->
    t.app
    |> App.middleware
      (Middleware.static ~local_path:"js" ~uri_prefix:"/js/")
    |> App.get "/" (main t) (* main page *)
    |> App.get "/snapshots/" (list_snapshots t)
    |> App.get "/snapshot/:uuid" (serve_snapshot t)
    |> App.get "/problem/" (serve_problem t)
    |> App.port t.port
    |> App.start
end