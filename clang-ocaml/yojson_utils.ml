(*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

module U = Utils
module P = Process

let ydump ?(compact_json=false) ?(std_json=false) ic oc =
  let cmd = "ydump" ^ (if compact_json then " -c" else "") ^ (if std_json then " -std" else "")
  in
  P.exec [| cmd |] ic oc stderr

let read_data_from_file reader fname =
  let input_gunzipped read_data ic =
    let pid, icz = P.fork (P.gunzip ic) in
    let data = read_data icz in
    let r = P.wait pid in
    P.close_in icz;
    if not r then failwith "read_data_from_file (gunzip)" else ();
    data
  in
  let ic = open_in fname in
  let data =
    if U.string_ends_with fname ".value.gz" then
      input_gunzipped Marshal.from_channel ic
    else if U.string_ends_with fname ".gz" then
      input_gunzipped (Ag_util.Json.from_channel ~fname reader) ic
    else if U.string_ends_with fname ".value" then
      Marshal.from_channel ic
    else
      Ag_util.Json.from_channel ~fname reader ic
  in
  close_in ic;
  data

let write_data_to_file ?(pretty=false) ?(compact_json=false) ?(std_json=false) writer fname data =
  let output_gzipped write_data oc data =
    let pid, icz = P.fork (fun ocz -> write_data ocz data; true) in
    let r1 = P.gzip icz oc
    and r2 = P.wait pid
    in
    P.close_in icz;
    if not (r1 && r2) then failwith "write_data_from_file (gzip)" else ()
  and output_pretty write_data oc data =
    (* TODO(mathieubaudet): find out how to write directly pretty json? *)
    let pid, icp = P.fork (fun ocp -> write_data ocp data; true) in
    let r1 = ydump ~compact_json ~std_json icp oc
    and r2 = P.wait pid
    in
    P.close_in icp;
    if not (r1 && r2) then failwith "write_data_from_file (pretty)" else ();
  in
  let write_json ocx data =
    if pretty then
      output_pretty (Ag_util.Json.to_channel writer) ocx data
    else
      Ag_util.Json.to_channel writer ocx data
  in
  let oc = open_out fname
  in
  if U.string_ends_with fname ".value.gz" then
    output_gzipped (fun oc data -> Marshal.to_channel oc data []) oc data
  else if U.string_ends_with fname ".value" then
    Marshal.to_channel oc data []
  else if U.string_ends_with fname ".gz" then
    output_gzipped write_json oc data
  else
    write_json oc data;
  close_out oc

let convert ?(pretty=false) ?(compact_json=false) ?(std_json=false) reader writer fin fout =
  try
    read_data_from_file reader fin
    |> write_data_to_file writer ~pretty ~compact_json ~std_json fout
  with
  | Yojson.Json_error s
  | Ag_oj_run.Error s ->
    begin
      prerr_string s;
      prerr_newline ();
      exit 1
    end

let make_converter reader writer argv =
  let len = Array.length argv
  in
  let i, pretty =
    if len > 1 && argv.(1) = "--pretty"
    then 2, true
    else 1, false
  in
  let process = convert ~pretty reader writer
  in 
  if i + 1 < len then
    process argv.(i) argv.(i+1)
  else if i < len then
    process argv.(i) (argv.(i) ^ ".value.gz")
  else begin
    Printf.fprintf stderr "Usage: %s [--pretty] INPUT_FILE [OUTPUT_FILE]\n" argv.(0);
    Printf.fprintf stderr "Parse yojson values and convert them to another format based on the extension of the output file (default: ${INPUT_FILE}.value.gz).\n";
    exit 1
  end