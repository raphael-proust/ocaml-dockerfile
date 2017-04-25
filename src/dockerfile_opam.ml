(*
 * Copyright (c) 2015 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

(** OPAM-specific Dockerfile rules *)

open Dockerfile
open Printf
module Linux = Dockerfile_linux

(** Rules to get the cloud solver if no aspcud available *)
let install_cloud_solver =
  run "curl -o /usr/bin/aspcud 'https://raw.githubusercontent.com/avsm/opam-solver-proxy/38133c7f82bae3f1aa9f7505901f26d9fb0ed1ee/aspcud.docker'" @@
  run "chmod 755 /usr/bin/aspcud"

(** RPM rules *)
module RPM = struct

  let install_system_opam = function
  | `CentOS7 -> Linux.RPM.install "opam aspcud"
  | `CentOS6 -> Linux.RPM.install "opam" @@ install_cloud_solver

end

(** Debian rules *)
module Apt = struct

  let install_system_opam =
    Linux.Apt.install "opam aspcud"
end

let run_as_opam fmt = Linux.run_as_user "opam" fmt
let opamhome = "/home/opam"

let opam_init
  ?(branch="master")
  ?(repo="git://github.com/ocaml/opam-repository")
  ?(need_upgrade=false)
  ?compiler_version () =
    let is_mainline = function (* FIXME only covers the compilers we use *)
      |"4.04.1"|"4.04.0"|"4.03.0"|"4.02.3"|"4.01.0"|"4.00.1" -> true
      |_ -> false in
    let compiler =
      match compiler_version, need_upgrade with
      | None, _ -> ""
      | Some v, false -> "--comp " ^ v ^ " "
      | Some v, true when is_mainline v -> "--comp ocaml-base-compiler." ^ v ^ " "
      | Some v, true -> "--comp ocaml-variants." ^ v ^ " "
    in
    let master_cmds = match need_upgrade with
      | true -> run_as_opam "cd %s/opam-repository && opam admin upgrade && git checkout -b v2 && git add . && git commit -a -m 'opam admin upgrade'" opamhome
      | false -> empty in
    run_as_opam "git clone -b %s %s" branch repo @@
    master_cmds @@
    run_as_opam "opam init -a -y %s%s/opam-repository" compiler opamhome

let install_opam_from_source ?prefix ?(install_wrappers=false) ?(branch="1.2") () =
  run "git clone -b %s git://github.com/ocaml/opam /tmp/opam" branch @@
  let wrappers_dir = match prefix with
  | None -> "/usr/local/share/opam"
  | Some p -> Filename.concat p "share/opam"
  in
  let inst name =
    Printf.sprintf "cp shell/wrap-%s.sh %s && echo 'wrap-%s-commands: \"%s/wrap-%s.sh\"' >> /etc/opamrc.userns" 
      name wrappers_dir name wrappers_dir name in
  let wrapper_cmd =
    match install_wrappers with
    | false -> "echo Not installing OPAM2 wrappers"
    | true -> Fmt.strf "mkdir -p %s && %s" wrappers_dir (String.concat " && " [inst "build"; inst "install"; inst "remove"])
  in
  Linux.run_sh
    "cd /tmp/opam && make cold && make%s install && %s && rm -rf /tmp/opam"
    (match prefix with None -> "" |Some p -> " prefix=\""^p^"\"")
    wrapper_cmd

let header ?maintainer img tag =
  let maintainer = match maintainer with None -> empty | Some t -> Dockerfile.maintainer "%s" t in
  comment "Autogenerated by OCaml-Dockerfile scripts" @@
  from ~tag img @@
  maintainer

let run_command fmt =
  ksprintf (fun cmd -> 
    eprintf "Exec: %s\n%!" cmd;
    match Sys.command cmd with
    | 0 -> ()
    | _ -> raise (Failure cmd)
  ) fmt

let write_to_file file dfile =
  eprintf "Open: %s\n%!" file;
  let fout = open_out file in
  output_string fout (string_of_t dfile);
  close_out fout

let generate_dockerfiles d output_dir =
  List.iter (fun (name, docker) ->
    printf "Generating: %s/%s/Dockerfile\n" output_dir name;
    run_command "mkdir -p %s/%s" output_dir name;
    write_to_file (output_dir ^ "/" ^ name ^ "/Dockerfile") docker
  ) d

let generate_dockerfiles_in_git_branches d output_dir =
  List.iter (fun (name, docker) ->
    printf "Switching to branch %s in %s\n" name output_dir;
    run_command "git -C \"%s\" checkout -q -B %s master" output_dir name;
    let file = output_dir ^ "/Dockerfile" in
    write_to_file file docker;
    run_command "git -C \"%s\" add Dockerfile" output_dir;
    run_command "git -C \"%s\" commit -q -m \"update %s Dockerfile\" -a" output_dir name
  ) d;
  run_command "git -C \"%s\" checkout -q master" output_dir
