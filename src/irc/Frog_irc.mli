
(* This file is free software, part of frog-utils. See file "license" for more details. *)

(** {1 IRC bot plugin} *)

val plugin : ?port:int -> unit -> Calculon.Plugin.t
