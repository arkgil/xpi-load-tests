%%==============================================================================
%% Copyright 2015 Erlang Solutions Ltd.
%% Licensed under the Apache License, Version 2.0 (see LICENSE file)
%%
%% In this scenarion users are sending message to its neighbours
%% (users wiht lower and grater idea defined by NUMBER_OF_*_NEIGHBOURS values)
%% Messages will be send NUMBER_OF_SEND_MESSAGE_REPEATS to every selected neighbour
%% after every message given the script will wait SLEEP_TIME_AFTER_EVERY_MESSAGE ms
%% Every CHECKER_SESSIONS_INDICATOR is a checker session which just measures message TTD
%%
%%==============================================================================
-module(pubsub_foreign_event).

-include_lib("exml/include/exml.hrl").

-define(HOST, <<"localhost">>). %% The virtual host served by the server
-define(PUBSUB, <<"pubsub.localhost">>).
-define(CHECKER_SESSIONS_INDICATOR, 10). %% How often a checker session should be generated
-define(SLEEP_TIME_AFTER_SCENARIO, 10000). %% wait 10s after scenario before disconnecting
-define(NUMBER_OF_PREV_NEIGHBOURS, 4).
-define(NUMBER_OF_NEXT_NEIGHBOURS, 4).
-define(NUMBER_OF_PERFORM_ACTION_REPEATS, 73).
-define(SLEEP_TIME_AFTER_EVERY_ACTION, 1000).
-define(USERS_PER_PUBUSB_NODE, 100).

-behaviour(amoc_scenario).

-export([start/1]).
-export([init/0]).

-define(MESSAGES_CT, [amoc, counters, messages_sent]).
-define(MESSAGE_TTD_CT, [amoc, times, message_ttd]).
-define(FOREIGN_EVENT_CT, [amoc, counters, foreign_events_sent]).
-define(FOREIGN_EVENT_ACK_TIME, [amoc, times, foreign_event_ack_time]).
-define(FOREIGN_EVENT_RESPONSE_PUBLISH_TIME, [amoc, times, foreign_event_response_publish_time]).
-define(FOREIGN_EVENT_PUBSUB_NODES_CT, [amoc, counters, foreign_event_pubsub_nodes]).

-type binjid() :: binary().

-spec init() -> ok.
init() ->
    lager:info("init some metrics"),
    catch exometer:new(?MESSAGES_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGES_CT, [one, count], 10000),
    catch exometer:new(?MESSAGE_TTD_CT, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?MESSAGE_TTD_CT, [mean, min, max, median, 95, 99, 999], 10000),
    catch exometer:new(?FOREIGN_EVENT_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?FOREIGN_EVENT_CT, [one, count], 10000),
    catch exometer:new(?FOREIGN_EVENT_ACK_TIME, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?FOREIGN_EVENT_ACK_TIME, [mean, min, max, median, 95, 99, 999], 10000),
    catch exometer:new(?FOREIGN_EVENT_RESPONSE_PUBLISH_TIME, histogram),
    exometer_report:subscribe(exometer_report_graphite, ?FOREIGN_EVENT_RESPONSE_PUBLISH_TIME, [mean, min, max, median, 95, 99, 999], 10000),
    catch exometer:new(?FOREIGN_EVENT_PUBSUB_NODES_CT, spiral),
    exometer_report:subscribe(exometer_report_graphite, ?FOREIGN_EVENT_PUBSUB_NODES_CT, [one, count], 10000),
    case http_service_url() of
        undefined ->
            exit({error, "AMOC_http_service_url environment variable needs to be set"});
        _ ->
            ok
    end.

-spec user_spec(binary(), binary(), binary()) -> escalus_users:user_spec().
user_spec(ProfileId, Password, Res) ->
    [ {username, ProfileId},
      {server, ?HOST},
      {host, pick_server()},
      {password, Password},
      {carbons, false},
      {stream_management, false},
      {resource, Res}
    ].

-spec make_user(amoc_scenario:user_id(), binary()) -> escalus_users:user_spec().
make_user(Id, R) ->
    BinId = integer_to_binary(Id),
    ProfileId = <<"user_", BinId/binary>>,
    Password = <<"password_", BinId/binary>>,
    user_spec(ProfileId, Password, R).

-spec start(amoc_scenario:user_id()) -> any().
start(MyId) ->
    Cfg = make_user(MyId, <<"res1">>),

    IsChecker = MyId rem ?CHECKER_SESSIONS_INDICATOR == 0,

    {ConnectionTime, ConnectionResult} = timer:tc(escalus_connection, start, [Cfg]),
    Client = case ConnectionResult of
        {ok, ConnectedClient, _, _} ->
            exometer:update([amoc, counters, connections], 1),
            exometer:update([amoc, times, connection], ConnectionTime),
            ConnectedClient;
        Error ->
            exometer:update([amoc, counters, connection_failures], 1),
            lager:error("Could not connect user=~p, reason=~p", [Cfg, Error]),
            exit(connection_failed)
    end,

    do(IsChecker, MyId, Client),

    timer:sleep(?SLEEP_TIME_AFTER_SCENARIO),
    send_presence_unavailable(Client),
    escalus_connection:stop(Client).

