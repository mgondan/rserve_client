/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (c)  2016, VU University Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(r_swish,
	  [ (<-)/2,			% ?Var, +Expression
	    (<-)/1,			% +Expression
					% Internal predicates
	    r/4,			% Quasi quotation parser
	    r_execute/3,		% +Assignments, +Command, -Result
	    r_setup_graphics/2,		% +Rconn, +Format

	    op(900,  fx, <-),
	    op(900, xfx, <-),
	    op(400, yfx, $),
	    op(100, yf,  [])
	  ]).
:- use_module(rserve).
:- use_module(r_grammar).
:- use_module(r_term).
:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(debug)).
:- use_module(library(pengines)).
:- use_module(library(http/html_write)).
:- use_module(library(http/js_write)).
:- use_module(library(quasi_quotations)).
:- use_module(library(dcg/basics)).
:- use_module(library(settings)).

:- multifile
	r_init_session/1.		% +Session


/** <module> R plugin for SWISH

This    module    make    R    available     to    SWISH    using    the
[Rserve](https://rforge.net/Rserve/) R package. The   module  r_serve.pl
implements a SWI-Prolog wrapper around the  Rserve C++ client to realise
the communication with the R server.

The      Prolog      view      at      R        is      inspired      by
[real](http://stoics.org.uk/~nicos/sware/real/) from Nicos Angelopoulos.

It consists of the following two predicates:

  - Var <- Expression
  Assign the result of evaluating the given R Expression to Var.  Var
  can be a Prolog variable or an R expression.
  - <- Expression
  Evaluate expression, discarding the result.  Possible console output
  is captured.

In addition, the _quasi quotation_ `r`   is defined. The quasi quotation
takes Prolog variables as arguments  and   an  R  expression as content.
Arguments (Prolog variable names) that  match   R  identifiers cause the
temporary of an R variable with that name bound to the translated Prolog
value. R quasi quotations can be used as   isolated goals, as well as as
right-hand arguments to <-/2 and <-/1.  The   example  below calls the R
plot() function on the given Prolog list.

  ```
  ?- numlist(1,10,Data),
     {|r(Data)||plot(Data)|}.
  ```

Images created by the R session are transferred   as SVG and sent to the
SWISH console using pengine_output/1.
*/

:- setting(rserve:socket, atom, '/home/rserve/socket',
	   "Unix domain socket for connecting to Rserve").
:- setting(rserve:host,	atom, localhost,
	   "Host for connecting to Rserve").
:- setting(rserve:port,	integer, 6311,
	   "Port for connecting to Rserve").

%%	(Var <- Expression) is det.
%
%	Assign the result of evaluating the   given R Expression to Var.
%	Var can be a Prolog variable or an R expression.

Var <- Expression :-
	var(Var), !,
	(   var(Expression)
	->  instantiation_error(Expression)
	;   Expression = r_execute(Assignments, Command, Var)
	->  r_execute(Assignments, Command, Var)
	;   phrase(r_expression(Expression, Assignments), Command)
	->  r_execute(Assignments, Command, Var)
	;   domain_error(r_expression, Expression)
	).
Var <- Expression :-
	(   atom(Var),
	    r_primitive_data(Expression)
	->  r_assign($, Var, Expression)
	;   <-(Var<-Expression)
	).

r_primitive_data(Data) :-
	is_list(Data), !.
r_primitive_data(Data) :-
	compound(Data), !, fail.

%%	(<- Expression) is det.
%
%	Evaluate Expression, discarding  the   result.  Possible console
%	output is captured using the R function `capture.output`.

<- Term :-
	(   var(Term)
	->  instantiation_error(Term)
	;   Term = r_execute(Assignments, Command, _Var)
	->  format(string(Capture), "capture.output(~s)", [Command]),
	    r_execute(Assignments, Capture, Output),
	    emit_r_output(Output)
	;   phrase(r_expression(capture.output(Term), Assignments), Command)
	->  r_execute(Assignments, Command, Output),
	    emit_r_output(Output)
	;   domain_error(r_expression, Term)
	).

emit_r_output([]) :- !.
emit_r_output(List) :-
	atomics_to_string(List, "\n", String),
	writeln(String).

%%	r_execute(+Assignments, +Command, -Result) is det.
%
%	Execute the R command Command  after   binding  the variables in
%	Assignments and unify the result with Result.
%
%	@arg Assignments is a list of Name=Value, where Name must be a
%	valid R indentifier.
%	@arg Command is a string holding the R command to execute

