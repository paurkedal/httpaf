open Core
open Async

open Httpaf
open Httpaf_async

let response_handler finished response response_body =
  match response with
  | { Response.status = `OK; _ } ->
    let rec on_read bs ~off ~len =
      Bigstring.to_string ~off ~len bs |> Core.Printf.printf "%s";
      Body.schedule_read response_body ~on_read ~on_eof
    and on_eof () = Ivar.fill finished () in
    Body.schedule_read response_body ~on_read ~on_eof;
;;

let error_handler _ = assert false

let main port address () =
  let where_to_connect = Tcp.to_host_and_port address port in
  let finished = Ivar.create () in
  Tcp.connect_sock where_to_connect
  >>= fun socket ->
    let headers =
      Headers.of_list
      [ "transfer-encoding", "chunked"
      ; "connection"       , "close" ]
    in
    let request_body =
      Client.request
        ~error_handler
        ~response_handler:(response_handler finished)
        socket
        (Request.create ~headers `POST "/")
    in
    let stdin = Lazy.force Reader.stdin in
    don't_wait_for (
      Reader.read_one_chunk_at_a_time stdin ~handle_chunk:(fun bs ~pos:off ~len ->
        Body.write_bigstring request_body bs ~off ~len;
        Body.flush request_body (fun () -> ());
        return (`Consumed(len, `Need_unknown)))
      >>| function
        | `Eof_with_unconsumed_data s -> Body.write_string request_body s; Body.close request_body
        | `Eof                        -> Body.close request_body
        | `Stopped ()                 -> assert false);
    Ivar.read finished
;;

let () =
  Command.async
    ~summary:"Start a hello world Async server"
    Command.Spec.(empty +>
      flag "-p" (optional_with_default 80 int)
        ~doc:"int destination port"
      +>
      flag "-a" (required string)
        ~doc:"string destination ip"
    ) main
  |> Command.run
