%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2013. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
%% Implements the handling of incoming and outgoing Diameter messages
%% except CER/CEA, DWR/DWA and DPR/DPA. That is, the messages that a
%% diameter client sends of receives.
%%

-module(diameter_traffic).

%% towards diameter
-export([send_request/4]).

%% towards diameter_watchdog
-export([receive_message/4]).

%% towards diameter_service
-export([make_recvdata/1,
         peer_up/1,
         peer_down/1,
         failover/1,
         pending/1]).

%% Other callbacks.
-export([send/1]).  %% send from remote node

-include_lib("diameter/include/diameter.hrl").
-include("diameter_internal.hrl").

-define(RELAY, ?DIAMETER_DICT_RELAY).
-define(BASE,  ?DIAMETER_DICT_COMMON).  %% Note: the RFC 3588 dictionary

-define(DEFAULT_TIMEOUT, 5000).  %% for outgoing requests

%% Table containing outgoing requests for which a reply has yet to be
%% received.
-define(REQUEST_TABLE, diameter_request).

%% Workaround for dialyzer's lack of understanding of match specs.
-type match(T)
   :: T | '_' | '$1' | '$2' | '$3' | '$4'.

%% Record diameter:call/4 options are parsed into.
-record(options,
        {filter = none  :: diameter:peer_filter(),
         extra = []     :: list(),
         timeout = ?DEFAULT_TIMEOUT :: 0..16#FFFFFFFF,
         detach = false :: boolean()}).

