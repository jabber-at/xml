%%%----------------------------------------------------------------------
%%% File    : xml_stream.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Parse XML streams
%%% Created : 17 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% p1_xml, Copyright (C) 2002-2015   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(xml_stream).

-author('alexey@process-one.net').

-behaviour(gen_server).

-export([new/1, new/2, parse/2, close/1,
	 change_callback_pid/2, parse_element/1]).

%% Internal exports, call-back functions.
-export([start_link/0, init/1, handle_call/3, handle_cast/2,
	 handle_info/2, code_change/3, terminate/2]).

-define(XML_START, 0).

-define(XML_END, 1).

-define(XML_CDATA, 2).

-define(XML_ERROR, 3).

-define(PARSE_COMMAND, 0).

-define(PARSE_FINAL_COMMAND, 1).

-include("xml.hrl").

-record(xml_stream_state,
	{callback_pid = self() :: pid(),
         port                  :: port(),
         stack = []            :: stack(),
         size = 0              :: non_neg_integer(),
         maxsize = infinity    :: non_neg_integer() | infinity}).

-type xml_stream_el() :: {xmlstreamraw, binary()} |
                         {xmlstreamcdata, binary()} |
                         {xmlstreamelement, xmlel()} |
                         {xmlstreamend, binary()} |
                         {xmlstreamstart, binary(), [attr()]} |
                         {xmlstreamerror, binary()}.

-type xml_stream_state() :: #xml_stream_state{}.
-type stack() :: [xmlel()].
-type event() :: {?XML_START, {binary(), [attr()]}} |
                 {?XML_END, binary()} |
                 {?XML_CDATA, binary()} |
                 {?XML_ERROR, binary()}.

-export_type([xml_stream_state/0, xml_stream_el/0]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],
			  []).

init([]) ->
    case load_driver() of
        ok ->
            {ok, []};
        {error, Why} ->
            {stop, Why}
    end.

%%% --------------------------------------------------------
%%% The call-back functions.
%%% --------------------------------------------------------

handle_call(_, _, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'EXIT', Port, Reason}, Port) ->
    {stop, {port_died, Reason}, Port};
handle_info({'EXIT', _Pid, _Reason}, Port) ->
    {noreply, Port};
handle_info(_, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

terminate(_Reason, _State) ->
    ok.

process_data(CallbackPid, Stack, Data) ->
    case Data of
      {?XML_START, {Name, Attrs}} ->
	  if
		Stack == [] ->
		    catch gen_fsm:send_event(CallbackPid,
					  {xmlstreamstart, Name, Attrs}),
		    %% There is no need to store name or attributes of
		    %% stream opening element as it is not used
		    %% anymore.
		    [xmlstreamstart];
		true ->
		    [#xmlel{name = Name, attrs = Attrs, children = []}
			| Stack]
	  end;
      {?XML_END, EndName} ->
	  case Stack of
	    [xmlstreamstart] ->
		    catch gen_fsm:send_event(CallbackPid,
					     {xmlstreamend, EndName}),
		    [];
	    [#xmlel{name = Name, attrs = Attrs, children = Els},
	     xmlstreamstart] ->
		NewEl = #xmlel{name = Name, attrs = Attrs,
			       children = lists:reverse(Els)},
		catch gen_fsm:send_event(CallbackPid,
			    {xmlstreamelement, NewEl}),
		[xmlstreamstart];
	    [#xmlel{name = Name, attrs = Attrs, children = Els},
	     #xmlel{name = Name1, attrs = Attrs1, children = Els1}
	     | Tail] ->
		NewEl = #xmlel{name = Name, attrs = Attrs,
			       children = lists:reverse(Els)},
		[{xmlel, Name1, Attrs1, [NewEl | Els1]} | Tail]
	  end;
      {?XML_CDATA, CData} ->
	  case Stack of
	    [xmlstreamstart] ->
		catch gen_fsm:send_all_state_event(CallbackPid,
						   {xmlstreamcdata, CData}),
		[xmlstreamstart];
	    %% Merge CDATA nodes if they are contiguous
	    %% This does not change the semantic: the split in
	    %% several CDATA nodes depends on the TCP/IP packet
	    %% fragmentation
	    [#xmlel{name = Name, attrs = Attrs,
		    children = [{xmlcdata, PreviousCData} | Els]}
	     | Tail] ->
		[#xmlel{name = Name, attrs = Attrs,
			children =
			    [{xmlcdata,
			      iolist_to_binary([PreviousCData, CData])}
			     | Els]}
		 | Tail];
	    %% No previous CDATA
	    [#xmlel{name = Name, attrs = Attrs, children = Els}
	     | Tail] ->
		[#xmlel{name = Name, attrs = Attrs,
			children = [{xmlcdata, CData} | Els]}
		 | Tail];
	    [] -> []
	  end;
      {?XML_ERROR, Err} ->
	  catch gen_fsm:send_event(CallbackPid,
				   {xmlstreamerror, Err})
    end.

