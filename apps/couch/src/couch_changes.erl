% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_changes).
-include("couch_db.hrl").

-export([handle_changes/3, get_changes_timeout/2, get_rest_db_updated/0,
    configure_filter/4, filter/2]).

%% @spec handle_changes(#changes_args{}, #httpd{} | {json_req, {[any()]}}, #db{}) -> any()
handle_changes(#changes_args{style=Style}=Args1, Req, Db) ->
    #changes_args{feed = Feed} = Args = Args1#changes_args{
        filter = make_filter_fun(Args1#changes_args.filter, Style, Req, Db)
    },
    StartSeq = case Args#changes_args.dir of
    rev ->
        couch_db:get_update_seq(Db);
    fwd ->
        Args#changes_args.since
    end,
    if Feed == "continuous" orelse Feed == "longpoll" ->
        fun(CallbackAcc) ->
            {Callback, UserAcc} = get_callback_acc(CallbackAcc),
            Self = self(),
            {ok, Notify} = couch_db_update_notifier:start_link(
                fun({_, DbName}) when DbName == Db#db.name ->
                    Self ! db_updated;
                (_) ->
                    ok
                end
            ),
            UserAcc2 = start_sending_changes(Callback, UserAcc, Feed),
            {Timeout, TimeoutFun} = get_changes_timeout(Args, Callback),
            try
                keep_sending_changes(
                    Args,
                    Callback,
                    UserAcc2,
                    Db,
                    StartSeq,
                    <<"">>,
                    Timeout,
                    TimeoutFun
                )
            after
                couch_db_update_notifier:stop(Notify),
                get_rest_db_updated(ok) % clean out any remaining update messages
            end
        end;
    true ->
        fun(CallbackAcc) ->
            {Callback, UserAcc} = get_callback_acc(CallbackAcc),
            UserAcc2 = start_sending_changes(Callback, UserAcc, Feed),
            {ok, {_, LastSeq, _Prepend, _, _, UserAcc3, _, _, _, _}} =
                send_changes(
                    Args#changes_args{feed="normal"},
                    Callback,
                    UserAcc2,
                    Db,
                    StartSeq,
                    <<>>
                ),
            end_sending_changes(Callback, UserAcc3, LastSeq, Feed)
        end
    end.

get_callback_acc({Callback, _UserAcc} = Pair) when is_function(Callback, 3) ->
    Pair;
get_callback_acc(Callback) when is_function(Callback, 2) ->
    {fun(Ev, Data, _) -> Callback(Ev, Data) end, ok}.

%% @spec make_filter_fun(string(), main_only|all_docs, #httpd{} | {json_req,
%%      {[any()]}}, #db{}) -> fun()
make_filter_fun([$_ | _] = FilterName, Style, Req, Db) ->
    builtin_filter_fun(FilterName, Style, Req, Db);
make_filter_fun(FilterName, Style, Req, Db) ->
    os_filter_fun(FilterName, Style, Req, Db).

os_filter_fun(FilterName, Style, Req, Db) ->
    case [list_to_binary(couch_httpd:unquote(Part))
            || Part <- string:tokens(FilterName, "/")] of
    [] ->
        fun(_Db2, #doc_info{revs=Revs}) ->
                builtin_results(Style, Revs)
        end;
    [DName, FName] ->
        DesignId = <<"_design/", DName/binary>>,
        DDoc = couch_httpd_db:couch_doc_open(Db, DesignId, nil, []),
        % validate that the ddoc has the filter fun
        #doc{body={Props}} = DDoc,
        couch_util:get_nested_json_value({Props}, [<<"filters">>, FName]),
        fun(Db2, DocInfo) ->
            DocInfos =
            case Style of
            main_only ->
                [DocInfo];
            all_docs ->
                [DocInfo#doc_info{revs=[Rev]}|| Rev <- DocInfo#doc_info.revs]
            end,
            Docs = [Doc || {ok, Doc} <- [
                    couch_db:open_doc(Db2, DocInfo2, [deleted, conflicts])
                        || DocInfo2 <- DocInfos]],
            {ok, Passes} = couch_query_servers:filter_docs(
                Req, Db2, DDoc, FName, Docs
            ),
            [{[{<<"rev">>, couch_doc:rev_to_str({RevPos,RevId})}]}
                || {Pass, #doc{revs={RevPos,[RevId|_]}}}
                <- lists:zip(Passes, Docs), Pass == true]
            end;
    _Else ->
        throw({bad_request,
            "filter parameter must be of the form `designname/filtername`"})
    end.

builtin_filter_fun("_doc_ids", Style, {json_req, {Props}}, _Db) ->
    filter_docids(couch_util:get_value(<<"doc_ids">>, Props), Style);
builtin_filter_fun("_doc_ids", Style, #httpd{method='POST'}=Req, _Db) ->
    {Props} = couch_httpd:json_body_obj(Req),
    DocIds =  couch_util:get_value(<<"doc_ids">>, Props, nil),
    filter_docids(DocIds, Style);
builtin_filter_fun("_doc_ids", Style, #httpd{method='GET'}=Req, _Db) ->
    DocIds = ?JSON_DECODE(couch_httpd:qs_value(Req, "doc_ids", "null")),
    filter_docids(DocIds, Style);
builtin_filter_fun("_design", Style, _Req, _Db) ->
    filter_designdoc(Style);
builtin_filter_fun(_FilterName, _Style, _Req, _Db) ->
    throw({bad_request, "unknown builtin filter name"}).

filter_docids(DocIds, Style) when is_list(DocIds)->
    fun(_Db, #doc_info{id=DocId, revs=Revs}) ->
            case lists:member(DocId, DocIds) of
                true ->
                    builtin_results(Style, Revs);
                _ -> []
            end
    end;
filter_docids(_, _) ->
    throw({bad_request, "`doc_ids` filter parameter is not a list."}).

filter_designdoc(Style) ->
    fun(_Db, #doc_info{id=DocId, revs=Revs}) ->
            case DocId of
            <<"_design", _/binary>> ->
                    builtin_results(Style, Revs);
                _ -> []
            end
    end.

builtin_results(Style, [#rev_info{rev=Rev}|_]=Revs) ->
    case Style of
        main_only ->
            [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]}];
        all_docs ->
            [{[{<<"rev">>, couch_doc:rev_to_str(R)}]}
                || #rev_info{rev=R} <- Revs]
    end.

configure_filter(Filter, Style, Req, Db) when is_list(Filter) ->
    case [?l2b(couch_httpd:unquote(X)) || X <- string:tokens(Filter, "/")] of
    [] ->
        % fall back to standard filter
        Style;
    [DName, FName] ->
        JsonReq = chttpd_external:json_req_obj(Req, Db),
        DesignId = <<"_design/", DName/binary>>,
        DDoc = chttpd_db:couch_doc_open(Db, DesignId, nil, []),
        % validate that the ddoc has the filter fun
        #doc{body={Props}} = DDoc,
        couch_util:get_nested_json_value({Props}, [<<"filters">>, FName]),
        {custom, Style, {Db, JsonReq, DDoc, FName}};
    [<<"_doc_ids">>] ->
        DocIds = ?JSON_DECODE(couch_httpd:qs_value(Req, "doc_ids", "null")),
        case is_list(DocIds) of
            true -> ok;
            false -> throw({bad_request, "`doc_ids` filter parameter is not a list."})
        end,
        {builtin, Style, {doc_ids, DocIds}};
    [<<"_design">>] ->
        {builtin, Style, design};
    [<<"_", _/binary>>] ->
        throw({bad_request, "unknown builtin filter name"});
    _Else ->
        throw({bad_request,
            "filter parameter must be of the form `designname/filtername`"})
    end;
configure_filter(_, Style, _, _) ->
    Style.

filter(#doc_info{revs=[#rev_info{rev=Rev}|_]}, main_only) ->
    [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]}];
filter(#doc_info{revs=Revs}, all_docs) ->
    [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]} || #rev_info{rev=Rev} <- Revs];
filter(#doc_info{id=Id, revs=RevInfos}, {custom, main_only, Acc}) ->
    custom_filter(Id, [(hd(RevInfos))#rev_info.rev], Acc);
filter(#doc_info{id=Id, revs=RevInfos}, {custom, all_docs, Acc}) ->
    custom_filter(Id, [R || #rev_info{rev=R} <- RevInfos], Acc);
filter(#doc_info{id=Id, revs=RevInfos}, {builtin, main_only, Acc}) ->
    builtin_filter(Id, [(hd(RevInfos))#rev_info.rev], Acc);
filter(#doc_info{id=Id, revs=RevInfos}, {builtin, all_docs, Acc}) ->
    builtin_filter(Id, [R || #rev_info{rev=R} <- RevInfos], Acc).

custom_filter(Id, Revs, {Db, JsonReq, DDoc, Filter}) ->
    {ok, Results} = fabric:open_revs(Db, Id, Revs, [deleted, conflicts]),
    Docs = [Doc || {ok, Doc} <- Results],
    {ok, Passes} = couch_query_servers:filter_docs({json_req,JsonReq}, Db,
        DDoc, Filter, Docs),
    % ?LOG_INFO("filtering ~p ~p", [Id, Passes]),
    [{[{<<"rev">>, couch_doc:rev_to_str({RevPos,RevId})}]}
        || {Pass, #doc{revs={RevPos,[RevId|_]}}}
        <- lists:zip(Passes, Docs), Pass == true].

builtin_filter(Id, Revs, design) ->
    case Id of
        <<"_design", _/binary>> ->
            [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]} || Rev <- Revs];
        _ ->
            []
    end;
builtin_filter(Id, Revs, {doc_ids, DocIds}) ->
    case lists:member(Id, DocIds) of
        true ->
            [{[{<<"rev">>, couch_doc:rev_to_str(Rev)}]} || Rev <- Revs];
        false ->
            []
    end.

get_changes_timeout(Args, Callback) ->
    #changes_args{
        heartbeat = Heartbeat,
        timeout = Timeout,
        feed = ResponseType
    } = Args,
    DefaultTimeout = list_to_integer(
        couch_config:get("httpd", "changes_timeout", "60000")
    ),
    case Heartbeat of
    undefined ->
        case Timeout of
        undefined ->
            {DefaultTimeout, fun(UserAcc) -> {stop, UserAcc} end};
        infinity ->
            {infinity, fun(UserAcc) -> {stop, UserAcc} end};
        _ ->
            {lists:min([DefaultTimeout, Timeout]),
                fun(UserAcc) -> {stop, UserAcc} end}
        end;
    true ->
        {DefaultTimeout,
            fun(UserAcc) -> {ok, Callback(timeout, ResponseType, UserAcc)} end};
    _ ->
        {lists:min([DefaultTimeout, Heartbeat]),
            fun(UserAcc) -> {ok, Callback(timeout, ResponseType, UserAcc)} end}
    end.

start_sending_changes(_Callback, UserAcc, "continuous") ->
    UserAcc;
start_sending_changes(Callback, UserAcc, ResponseType) ->
    Callback(start, ResponseType, UserAcc).

send_changes(Args, Callback, UserAcc, Db, StartSeq, Prepend) ->
    #changes_args{
        style = Style,
        include_docs = IncludeDocs,
        conflicts = Conflicts,
        limit = Limit,
        feed = ResponseType,
        dir = Dir,
        filter = FilterFun
    } = Args,
    couch_db:changes_since(
        Db,
        Style,
        StartSeq,
        fun changes_enumerator/2,
        [{dir, Dir}],
        {Db, StartSeq, Prepend, FilterFun, Callback, UserAcc, ResponseType,
            Limit, IncludeDocs, Conflicts}
    ).

keep_sending_changes(Args, Callback, UserAcc, Db, StartSeq, Prepend, Timeout,
    TimeoutFun) ->
    #changes_args{
        feed = ResponseType,
        limit = Limit,
        db_open_options = DbOptions
    } = Args,
    % ?LOG_INFO("send_changes start ~p",[StartSeq]),
    {ok, {_, EndSeq, Prepend2, _, _, UserAcc2, _, NewLimit, _, _}} = send_changes(
        Args#changes_args{dir=fwd}, Callback, UserAcc, Db, StartSeq, Prepend
    ),
    % ?LOG_INFO("send_changes last ~p",[EndSeq]),
    couch_db:close(Db),
    if Limit > NewLimit, ResponseType == "longpoll" ->
        end_sending_changes(Callback, UserAcc2, EndSeq, ResponseType);
    true ->
        case wait_db_updated(Timeout, TimeoutFun, UserAcc2) of
        {updated, UserAcc3} ->
            % ?LOG_INFO("wait_db_updated updated ~p",[{Db#db.name, EndSeq}]),
            DbOptions1 = [{user_ctx, Db#db.user_ctx} | DbOptions],
            case couch_db:open(Db#db.name, DbOptions1) of
            {ok, Db2} ->
                keep_sending_changes(
                    Args#changes_args{limit=NewLimit},
                    Callback,
                    UserAcc3,
                    Db2,
                    EndSeq,
                    Prepend2,
                    Timeout,
                    TimeoutFun
                );
            _Else ->
                end_sending_changes(Callback, UserAcc2, EndSeq, ResponseType)
            end;
        {stop, UserAcc3} ->
            % ?LOG_INFO("wait_db_updated stop ~p",[{Db#db.name, EndSeq}]),
            end_sending_changes(Callback, UserAcc3, EndSeq, ResponseType)
        end
    end.

end_sending_changes(Callback, UserAcc, EndSeq, ResponseType) ->
    Callback({stop, EndSeq}, ResponseType, UserAcc).

changes_enumerator(DocInfo, {Db, _, _, FilterFun, Callback, UserAcc,
    "continuous", Limit, IncludeDocs, Conflicts}) ->

    #doc_info{high_seq = Seq} = DocInfo,
    Results0 = FilterFun(Db, DocInfo),
    Results = [Result || Result <- Results0, Result /= null],
    Go = if Limit =< 1 -> stop; true -> ok end,
    case Results of
    [] ->
        {Go, {Db, Seq, nil, FilterFun, Callback, UserAcc, "continuous", Limit,
                IncludeDocs, Conflicts}
        };
    _ ->
        ChangesRow = changes_row(Db, Results, DocInfo, IncludeDocs, Conflicts),
        UserAcc2 = Callback({change, ChangesRow, <<>>}, "continuous", UserAcc),
        {Go, {Db, Seq, nil, FilterFun, Callback, UserAcc2, "continuous",
                Limit - 1, IncludeDocs, Conflicts}
        }
    end;
changes_enumerator(DocInfo, {Db, _, Prepend, FilterFun, Callback, UserAcc,
    ResponseType, Limit, IncludeDocs, Conflicts}) ->

    #doc_info{high_seq = Seq} = DocInfo,
    Results0 = FilterFun(Db, DocInfo),
    Results = [Result || Result <- Results0, Result /= null],
    Go = if (Limit =< 1) andalso Results =/= [] -> stop; true -> ok end,
    case Results of
    [] ->
        {Go, {Db, Seq, Prepend, FilterFun, Callback, UserAcc, ResponseType,
                Limit, IncludeDocs, Conflicts}
        };
    _ ->
        ChangesRow = changes_row(Db, Results, DocInfo, IncludeDocs, Conflicts),
        UserAcc2 = Callback({change, ChangesRow, Prepend}, ResponseType, UserAcc),
        {Go, {Db, Seq, <<",\n">>, FilterFun, Callback, UserAcc2, ResponseType,
                Limit - 1, IncludeDocs, Conflicts}
        }
    end.


changes_row(Db, Results, DocInfo, IncludeDoc, Conflicts) ->
    #doc_info{
        id = Id, high_seq = Seq, revs = [#rev_info{deleted = Del} | _]
    } = DocInfo,
    {[{<<"seq">>, Seq}, {<<"id">>, Id}, {<<"changes">>, Results}] ++
        deleted_item(Del) ++ case IncludeDoc of
            true ->
                Options = if Conflicts -> [conflicts]; true -> [] end,
                couch_httpd_view:doc_member(Db, DocInfo, Options);
            false ->
                []
        end}.

deleted_item(true) -> [{<<"deleted">>, true}];
deleted_item(_) -> [].

% waits for a db_updated msg, if there are multiple msgs, collects them.
wait_db_updated(Timeout, TimeoutFun, UserAcc) ->
    receive
    db_updated ->
        get_rest_db_updated(UserAcc)
    after Timeout ->
        {Go, UserAcc2} = TimeoutFun(UserAcc),
        case Go of
        ok ->
            wait_db_updated(Timeout, TimeoutFun, UserAcc2);
        stop ->
            {stop, UserAcc2}
        end
    end.

get_rest_db_updated(UserAcc) ->
    receive
    db_updated ->
        get_rest_db_updated(UserAcc)
    after 0 ->
        {updated, UserAcc}
    end.

get_rest_db_updated() ->
    receive db_updated -> get_rest_db_updated()
    after 0 -> updated
    end.