%% Term passed back to receive_message/4 with every incoming message.
-record(recvdata,
        {peerT        :: ets:tid(),
         service_name :: diameter:service_name(),
         apps         :: [#diameter_app{}],
         sequence     :: diameter:sequence()}).

%% Record stored in diameter_request for each outgoing request.
-record(request,
        {ref        :: match(reference()),  %% used to receive answer
         caller     :: match(pid()),        %% calling process
         handler    :: match(pid()),        %% request process
         transport  :: match(pid()),        %% peer process
         caps       :: match(#diameter_caps{}),     %% of connection
         packet     :: match(#diameter_packet{})}). %% of request

%% ---------------------------------------------------------------------------
%% # make_recvdata/1
%% ---------------------------------------------------------------------------

make_recvdata([SvcName, PeerT, Apps, Mask | _]) ->
    #recvdata{service_name = SvcName,
              peerT = PeerT,
              apps = Apps,
              sequence = Mask}.
%% Take a list so that the caller (diameter_service) can be upgraded
%% first if new members are added. Note that receive_message/4 might
%% still get an old term from any watchdog started in old code.

%% ---------------------------------------------------------------------------
%% peer_up/1
%% ---------------------------------------------------------------------------

%% Insert an element that is used to detect whether or not there has
%% been a failover when inserting an outgoing request.
peer_up(TPid) ->
    ets:insert(?REQUEST_TABLE, {TPid}).

%% ---------------------------------------------------------------------------
%% peer_down/1
%% ---------------------------------------------------------------------------

peer_down(TPid) ->
    ets:delete(?REQUEST_TABLE, TPid),
    failover(TPid).

%% ---------------------------------------------------------------------------
%% pending/1
%% ---------------------------------------------------------------------------

pending(TPids) ->
    MatchSpec = [{{'$1',
                   #request{caller = '$2',
                            handler = '$3',
                            transport = '$4',
                            _ = '_'},
                   '_'},
                  [?ORCOND([{'==', T, '$4'} || T <- TPids])],
                  [{{'$1', [{{caller, '$2'}},
                            {{handler, '$3'}},
                            {{transport, '$4'}}]}}]}],

    try
        ets:select(?REQUEST_TABLE, MatchSpec)
    catch
        error: badarg -> []  %% service has gone down
    end.

%% ---------------------------------------------------------------------------
%% # receive_message/4
%%
%% Handle an incoming Diameter message.
%% ---------------------------------------------------------------------------

%% Handle an incoming Diameter message in the watchdog process. This
%% used to come through the service process but this avoids that
%% becoming a bottleneck.

receive_message(TPid, Pkt, Dict0, RecvData)
  when is_pid(TPid) ->
    #diameter_packet{header = #diameter_header{is_request = R}} = Pkt,
    recv(R,
         (not R) andalso lookup_request(Pkt, TPid),
         TPid,
         Pkt,
         Dict0,
         RecvData).

%% Incoming request ...
recv(true, false, TPid, Pkt, Dict0, RecvData) ->
    try
        spawn(fun() -> recv_request(TPid, Pkt, Dict0, RecvData) end)
    catch
        error: system_limit = E ->  %% discard
            ?LOG({error, E}, now())
    end;

%% ... answer to known request ...
recv(false, #request{ref = Ref, handler = Pid} = Req, _, Pkt, Dict0, _) ->
    Pid ! {answer, Ref, Req, Dict0, Pkt};
%% Note that failover could have happened prior to this message being
%% received and triggering failback. That is, both a failover message
%% and answer may be on their way to the handler process. In the worst
%% case the request process gets notification of the failover and
%% sends to the alternate peer before an answer arrives, so it's
%% always the case that we can receive more than one answer after
%% failover. The first answer received by the request process wins,
%% any others are discarded.

%% ... or not.
recv(false, false, _, _, _, _) ->
    ok.

%% ---------------------------------------------------------------------------
%% recv_request/4
%% ---------------------------------------------------------------------------

recv_request(TPid,
             #diameter_packet{header = #diameter_header{application_id = Id}}
             = Pkt,
             Dict0,
             #recvdata{peerT = PeerT, apps = Apps}
             = RecvData) ->
    recv_request(diameter_service:find_incoming_app(PeerT, TPid, Id, Apps),
                 TPid,
                 Pkt,
                 Dict0,
                 RecvData).

%% recv_request/5

recv_request({#diameter_app{id = Id, dictionary = Dict} = App, Caps},
             TPid,
             Pkt,
             Dict0,
             RecvData) ->
    recv_R(App,
           TPid,
           Caps,
           Dict0,
           RecvData,
           diameter_codec:decode(Id, Dict, Pkt));
%% Note that the decode is different depending on whether or not Id is
%% ?APP_ID_RELAY.

%%   DIAMETER_APPLICATION_UNSUPPORTED   3007
%%      A request was sent for an application that is not supported.

recv_request(#diameter_caps{} = Caps, TPid, Pkt, Dict0, _) ->
    As = collect_avps(Pkt),
    protocol_error(3007, TPid, Caps, Dict0, Pkt#diameter_packet{avps = As});

recv_request(false, _, _, _, _) ->  %% transport has gone down
    ok.

collect_avps(Pkt) ->
    case diameter_codec:collect_avps(Pkt) of
        {_Bs, As} ->
            As;
        As ->
            As
    end.

%% recv_R/6

%% Wrong number of bits somewhere in the message: reply.
%%
%%   DIAMETER_INVALID_AVP_BITS          3009
%%      A request was received that included an AVP whose flag bits are
%%      set to an unrecognized value, or that is inconsistent with the
%%      AVP's definition.
%%
recv_R(_App,
       TPid,
       Caps,
       Dict0,
       _RecvData,
       #diameter_packet{errors = [Bs | _]} = Pkt)
  when is_bitstring(Bs) ->
    protocol_error(3009, TPid, Caps, Dict0, Pkt);

%% Either we support this application but don't recognize the command
%% or we're a relay and the command isn't proxiable.
%%
%%   DIAMETER_COMMAND_UNSUPPORTED       3001
%%      The Request contained a Command-Code that the receiver did not
%%      recognize or support.  This MUST be used when a Diameter node
%%      receives an experimental command that it does not understand.
%%
recv_R(#diameter_app{id = Id},
       TPid,
       Caps,
       Dict0,
       _RecvData,
       #diameter_packet{header = #diameter_header{is_proxiable = P},
                        msg = M}
       = Pkt)
  when ?APP_ID_RELAY /= Id, undefined == M;
       ?APP_ID_RELAY == Id, not P ->
    protocol_error(3001, TPid, Caps, Dict0, Pkt);

%% Error bit was set on a request.
%%
%%   DIAMETER_INVALID_HDR_BITS          3008
%%      A request was received whose bits in the Diameter header were
%%      either set to an invalid combination, or to a value that is
%%      inconsistent with the command code's definition.
%%
recv_R(_App,
       TPid,
       Caps,
       Dict0,
       _RecvData,
       #diameter_packet{header = #diameter_header{is_error = true}}
       = Pkt) ->
    protocol_error(3008, TPid, Caps, Dict0, Pkt);

%% A message in a locally supported application or a proxiable message
%% in the relay application. Don't distinguish between the two since
%% each application has its own callback config. That is, the user can
%% easily distinguish between the two cases.
recv_R(App, TPid, Caps, Dict0, RecvData, Pkt) ->
    request_cb(App, TPid, Caps, Dict0, RecvData, examine(Pkt)).

%% Note that there may still be errors but these aren't protocol
%% (3xxx) errors that lead to an answer-message.

request_cb(App,
           TPid,
           Caps,
           Dict0,
           #recvdata{service_name = SvcName}
           = RecvData,
           Pkt) ->
    request_cb(cb(App, handle_request, [Pkt, SvcName, {TPid, Caps}]),
               App,
               TPid,
               Caps,
               Dict0,
               RecvData,
               [],
               Pkt).

%% examine/1
%%
%% Look for errors in a decoded message. It's odd/unfortunate that
%% 501[15] aren't protocol errors.

%%   DIAMETER_INVALID_MESSAGE_LENGTH 5015
%%
%%      This error is returned when a request is received with an invalid
%%      message length.

examine(#diameter_packet{header = #diameter_header{length = Len},
                         bin = Bin,
                         errors = Es}
        = Pkt)
  when Len < 20;
       0 /= Len rem 4;
       8*Len /= bit_size(Bin) ->
    Pkt#diameter_packet{errors = [5015 | Es]};

%%   DIAMETER_UNSUPPORTED_VERSION       5011
%%      This error is returned when a request was received, whose version
%%      number is unsupported.

examine(#diameter_packet{header = #diameter_header{version = V},
                         errors = Es}
        = Pkt)
  when V /= ?DIAMETER_VERSION ->
    Pkt#diameter_packet{errors = [5011 | Es]};

examine(Pkt) ->
    Pkt.

%% request_cb/8

%% A reply may be an answer-message, constructed either here or by
%% the handle_request callback. The header from the incoming request
%% is passed into the encode so that it can retrieve the relevant
%% command code in this case. It will also then ignore Dict and use
%% the base encoder.
request_cb({reply, Ans},
           #diameter_app{dictionary = Dict},
           TPid,
           _Caps,
           Dict0,
           _RecvData,
           Fs,
           Pkt) ->
    reply(Ans, dict(Dict, Dict0, Ans), TPid, Fs, Pkt);

%% An 3xxx result code, for which the E-bit is set in the header.
request_cb({protocol_error, RC},
           _App,
           TPid,
           Caps,
           Dict0,
           _RecvData,
           Fs,
           Pkt)
  when 3000 =< RC, RC < 4000 ->
    protocol_error(RC, TPid, Caps, Dict0, Fs, Pkt);

%% RFC 3588 says we must reply 3001 to anything unrecognized or
%% unsupported. 'noreply' is undocumented (and inappropriately named)
%% backwards compatibility for this, protocol_error the documented
%% alternative.
request_cb(noreply,
           _App,
           TPid,
           Caps,
           Dict0,
           _RecvData,
           Fs,
           Pkt) ->
    protocol_error(3001, TPid, Caps, Dict0, Fs, Pkt);

%% Relay a request to another peer. This is equivalent to doing an
%% explicit call/4 with the message in question except that (1) a loop
%% will be detected by examining Route-Record AVP's, (3) a
%% Route-Record AVP will be added to the outgoing request and (3) the
%% End-to-End Identifier will default to that in the
%% #diameter_header{} without the need for an end_to_end_identifier
%% option.
%%
%% relay and proxy are similar in that they require the same handling
%% with respect to Route-Record and End-to-End identifier. The
%% difference is that a proxy advertises specific applications, while
%% a relay advertises the relay application. If a callback doesn't
%% want to distinguish between the cases in the callback return value
%% then 'resend' is a neutral alternative.
%%
request_cb({A, Opts},
           #diameter_app{id = Id}
           = App,
           TPid,
           Caps,
           Dict0,
           RecvData,
           Fs,
           Pkt)
  when A == relay, Id == ?APP_ID_RELAY;
       A == proxy, Id /= ?APP_ID_RELAY;
       A == resend ->
    resend(Opts, App, TPid, Caps, Dict0, RecvData, Fs, Pkt);

request_cb(discard, _, _, _, _, _, _, _) ->
    ok;

request_cb({eval_packet, RC, F}, App, TPid, Caps, Dict0, RecvData, Fs, Pkt) ->
    request_cb(RC, App, TPid, Caps, Dict0, RecvData, [F|Fs], Pkt);

request_cb({eval, RC, F}, App, TPid, Caps, Dict0, RecvData, Fs, Pkt) ->
    request_cb(RC, App, TPid, Caps, Dict0, RecvData, Fs, Pkt),
    diameter_lib:eval(F).

%% dict/3

%% An incoming answer, not yet decoded.
dict(Dict, Dict0, #diameter_packet{header
                                   = #diameter_header{is_request = false,
                                                      is_error = E},
                                   msg = undefined}) ->
    if E -> Dict0; true -> Dict end;

dict(Dict, Dict0, [Msg]) ->
    dict(Dict, Dict0, Msg);

dict(Dict, Dict0, #diameter_packet{msg = Msg}) ->
    dict(Dict, Dict0, Msg);

dict(_Dict, Dict0, ['answer-message' | _]) ->
    Dict0;

dict(Dict, Dict0, Rec) ->
    try
        'answer-message' = Dict0:rec2msg(element(1,Rec)),
        Dict0
    catch
        error:_ -> Dict
    end.

%% protocol_error/6

protocol_error(RC, TPid, Caps, Dict0, Fs, Pkt) ->
    #diameter_caps{origin_host = {OH,_},
                   origin_realm = {OR,_}}
        = Caps,
    #diameter_packet{avps = Avps, errors = Es}
        = Pkt,

    ?LOG({error, RC}, Pkt),
    reply(answer_message({OH, OR, RC}, Dict0, Avps),
          Dict0,
          TPid,
          Fs,
          Pkt#diameter_packet{errors = [RC | Es]}).
%% Note that reply/5 may set the result code once more. It's set in
%% answer_message/3 in case reply/5 doesn't.

%% protocol_error/5

protocol_error(RC, TPid, Caps, Dict0, Pkt) ->
    protocol_error(RC, TPid, Caps, Dict0, [], Pkt).

%% resend/7
%%
%% Resend a message as a relay or proxy agent.

resend(Opts,
       #diameter_app{}
       = App,
       TPid,
       #diameter_caps{origin_host = {OH,_}}
       = Caps,
       Dict0,
       RecvData,
       Fs,
       #diameter_packet{avps = Avps}
       = Pkt) ->
    {Code, _Flags, Vid} = Dict0:avp_header('Route-Record'),
    resend(is_loop(Code, Vid, OH, Dict0, Avps),
           Opts,
           App,
           TPid,
           Caps,
           Dict0,
           RecvData,
           Fs,
           Pkt).

%%   DIAMETER_LOOP_DETECTED             3005
%%      An agent detected a loop while trying to get the message to the
%%      intended recipient.  The message MAY be sent to an alternate peer,
%%      if one is available, but the peer reporting the error has
%%      identified a configuration problem.

resend(true, _Opts, _App, TPid, Caps, Dict0, _RecvData, Fs, Pkt) ->
    protocol_error(3005, TPid, Caps, Dict0, Fs, Pkt);

%% 6.1.8.  Relaying and Proxying Requests
%%
%%   A relay or proxy agent MUST append a Route-Record AVP to all requests
%%   forwarded.  The AVP contains the identity of the peer the request was
%%   received from.

resend(false,
       Opts,
       App,
       TPid,
       #diameter_caps{origin_host = {_,OH}}
       = Caps,
       Dict0,
       #recvdata{service_name = SvcName,
                 sequence = Mask},
       Fs,
       #diameter_packet{header = Hdr0,
                        avps = Avps}
       = Pkt) ->
    Route = #diameter_avp{data = {Dict0, 'Route-Record', OH}},
    Seq = diameter_session:sequence(Mask),
    Hdr = Hdr0#diameter_header{hop_by_hop_id = Seq},
    Msg = [Hdr, Route | Avps],
    resend(send_request(SvcName, App, Msg, Opts), TPid, Caps, Dict0, Fs, Pkt).
%% The incoming request is relayed with the addition of a
%% Route-Record. Note the requirement on the return from call/4 below,
%% which places a requirement on the value returned by the
%% handle_answer callback of the application module in question.
%%
%% Note that there's nothing stopping the request from being relayed
%% back to the sender. A pick_peer callback may want to avoid this but
%% a smart peer might recognize the potential loop and choose another
%% route. A less smart one will probably just relay the request back
%% again and force us to detect the loop. A pick_peer that wants to
%% avoid this can specify filter to avoid the possibility.
%% Eg. {neg, {host, OH} where #diameter_caps{origin_host = {OH, _}}.
%%
%% RFC 6.3 says that a relay agent does not modify Origin-Host but
%% says nothing about a proxy. Assume it should behave the same way.

%% resend/6
%%
%% Relay a reply to a relayed request.

%% Answer from the peer: reset the hop by hop identifier and send.
resend(#diameter_packet{bin = B}
       = Pkt,
       TPid,
       _Caps,
       _Dict0,
       Fs,
       #diameter_packet{header = #diameter_header{hop_by_hop_id = Id},
                        transport_data = TD}) ->
    P = Pkt#diameter_packet{bin = diameter_codec:hop_by_hop_id(Id, B),
                            transport_data = TD},
    eval_packet(P, Fs),
    send(TPid, P);
%% TODO: counters

%% Or not: DIAMETER_UNABLE_TO_DELIVER.
resend(_, TPid, Caps, Dict0, Fs, Pkt) ->
    protocol_error(3002, TPid, Caps, Dict0, Fs, Pkt).

%% is_loop/5
%%
%% Is there a Route-Record AVP with our Origin-Host?

is_loop(Code,
        Vid,
        Bin,
        _Dict0,
        [#diameter_avp{code = Code, vendor_id = Vid, data = Bin} | _]) ->
    true;

is_loop(_, _, _, _, []) ->
    false;

is_loop(Code, Vid, OH, Dict0, [_ | Avps])
  when is_binary(OH) ->
    is_loop(Code, Vid, OH, Dict0, Avps);

is_loop(Code, Vid, OH, Dict0, Avps) ->
    is_loop(Code, Vid, Dict0:avp(encode, OH, 'Route-Record'), Dict0, Avps).

%% reply/5
%%
%% Send a locally originating reply.

%% Skip the setting of Result-Code and Failed-AVP's below. This is
%% currently undocumented.
reply([Msg], Dict, TPid, Fs, Pkt)
  when is_list(Msg);
       is_tuple(Msg) ->
    reply(Msg, Dict, TPid, Fs, Pkt#diameter_packet{errors = []});

%% No errors or a diameter_header/avp list.
reply(Msg, Dict, TPid, Fs, #diameter_packet{errors = Es} = ReqPkt)
  when [] == Es;
       is_record(hd(Msg), diameter_header) ->
    Pkt = encode(Dict, make_answer_packet(Msg, ReqPkt), Fs),
    incr(send, Pkt, Dict, TPid),  %% count result codes in sent answers
    send(TPid, Pkt);

%% Or not: set Result-Code and Failed-AVP AVP's.
reply(Msg, Dict, TPid, Fs, #diameter_packet{errors = [H|_] = Es} = Pkt) ->
    reply(rc(Msg, rc(H), [A || {_,A} <- Es], Dict),
          Dict,
          TPid,
          Fs,
          Pkt#diameter_packet{errors = []}).

eval_packet(Pkt, Fs) ->
    lists:foreach(fun(F) -> diameter_lib:eval([F,Pkt]) end, Fs).

%% make_answer_packet/2

%% A reply message clears the R and T flags and retains the P flag.
%% The E flag will be set at encode. 6.2 of 3588 requires the same P
%% flag on an answer as on the request. A #diameter_packet{} returned
%% from a handle_request callback can circumvent this by setting its
%% own header values.
make_answer_packet(#diameter_packet{header = Hdr,
                                    msg = Msg,
                                    transport_data = TD},
                   #diameter_packet{header = ReqHdr}) ->
    Hdr0 = ReqHdr#diameter_header{version = ?DIAMETER_VERSION,
                                  is_request = false,
                                  is_error = undefined,
                                  is_retransmitted = false},
    #diameter_packet{header = fold_record(Hdr0, Hdr),
                     msg = Msg,
                     transport_data = TD};

%% Binaries and header/avp lists are sent as-is.
make_answer_packet(Bin, #diameter_packet{transport_data = TD})
  when is_binary(Bin) ->
    #diameter_packet{bin = Bin,
                     transport_data = TD};
make_answer_packet([#diameter_header{} | _] = Msg,
                   #diameter_packet{transport_data = TD}) ->
    #diameter_packet{msg = Msg,
                     transport_data = TD};

%% Otherwise, preserve transport_data.
make_answer_packet(Msg, #diameter_packet{transport_data = TD} = Pkt) ->
    make_answer_packet(#diameter_packet{msg = Msg, transport_data = TD}, Pkt).

%% rc/1

rc({RC, _}) ->
    RC;
rc(RC) ->
    RC.

%% rc/4

rc(#diameter_packet{msg = Rec} = Pkt, RC, Failed, DictT) ->
    Pkt#diameter_packet{msg = rc(Rec, RC, Failed, DictT)};

rc(Rec, RC, Failed, DictT)
  when is_integer(RC) ->
    set(Rec,
        lists:append([rc(Rec, {'Result-Code', RC}, DictT),
                      failed_avp(Rec, Failed, DictT)]),
        DictT).

%% Reply as name and tuple list ...
set([_|_] = Ans, Avps, _) ->
    Ans ++ Avps;  %% Values nearer tail take precedence.

%% ... or record.
set(Rec, Avps, Dict) ->
    Dict:'#set-'(Avps, Rec).

%% rc/3
%%
%% Turn the result code into a list if its optional and only set it if
%% the arity is 1 or {0,1}. In other cases (which probably shouldn't
%% exist in practise) we can't know what's appropriate.

rc([MsgName | _], {'Result-Code' = K, RC} = T, Dict) ->
    case Dict:avp_arity(MsgName, 'Result-Code') of
        1     -> [T];
        {0,1} -> [{K, [RC]}];
        _     -> []
    end;

rc(Rec, T, Dict) ->
    rc([Dict:rec2msg(element(1, Rec))], T, Dict).

%% failed_avp/3

failed_avp(_, [] = No, _) ->
    No;

failed_avp(Rec, Failed, Dict) ->
    [fa(Rec, [{'AVP', Failed}], Dict)].

%% Reply as name and tuple list ...
fa([MsgName | Values], FailedAvp, Dict) ->
    R = Dict:msg2rec(MsgName),
    try
        Dict:'#info-'(R, {index, 'Failed-AVP'}),
        {'Failed-AVP', [FailedAvp]}
    catch
        error: _ ->
            Avps = proplists:get_value('AVP', Values, []),
            A = #diameter_avp{name = 'Failed-AVP',
                              value = FailedAvp},
            {'AVP', [A|Avps]}
    end;

%% ... or record.
fa(Rec, FailedAvp, Dict) ->
    try
        {'Failed-AVP', [FailedAvp]}
    catch
        error: _ ->
            Avps = Dict:'get-'('AVP', Rec),
            A = #diameter_avp{name = 'Failed-AVP',
                              value = FailedAvp},
            {'AVP', [A|Avps]}
    end.

%% 3.  Diameter Header
%%
%%       E(rror)     - If set, the message contains a protocol error,
%%                     and the message will not conform to the ABNF
%%                     described for this command.  Messages with the 'E'
%%                     bit set are commonly referred to as error
%%                     messages.  This bit MUST NOT be set in request
%%                     messages.  See Section 7.2.

%% 3.2.  Command Code ABNF specification
%%
%%    e-bit            = ", ERR"
%%                       ; If present, the 'E' bit in the Command
%%                       ; Flags is set, indicating that the answer
%%                       ; message contains a Result-Code AVP in
%%                       ; the "protocol error" class.

%% 7.1.3.  Protocol Errors
%%
%%    Errors that fall within the Protocol Error category SHOULD be treated
%%    on a per-hop basis, and Diameter proxies MAY attempt to correct the
%%    error, if it is possible.  Note that these and only these errors MUST
%%    only be used in answer messages whose 'E' bit is set.

%% Thus, only construct answers to protocol errors. Other errors
%% require an message-specific answer and must be handled by the
%% application.

%% 6.2.  Diameter Answer Processing
%%
%%    When a request is locally processed, the following procedures MUST be
%%    applied to create the associated answer, in addition to any
%%    additional procedures that MAY be discussed in the Diameter
%%    application defining the command:
%%
%%    -  The same Hop-by-Hop identifier in the request is used in the
%%       answer.
%%
%%    -  The local host's identity is encoded in the Origin-Host AVP.
%%
%%    -  The Destination-Host and Destination-Realm AVPs MUST NOT be
%%       present in the answer message.
%%
%%    -  The Result-Code AVP is added with its value indicating success or
%%       failure.
%%
%%    -  If the Session-Id is present in the request, it MUST be included
%%       in the answer.
%%
%%    -  Any Proxy-Info AVPs in the request MUST be added to the answer
%%       message, in the same order they were present in the request.
%%
%%    -  The 'P' bit is set to the same value as the one in the request.
%%
%%    -  The same End-to-End identifier in the request is used in the
%%       answer.
%%
%%    Note that the error messages (see Section 7.3) are also subjected to
%%    the above processing rules.

%% 7.3.  Error-Message AVP
%%
%%    The Error-Message AVP (AVP Code 281) is of type UTF8String.  It MAY
%%    accompany a Result-Code AVP as a human readable error message.  The
%%    Error-Message AVP is not intended to be useful in real-time, and
%%    SHOULD NOT be expected to be parsed by network entities.

%% answer_message/3

answer_message({OH, OR, RC}, Dict0, Avps) ->
    {Code, _, Vid} = Dict0:avp_header('Session-Id'),
    ['answer-message', {'Origin-Host', OH},
                       {'Origin-Realm', OR},
                       {'Result-Code', RC}
                       | session_id(Code, Vid, Dict0, Avps)].

session_id(Code, Vid, Dict0, Avps)
  when is_list(Avps) ->
    try
        {value, #diameter_avp{data = D}} = find_avp(Code, Vid, Avps),
        [{'Session-Id', [Dict0:avp(decode, D, 'Session-Id')]}]
    catch
        error: _ ->
            []
    end.

%% find_avp/3

find_avp(Code, Vid, Avps)
  when is_integer(Code), (undefined == Vid orelse is_integer(Vid)) ->
    find(fun(A) -> is_avp(Code, Vid, A) end, Avps).

%% The final argument here could be a list of AVP's, depending on the case,
%% but we're only searching at the top level.
is_avp(Code, Vid, #diameter_avp{code = Code, vendor_id = Vid}) ->
    true;
is_avp(_, _, _) ->
    false.

find(_, []) ->
    false;
find(Pred, [H|T]) ->
    case Pred(H) of
        true ->
            {value, H};
        false ->
            find(Pred, T)
    end.

%% 7.  Error Handling
%%
%%    There are certain Result-Code AVP application errors that require
%%    additional AVPs to be present in the answer.  In these cases, the
%%    Diameter node that sets the Result-Code AVP to indicate the error
%%    MUST add the AVPs.  Examples are:
%%
%%    -  An unrecognized AVP is received with the 'M' bit (Mandatory bit)
%%       set, causes an answer to be sent with the Result-Code AVP set to
%%       DIAMETER_AVP_UNSUPPORTED, and the Failed-AVP AVP containing the
%%       offending AVP.
%%
%%    -  An AVP that is received with an unrecognized value causes an
%%       answer to be returned with the Result-Code AVP set to
%%       DIAMETER_INVALID_AVP_VALUE, with the Failed-AVP AVP containing the
%%       AVP causing the error.
%%
%%    -  A command is received with an AVP that is omitted, yet is
%%       mandatory according to the command's ABNF.  The receiver issues an
%%       answer with the Result-Code set to DIAMETER_MISSING_AVP, and
%%       creates an AVP with the AVP Code and other fields set as expected
%%       in the missing AVP.  The created AVP is then added to the Failed-
%%       AVP AVP.
%%
%%    The Result-Code AVP describes the error that the Diameter node
%%    encountered in its processing.  In case there are multiple errors,
%%    the Diameter node MUST report only the first error it encountered
%%    (detected possibly in some implementation dependent order).  The
%%    specific errors that can be described by this AVP are described in
%%    the following section.

%% 7.5.  Failed-AVP AVP
%%
%%    The Failed-AVP AVP (AVP Code 279) is of type Grouped and provides
%%    debugging information in cases where a request is rejected or not
%%    fully processed due to erroneous information in a specific AVP.  The
%%    value of the Result-Code AVP will provide information on the reason
%%    for the Failed-AVP AVP.
%%
%%    The possible reasons for this AVP are the presence of an improperly
%%    constructed AVP, an unsupported or unrecognized AVP, an invalid AVP
%%    value, the omission of a required AVP, the presence of an explicitly
%%    excluded AVP (see tables in Section 10), or the presence of two or
%%    more occurrences of an AVP which is restricted to 0, 1, or 0-1
%%    occurrences.
%%
%%    A Diameter message MAY contain one Failed-AVP AVP, containing the
%%    entire AVP that could not be processed successfully.  If the failure
%%    reason is omission of a required AVP, an AVP with the missing AVP
%%    code, the missing vendor id, and a zero filled payload of the minimum
%%    required length for the omitted AVP will be added.

%% incr/4
%%
%% Increment a stats counter for an incoming or outgoing message.

%% Outgoing message as binary: don't count. (Sending binaries is only
%% partially supported.)
incr(_, #diameter_packet{msg = undefined}, _, _) ->
    ok;

incr(recv = D, #diameter_packet{header = H, errors = [_|_]}, _, TPid) ->
    incr(TPid, {diameter_codec:msg_id(H), D, error});

incr(Dir, Pkt, Dict, TPid) ->
    #diameter_packet{header = #diameter_header{is_error = E}
                            = Hdr,
                     msg = Rec}
        = Pkt,

    RC = int(get_avp_value(Dict, 'Result-Code', Rec)),
    PE = is_protocol_error(RC),

    %% Check that the E bit is set only for 3xxx result codes.
    (not (E orelse PE))
        orelse (E andalso PE)
        orelse x({invalid_error_bit, RC}, answer, [Dir, Pkt]),

    irc(TPid, Hdr, Dir, rc_counter(Dict, Rec, RC)).

irc(_, _, _, undefined) ->
    false;

irc(TPid, Hdr, Dir, Ctr) ->
    incr(TPid, {diameter_codec:msg_id(Hdr), Dir, Ctr}).

%% incr/2

incr(TPid, Counter) ->
    diameter_stats:incr(Counter, TPid, 1).

%% error_counter/2

%% RFC 3588, 7.6:
%%
%%   All Diameter answer messages defined in vendor-specific
%%   applications MUST include either one Result-Code AVP or one
%%   Experimental-Result AVP.
%%
%% Maintain statistics assuming one or the other, not both, which is
%% surely the intent of the RFC.

rc_counter(Dict, Rec, undefined) ->
    rcc(get_avp_value(Dict, 'Experimental-Result', Rec));
rc_counter(_, _, RC) ->
    {'Result-Code', RC}.

%% Outgoing answers may be in any of the forms messages can be sent
%% in. Incoming messages will be records. We're assuming here that the
%% arity of the result code AVP's is 0 or 1.

rcc([{_,_,N} = T | _])
  when is_integer(N) ->
    T;
rcc({_,_,N} = T)
  when is_integer(N) ->
    T;
rcc(_) ->
    undefined.

%% Extract the first good looking integer. There's no guarantee
%% that what we're looking for has arity 1.
int([N|_])
  when is_integer(N) ->
    N;
int(N)
  when is_integer(N) ->
    N;
int(_) ->
    undefined.

is_protocol_error(RC) ->
    3000 =< RC andalso RC < 4000.

-spec x(any(), atom(), list()) -> no_return().

%% Warn and exit request process on errors in an incoming answer.
x(Reason, F, A) ->
    diameter_lib:warning_report(Reason, {?MODULE, F, A}),
    x(Reason).

x(T) ->
    exit(T).

%% ---------------------------------------------------------------------------
%% # send_request/4
%%
%% Handle an outgoing Diameter request.
%% ---------------------------------------------------------------------------

send_request(SvcName, AppOrAlias, Msg, Options)
  when is_list(Options) ->
    Rec = make_options(Options),
    Ref = make_ref(),
    Caller = {self(), Ref},
    ReqF = fun() ->
                   exit({Ref, send_R(SvcName, AppOrAlias, Msg, Rec, Caller)})
           end,
    try spawn_monitor(ReqF) of
        {_, MRef} ->
            recv_A(MRef, Ref, Rec#options.detach, false)
    catch
        error: system_limit = E ->
            {error, E}
    end.
%% The R in send_R is because Diameter request are usually given short
%% names of the form XXR. (eg. CER, DWR, etc.) Similarly, answers have
%% names of the form XXA.

%% Don't rely on gen_server:call/3 for the timeout handling since it
%% makes no guarantees about not leaving a reply message in the
%% mailbox if we catch its exit at timeout. It currently *can* do so,
%% which is also undocumented.

recv_A(MRef, _, true, true) ->
    erlang:demonitor(MRef, [flush]),
    ok;

recv_A(MRef, Ref, Detach, Sent) ->
    receive
        Ref ->  %% send has been attempted
            recv_A(MRef, Ref, Detach, true);
        {'DOWN', MRef, process, _, Reason} ->
            answer_rc(Reason, Ref, Sent)
    end.

%% send_R/5 has returned ...
answer_rc({Ref, Ans}, Ref, _) ->
    Ans;

%% ... or not. Note that failure/encode are documented return values.
answer_rc(_, _, Sent) ->
    {error, choose(Sent, failure, encode)}.

%% send_R/5
%%
%% In the process spawned for the outgoing request.

send_R(SvcName, AppOrAlias, Msg, Opts, Caller) ->
    case pick_peer(SvcName, AppOrAlias, Msg, Opts) of
        {{_,_,_} = Transport, Mask} ->
            send_request(Transport, Mask, Msg, Opts, Caller, SvcName);
        false ->
            {error, no_connection};
        {error, _} = No ->
            No
    end.

%% make_options/1

make_options(Options) ->
    lists:foldl(fun mo/2, #options{}, Options).

mo({timeout, T}, Rec)
  when is_integer(T), 0 =< T ->
    Rec#options{timeout = T};

mo({filter, F}, #options{filter = none} = Rec) ->
    Rec#options{filter = F};
mo({filter, F}, #options{filter = {all, Fs}} = Rec) ->
    Rec#options{filter = {all, [F | Fs]}};
mo({filter, F}, #options{filter = F0} = Rec) ->
    Rec#options{filter = {all, [F0, F]}};

mo({extra, L}, #options{extra = X} = Rec)
  when is_list(L) ->
    Rec#options{extra = X ++ L};

mo(detach, Rec) ->
    Rec#options{detach = true};

mo(T, _) ->
    ?ERROR({invalid_option, T}).

%% ---------------------------------------------------------------------------
%% # send_request/6
%% ---------------------------------------------------------------------------

%% Send an outgoing request in its dedicated process.
%%
%% Note that both encode of the outgoing request and of the received
%% answer happens in this process. It's also this process that replies
%% to the caller. The service process only handles the state-retaining
%% callbacks.
%%
%% The module field of the #diameter_app{} here includes any extra
%% arguments passed to diameter:call/4.

send_request({TPid, Caps, App}
             = Transport,
             Mask,
             Msg,
             Opts,
             Caller,
             SvcName) ->
    Pkt = make_prepare_packet(Mask, Msg),

    send_R(cb(App, prepare_request, [Pkt, SvcName, {TPid, Caps}]),
           Pkt,
           Transport,
           Opts,
           Caller,
           SvcName,
           []).

send_R({send, Msg}, Pkt, Transport, Opts, Caller, SvcName, Fs) ->
    send_R(make_request_packet(Msg, Pkt),
           Transport,
           Opts,
           Caller,
           SvcName,
           Fs);

send_R({discard, Reason} , _, _, _, _, _, _) ->
    {error, Reason};

send_R(discard, _, _, _, _, _, _) ->
    {error, discarded};

send_R({eval_packet, RC, F}, Pkt, T, Opts, Caller, SvcName, Fs) ->
    send_R(RC, Pkt, T, Opts, Caller, SvcName, [F|Fs]);

send_R(E, _, {_, _, App}, _, _, _, _) ->
    ?ERROR({invalid_return, prepare_request, App, E}).

%% make_prepare_packet/2
%%
%% Turn an outgoing request as passed to call/4 into a diameter_packet
%% record in preparation for a prepare_request callback.

make_prepare_packet(_, Bin)
  when is_binary(Bin) ->
    #diameter_packet{header = diameter_codec:decode_header(Bin),
                     bin = Bin};

make_prepare_packet(Mask, #diameter_packet{msg = [#diameter_header{} = Hdr
                                                  | Avps]}
                          = Pkt) ->
    Pkt#diameter_packet{msg = [make_prepare_header(Mask, Hdr) | Avps]};

make_prepare_packet(Mask, #diameter_packet{header = Hdr} = Pkt) ->
    Pkt#diameter_packet{header = make_prepare_header(Mask, Hdr)};

make_prepare_packet(Mask, Msg) ->
    make_prepare_packet(Mask, #diameter_packet{msg = Msg}).

%% make_prepare_header/2

make_prepare_header(Mask, undefined) ->
    Seq = diameter_session:sequence(Mask),
    make_prepare_header(#diameter_header{end_to_end_id = Seq,
                                         hop_by_hop_id = Seq});

make_prepare_header(Mask, #diameter_header{end_to_end_id = undefined,
                                           hop_by_hop_id = undefined}
                          = H) ->
    Seq = diameter_session:sequence(Mask),
    make_prepare_header(H#diameter_header{end_to_end_id = Seq,
                                          hop_by_hop_id = Seq});

make_prepare_header(Mask, #diameter_header{end_to_end_id = undefined} = H) ->
    Seq = diameter_session:sequence(Mask),
    make_prepare_header(H#diameter_header{end_to_end_id = Seq});

make_prepare_header(Mask, #diameter_header{hop_by_hop_id = undefined} = H) ->
    Seq = diameter_session:sequence(Mask),
    make_prepare_header(H#diameter_header{hop_by_hop_id = Seq});

make_prepare_header(_, Hdr) ->
    make_prepare_header(Hdr).

%% make_prepare_header/1

make_prepare_header(#diameter_header{version = undefined} = Hdr) ->
    make_prepare_header(Hdr#diameter_header{version = ?DIAMETER_VERSION});

make_prepare_header(#diameter_header{} = Hdr) ->
    Hdr;

make_prepare_header(T) ->
    ?ERROR({invalid_header, T}).

%% make_request_packet/2
%%
%% Reconstruct a diameter_packet from the return value of
%% prepare_request or prepare_retransmit callback.

make_request_packet(Bin, _)
  when is_binary(Bin) ->
    make_prepare_packet(false, Bin);

make_request_packet(#diameter_packet{msg = [#diameter_header{} | _]}
                    = Pkt,
                    _) ->
    Pkt;

%% Returning a diameter_packet with no header from a prepare_request
%% or prepare_retransmit callback retains the header passed into it.
%% This is primarily so that the end to end and hop by hop identifiers
%% are retained.
make_request_packet(#diameter_packet{header = Hdr} = Pkt,
                    #diameter_packet{header = Hdr0}) ->
    Pkt#diameter_packet{header = fold_record(Hdr0, Hdr)};

make_request_packet(Msg, Pkt) ->
    Pkt#diameter_packet{msg = Msg}.

%% fold_record/2

fold_record(undefined, R) ->
    R;
fold_record(Rec, R) ->
    diameter_lib:fold_tuple(2, Rec, R).

%% send_R/6

send_R(Pkt0,
       {TPid, Caps, #diameter_app{dictionary = Dict} = App},
       Opts,
       {Pid, Ref},
       SvcName,
       Fs) ->
    Pkt = encode(Dict, Pkt0, Fs),

    #options{timeout = Timeout}
        = Opts,

    Req = #request{ref = Ref,
                   caller = Pid,
                   handler = self(),
                   transport = TPid,
                   caps = Caps,
                   packet = Pkt0},

    try
        TRef = send_request(TPid, Pkt, Req, SvcName, Timeout),
        Pid ! Ref,  %% tell caller a send has been attempted
        handle_answer(SvcName,
                      App,
                      recv_A(Timeout, SvcName, App, Opts, {TRef, Req}))
    after
        erase_requests(Pkt)
    end.

%% recv_A/5

recv_A(Timeout, SvcName, App, Opts, {TRef, #request{ref = Ref} = Req}) ->
    %% Matching on TRef below ensures we ignore messages that pertain
    %% to a previous transport prior to failover. The answer message
    %% includes the #request{} since it's not necessarily Req; that
    %% is, from the last peer to which we've transmitted.
    receive
        {answer = A, Ref, Rq, Dict0, Pkt} ->  %% Answer from peer
            {A, Rq, Dict0, Pkt};
        {timeout = Reason, TRef, _} ->        %% No timely reply
            {error, Req, Reason};
        {failover, TRef} ->       %% Service says peer has gone down
            retransmit(pick_peer(SvcName, App, Req, Opts),
                       Req,
                       Opts,
                       SvcName,
                       Timeout)
    end.

%% handle_answer/3

handle_answer(SvcName, App, {error, Req, Reason}) ->
    handle_error(App, Req, Reason, SvcName);

handle_answer(SvcName,
              #diameter_app{dictionary = Dict}
              = App,
              {answer, Req, Dict0, Pkt}) ->
    Mod = dict(Dict, Dict0, Pkt),
    answer(examine(diameter_codec:decode(Mod, Pkt)),
           SvcName,
           Mod,
           App,
           Req).

%% We don't really need to do a full decode if we're a relay and will
%% just resend with a new hop by hop identifier, but might a proxy
%% want to examine the answer?

answer(Pkt, SvcName, Dict, App, #request{transport = TPid} = Req) ->
    try
        incr(recv, Pkt, Dict, TPid)
    of
        _ -> answer(Pkt, SvcName, App, Req)
    catch
        exit: {invalid_error_bit, _} = E ->
            answer(Pkt#diameter_packet{errors = [E]}, SvcName, App, Req)
    end.

answer(Pkt,
       SvcName,
       #diameter_app{module = ModX,
                     options = [{answer_errors, AE} | _]},
       Req) ->
    a(Pkt, SvcName, ModX, AE, Req).

a(#diameter_packet{errors = Es}
  = Pkt,
  SvcName,
  ModX,
  AE,
  #request{transport = TPid,
           caps = Caps,
           packet = P})
  when [] == Es;
       callback == AE ->
    cb(ModX, handle_answer, [Pkt, msg(P), SvcName, {TPid, Caps}]);

a(Pkt, SvcName, _, report, Req) ->
    x(errors, handle_answer, [SvcName, Req, Pkt]);

a(Pkt, SvcName, _, discard, Req) ->
    x({errors, handle_answer, [SvcName, Req, Pkt]}).

%% Note that we don't check that the application id in the answer's
%% header is what we expect. (TODO: Does the rfc says anything about
%% this?)

%% Note that failover starts a new timer and that expiry of an old
%% timer value is ignored. This means that an answer could be accepted
%% from a peer after timeout in the case of failover.

retransmit({{_,_,App} = Transport, _Mask}, Req, Opts, SvcName, Timeout) ->
    try retransmit(Transport, Req, SvcName, Timeout) of
        T -> recv_A(Timeout, SvcName, App, Opts, T)
    catch
        ?FAILURE(Reason) -> {error, Req, Reason}
    end;

retransmit(_, Req, _, _, _) ->  %% no alternate peer
    {error, Req, failover}.

%% pick_peer/4

%% Retransmission after failover: call-specific arguments have already
%% been appended in App.
pick_peer(SvcName,
          App,
          #request{packet = #diameter_packet{msg = Msg}},
          Opts) ->
    pick_peer(SvcName, App, Msg, Opts#options{extra = []});

pick_peer(_, _, undefined, _) ->
    false;

pick_peer(SvcName,
          AppOrAlias,
          Msg,
          #options{filter = Filter, extra = Xtra}) ->
    diameter_service:pick_peer(SvcName,
                               AppOrAlias,
                               {fun(D) -> get_destination(D, Msg) end,
                                Filter,
                                Xtra}).

%% handle_error/4

handle_error(App,
             #request{packet = Pkt,
                      transport = TPid,
                      caps = Caps},
             Reason,
             SvcName) ->
    cb(App, handle_error, [Reason, msg(Pkt), SvcName, {TPid, Caps}]).

msg(#diameter_packet{msg = undefined, bin = Bin}) ->
    Bin;
msg(#diameter_packet{msg = Msg}) ->
    Msg.

%% encode/3

encode(Dict, Pkt, Fs) ->
    P = encode(Dict, Pkt),
    eval_packet(P, Fs),
    P.

%% encode/2

%% Note that prepare_request can return a diameter_packet containing a
%% header or transport_data. Even allow the returned record to contain
%% an encoded binary. This isn't the usual case and doesn't properly
%% support retransmission but is useful for test.

%% A message to be encoded.
encode(Dict, #diameter_packet{bin = undefined} = Pkt) ->
    diameter_codec:encode(Dict, Pkt);

%% An encoded binary: just send.
encode(_, #diameter_packet{} = Pkt) ->
    Pkt.

%% send_request/5

send_request(TPid, #diameter_packet{bin = Bin} = Pkt, Req, _SvcName, Timeout)
  when node() == node(TPid) ->
    %% Store the outgoing request before sending to avoid a race with
    %% reply reception.
    TRef = store_request(TPid, Bin, Req, Timeout),
    send(TPid, Pkt),
    TRef;

%% Send using a remote transport: spawn a process on the remote node
%% to relay the answer.
send_request(TPid, #diameter_packet{} = Pkt, Req, SvcName, Timeout) ->
    TRef = erlang:start_timer(Timeout, self(), TPid),
    T = {TPid, Pkt, Req, SvcName, Timeout, TRef},
    spawn(node(TPid), ?MODULE, send, [T]),
    TRef.

%% send/1

send({TPid, Pkt, #request{handler = Pid} = Req, SvcName, Timeout, TRef}) ->
    Ref = send_request(TPid,
                       Pkt,
                       Req#request{handler = self()},
                       SvcName,
                       Timeout),
    Pid ! reref(receive T -> T end, Ref, TRef).

reref({T, Ref, R}, Ref, TRef) ->
    {T, TRef, R};
reref(T, _, _) ->
    T.

%% send/2

send(Pid, Pkt) ->
    Pid ! {send, Pkt}.

%% retransmit/4

retransmit({TPid, Caps, App}
           = Transport,
           #request{packet = Pkt0}
           = Req,
           SvcName,
           Timeout) ->
    have_request(Pkt0, TPid)     %% Don't failover to a peer we've
        andalso ?THROW(timeout), %% already sent to.

    #diameter_packet{header = Hdr0} = Pkt0,
    Hdr = Hdr0#diameter_header{is_retransmitted = true},
    Pkt = Pkt0#diameter_packet{header = Hdr},

    retransmit(cb(App, prepare_retransmit, [Pkt, SvcName, {TPid, Caps}]),
               Transport,
               Req#request{packet = Pkt},
               SvcName,
               Timeout,
               []).

retransmit({send, Msg},
           Transport,
           #request{packet = Pkt}
           = Req,
           SvcName,
           Timeout,
           Fs) ->
    resend_request(make_request_packet(Msg, Pkt),
                   Transport,
                   Req,
                   SvcName,
                   Timeout,
                   Fs);

retransmit({discard, Reason}, _, _, _, _, _) ->
    ?THROW(Reason);

retransmit(discard, _, _, _, _, _) ->
    ?THROW(discarded);

retransmit({eval_packet, RC, F}, Transport, Req, SvcName, Timeout, Fs) ->
    retransmit(RC, Transport, Req, SvcName, Timeout, [F|Fs]);

retransmit(T, {_, _, App}, _, _, _, _) ->
    ?ERROR({invalid_return, prepare_retransmit, App, T}).

resend_request(Pkt0,
               {TPid, Caps, #diameter_app{dictionary = Dict}},
               Req0,
               SvcName,
               Tmo,
               Fs) ->
    Pkt = encode(Dict, Pkt0, Fs),

    Req = Req0#request{transport = TPid,
                       packet = Pkt0,
                       caps = Caps},

    ?LOG(retransmission, Req),
    TRef = send_request(TPid, Pkt, Req, SvcName, Tmo),
    {TRef, Req}.

%% store_request/4

store_request(TPid, Bin, Req, Timeout) ->
    Seqs = diameter_codec:sequence_numbers(Bin),
    TRef = erlang:start_timer(Timeout, self(), timeout),
    ets:insert(?REQUEST_TABLE, {Seqs, Req, TRef}),
    ets:member(?REQUEST_TABLE, TPid)
        orelse (self() ! {failover, TRef}),  %% failover/1 may have missed
    TRef.

%% lookup_request/2

lookup_request(Msg, TPid) ->
    Seqs = diameter_codec:sequence_numbers(Msg),
    Spec = [{{Seqs, #request{transport = TPid, _ = '_'}, '_'},
             [],
             ['$_']}],
    case ets:select(?REQUEST_TABLE, Spec) of
        [{_, Req, _}] ->
            Req;
        [] ->
            false
    end.

%% erase_requests/1

erase_requests(Pkt) ->
    ets:delete(?REQUEST_TABLE, diameter_codec:sequence_numbers(Pkt)).

%% match_requests/1

match_requests(TPid) ->
    Pat = {'_', #request{transport = TPid, _ = '_'}, '_'},
    ets:select(?REQUEST_TABLE, [{Pat, [], ['$_']}]).

%% have_request/2

have_request(Pkt, TPid) ->
    Seqs = diameter_codec:sequence_numbers(Pkt),
    Pat = {Seqs, #request{transport = TPid, _ = '_'}, '_'},
    '$end_of_table' /= ets:select(?REQUEST_TABLE, [{Pat, [], ['$_']}], 1).

%% ---------------------------------------------------------------------------
%% # failover/1-2
%% ---------------------------------------------------------------------------

failover(TPid)
  when is_pid(TPid) ->
    lists:foreach(fun failover/1, match_requests(TPid));
%% Note that a request process can store its request after failover
%% notifications are sent here: store_request/4 sends the notification
%% in that case.

%% Failover as a consequence of request_peer_down/1: inform the
%% request process.
failover({_, Req, TRef}) ->
    #request{handler = Pid,
             packet = #diameter_packet{msg = M}}
        = Req,
    M /= undefined andalso (Pid ! {failover, TRef}).
%% Failover is not performed when msg = binary() since sending
%% pre-encoded binaries is only partially supported. (Mostly for
%% test.)

%% get_destination/2

get_destination(Dict, Msg) ->
    [str(get_avp_value(Dict, D, Msg)) || D <- ['Destination-Realm',
                                               'Destination-Host']].

%% This is not entirely correct. The avp could have an arity 1, in
%% which case an empty list is a DiameterIdentity of length 0 rather
%% than the list of no values we treat it as by mapping to undefined.
%% This behaviour is documented.
str([]) ->
    undefined;
str(T) ->
    T.

%% get_avp_value/3
%%
%% Find an AVP in a message of one of three forms:
%%
%% - a message record (as generated from a .dia spec) or
%% - a list of an atom message name followed by 2-tuple, avp name/value pairs.
%% - a list of a #diameter_header{} followed by #diameter_avp{} records,
%%
%% In the first two forms a dictionary module is used at encode to
%% identify the type of the AVP and its arity in the message in
%% question. The third form allows messages to be sent as is, without
%% a dictionary, which is needed in the case of relay agents, for one.

%% Messages will be header/avps list as a relay and the only AVP's we
%% look for are in the common dictionary. This is required since the
%% relay dictionary doesn't inherit the common dictionary (which maybe
%% it should).
get_avp_value(?RELAY, Name, Msg) ->
    get_avp_value(?BASE, Name, Msg);

%% Message sent as a header/avps list, probably a relay case but not
%% necessarily.
get_avp_value(Dict, Name, [#diameter_header{} | Avps]) ->
    try
        {Code, _, VId} = Dict:avp_header(Name),
        [A|_] = lists:dropwhile(fun(#diameter_avp{code = C, vendor_id = V}) ->
                                        C /= Code orelse V /= VId
                                end,
                                Avps),
        avp_decode(Dict, Name, A)
    catch
        error: _ ->
            undefined
    end;

%% Outgoing message as a name/values list.
get_avp_value(_, Name, [_MsgName | Avps]) ->
    case lists:keyfind(Name, 1, Avps) of
        {_, V} ->
            V;
        _ ->
            undefined
    end;

%% Message is typically a record but not necessarily.
get_avp_value(Dict, Name, Rec) ->
    try
        Dict:'#get-'(Name, Rec)
    catch
        error:_ ->
            undefined
    end.

avp_decode(Dict, Name, #diameter_avp{value = undefined,
                                     data = Bin}) ->
    Dict:avp(decode, Bin, Name);
avp_decode(_, _, #diameter_avp{value = V}) ->
    V.

cb(#diameter_app{module = [_|_] = M}, F, A) ->
    eval(M, F, A);
cb([_|_] = M, F, A) ->
    eval(M, F, A).

eval([M|X], F, A) ->
    apply(M, F, A ++ X).

choose(true, X, _)  -> X;
choose(false, _, X) -> X.