-spec new(pid()) -> xml_stream_state().

new(CallbackPid) -> new(CallbackPid, infinity).

-spec new(pid(), non_neg_integer() | infinity) -> xml_stream_state().

new(CallbackPid, MaxSize) ->
    Port = open_port({spawn, "expat_erl"}, [binary]),
    #xml_stream_state{callback_pid = CallbackPid,
		      port = Port, stack = [], size = 0, maxsize = MaxSize}.

-spec change_callback_pid(xml_stream_state(), pid()) -> xml_stream_state().

change_callback_pid(State, CallbackPid) ->
    State#xml_stream_state{callback_pid = CallbackPid}.

-spec parse(xml_stream_state(), iodata()) -> xml_stream_state().

parse(#xml_stream_state{callback_pid = CallbackPid,
			port = Port, stack = Stack, size = Size,
			maxsize = MaxSize} =
	  State,
      Str) ->
    StrSize = byte_size(Str),
    Res = port_control(Port, ?PARSE_COMMAND, Str),
    {NewStack, NewSize} = lists:foldl(fun (Data,
					   {St, Sz}) ->
					      NewSt = process_data(CallbackPid,
								   St, Data),
					      case NewSt of
						[_] -> {NewSt, 0};
						_ -> {NewSt, Sz}
					      end
				      end,
				      {Stack, Size + StrSize},
				      binary_to_term(Res)),
    if NewSize > MaxSize ->
	   catch gen_fsm:send_event(CallbackPid,
				    {xmlstreamerror,
				     <<"XML stanza is too big">>});
       true -> ok
    end,
    State#xml_stream_state{stack = NewStack,
			   size = NewSize}.

-spec close(xml_stream_state()) -> true.

close(#xml_stream_state{port = Port}) ->
    port_close(Port).

-spec parse_element(iodata()) -> xmlel() |
                                 {error, parse_error} |
                                 {error, binary()}.

parse_element(Str) ->
    Port = open_port({spawn, "expat_erl"}, [binary]),
    Res = port_control(Port, ?PARSE_FINAL_COMMAND, Str),
    port_close(Port),
    process_element_events(binary_to_term(Res)).

process_element_events(Events) ->
    process_element_events(Events, []).

-spec process_element_events([event()], stack()) -> xmlel() |
                                                    {error, parse_error} |
                                                    {error, binary()}.

process_element_events([], _Stack) ->
    {error, parse_error};
process_element_events([Event | Events], Stack) ->
    case Event of
      {?XML_START, {Name, Attrs}} ->
	  process_element_events(Events,
				 [#xmlel{name = Name, attrs = Attrs,
					 children = []}
				  | Stack]);
      {?XML_END, _EndName} ->
	  case Stack of
	    [#xmlel{name = Name, attrs = Attrs, children = Els}
	     | Tail] ->
		NewEl = #xmlel{name = Name, attrs = Attrs,
			       children = lists:reverse(Els)},
		case Tail of
		  [] ->
		      if Events == [] -> NewEl;
			 true -> {error, parse_error}
		      end;
		  [#xmlel{name = Name1, attrs = Attrs1, children = Els1}
		   | Tail1] ->
		      process_element_events(Events,
					     [#xmlel{name = Name1,
						     attrs = Attrs1,
						     children = [NewEl | Els1]}
					      | Tail1])
		end
	  end;
      {?XML_CDATA, CData} ->
	  case Stack of
	    [#xmlel{name = Name, attrs = Attrs, children = Els}
	     | Tail] ->
		process_element_events(Events,
				       [#xmlel{name = Name, attrs = Attrs,
					       children =
						   [{xmlcdata, CData} | Els]}
					| Tail]);
	    [] -> process_element_events(Events, [])
	  end;
      {?XML_ERROR, Err} -> {error, Err}
    end.

get_so_path() ->
    EbinDir = filename:dirname(code:which(?MODULE)),
    AppDir = filename:dirname(EbinDir),
    filename:join([AppDir, "priv", "lib"]).

load_driver() ->
    case erl_ddll:load_driver(get_so_path(), expat_erl) of
        ok ->
            ok;
        {error, already_loaded} ->
            ok;
        {error, ErrorDesc} = Err ->
            error_logger:error_msg("failed to load Expat driver: ~s~n",
                                   [erl_ddll:format_error(ErrorDesc)]),
            Err
    end.