-spec do(boolean(), amoc_scenario:user_id(), escalus:client()) -> any().
do(false, MyId, Client) ->
    %% we accepts only IQs to ensure PubSub interactions are successful
    escalus_connection:set_filter_predicate(Client,
                                            fun(#xmlel{name = <<"iq">>}) ->
                                                    true;
                                               (_) ->
                                                    false
                                            end),


    send_presence_available(Client),
    timer:sleep(5000),

    create_pubsub_node(Client, MyId),
    subscribe_to_pubsub_node(Client, MyId),

    %% we accept only IQs and messages from pubsub
    escalus_connection:set_filter_predicate(Client,
                                            fun(#xmlel{name = <<"iq">>}) ->
                                                    true;
                                               (#xmlel{name = <<"message">>} = Stanza) ->
                                                    exml_query:attr(Stanza, <<"from">>) == ?PUBSUB;
                                               (_) ->
                                                    false
                                            end),

    NeighbourIds = lists:delete(MyId, lists:seq(max(1,MyId-?NUMBER_OF_PREV_NEIGHBOURS),
                                                MyId+?NUMBER_OF_NEXT_NEIGHBOURS)),
    perform_action_many_times(Client, MyId, ?SLEEP_TIME_AFTER_EVERY_ACTION, NeighbourIds, 1);
do(_Other, _MyId, Client) ->
    lager:info("checker"),
    send_presence_available(Client),
    receive_forever(Client).

-spec receive_forever(escalus:client()) -> no_return().
receive_forever(Client) ->
    Stanza = escalus_connection:get_stanza(Client, message, infinity),
    Now = usec:from_now(os:timestamp()),
    case Stanza of
        #xmlel{name = <<"message">>, attrs=Attrs} ->
            case lists:keyfind(<<"timestamp">>, 1, Attrs) of
                {_, Sent} ->
                    TTD = (Now - binary_to_integer(Sent)),
                    exometer:update(?MESSAGE_TTD_CT, TTD);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    receive_forever(Client).


-spec send_presence_available(escalus:client()) -> ok.
send_presence_available(Client) ->
    Pres = escalus_stanza:presence(<<"available">>),
    escalus_connection:send(Client, Pres).

-spec send_presence_unavailable(escalus:client()) -> ok.
send_presence_unavailable(Client) ->
    Pres = escalus_stanza:presence(<<"unavailable">>),
    escalus_connection:send(Client, Pres).

-spec perform_action_many_times(escalus:client(), non_neg_integer(), timeout(), [binjid()], non_neg_integer()) -> ok.
perform_action_many_times(Client, UserId, MessageInterval, NeighbourIds, ActionNo) ->
    case ActionNo of
        ?NUMBER_OF_PERFORM_ACTION_REPEATS ->
            ok;
        _ ->
            case rand:uniform(2) of
                1 ->
                    send_foreign_event(Client, UserId);
                2 ->
                    send_messages_to_neighbors(Client, NeighbourIds, MessageInterval)
            end,
            perform_action_many_times(Client, UserId, MessageInterval, NeighbourIds, ActionNo + 1)
    end.

send_foreign_event(Client, UserId) ->
    lager:info("sending foreign event"),
    Id = id(),
    {_, PubsubNode} = pubsub_node_name(UserId),
    Stanza = foreign_event_request(Id, PubsubNode),
    Sent = timestamp(),
    escalus_connection:send(Client, Stanza),
    Stanzas = escalus:wait_for_stanzas(Client, 2, 10000),
    wait_for_result_and_response_publish(Client, Id, Sent),
    exometer:update(?FOREIGN_EVENT_CT, 1).

wait_for_result_and_response_publish(Client, Id, Sent) ->
    wait_for_result_and_response_publish(Client, Id, Sent, false, false).

wait_for_result_and_response_publish(_, _, _, true, true) ->
    ok;
wait_for_result_and_response_publish(Client, Id, Sent, GotIqResult, GotResponsePublish) ->
    Stanza = escalus:wait_for_stanza(Client, 60000),
    case Stanza of
        #xmlel{name = <<"iq">>} ->
            exometer:update(?FOREIGN_EVENT_ACK_TIME, timestamp() - Sent),
            wait_for_result_and_response_publish(Client, Id, Sent, true, GotResponsePublish);
        #xmlel{name = <<"message">>} ->
            GotResponsePublish1 = check_fe_response_publish(Stanza, Id, Sent),
            wait_for_result_and_response_publish(Client, Id, Sent, GotIqResult, GotResponsePublish1)
    end.


check_fe_response_publish(Stanza, Id, Sent) ->
    FEId = exml_query:path(Stanza, [{element, <<"event">>},
                                    {element, <<"items">>},
                                    {element, <<"item">>},
                                    {element, <<"foreign-event">>},
                                    {attr, <<"id">>}]),
    case FEId of
        Id ->
            lager:info("Got my response"),
            exometer:update(?FOREIGN_EVENT_RESPONSE_PUBLISH_TIME, timestamp() - Sent),
            true;
        _ ->
            false
    end.


timestamp() ->
    usec:from_now(os:timestamp()).

foreign_event_request(Id, PubsubNode) ->
    escalus_stanza:iq(<<"foreign.localhost">>, <<"set">>,
                     [
                      #xmlel{name = <<"foreign-event">>,
                             attrs = [{<<"xmlns">>, <<"urn:xmpp:foreign_event:0">>},
                                      {<<"id">>, Id}],
                             children = [#xmlel{name = <<"publish">>,
                                                attrs = [{<<"type">>, <<"response">>},
                                                         {<<"to">>, <<"pubsub">>},
                                                         {<<"name">>, PubsubNode}]},
                                         #xmlel{name = <<"request">>,
                                                attrs = [{<<"xmlns">>, <<"urn:xmpp:foreign_event:http:0">>},
                                                         {<<"type">>, <<"http">>},
                                                         {<<"url">>, http_service_url()},
                                                         {<<"method">>, <<"get">>}],
                                                children = [
                                                            #xmlel{name = <<"header">>,
                                                                   attrs = [{<<"name">>, <<"Content-Type">>}],
                                                                   children = [
                                                                               #xmlcdata{content = <<"application/json">>}
                                                                              ]
                                                                  },
                                                            #xmlel{name = <<"payload">>,
                                                                   children = [
                                                                               #xmlcdata{content = <<>>}
                                                                              ]
                                                                  }
                                                           ]
                                               }
                                        ]
                            }
                     ]).