r_execute(Assignments, Command, Result) :-
	setup_call_cleanup(
	    maplist(r_bind, Assignments),
	    r_eval_ex($, Command, Result),
	    r_unbind(Assignments)),
	r_send_images.

r_bind(RVar=Value) :-
	r_assign($, RVar, Value).

%%	r_unbind(+Bindings)
%
%	Remove the created bindings from the R environment

r_unbind([]) :- !.
r_unbind(Bindings) :-
	maplist(arg(1), Bindings, Vars),
	phrase(r_remove(Vars), Command),
	r_eval($, Command, _).

r_remove(Vars) -->
	"remove(", r_vars(Vars), ")".

r_vars([H|T]) -->
	atom(H),
	(   {T==[]}
	->  ""
	;   ",",
	    r_vars(T)
	).


		 /*******************************
		 *	  QUASI QUOTATION	*
		 *******************************/

:- quasi_quotation_syntax(r).

%%	r(+Content, +Vars, +VarDict, -Goal) is det.
%
%	Parse {|r(Arg,...||R-code|} into a the   expression  below. This
%	expression may be passed to  <-/2  and   <-/1  as  well  as used
%	directly as a goal, calling r_execute/3.
%
%	    r_execute(Assignments, Command, Result)
%
%	@see https://cran.r-project.org/doc/manuals/r-release/R-lang.html#Parser
%	@tbd Verify more of the R syntax.

r(Content, Vars, Dict, r_execute(Assignments, Command, _Result)) :-
	include(qq_var(Vars), Dict, QQDict),
	phrase_from_quasi_quotation(
	    r(QQDict, Assignments, Parts),
	    Content),
	atomics_to_string(Parts, Command).

qq_var(Vars, _=Var) :-
	member(V, Vars),
	V == Var, !.

r(Dict, Assignments, [Pre|More]) -->
	here(Here0),
	r_tokens(_),
	r_token(identifier(Name)),
	here(Here1),
	{ memberchk(Name=Var, Dict), !,
	  Assignments = [Name=Var|AT],
	  diff_to_atom(Here0, Here1, Pre)
	},
	r(Dict, AT, More).
r(_, [], [Last]) -->
	string(Codes),
	\+ [_], !,
	{ atom_codes(Last, Codes) }.


%%	diff_to_atom(+Start, +End, -Atom)
%
%	True when Atom is an atom that represents the characters between
%	Start and End, where End must be in the tail of the list Start.

diff_to_atom(Start, End, Atom) :-
	diff_list(Start, End, List),
	atom_codes(Atom, List).

diff_list(Start, End, List) :-
	Start == End, !,
	List = [].
diff_list([H|Start], End, [H|List]) :-
	diff_list(Start, End, List).

here(Here, Here, Here).


		 /*******************************
		 *	       IMAGES		*
		 *******************************/

:- multifile rserve:r_open_hook/2.

%%	rserve:r_open_hook(+Name, -R)
%
%	Called for lazy creation to the   Rserve server. Connections are
%	per-thread. The destination depends on settings:
%
%	  $ Unix domain socket :
%	  If `rserve:socket` is defined and not empty, it is taken
%	  as the path to a Unix domain socket to connect to.
%	  $ TCP/IP socket :
%	  Else, if `rserve:port` and `rserve:host` is defined, we
%	  connect to the indicated host and port.
%
%	After  the  connection  is  established,   the  session  can  be
%	configured using the hook r_init_session/1.   The  default calls
%	r_setup_graphics/2 to setup graphics output to send SVG files.

rserve:r_open_hook($, R) :-
	nb_current('R', R), !.
rserve:r_open_hook($, R) :-
	setting(rserve:socket, Socket),
	Socket \== '',
	access_file(Socket, exist), !,
	debug(r(connect), 'Connecting to ~p ...', [Socket]),
	r_open(R,
	       [ host(Socket),
		 port(-1)
	       ]),
	r_setup(R).
rserve:r_open_hook($, R) :-
	setting(rserve:port, Port),
	setting(rserve:host, Host),
	debug(r(connect), 'Connecting to ~p ...', [Host:Port]),
	r_open(R,
	       [ host(Host),
		 port(Port)
	       ]),
	r_setup(R).

r_setup(R) :-
	thread_at_exit(r_close(R)),
	debug(r, 'Created ~p', [R]),
	call_init_session(R),
	nb_setval('R', R), !.

call_init_session(R) :-
	r_init_session(R), !.
call_init_session(R) :-
	r_setup_graphics(R, svg).

%%	r_init_session(+RConn) is semidet.
%
%	Multifile hook that is called after the Rserve server has handed
%	us a new connection. If this   hook fails, r_setup_graphics/2 is
%	called to setup capturing graphics as SVG files.

%%	r_setup_graphics(+Rconn, +Format) is det.
%
%	Setup graphics output  using  files.   Currently  only  supports
%	`Format = svg`.

r_setup_graphics(R, svg) :-
	r_eval(R, "mysvg <- function() {
                     svg(\"Rplot%03d.svg\")
		     par(mar=c(4,4,1,1))
                   }
	           options(device=mysvg)", X),
	debug(r, 'Devices: ~p', [X]),
	nb_setval('Rimage_base', 'Rplot'),
	nb_setval('Rimage_ext', 'svg').

%%	r_send_images is det.
%
%	Collect the images saved on the server and send them to SWISH
%	using pengine_output/1.

r_send_images :-
	svg_files(Images), !,
	length(Images, Count),
	debug(r, 'Got ~d images~n', [Count]),
	svg_html(Images, HTMlString),
	pengine_output(HTMlString).
r_send_images.

svg_files(List) :-
	nb_current('R', _),
	(   r_eval($, "dev.cur()", [L]),
	    L > 1
	->  (   repeat,
		r_eval($, "dev.off()", [1])
	    ->  true
	    ),
	    fetch_images(1, List)
	).

fetch_images(I, Files) :-
	nb_getval('Rimage_base', Base),
	nb_getval('Rimage_ext', Ext),
	format(string(Name), "~w~|~`0t~d~3+.~w", [Base,I,Ext]),
	debug(r, 'Trying ~p~n', [Name]),
	(   catch(r_read_file($, Name, File), E, r_error_fail(E))
	->  debug(r, 'Got ~p~n', [Name]),
	    Files = [File|Rest],
	    (   debugging(r(plot))
	    ->  save_plot(Name, File)
	    ;	true
	    ),
	    I2 is I+1,
	    fetch_images(I2, Rest)
	;   Files = []
	).

r_error_fail(error(r_error(70),_)) :- !, fail.
r_error_fail(Error) :- print_message(warning, Error), fail.

save_plot(File, Data) :-
	setup_call_cleanup(
	    open(File, write, Out, [encoding(utf8)]),
	    format(Out, '~s', [Data]),
	    close(Out)).

%%	svg_html(+Images, -HTMlString) is det.
%
%	Turn a list of SVG images into an HTML string.

svg_html(Images, HTMlString) :-
	phrase(svg_html(Images), Tokens),
	with_output_to(string(HTMlString), print_html(Tokens)).

svg_html(Images) -->
	html(div(class('Rplots'), \rplots(Images))).

rplots([]) --> [].
rplots([H|T]) -->
	html(div(class(['reactive-size', 'R', svg]), \svg(H, []))),
	rplots(T).


svg(SVG, _Options) -->
	html(\[SVG]),
	pan_zoom,
	"".

pan_zoom -->
	html(\js_script({|javascript||
var svg  = node.node().find("svg");
//svg.removeAttr("width height");		// trying to remove white space
//svg.find("rect").first().remove();	// trying to remove white space
var data = { w0: svg.width(),
	     h0: svg.height()
	   };
var pan;

function updateSize() {
  var w = svg.closest("div.Rplots").innerWidth();
  console.log(w);

  function reactive() {
    if ( !data.reactive ) {
      var div = svg.closest("div.reactive-size");
      data.reactive = true;
      div.on("reactive-resize", updateSize);
    }
  }

  w = Math.max(w*0.95, 100);
  if ( w < data.w0 ) {
    svg.width(w);
    svg.height(w = Math.max(w*data.h0/data.w0, w/4));
    reactive();
    if ( pan ) {
      pan.resize();
      pan.fit();
      pan.center();
    }
  }
}

require(["svg-pan-zoom"], function(svgPanZoom) {
  updateSize()
  pan = svgPanZoom(svg[0], {
    maxZoom: 50
  });
});
		      |})).