-spec send_messages_to_neighbors(escalus:client(), [binjid()], timeout()) -> list().
send_messages_to_neighbors(Client, TargetIds, SleepTime) ->
    lager:info("sending messages"),
    [send_message(Client, make_jid(TargetId), SleepTime)
     || TargetId <- TargetIds].

-spec send_message(escalus:client(), binjid(), timeout()) -> ok.
send_message(Client, ToId, SleepTime) ->
    MsgIn = make_message(ToId),
    TimeStamp = integer_to_binary(usec:from_now(os:timestamp())),
    escalus_connection:send(Client, escalus_stanza:setattr(MsgIn, <<"timestamp">>, TimeStamp)),
    exometer:update([amoc, counters, messages_sent], 1),
    timer:sleep(SleepTime).

-spec make_message(binjid()) -> exml:element().
make_message(ToId) ->
    Body = <<"hello sir, you are a gentelman and a scholar.">>,
    Id = escalus_stanza:id(),
    escalus_stanza:set_id(escalus_stanza:chat_to(ToId, Body), Id).

-spec make_jid(amoc_scenario:user_id()) -> binjid().
make_jid(Id) ->
    BinInt = integer_to_binary(Id),
    ProfileId = <<"user_", BinInt/binary>>,
    Host = ?HOST,
    << ProfileId/binary, "@", Host/binary >>.

-spec pick_server() -> binary().
pick_server() ->
    Servers = amoc_config:get(xmpp_servers),
    S = size(Servers),
    N = erlang:phash2(self(), S) + 1,
    element(N, Servers).

http_service_url() ->
    list_to_binary(amoc_config:get(http_service_url)).

maybe_create_pubsub_node(Client, UserId) ->
    case UserId rem ?USERS_PER_PUBUSB_NODE of
        0 ->
            create_pubsub_node(Client, UserId);
        _ ->
            ok
    end.

pubsub_node_name(UserId) ->
    BinId = integer_to_binary(UserId div ?USERS_PER_PUBUSB_NODE),
    {?PUBSUB, <<"foreign-event-node-", BinId/binary>>}.

create_pubsub_node(Client, UserId) ->
    Jid = make_jid(UserId),
    IqId = id(),
    NodeConfig = [{<<"pubsub#publish_model">>, <<"open">>}],
    Iq = escalus_pubsub_stanza:create_node(Jid, IqId, pubsub_node_name(UserId),
                                           NodeConfig),
    Resp = escalus:send_and_wait(Client, Iq),
    #xmlel{name = <<"iq">>} = Resp,
    case exml_query:attr(Resp, <<"type">>) of
        <<"result">> ->
            exometer:update(?FOREIGN_EVENT_PUBSUB_NODES_CT, 1);
        _ ->
            ok
    end.

subscribe_to_pubsub_node(Client, UserId) ->
    Jid = make_jid(UserId),
    IqId = base16:encode(crypto:strong_rand_bytes(16)),
    Iq = escalus_pubsub_stanza:subscribe(Jid, IqId, pubsub_node_name(UserId)),
    Resp= escalus:send_and_wait(Client, Iq),
    #xmlel{name = <<"iq">>} = Resp,
    <<"result">> = exml_query:attr(Resp, <<"type">>).

id() ->
    base16:encode(crypto:strong_rand_bytes(16)).
