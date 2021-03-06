%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc Web server for menelaus.

-module(menelaus_web).

-author('NorthScale <info@northscale.com>').

% -behavior(ns_log_categorizing).
% the above is commented out because of the way the project is structured

-include_lib("eunit/include/eunit.hrl").

-include("menelaus_web.hrl").
-include("ns_common.hrl").
-include("ns_heart.hrl").
-include("ns_stats.hrl").
-include("rbac.hrl").

-ifdef(EUNIT).
-export([test/0]).
-endif.

-export([start_link/0,
         start_link/1,
         stop/0,
         loop/2,
         webconfig/0,
         webconfig/1,
         restart/0,
         build_node_hostname/3,
         build_nodes_info/0,
         build_nodes_info_fun/4,
         build_full_node_info/2,
         handle_streaming/3,
         maybe_cleanup_old_buckets/0,
         find_node_hostname/2,
         build_bucket_auto_compaction_settings/1,
         parse_validate_auto_compaction_settings/2,
         parse_validate_boolean_field/3,
         is_xdcr_over_ssl_allowed/0,
         assert_is_enterprise/0,
         assert_is_40/0,
         assert_is_45/0,
         assert_is_spock/0]).

-export([ns_log_cat/1, ns_log_code_string/1, alert_key/1]).

-export([handle_streaming_wakeup/4,
         handle_pool_info_wait_wake/4]).

%% for /diag
-export([build_internal_settings_kvs/0]).

-import(menelaus_util,
        [redirect_permanently/2,
         bin_concat_path/1,
         bin_concat_path/2,
         reply/2,
         reply/3,
         reply_text/3,
         reply_text/4,
         reply_ok/3,
         reply_ok/4,
         reply_json/2,
         reply_json/3,
         reply_json/4,
         reply_not_found/1,
         get_option/2,
         parse_validate_number/3,
         is_valid_positive_integer/1,
         is_valid_positive_integer_in_range/3,
         validate_boolean/2,
         validate_dir/2,
         validate_integer/2,
         validate_range/4,
         validate_range/5,
         validate_unsupported_params/1,
         validate_has_params/1,
         validate_any_value/2,
         validate_by_fun/3,
         execute_if_validated/3]).

-define(AUTO_FAILLOVER_MIN_TIMEOUT, 30).
-define(AUTO_FAILLOVER_MAX_TIMEOUT, 3600).
-define(PLUGGABLE_UI, "_p").

%% External API

start_link() ->
    start_link(webconfig()).

start_link(Options) ->
    {AppRoot, Options1} = get_option(approot, Options),
    Plugins = menelaus_pluggable_ui:find_plugins(),
    IsSSL = proplists:get_value(ssl, Options1, false),
    Loop = fun (Req) ->
                   ?MODULE:loop(Req, {AppRoot, IsSSL, Plugins})
           end,
    case mochiweb_http:start_link([{loop, Loop} | Options1]) of
        {ok, Pid} -> {ok, Pid};
        Other ->
            ?MENELAUS_WEB_LOG(?START_FAIL,
                              "Failed to start web service:  ~p~n", [Other]),
            Other
    end.

stop() ->
    % Note that a supervisor might restart us right away.
    mochiweb_http:stop(?MODULE).

restart() ->
    % Depend on our supervision tree to restart us right away.
    stop().

webconfig(Config) ->
    Ip = case os:getenv("MOCHIWEB_IP") of
             false -> "0.0.0.0";
             Any -> Any
         end,
    Port = case os:getenv("MOCHIWEB_PORT") of
               false ->
                   misc:node_rest_port(Config, node());
               P -> list_to_integer(P)
           end,
    WebConfig = [{ip, Ip},
                 {name, ?MODULE},
                 {port, Port},
                 {nodelay, true},
                 {approot, menelaus_deps:local_path(["priv","public"],
                                                    ?MODULE)}],
    WebConfig.

webconfig() ->
    webconfig(ns_config:get()).

loop(Req, Config) ->
    ok = menelaus_sup:barrier_wait(),

    random:seed(os:timestamp()),

    try
        %% Using raw_path so encoded slash characters like %2F are handed correctly,
        %% in that we delay converting %2F's to slash characters until after we split by slashes.
        "/" ++ RawPath = Req:get(raw_path),
        {Path, _, _} = mochiweb_util:urlsplit_path(RawPath),
        PathTokens = lists:map(fun mochiweb_util:unquote/1, string:tokens(Path, "/")),

        case is_throttled_request(PathTokens) of
            false ->
                loop_inner(Req, Config, Path, PathTokens);
            true ->
                request_throttler:request(
                  rest,
                  fun () ->
                          loop_inner(Req, Config, Path, PathTokens)
                  end,
                  fun (_Error, Reason) ->
                          Retry = integer_to_list(random:uniform(10)),
                          reply_text(Req, Reason, 503, [{"Retry-After", Retry}])
                  end)
        end
    catch
        exit:normal ->
            %% this happens when the client closed the connection
            exit(normal);
        throw:{web_exception, StatusCode, Message, ExtraHeaders} ->
            reply_text(Req, Message, StatusCode, ExtraHeaders);
        Type:What ->
            Report = ["web request failed",
                      {path, Req:get(path)},
                      {method, Req:get(method)},
                      {type, Type}, {what, What},
                      {trace, erlang:get_stacktrace()}], % todo: find a way to enable this for field info gathering
            ?log_error("Server error during processing: ~p", [Report]),
            reply_json(Req, [list_to_binary("Unexpected server error, request logged.")], 500)
    end.

is_throttled_request(["internalSettings"]) ->
    false;
is_throttled_request(["diag" | _]) ->
    false;
is_throttled_request(["couchBase" | _]) ->      % this gets throttled as capi request
    false;
%% this gets throttled via capi too
is_throttled_request(["pools", _, "buckets", _BucketId, "docs"]) ->
    false;
is_throttled_request([?PLUGGABLE_UI | _]) ->
    %% Requests for pluggable UI is not throttled here.
    %% If necessary it is done in the service node.
    false;
is_throttled_request(_) ->
    true.

-type action() :: {done, term()} |
                  {local, fun()} |
                  {ui, boolean(), fun()} |
                  {ui, boolean(), fun(), [term()]} |
                  {rbac_permission() | no_check, fun()} |
                  {rbac_permission() | no_check, fun(), [term()]}.

-spec get_action(mochiweb_request(), {term(), boolean(), term()}, string(), [string()]) -> action().
get_action(Req, {AppRoot, IsSSL, Plugins}, Path, PathTokens) ->
    case Req:get(method) of
        Method when Method =:= 'GET'; Method =:= 'HEAD' ->
            case PathTokens of
                [] ->
                    {done, redirect_permanently("/ui/index.html", Req)};
                ["versions"] ->
                    {done, handle_versions(Req)};
                ["whoami"] ->
                    {no_check, fun menelaus_web_rbac:handle_whoami/1};
                ["pools"] ->
                    {{[pools], read}, fun handle_pools/1};
                ["pools", "default"] ->
                    {{[pools], read}, fun check_and_handle_pool_info/2, ["default"]};
                %% NOTE: see MB-10859. Our docs used to
                %% recommend doing this which due to old
                %% code's leniency worked just like
                %% /pools/default. So temporarily we allow
                %% /pools/nodes to be alias for
                %% /pools/default
                ["pools", "nodes"] ->
                    {{[pools], read}, fun check_and_handle_pool_info/2, ["default"]};
                ["pools", "default", "overviewStats"] ->
                    {{[{bucket, any}, stats], read}, fun menelaus_stats:handle_overview_stats/2, ["default"]};
                ["_uistats"] ->
                    {{[stats], read}, fun menelaus_stats:serve_ui_stats/1};
                ["_uiEnv"] ->
                    {done, serve_ui_env(Req)};
                ["poolsStreaming", "default"] ->
                    {{[pools], read}, fun handle_pool_info_streaming/2, ["default"]};
                ["pools", "default", "buckets"] ->
                    {{[{bucket, any}, settings], read}, fun menelaus_web_buckets:handle_bucket_list/1, []};
                ["pools", "default", "saslBucketsStreaming"] ->
                    {{[admin, buckets], read},
                     fun menelaus_web_buckets:handle_sasl_buckets_streaming/2,
                     ["default"]};
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_buckets:handle_bucket_info/3,
                     ["default", Id]};
                ["pools", "default", "bucketsStreaming", Id] ->
                    {{[{bucket, Id}, settings], read},
                     fun menelaus_web_buckets:handle_bucket_info_streaming/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "ddocs"] ->
                    {{[{bucket, Id}, views], read},
                     fun menelaus_web_buckets:handle_ddocs_list/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "docs"] ->
                    {{[{bucket, Id}, data], read},
                     fun menelaus_web_crud:handle_list/2, [Id]};
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data], read},
                     fun menelaus_web_crud:handle_get/3, [Id, DocId]};
                ["pools", "default", "buckets", "@query", "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", "@query"]};
                ["pools", "default", "buckets", "@xdcr-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", "@index-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", "@fts-" ++ _ = Id, "stats"] ->
                    {{[stats], read},
                     fun menelaus_stats:handle_stats_section/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "stats"] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_bucket_stats/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "localRandomKey"] ->
                    {{[{bucket, Id}, data], read},
                     fun menelaus_web_buckets:handle_local_random_key/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "statsDirectory"] ->
                    {{[{bucket, Id}, stats], read}, fun menelaus_stats:serve_stats_directory/3,
                     ["default", Id]};
                ["pools", "default", "nodeServices"] ->
                    {{[pools], read}, fun serve_node_services/1, []};
                ["pools", "default", "nodeServicesStreaming"] ->
                    {{[pools], read}, fun serve_node_services_streaming/1, []};
                ["pools", "default", "b", BucketName] ->
                    {{[{bucket, BucketName}, settings], read},
                     fun serve_short_bucket_info/3,
                     ["default", BucketName]};
                ["pools", "default", "bs", BucketName] ->
                    {{[{bucket, BucketName}, settings], read},
                     fun serve_streaming_short_bucket_info/3,
                     ["default", BucketName]};
                ["pools", "default", "buckets", Id, "nodes"] ->
                    {{[{bucket, Id}, settings], read},
                     fun handle_bucket_node_list/3,
                     ["default", Id]};
                ["pools", "default", "buckets", Id, "nodes", NodeId] ->
                    {{[{bucket, Id}, settings], read},
                     fun handle_bucket_node_info/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", "@query", "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", "@query", NodeId]};
                ["pools", "default", "buckets", "@xdcr-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", "@index-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", "@fts-" ++ _ = Id, "nodes", NodeId, "stats"] ->
                    {{[stats], read}, fun menelaus_stats:handle_stats_section_for_node/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", Id, "nodes", NodeId, "stats"] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_bucket_node_stats/4,
                     ["default", Id, NodeId]};
                ["pools", "default", "buckets", Id, "stats", StatName] ->
                    {{[{bucket, Id}, stats], read},
                     fun menelaus_stats:handle_specific_stat_for_buckets/4,
                     ["default", Id, StatName]};
                ["pools", "default", "buckets", Id, "recoveryStatus"] ->
                    {{[{bucket, Id}, recovery], read},
                     fun menelaus_web_recovery:handle_recovery_status/3,
                     ["default", Id]};
                ["pools", "default", "remoteClusters"] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], read},
                      fun menelaus_web_remote_clusters:handle_remote_clusters/1);
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], read},
                     fun menelaus_web_groups:handle_server_groups/1};
                ["pools", "default", "certificate"] ->
                    {done, menelaus_web_cert:handle_cluster_certificate(Req)};
                ["pools", "default", "certificate", "node", Node] ->
                    {{[admin, security], read},
                     fun menelaus_web_cert:handle_get_node_certificate/2, [Node]};
                ["pools", "default", "settings", "memcached", "global"] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_global_get/1};
                ["pools", "default", "settings", "memcached", "effective", Node] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_effective_get/2, [Node]};
                ["pools", "default", "settings", "memcached", "node", Node] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_node_get/2, [Node]};
                ["pools", "default", "settings", "memcached", "node", Node, "setting", Name] ->
                    {{[admin, memcached], read}, fun menelaus_web_mcd_settings:handle_node_setting_get/3, [Node, Name]};
                ["nodeStatuses"] ->
                    {{[nodes], read}, fun handle_node_statuses/1};
                ["logs"] ->
                    {{[logs], read}, fun menelaus_alert:handle_logs/1};
                ["settings", "web"] ->
                    {{[settings], read}, fun handle_settings_web/1};
                ["settings", "alerts"] ->
                    {{[settings], read}, fun handle_settings_alerts/1};
                ["settings", "stats"] ->
                    {{[settings], read}, fun handle_settings_stats/1};
                ["settings", "autoFailover"] ->
                    {{[settings], read}, fun handle_settings_auto_failover/1};
                ["settings", "maxParallelIndexers"] ->
                    {{[indexes], read}, fun handle_settings_max_parallel_indexers/1};
                ["settings", "viewUpdateDaemon"] ->
                    {{[indexes], read}, fun handle_settings_view_update_daemon/1};
                ["settings", "autoCompaction"] ->
                    {{[settings], read}, fun handle_settings_auto_compaction/1};
                ["settings", "readOnlyAdminName"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_settings_read_only_admin_name/1};
                ["settings", "replications"] ->
                    goxdcr_rest:spec(
                      {[xdcr, settings], read},
                      fun menelaus_web_xdc_replications:handle_global_replication_settings/1);
                ["settings", "replications", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], read},
                      fun menelaus_web_xdc_replications:handle_replication_settings/2, [XID]);
                ["settings", "saslauthdAuth"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_saslauthd_auth_settings/1};
                ["settings", "audit"] ->
                    {{[admin, security], read},
                     fun handle_settings_audit/1};
                ["settings", "rbac", "roles"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_roles/1};
                ["settings", "rbac", "users"] ->
                    {{[admin, security], read},
                     fun menelaus_web_rbac:handle_get_users/1};
                ["internalSettings"] ->
                    {{[admin, settings], read},
                     fun handle_internal_settings/1};
                ["nodes", NodeId] ->
                    {{[nodes], read}, fun handle_node/2, [NodeId]};
                ["nodes", "self", "xdcrSSLPorts"] ->
                    {done, handle_node_self_xdcr_ssl_ports(Req)};
                ["indexStatus"] ->
                    {{[indexes], read}, fun menelaus_web_indexes:handle_index_status/1};
                ["settings", "indexes"] ->
                    {{[indexes], read}, fun menelaus_web_indexes:handle_settings_get/1};
                ["diag"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag/1, []};
                ["diag", "vbuckets"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_vbuckets/1};
                ["diag", "ale"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_ale/1};
                ["diag", "masterEvents"] ->
                    {{[admin, diag], read}, fun diag_handler:handle_diag_master_events/1};
                ["diag", "password"] ->
                    {local, fun diag_handler:handle_diag_get_password/1};
                ["pools", "default", "rebalanceProgress"] ->
                    {{[tasks], read}, fun handle_rebalance_progress/2, ["default"]};
                ["pools", "default", "tasks"] ->
                    {{[tasks], read}, fun handle_tasks/2, ["default"]};
                ["index.html"] ->
                    {done, redirect_permanently("/ui/index.html", Req)};
                ["ui", "index.html"] ->
                    {ui, IsSSL, fun handle_ui_root/5, [AppRoot, Path, ?SPOCK_VERSION_NUM,
                                                       Plugins]};
                ["ui", "classic-index.html"] ->
                    {ui, IsSSL, fun handle_ui_root/5, [AppRoot, Path, ?VERSION_45,
                                                       Plugins]};
                ["classic-index.html"] ->
                    {ui, IsSSL, fun handle_ui_root/5, [AppRoot, Path, ?VERSION_41, []]};
                ["dot", Bucket] ->
                    {{[{bucket, Bucket}, settings], read}, fun handle_dot/2, [Bucket]};
                ["dotsvg", Bucket] ->
                    {{[{bucket, Bucket}, settings], read}, fun handle_dotsvg/2, [Bucket]};
                ["sasl_logs"] ->
                    {{[admin, logs], read}, fun diag_handler:handle_sasl_logs/1, []};
                ["sasl_logs", LogName] ->
                    {{[admin, logs], read}, fun diag_handler:handle_sasl_logs/2, [LogName]};
                ["images" | _] ->
                    {done, menelaus_util:serve_file(Req, Path, AppRoot,
                                                    [{"Cache-Control", "max-age=30000000"}])};
                ["couchBase" | _] -> {no_check,
                                      fun menelaus_pluggable_ui:proxy_req/4,
                                      ["couchBase",
                                       drop_prefix(Req:get(raw_path)),
                                       Plugins]};
                ["sampleBuckets"] -> {{[samples], read}, fun handle_sample_buckets/1};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_get/2, [Path]};
                ["_goxdcr", "controller", "bucketSettings", _Bucket] ->
                    XdcrPath = drop_prefix(Req:get(raw_path)),
                    {{[admin, internal], all},
                     fun goxdcr_rest:get_controller_bucket_settings/2, [XdcrPath]};
                ["_cbauth", "checkPermission"] ->
                    {{[admin, internal], all},
                     fun menelaus_web_rbac:handle_check_permission_for_cbauth/1};
                [?PLUGGABLE_UI, "ui", RestPrefix | _] ->
                    {done, menelaus_pluggable_ui:maybe_serve_file(
                             RestPrefix, Plugins, Req,
                             nth_path_tail(Path, 3))};

                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    {done, menelaus_util:serve_file(
                             Req, Path, AppRoot,
                             [{"Cache-Control", "max-age=10"}])}
            end;
        'POST' ->
            case PathTokens of
                ["uilogin"] ->
                    {ui, IsSSL, fun handle_uilogin/1};
                ["uilogout"] ->
                    {done, handle_uilogout(Req)};
                ["sampleBuckets", "install"] ->
                    {{[buckets], create}, fun handle_post_sample_buckets/1};
                ["engageCluster2"] ->
                    {{[admin, setup], write}, fun handle_engage_cluster2/1};
                ["completeJoin"] ->
                    {{[admin, setup], write}, fun handle_complete_join/1};
                ["node", "controller", "doJoinCluster"] ->
                    {{[admin, setup], write}, fun handle_join/1};
                ["node", "controller", "doJoinClusterV2"] ->
                    {{[admin, setup], write}, fun handle_join/1};
                ["node", "controller", "rename"] ->
                    {{[admin, setup], write}, fun handle_node_rename/1};
                ["nodes", NodeId, "controller", "settings"] ->
                    {{[admin, setup], write}, fun handle_node_settings_post/2,
                     [NodeId]};
                ["node", "controller", "setupServices"] ->
                    {{[admin, setup], write}, fun handle_setup_services_post/1};
                ["node", "controller", "reloadCertificate"] ->
                    {{[admin, setup], write},
                     fun menelaus_web_cert:handle_reload_node_certificate/1};
                ["node", "controller", "changeMasterPassword"] ->
                    {{[admin, security], write},
                     fun menelaus_web_secrets:handle_change_master_password/1};
                ["node", "controller", "rotateDataKey"] ->
                    {{[admin, security], write},
                     fun menelaus_web_secrets:handle_rotate_data_key/1};
                ["settings", "web"] ->
                    {{[admin, setup], write}, fun handle_settings_web_post/1};
                ["settings", "alerts"] ->
                    {{[settings], write}, fun handle_settings_alerts_post/1};
                ["settings", "alerts", "testEmail"] ->
                    {{[settings], write}, fun handle_settings_alerts_send_test_email/1};
                ["settings", "stats"] ->
                    {{[settings], write}, fun handle_settings_stats_post/1};
                ["settings", "autoFailover"] ->
                    {{[settings], write}, fun handle_settings_auto_failover_post/1};
                ["settings", "autoFailover", "resetCount"] ->
                    {{[settings], write}, fun handle_settings_auto_failover_reset_count/1};
                ["settings", "maxParallelIndexers"] ->
                    {{[indexes], write}, fun handle_settings_max_parallel_indexers_post/1};
                ["settings", "viewUpdateDaemon"] ->
                    {{[indexes], write}, fun handle_settings_view_update_daemon_post/1};
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_settings_read_only_user_post/1};
                ["settings", "replications"] ->
                    goxdcr_rest:spec(
                      {[xdcr, settings], write},
                      fun menelaus_web_xdc_replications:handle_global_replication_settings_post/1);
                ["settings", "replications", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], [write, execute]},
                      fun menelaus_web_xdc_replications:handle_replication_settings_post/2, [XID]);
                ["settings", "saslauthdAuth"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_saslauthd_auth_settings_post/1};
                ["settings", "audit"] ->
                    {{[admin, security], write},
                     fun handle_settings_audit_post/1};
                ["validateCredentials"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_validate_saslauthd_creds_post/1};
                ["internalSettings"] ->
                    {{[admin, settings], write},
                     fun handle_internal_settings_post/1};
                ["pools", "default"] ->
                    {{[pools], write}, fun handle_pool_settings_post/1};
                ["controller", "ejectNode"] ->
                    {{[pools], write}, fun handle_eject_post/1};
                ["controller", "addNode"] ->
                    {{[pools], write}, fun handle_add_node/1};
                ["controller", "addNodeV2"] ->
                    {{[pools], write}, fun handle_add_node/1};
                ["pools", "default", "serverGroups", UUID, "addNode"] ->
                    {{[pools], write}, fun handle_add_node_to_group/2, [UUID]};
                ["pools", "default", "serverGroups", UUID, "addNodeV2"] ->
                    {{[pools], write}, fun handle_add_node_to_group/2, [UUID]};
                ["controller", "failOver"] ->
                    {{[pools], write}, fun handle_failover/1};
                ["controller", "startGracefulFailover"] ->
                    {{[pools], write}, fun handle_start_graceful_failover/1};
                ["controller", "rebalance"] ->
                    {{[pools], write}, fun handle_rebalance/1};
                ["controller", "reAddNode"] ->
                    {{[pools], write}, fun handle_re_add_node/1};
                ["controller", "reFailOver"] ->
                    {{[pools], write}, fun handle_re_failover/1};
                ["controller", "stopRebalance"] ->
                    {{[pools], write}, fun handle_stop_rebalance/1};
                ["controller", "setRecoveryType"] ->
                    {{[pools], write}, fun handle_set_recovery_type/1};
                ["controller", "setAutoCompaction"] ->
                    {{[settings], write}, fun handle_set_autocompaction/1};
                ["controller", "createReplication"] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_create_replication/1);
                ["controller", "cancelXDCR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID]);
                ["controller", "cancelXCDR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID],
                      menelaus_util:concat_url_path(["controller", "cancelXDCR", XID]));
                ["controller", "resetAlerts"] ->
                    {{[settings], write}, fun handle_reset_alerts/1};
                ["controller", "regenerateCertificate"] ->
                    {{[admin, security], write},
                     fun menelaus_web_cert:handle_regenerate_certificate/1};
                ["controller", "uploadClusterCA"] ->
                    {{[admin, security], write},
                     fun menelaus_web_cert:handle_upload_cluster_ca/1};
                ["controller", "startLogsCollection"] ->
                    {{[admin, logs], read},
                     fun menelaus_web_cluster_logs:handle_start_collect_logs/1};
                ["controller", "cancelLogsCollection"] ->
                    {{[admin, logs], read},
                     fun menelaus_web_cluster_logs:handle_cancel_collect_logs/1};
                ["controller", "resetAdminPassword"] ->
                    {local, fun menelaus_web_rbac:handle_reset_admin_password/1};
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}, settings], write},
                     fun menelaus_web_buckets:handle_bucket_update/3,
                     ["default", Id]};
                ["pools", "default", "buckets"] ->
                    {{[buckets], create},
                     fun menelaus_web_buckets:handle_bucket_create/2,
                     ["default"]};
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data], write},
                     fun menelaus_web_crud:handle_post/3, [Id, DocId]};
                ["pools", "default", "buckets", Id, "controller", "doFlush"] ->
                    {{[{bucket, Id}], flush},
                     fun menelaus_web_buckets:handle_bucket_flush/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "compactBucket"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_compact_bucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "unsafePurgeBucket"] ->
                    {{[{bucket, Id}], delete},
                     fun menelaus_web_buckets:handle_purge_compact_bucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "cancelBucketCompaction"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_cancel_bucket_compaction/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "compactDatabases"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_compact_databases/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "cancelDatabasesCompaction"] ->
                    {{[{bucket, Id}], compact},
                     fun menelaus_web_buckets:handle_cancel_databases_compaction/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "startRecovery"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_start_recovery/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "stopRecovery"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_stop_recovery/3, ["default", Id]};
                ["pools", "default", "buckets", Id, "controller", "commitVBucket"] ->
                    {{[{bucket, Id}, recovery], write},
                     fun menelaus_web_recovery:handle_commit_vbucket/3, ["default", Id]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "compactView"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_compact_view/4, ["default", Id, DDocId]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "cancelViewCompaction"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_cancel_view_compaction/4,
                     ["default", Id, DDocId]};
                ["pools", "default", "buckets", Id,
                 "ddocs", DDocId, "controller", "setUpdateMinChanges"] ->
                    {{[{bucket, Id}, views], compact},
                     fun menelaus_web_buckets:handle_set_ddoc_update_min_changes/4,
                     ["default", Id, DDocId]};
                ["pools", "default", "remoteClusters"] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_clusters_post/1);
                ["pools", "default", "remoteClusters", Id] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_cluster_update/2, [Id]);
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_groups_post/1};
                ["pools", "default", "settings", "memcached", "global"] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_global_post/1};
                ["pools", "default", "settings", "memcached", "node", Node] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_node_post/2, [Node]};
                ["pools", "default", "checkPermissions"] ->
                    {{[pools], read},
                     fun menelaus_web_rbac:handle_check_permissions_post/1};
                ["settings", "indexes"] ->
                    {{[indexes], write}, fun menelaus_web_indexes:handle_settings_post/1};
                ["_cbauth"] ->
                    {no_check, fun menelaus_cbauth:handle_cbauth_post/1};
                ["_log"] ->
                    {{[admin, internal], all}, fun handle_log_post/1};
                ["_goxdcr", "regexpValidation"] ->
                    goxdcr_rest:spec(
                      no_check,
                      fun menelaus_util:reply_not_found/1, [],
                      menelaus_util:concat_url_path(["controller", "regexpValidation"]));
                ["_goxdcr", "controller", "bucketSettings", _Bucket] ->
                    XdcrPath = drop_prefix(Req:get(raw_path)),
                    {{[admin, internal], all},
                     fun goxdcr_rest:post_controller_bucket_settings/2, [XdcrPath]};
                ["logClientError"] -> {no_check,
                                       fun (R) ->
                                               User = menelaus_auth:extract_auth_user(R),
                                               ?MENELAUS_WEB_LOG(?UI_SIDE_ERROR_REPORT,
                                                                 "Client-side error-report for user ~p on node ~p:~nUser-Agent:~s~n~s~n",
                                                                 [User, node(),
                                                                  Req:get_header_value("user-agent"), binary_to_list(R:recv_body())]),
                                               reply_ok(R, "text/plain", [])
                                       end};
                ["diag", "eval"] ->
                    {{[admin, diag], write}, fun diag_handler:handle_diag_eval/1};
                ["couchBase" | _] ->
                    {no_check, fun menelaus_pluggable_ui:proxy_req/4,
                     ["couchBase",
                      drop_prefix(Req:get(raw_path)),
                      Plugins]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0001, "Invalid post received: ~p", [Req]),
                    {done, reply_not_found(Req)}
            end;
        'DELETE' ->
            case PathTokens of
                ["pools", "default", "buckets", Id] ->
                    {{[{bucket, Id}], delete},
                     fun menelaus_web_buckets:handle_bucket_delete/3, ["default", Id]};
                ["pools", "default", "remoteClusters", Id] ->
                    goxdcr_rest:spec(
                      {[xdcr, remote_clusters], write},
                      fun menelaus_web_remote_clusters:handle_remote_cluster_delete/2, [Id]);
                ["pools", "default", "buckets", Id, "docs", DocId] ->
                    {{[{bucket, Id}, data], write},
                     fun menelaus_web_crud:handle_delete/3, [Id, DocId]};
                ["controller", "cancelXCDR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID],
                      menelaus_util:concat_url_path(["controller", "cancelXDCR", XID]));
                ["controller", "cancelXDCR", XID] ->
                    goxdcr_rest:spec(
                      {[{bucket, any}, xdcr], write},
                      fun menelaus_web_xdc_replications:handle_cancel_replication/2, [XID]);
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_read_only_user_delete/1};
                ["pools", "default", "serverGroups", GroupUUID] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_group_delete/2, [GroupUUID]};
                ["pools", "default", "settings", "memcached", "node", Node, "setting", Name] ->
                    {{[admin, memcached], write},
                     fun menelaus_web_mcd_settings:handle_node_setting_delete/3, [Node, Name]};
                ["settings", "rbac", "users", UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_delete_user/3, ["saslauthd", UserId]};
                ["settings", "rbac", "users", Type, UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_delete_user/3, [Type, UserId]};
                ["couchBase" | _] -> {no_check,
                                      fun menelaus_pluggable_ui:proxy_req/4,
                                      ["couchBase",
                                       drop_prefix(Req:get(raw_path)),
                                       Plugins]};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_delete/2, [Path]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0002, "Invalid delete received: ~p as ~p",
                                      [Req, PathTokens]),
                    {done, reply_text(Req, "Method Not Allowed", 405)}
            end;
        'PUT' = Method ->
            case PathTokens of
                ["settings", "readOnlyUser"] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_read_only_user_reset/1};
                ["pools", "default", "serverGroups"] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_groups_put/1};
                ["pools", "default", "serverGroups", GroupUUID] ->
                    {{[server_groups], write},
                     fun menelaus_web_groups:handle_server_group_update/2, [GroupUUID]};
                ["settings", "rbac", "users", UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_put_user/3, ["saslauthd", UserId]};
                ["settings", "rbac", "users", Type, UserId] ->
                    {{[admin, security], write},
                     fun menelaus_web_rbac:handle_put_user/3, [Type, UserId]};
                ["couchBase" | _] ->
                    {no_check, fun menelaus_pluggable_ui:proxy_req/4,
                     ["couchBase",
                      drop_prefix(Req:get(raw_path)),
                      Plugins]};
                ["_metakv" | _] ->
                    {{[admin, internal], all}, fun menelaus_metakv:handle_put/2, [Path]};
                [?PLUGGABLE_UI, RestPrefix | _] ->
                    {no_check,
                     fun (PReq) ->
                             menelaus_pluggable_ui:proxy_req(
                               RestPrefix,
                               drop_rest_prefix(Req:get(raw_path)),
                               Plugins, PReq)
                     end};
                _ ->
                    ?MENELAUS_WEB_LOG(0003, "Invalid ~p received: ~p", [Method, Req]),
                    {done, reply_text(Req, "Method Not Allowed", 405)}
            end;
        "RPCCONNECT" ->
            {{[admin, internal], all}, fun json_rpc_connection_sup:handle_rpc_connect/1};

        _ ->
            ?MENELAUS_WEB_LOG(0004, "Invalid request received: ~p", [Req]),
            {done, reply_text(Req, "Method Not Allowed", 405)}
    end.

serve_ui(Req, false, F, Args) ->
    case ns_config:read_key_fast(disable_ui_over_http, false) of
        true ->
            reply(Req, 404);
        false ->
            serve_ui(Req, true, F, Args)
    end;
serve_ui(Req, true, F, Args) ->
    apply(F, Args ++ [Req]).

use_minified(Req) ->
    Query = Req:parse_qs(),
    %% explicity specified minified in the query params
    %% overrides the application env value
    Minified = proplists:get_value("minified", Query),
    Minified =:= "true" orelse
        Minified =:= undefined andalso
        misc:get_env_default(use_minified, true).

serve_ui_env(Req) ->
    %% UI env values are expected to be unfolded proplists
    UIEnvDefault = lists:ukeysort(1, misc:get_env_default(ui_env, [])),
    GlobalUIEnv = lists:ukeysort(1, ns_config:read_key_fast(ui_env, [])),
    NodeSpecificUIEnv = lists:ukeysort(1, ns_config:read_key_fast({node, node(), ui_env}, [])),
    menelaus_util:reply_json(Req,
                             {lists:ukeymerge(1, NodeSpecificUIEnv,
                                              lists:ukeymerge(1, GlobalUIEnv, UIEnvDefault))}).

handle_ui_root(AppRoot, Path, UiCompatVersion, Plugins, Req)
  when UiCompatVersion =:= ?VERSION_45;
       UiCompatVersion =:= ?SPOCK_VERSION_NUM ->
    Filename = case UiCompatVersion =:= ?SPOCK_VERSION_NUM andalso use_minified(Req) of
                   true ->
                       filename:join([AppRoot, "ui", "index.min.html"]);
                   _ ->
                       filename:join(AppRoot, Path)
               end,
    menelaus_util:reply_ok(
      Req,
      "text/html; charset=utf8",
      menelaus_pluggable_ui:inject_head_fragments(Filename, UiCompatVersion, Plugins),
      [{"Cache-Control", "must-revalidate"}]);
handle_ui_root(AppRoot, Path, ?VERSION_41, [], Req) ->
    menelaus_util:serve_static_file(Req, {AppRoot, Path},
                                    "text/html; charset=utf8",
                                    [{"Cache-Control", "must-revalidate"}]).

loop_inner(Req, Info, Path, PathTokens) ->
    menelaus_auth:validate_request(Req),
    perform_action(Req, get_action(Req, Info, Path, PathTokens)).

require_auth(Req) ->
    case Req:get_header_value("invalid-auth-response") of
        "on" ->
            %% We need this for browsers that display auth
            %% dialog when faced with 401 with
            %% WWW-Authenticate header response, even via XHR
            menelaus_util:reply(Req, 401);
        _ ->
            menelaus_util:reply(Req, 401, [{"WWW-Authenticate",
                                            "Basic realm=\"Couchbase Server Admin / REST\""}])
    end.

-spec get_bucket_id(rbac_permission() | no_check) -> bucket_name() | false.
get_bucket_id(no_check) ->
    false;
get_bucket_id({Object, _Operations}) ->
    case lists:keyfind(bucket, 1, Object) of
        {bucket, any} ->
            false;
        {bucket, Bucket} ->
            Bucket;
        false ->
            false
    end.

-spec perform_action(mochiweb_request(), action()) -> term().
perform_action(_Req, {done, RV}) ->
    RV;
perform_action(Req, {local, Fun}) ->
    case menelaus_auth:verify_local_token(Req) of
        {allowed, NewReq} ->
            Fun(NewReq);
        auth_failure ->
            require_auth(Req)
    end;
perform_action(Req, {ui, IsSSL, Fun}) ->
    perform_action(Req, {ui, IsSSL, Fun, []});
perform_action(Req, {ui, IsSSL, Fun, Args}) ->
    serve_ui(Req, IsSSL, Fun, Args);
perform_action(Req, {Permission, Fun}) ->
    perform_action(Req, {Permission, Fun, []});
perform_action(Req, {Permission, Fun, Args}) ->
    case menelaus_auth:verify_rest_auth(Req, Permission) of
        {allowed, NewReq} ->
            case get_bucket_id(Permission) of
                false ->
                    check_uuid(Fun, Args, NewReq);
                Bucket ->
                    check_bucket_uuid(Bucket, fun check_uuid/3, [Fun, Args], NewReq)
            end;
        auth_failure ->
            require_auth(Req);
        forbidden ->
            menelaus_util:reply_json(Req, menelaus_web_rbac:forbidden_response(Permission), 403)
    end.

handle_uilogin(Req) ->
    Params = Req:parse_post(),
    User = proplists:get_value("user", Params),
    Password = proplists:get_value("password", Params),
    case menelaus_auth:verify_login_creds(User, Password) of
        {ok, Identity} ->
            menelaus_auth:complete_uilogin(Req, Identity);
        false ->
            menelaus_auth:reject_uilogin(Req, {User, rejected})
    end.

handle_uilogout(Req) ->
    case menelaus_auth:extract_ui_auth_token(Req) of
        undefined ->
            ok;
        Token ->
            menelaus_ui_auth:logout(Token)
    end,
    menelaus_auth:complete_uilogout(Req).

check_uuid(F, Args, Req) ->
    ReqUUID0 = proplists:get_value("uuid", Req:parse_qs()),
    case ReqUUID0 =/= undefined of
        true ->
            ReqUUID = list_to_binary(ReqUUID0),
            UUID = get_uuid(),
            %%
            %% get_uuid() will return empty UUID if the system is not
            %% provisioned yet. If ReqUUID is also empty then we let
            %% the request go through. But, if ReqUUID is not-empty
            %% and UUID is empty then we will retrun 404 error.
            %%
            case ReqUUID =:= UUID of
                true ->
                    erlang:apply(F, Args ++ [Req]);
                false ->
                    reply_text(Req, "Cluster uuid does not match the requested.\r\n", 404)
            end;
        false ->
            erlang:apply(F, Args ++ [Req])
    end.

check_bucket_uuid(Bucket, F, Args, Req) ->
    case ns_bucket:get_bucket(Bucket) of
        not_present ->
            ?log_debug("Attempt to access non existent bucket ~p", [Bucket]),
            reply_not_found(Req);
        {ok, BucketConfig} ->
            menelaus_web_buckets:checking_bucket_uuid(
              Req, BucketConfig,
              fun () ->
                      erlang:apply(F, Args ++ [Req])
              end)
    end.

%% Internal API
-define(SAMPLES_LOADING_TIMEOUT, 120000).
-define(SAMPLE_BUCKET_QUOTA_MB, 100).
-define(SAMPLE_BUCKET_QUOTA, 1024 * 1024 * ?SAMPLE_BUCKET_QUOTA_MB).

handle_sample_buckets(Req) ->

    Buckets = [Bucket || {Bucket, _} <- ns_bucket:get_buckets(ns_config:get())],

    Map = [ begin
                Name = filename:basename(Path, ".zip"),
                Installed = lists:member(Name, Buckets),
                {struct, [{name, list_to_binary(Name)},
                          {installed, Installed},
                          {quotaNeeded, ?SAMPLE_BUCKET_QUOTA}]}
            end || Path <- list_sample_files() ],

    reply_json(Req, Map).

handle_post_sample_buckets(Req) ->
    Samples = mochijson2:decode(Req:recv_body()),

    Errors = case validate_post_sample_buckets(Samples) of
                 ok ->
                     start_loading_samples(Req, Samples);
                 X1 ->
                     X1
             end,


    case Errors of
        ok ->
            reply_json(Req, [], 202);
        X2 ->
            reply_json(Req, [Msg || {error, Msg} <- X2], 400)
    end.

start_loading_samples(Req, Samples) ->
    Errors = [start_loading_sample(Req, binary_to_list(Sample))
              || Sample <- Samples],
    case [X || X <- Errors, X =/= ok] of
        [] ->
            ok;
        X ->
            lists:flatten(X)
    end.

start_loading_sample(Req, Name) ->
    Params = [{"threadsNumber", "3"},
              {"replicaIndex", "0"},
              {"replicaNumber", "1"},
              {"saslPassword", ""},
              {"authType", "sasl"},
              {"ramQuotaMB", integer_to_list(?SAMPLE_BUCKET_QUOTA_MB) },
              {"bucketType", "membase"},
              {"name", Name}],
    case menelaus_web_buckets:create_bucket(Req, Name, Params) of
        ok ->
            start_loading_sample_task(Req, Name);
        {_, Code} when Code < 300 ->
            start_loading_sample_task(Req, Name);
        {{struct, [{errors, {struct, Errors}}, _]}, _} ->
            ?log_debug("Failed to create sample bucket: ~p", [Errors]),
            [{error, <<"Failed to create bucket!">>} | [{error, Msg} || {_, Msg} <- Errors]];
        {{struct, [{'_', Error}]}, _} ->
            ?log_debug("Failed to create sample bucket: ~p", [Error]),
            [{error, Error}];
        X ->
            ?log_debug("Failed to create sample bucket: ~p", [X]),
            X
    end.

start_loading_sample_task(Req, Name) ->
    case samples_loader_tasks:start_loading_sample(Name, ?SAMPLE_BUCKET_QUOTA_MB) of
        ok ->
            ns_audit:start_loading_sample(Req, Name);
        already_started ->
            ok
    end,
    ok.

list_sample_files() ->
    BinDir = path_config:component_path(bin),
    filelib:wildcard(filename:join([BinDir, "..", "samples", "*.zip"])).


sample_exists(Name) ->
    BinDir = path_config:component_path(bin),
    filelib:is_file(filename:join([BinDir, "..", "samples", binary_to_list(Name) ++ ".zip"])).

validate_post_sample_buckets(Samples) ->
    case check_valid_samples(Samples) of
        ok ->
            check_quota(Samples);
        X ->
            X
    end.

check_quota(Samples) ->
    NodesCount = length(ns_cluster_membership:service_active_nodes(kv)),
    StorageInfo = ns_storage_conf:cluster_storage_info(),
    RamQuotas = proplists:get_value(ram, StorageInfo),
    QuotaUsed = proplists:get_value(quotaUsed, RamQuotas),
    QuotaTotal = proplists:get_value(quotaTotal, RamQuotas),
    Required = ?SAMPLE_BUCKET_QUOTA * erlang:length(Samples),

    case (QuotaTotal - QuotaUsed) <  (Required * NodesCount) of
        true ->
            Err = ["Not enough Quota, you need to allocate ", format_MB(Required),
                   " to install sample buckets"],
            [{error, list_to_binary(Err)}];
        false ->
            ok
    end.


check_valid_samples(Samples) ->
    Errors = [begin
                  case ns_bucket:name_conflict(binary_to_list(Name)) of
                      true ->
                          Err1 = ["Sample bucket ", Name, " is already loaded."],
                          {error, list_to_binary(Err1)};
                      _ ->
                          case sample_exists(Name) of
                              false ->
                                  Err2 = ["Sample ", Name, " is not a valid sample."],
                                  {error, list_to_binary(Err2)};
                              _ -> ok
                          end
                  end
              end || Name <- Samples],
    case [X || X <- Errors, X =/= ok] of
        [] ->
            ok;
        X ->
            X
    end.


format_MB(X) ->
    integer_to_list(misc:ceiling(X / 1024 / 1024)) ++ "MB".

get_content_for_provisioned_system() ->
    {Pools, Settings, UUID} =
        case ns_config_auth:is_system_provisioned() of
            true ->
                UUID1 = get_uuid(),
                Pools1 = [{struct,
                           [{name, <<"default">>},
                            {uri, <<"/pools/default?uuid=", UUID1/binary>>},
                            {streamingUri, <<"/poolsStreaming/default?uuid=", UUID1/binary>>}]}],
                Settings1 = {struct,
                             [{<<"maxParallelIndexers">>,
                               <<"/settings/maxParallelIndexers?uuid=", UUID1/binary>>},
                              {<<"viewUpdateDaemon">>,
                               <<"/settings/viewUpdateDaemon?uuid=", UUID1/binary>>}]},
                {Pools1, Settings1, UUID1};
            false ->
                {[], [], []}
        end,
    [{pools, Pools}, {settings, Settings}, {uuid, UUID}].

handle_pools(Req) ->
    %% TODO RBAC for the time being let's tell the UI that the user is admin
    %% later there will be an API to test the permissions

    RV1 = [{isAdminCreds, true},
           {isROAdminCreds, false},
           {isEnterprise, cluster_compat_mode:is_enterprise()}
           | get_content_for_provisioned_system()],
    RV = RV1 ++ menelaus_web_cache:versions_response(),
    reply_json(Req, {struct, RV}).

handle_engage_cluster2(Req) ->
    Body = Req:recv_body(),
    {struct, NodeKVList} = mochijson2:decode(Body),
    %% a bit kludgy, but 100% correct way to protect ourselves when
    %% everything will restart.
    process_flag(trap_exit, true),
    case ns_cluster:engage_cluster(NodeKVList) of
        {ok, _} ->
            %% NOTE: for 2.1+ cluster compat we may need
            %% something fancier. For now 2.0 is compatible only with
            %% itself and 1.8.x thus no extra work is needed.
            %%
            %% The idea is that engage_cluster/complete_join sequence
            %% is our cluster version compat negotiation. First
            %% cluster sends joinee node it's info in engage_cluster
            %% payload. Node then checks if it can work in that compat
            %% mode (node itself being single node cluster works in
            %% max compat mode it supports, which is perhaps higher
            %% then cluster's). If node supports this mode, it needs
            %% to send back engage_cluster reply with
            %% clusterCompatibility of cluster compat mode. Otherwise
            %% cluster would refuse this node as it runs in higher
            %% compat mode. That could be much much higher future
            %% compat mode. So only joinee knows if it can work in
            %% backwards compatible mode or not. Thus sending back of
            %% 'corrected' clusterCompatibility in engage_cluster
            %% response is our only option.
            %%
            %% NOTE: we don't need to actually switch to lower compat
            %% mode during engage_cluster. Because complete_join will
            %% cause full restart of joinee node, which will cause it
            %% to start back in cluster's compat mode.
            %%
            %% For now we just look if 1.8.x is asking us to join it
            %% and if it is, then we reply with clusterCompatibility
            %% of 1 which is the only thing they'll support
            %%
            %% NOTE: I was thinking about simply sending back
            %% clusterCompatibility of cluster, but that would break
            %% 10.x (i.e. much future version) check of backwards
            %% compatibility with us. I.e. because 2.0 is not checking
            %% cluster's compatibility (there's no need), lying about
            %% our cluster compat mode would not allow cluster to
            %% check we're compatible with it.
            %%
            %% 127.0.0.1 below is a bit subtle. See MB-8404. In
            %% CBSE-385 we saw how mis-configured node that was forced
            %% into 127.0.0.1 address was successfully added to
            %% cluster. And my thinking is "rename node in
            %% node-details output if node is 127.0.0.1" behavior
            %% that's needed for correct client's operation is to
            %% blame here. But given engage cluster is strictly
            %% intra-cluster thing we can return 127.0.0.1 back as
            %% 127.0.0.1 and thus join attempt in CBSE-385 would be
            %% prevented at completeJoin step which would be sent to
            %% 127.0.0.1 (joiner) and bounced.
            {struct, Result} = build_full_node_info(node(), "127.0.0.1"),
            {_, _} = CompatTuple = lists:keyfind(<<"clusterCompatibility">>, 1, NodeKVList),
            ThreeXCompat = cluster_compat_mode:effective_cluster_compat_version_for(
                             cluster_compat_mode:supported_compat_version()),
            ResultWithCompat =
                case CompatTuple of
                    {_, V} when V < ThreeXCompat ->
                        ?log_info("Lowering our advertised clusterCompatibility in order to enable joining older cluster"),
                        Result3 = lists:keyreplace(<<"clusterCompatibility">>, 1, Result, CompatTuple),
                        lists:keyreplace(clusterCompatibility, 1, Result3, CompatTuple);
                    _ ->
                        Result
                end,
            reply_json(Req, {struct, ResultWithCompat});
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

handle_complete_join(Req) ->
    {struct, NodeKVList} = mochijson2:decode(Req:recv_body()),
    erlang:process_flag(trap_exit, true),
    case ns_cluster:complete_join(NodeKVList) of
        {ok, _} ->
            reply_json(Req, [], 200);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

%% Returns an UUID from the ns_config
%% cluster UUID is set in ns_config only when the system is provisioned.
get_uuid() ->
    case ns_config:search(uuid) of
        false ->
            <<>>;
        {value, Uuid2} ->
            Uuid2
    end.

handle_versions(Req) ->
    reply_json(Req, {struct, menelaus_web_cache:versions_response()}).

is_xdcr_over_ssl_allowed() ->
    cluster_compat_mode:is_enterprise().

assert_is_enterprise() ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            ok;
        _ ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint requires enterprise edition",
                          [{"X-enterprise-edition-needed", 1}]})
    end.

assert_is_40() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_40/0).

assert_is_45() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_45/0).

assert_is_spock() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_spock/0).

assert_cluster_version(Fun) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint isn't supported in mixed version clusters",
                          []})
    end.

% {"default", [
%   {port, 11211},
%   {buckets, [
%     {"default", [
%       {auth_plain, undefined},
%       {size_per_node, 64}, % In MB.
%       {cache_expiration_range, {0,600}}
%     ]}
%   ]}
% ]}

check_and_handle_pool_info(Id, Req) ->
    case ns_config_auth:is_system_provisioned() of
        true ->
            handle_pool_info(Id, Req);
        _ ->
            reply_json(Req, <<"unknown pool">>, 404)
    end.

handle_pool_info(Id, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    Query = Req:parse_qs(),
    WaitChangeS = proplists:get_value("waitChange", Query),
    PassedETag = proplists:get_value("etag", Query),
    case WaitChangeS of
        undefined ->
            reply_json(Req,
                       build_pool_info(Id, Req, normal, unstable, LocalAddr));
        _ ->
            WaitChange = list_to_integer(WaitChangeS),
            menelaus_event:register_watcher(self()),
            erlang:send_after(WaitChange, self(), wait_expired),
            handle_pool_info_wait(Req, Id, LocalAddr, PassedETag)
    end.

handle_pool_info_wait(Req, Id, LocalAddr, PassedETag) ->
    Info = build_pool_info(Id, Req, for_ui, stable, LocalAddr),
    ETag = integer_to_list(erlang:phash2(Info)),
    if
        ETag =:= PassedETag ->
            erlang:hibernate(?MODULE, handle_pool_info_wait_wake,
                             [Req, Id, LocalAddr, PassedETag]);
        true ->
            handle_pool_info_wait_tail(Req, Id, LocalAddr, ETag)
    end.

handle_pool_info_wait_wake(Req, Id, LocalAddr, PassedETag) ->
    receive
        wait_expired ->
            handle_pool_info_wait_tail(Req, Id, LocalAddr, PassedETag);
        notify_watcher ->
            timer:sleep(200), %% delay a bit to catch more notifications
            consume_notifications(),
            handle_pool_info_wait(Req, Id, LocalAddr, PassedETag);
        _ ->
            exit(normal)
    end.

consume_notifications() ->
    receive
        notify_watcher -> consume_notifications()
    after 0 ->
            done
    end.

handle_pool_info_wait_tail(Req, Id, LocalAddr, ETag) ->
    menelaus_event:unregister_watcher(self()),
    %% consume all notifications
    consume_notifications(),
    %% and reply
    {struct, PList} = build_pool_info(Id, Req, for_ui, unstable, LocalAddr),
    Info = {struct, [{etag, list_to_binary(ETag)} | PList]},
    reply_ok(Req, "application/json", menelaus_util:encode_json(Info),
             menelaus_auth:maybe_refresh_token(Req)),
    %% this will cause some extra latency on ui perhaps,
    %% because browsers commonly assume we'll keepalive, but
    %% keeping memory usage low is imho more important
    exit(normal).


build_pool_info(Id, Req, normal, Stability, LocalAddr) ->
    CanIncludeOtpCookie = menelaus_auth:has_permission({[admin, internal], all}, Req),

    %% NOTE: we limit our caching here for "normal" info
    %% level. Explicitly excluding UI (which InfoLevel = for_ui). This
    %% is because caching doesn't take into account "buckets version"
    %% which is important to deliver asap to UI (i.e. without any
    %% caching "staleness"). Same situation is with tasks version
    menelaus_web_cache:lookup_or_compute_with_expiration(
      {pool_details, CanIncludeOtpCookie, Stability, LocalAddr},
      fun () ->
              %% NOTE: token needs to be taken before building pool info
              Token = ns_config:config_version_token(),
              {do_build_pool_info(Id, CanIncludeOtpCookie,
                                  normal, Stability, LocalAddr), 1000, Token}
      end,
      fun (_Key, _Value, ConfigVersionToken) ->
              ConfigVersionToken =/= ns_config:config_version_token()
      end);
build_pool_info(Id, _Req, InfoLevel, Stability, LocalAddr) ->
    do_build_pool_info(Id, false, InfoLevel, Stability, LocalAddr).

do_build_pool_info(Id, CanIncludeOtpCookie, InfoLevel, Stability, LocalAddr) ->
    UUID = get_uuid(),

    F = build_nodes_info_fun(CanIncludeOtpCookie, InfoLevel, Stability, LocalAddr),
    Nodes = [F(N, undefined) || N <- ns_node_disco:nodes_wanted()],
    Config = ns_config:get(),
    BucketsVer = erlang:phash2(ns_bucket:get_bucket_names(ns_bucket:get_buckets(Config)))
        bxor erlang:phash2([{proplists:get_value(hostname, KV),
                             proplists:get_value(status, KV)} || {struct, KV} <- Nodes]),
    BucketsInfo = {struct, [{uri, bin_concat_path(["pools", Id, "buckets"],
                                                  [{"v", BucketsVer},
                                                   {"uuid", UUID}])},
                            {terseBucketsBase, <<"/pools/default/b/">>},
                            {terseStreamingBucketsBase, <<"/pools/default/bs/">>}]},
    RebalanceStatus = case ns_orchestrator:is_rebalance_running() of
                          true -> <<"running">>;
                          _ -> <<"none">>
                      end,

    {Alerts0, AlertsSilenceToken} = menelaus_web_alerts_srv:fetch_alerts(),
    Alerts = build_alerts(Alerts0),

    Controllers = {struct, [
      {addNode, {struct, [{uri, <<"/controller/addNodeV2?uuid=", UUID/binary>>}]}},
      {rebalance, {struct, [{uri, <<"/controller/rebalance?uuid=", UUID/binary>>}]}},
      {failOver, {struct, [{uri, <<"/controller/failOver?uuid=", UUID/binary>>}]}},
      {startGracefulFailover, {struct, [{uri, <<"/controller/startGracefulFailover?uuid=", UUID/binary>>}]}},
      {reAddNode, {struct, [{uri, <<"/controller/reAddNode?uuid=", UUID/binary>>}]}},
      {reFailOver, {struct, [{uri, <<"/controller/reFailOver?uuid=", UUID/binary>>}]}},
      {ejectNode, {struct, [{uri, <<"/controller/ejectNode?uuid=", UUID/binary>>}]}},
      {setRecoveryType, {struct, [{uri, <<"/controller/setRecoveryType?uuid=", UUID/binary>>}]}},
      {setAutoCompaction, {struct, [
        {uri, <<"/controller/setAutoCompaction?uuid=", UUID/binary>>},
        {validateURI, <<"/controller/setAutoCompaction?just_validate=1">>}
      ]}},
      {clusterLogsCollection, {struct, [
        {startURI, <<"/controller/startLogsCollection?uuid=", UUID/binary>>},
        {cancelURI, <<"/controller/cancelLogsCollection?uuid=", UUID/binary>>}]}},
      {replication, {struct, [
        {createURI, <<"/controller/createReplication?uuid=", UUID/binary>>},
        {validateURI, <<"/controller/createReplication?just_validate=1">>}
      ]}}
    ]},

    TasksURI = bin_concat_path(["pools", Id, "tasks"],
                               [{"v", ns_doctor:get_tasks_version()}]),

    {ok, IndexesVersion0} = indexer_gsi:get_indexes_version(),
    IndexesVersion = list_to_binary(integer_to_list(IndexesVersion0)),

    GroupsV = erlang:phash2(ns_config:search(Config, server_groups)),

    PropList0 = [{name, list_to_binary(Id)},
                 {alerts, Alerts},
                 {alertsSilenceURL,
                  iolist_to_binary([<<"/controller/resetAlerts?token=">>,
                                    AlertsSilenceToken,
                                    $&, <<"uuid=">>, UUID])},
                 {nodes, Nodes},
                 {buckets, BucketsInfo},
                 {remoteClusters,
                  {struct, [{uri, <<"/pools/default/remoteClusters?uuid=", UUID/binary>>},
                            {validateURI, <<"/pools/default/remoteClusters?just_validate=1">>}]}},
                 {controllers, Controllers},
                 {rebalanceStatus, RebalanceStatus},
                 {rebalanceProgressUri, bin_concat_path(["pools", Id, "rebalanceProgress"])},
                 {stopRebalanceUri, <<"/controller/stopRebalance?uuid=", UUID/binary>>},
                 {nodeStatusesUri, <<"/nodeStatuses">>},
                 {maxBucketCount, ns_config:read_key_fast(max_bucket_count, 10)},
                 {autoCompactionSettings, build_global_auto_compaction_settings(Config)},
                 {tasks, {struct, [{uri, TasksURI}]}},
                 {counters, {struct, ns_cluster:counters()}},
                 {indexStatusURI, <<"/indexStatus?v=", IndexesVersion/binary>>},
                 {checkPermissionsURI,
                  bin_concat_path(["pools", Id, "checkPermissions"],
                                  [{"v", menelaus_web_rbac:check_permissions_url_version(Config)}])},
                 {serverGroupsUri, <<"/pools/default/serverGroups?v=",
                                     (list_to_binary(integer_to_list(GroupsV)))/binary>>},
                 {clusterName, list_to_binary(get_cluster_name())}],

    PropList1 = build_memory_quota_info(Config) ++ PropList0,
    PropList2 =
        case InfoLevel of
            for_ui ->
                [{balanced, ns_cluster_membership:is_balanced()},
                 {failoverWarnings, ns_bucket:failover_warnings()},
                 {goxdcrEnabled, cluster_compat_mode:is_goxdcr_enabled(Config)},
                 {ldapEnabled, cluster_compat_mode:is_ldap_enabled()}
                 | PropList1];
            _ ->
                PropList1
        end,

    PropList =
        case Stability of
            stable ->
                PropList2;
            unstable ->
                StorageTotals = [{Key, {struct, StoragePList}}
                                 || {Key, StoragePList} <- ns_storage_conf:cluster_storage_info()],
                [{storageTotals, {struct, StorageTotals}} | PropList2]
        end,

    {struct, PropList}.

build_alerts(Alerts) ->
    [build_one_alert(Alert) || Alert <- Alerts].

build_one_alert({_Key, Msg, Time}) ->
    LocalTime = calendar:now_to_local_time(misc:now_int_to_now(Time)),
    StrTime = menelaus_util:format_server_time(LocalTime),

    {struct, [{msg, Msg},
              {serverTime, StrTime}]}.

build_global_auto_compaction_settings() ->
    build_global_auto_compaction_settings(ns_config:latest()).

build_global_auto_compaction_settings(Config) ->
    Extra = case cluster_compat_mode:is_cluster_40() of
                true ->
                    IndexCompaction = index_settings_manager:get(compaction),
                    true = (IndexCompaction =/= undefined),
                    {_, Fragmentation} = lists:keyfind(fragmentation, 1, IndexCompaction),
                    [{indexFragmentationThreshold,
                      {struct, [{percentage, Fragmentation}]}}];
                false ->
                    []
            end,
    IndexExtra = (case cluster_compat_mode:is_cluster_45() of
                      true ->
                          CompMode = index_settings_manager:get(compactionMode),
                          true = (CompMode =/= undefined),
                          Circ0 = index_settings_manager:get(circularCompaction),
                          true = (Circ0 =/= undefined),
                          Int = proplists:get_value(interval, Circ0),
                          Circ1 = [{abort_outside,
                                    proplists:get_value(abort_outside, Circ0)}] ++ Int,
                          Circ = [{daysOfWeek,
                                   proplists:get_value(daysOfWeek, Circ0)},
                                  {interval,
                                   build_auto_compaction_allowed_time_period(
                                     Circ1)}],
                          [{indexCompactionMode, CompMode},
                           {indexCircularCompaction, {struct, Circ}}];
                      false ->
                          []
                  end) ++ Extra,
    case ns_config:search(Config, autocompaction) of
        false ->
            do_build_auto_compaction_settings([], IndexExtra);
        {value, ACSettings} ->
            do_build_auto_compaction_settings(ACSettings, IndexExtra)
    end.

build_bucket_auto_compaction_settings(Settings) ->
    do_build_auto_compaction_settings(Settings, []).

do_build_auto_compaction_settings(Settings, Extra) ->
    PropFun = fun ({JSONName, CfgName}) ->
                      case proplists:get_value(CfgName, Settings) of
                          undefined -> [];
                          {Percentage, Size} ->
                              [{JSONName, {struct, [{percentage, Percentage},
                                                    {size,  Size}]}}]
                      end
              end,
    DBAndView = lists:flatmap(PropFun,
                              [{databaseFragmentationThreshold, database_fragmentation_threshold},
                               {viewFragmentationThreshold, view_fragmentation_threshold}]),

    {struct, [{parallelDBAndViewCompaction, proplists:get_bool(parallel_db_and_view_compaction, Settings)}
              | case proplists:get_value(allowed_time_period, Settings) of
                    undefined -> [];
                    V -> [{allowedTimePeriod, build_auto_compaction_allowed_time_period(V)}]
                end] ++ DBAndView ++ Extra}.

build_auto_compaction_allowed_time_period(AllowedTimePeriod) ->
    {struct, [{JSONName, proplists:get_value(CfgName, AllowedTimePeriod)}
              || {JSONName, CfgName} <- [{fromHour, from_hour},
                                         {toHour, to_hour},
                                         {fromMinute, from_minute},
                                         {toMinute, to_minute},
                                         {abortOutside, abort_outside}]]}.




build_nodes_info() ->
    F = build_nodes_info_fun(true, normal, unstable, "127.0.0.1"),
    [F(N, undefined) || N <- ns_node_disco:nodes_wanted()].

%% builds health/warmup status of given node (w.r.t. given Bucket if
%% not undefined)
build_node_status(Node, Bucket, InfoNode, BucketsAll) ->
    case proplists:get_bool(down, InfoNode) of
        false ->
            ReadyBuckets = proplists:get_value(ready_buckets, InfoNode),
            NodeBucketNames = ns_bucket:node_bucket_names(Node, BucketsAll),
            case Bucket of
                undefined ->
                    case ordsets:is_subset(lists:sort(NodeBucketNames),
                                           lists:sort(ReadyBuckets)) of
                        true ->
                            <<"healthy">>;
                        false ->
                            <<"warmup">>
                    end;
                _ ->
                    case lists:member(Bucket, ReadyBuckets) of
                        true ->
                            <<"healthy">>;
                        false ->
                            case lists:member(Bucket, NodeBucketNames) of
                                true ->
                                    <<"warmup">>;
                                false ->
                                    <<"unhealthy">>
                            end
                    end
            end;
        true ->
            <<"unhealthy">>
    end.

build_nodes_info_fun(CanIncludeOtpCookie, InfoLevel, Stability, LocalAddr) ->
    OtpCookie = list_to_binary(atom_to_list(erlang:get_cookie())),
    NodeStatuses = ns_doctor:get_nodes(),
    Config = ns_config:get(),
    BucketsAll = ns_bucket:get_buckets(Config),
    fun(WantENode, Bucket) ->
            InfoNode = ns_doctor:get_node(WantENode, NodeStatuses),
            KV = build_node_info(Config, WantENode, InfoNode, LocalAddr),

            Status = build_node_status(WantENode, Bucket, InfoNode, BucketsAll),
            KV1 = [{clusterMembership,
                    atom_to_binary(
                      ns_cluster_membership:get_cluster_membership(
                        WantENode, Config),
                      latin1)},
                   {recoveryType,
                    ns_cluster_membership:get_recovery_type(Config, WantENode)},
                   {status, Status},
                   {otpNode, list_to_binary(atom_to_list(WantENode))}
                   | KV],
            %% NOTE: the following avoids exposing otpCookie to UI
            KV2 = case CanIncludeOtpCookie andalso InfoLevel =:= normal of
                      true ->
                          [{otpCookie, OtpCookie} | KV1];
                      false -> KV1
                  end,
            KV3 = case Bucket of
                      undefined ->
                          [{Key, URL} || {Key, Node} <- [{couchApiBase, WantENode},
                                                         {couchApiBaseHTTPS, {ssl, WantENode}}],
                                         URL <- [capi_utils:capi_url_bin(Node, <<"/">>, LocalAddr)],
                                         URL =/= undefined] ++ KV2;
                      _ ->
                          Replication = case ns_bucket:get_bucket(Bucket, Config) of
                                            not_present -> 0.0;
                                            {ok, BucketConfig} ->
                                                failover_safeness_level:extract_replication_uptodateness(Bucket, BucketConfig,
                                                                                                         WantENode, NodeStatuses)
                                        end,
                          [{replication, Replication} | KV2]
                  end,
            KV4 = case Stability of
                      stable ->
                          KV3;
                      unstable ->
                          build_extra_node_info(Config, WantENode,
                                                InfoNode, BucketsAll, KV3)
                  end,
            {struct, KV4}
    end.

build_extra_node_info(Config, Node, InfoNode, _BucketsAll, Append) ->

    {UpSecs, {MemoryTotalErlang, MemoryAllocedErlang, _}} =
        {proplists:get_value(wall_clock, InfoNode, 0),
         proplists:get_value(memory_data, InfoNode,
                             {0, 0, undefined})},

    SystemStats = proplists:get_value(system_stats, InfoNode, []),
    SigarMemTotal = proplists:get_value(mem_total, SystemStats),
    SigarMemFree = proplists:get_value(mem_free, SystemStats),
    {MemoryTotal, MemoryFree} =
        case SigarMemTotal =:= undefined orelse SigarMemFree =:= undefined of
            true ->
                {MemoryTotalErlang, MemoryTotalErlang - MemoryAllocedErlang};
            _ ->
                {SigarMemTotal, SigarMemFree}
        end,

    NodesBucketMemoryTotal = case ns_config:search_node_prop(Node,
                                                             Config,
                                                             memcached,
                                                             max_size) of
                                 X when is_integer(X) -> X;
                                 undefined -> (MemoryTotal * 4) div (5 * ?MIB)
                             end,

    NodesBucketMemoryAllocated = NodesBucketMemoryTotal,
    [{systemStats, {struct, proplists:get_value(system_stats, InfoNode, [])}},
     {interestingStats, {struct, proplists:get_value(interesting_stats, InfoNode, [])}},
     %% TODO: deprecate this in API (we need 'stable' "startupTStamp"
     %% first)
     {uptime, list_to_binary(integer_to_list(UpSecs))},
     %% TODO: deprecate this in API
     {memoryTotal, erlang:trunc(MemoryTotal)},
     %% TODO: deprecate this in API
     {memoryFree, erlang:trunc(MemoryFree)},
     %% TODO: deprecate this in API
     {mcdMemoryReserved, erlang:trunc(NodesBucketMemoryTotal)},
     %% TODO: deprecate this in API
     {mcdMemoryAllocated, erlang:trunc(NodesBucketMemoryAllocated)}
     | Append].

build_node_hostname(Config, Node, LocalAddr) ->
    Host = case misc:node_name_host(Node) of
               {_, "127.0.0.1"} -> LocalAddr;
               {_Name, H} -> H
           end,
    Host ++ ":" ++ integer_to_list(misc:node_rest_port(Config, Node)).

build_node_info(Config, WantENode, InfoNode, LocalAddr) ->

    DirectPort = ns_config:search_node_prop(WantENode, Config, memcached, port),
    ProxyPort = ns_config:search_node_prop(WantENode, Config, moxi, port),
    Versions = proplists:get_value(version, InfoNode, []),
    Version = proplists:get_value(ns_server, Versions, "unknown"),
    OS = proplists:get_value(system_arch, InfoNode, "unknown"),
    HostName = build_node_hostname(Config, WantENode, LocalAddr),

    PortsKV0 = [{proxy, ProxyPort},
                {direct, DirectPort}],

    %% this is used by xdcr over ssl since 2.5.0
    PortKeys = [{ssl_capi_port, httpsCAPI},
                {ssl_rest_port, httpsMgmt}]
        ++ case is_xdcr_over_ssl_allowed() of
               true ->
                   [{ssl_proxy_downstream_port, sslProxy}];
               _ -> []
           end,

    PortsKV = lists:foldl(
                fun ({ConfigKey, JKey}, Acc) ->
                        case ns_config:search_node(WantENode, Config, ConfigKey) of
                            {value, Value} when Value =/= undefined -> [{JKey, Value} | Acc];
                            _ -> Acc
                        end
                end, PortsKV0, PortKeys),

    RV = [{hostname, list_to_binary(HostName)},
          {clusterCompatibility, cluster_compat_mode:effective_cluster_compat_version()},
          {version, list_to_binary(Version)},
          {os, list_to_binary(OS)},
          {ports, {struct, PortsKV}},
          {services, ns_cluster_membership:node_services(Config, WantENode)}
         ],
    case WantENode =:= node() of
        true ->
            [{thisNode, true} | RV];
        _ -> RV
    end.

handle_pool_info_streaming(Id, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    F = fun(InfoLevel, Stability) ->
                build_pool_info(Id, Req, InfoLevel, Stability, LocalAddr)
        end,
    handle_streaming(F, Req, undefined).

handle_streaming(F, Req, LastRes) ->
    HTTPRes = reply_ok(Req, "application/json; charset=utf-8", chunked),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    mochiweb_socket:setopts(Sock, [{active, true}]),
    handle_streaming(F, Req, HTTPRes, LastRes).

streaming_inner(F, HTTPRes, LastRes) ->
    Res = F(normal, stable),
    case Res =:= LastRes of
        true ->
            ok;
        false ->
            ResNormal = case Res of
                            {just_write, Stuff} ->
                                Stuff;
                            _ ->
                                F(normal, unstable)
                        end,
            Encoded = case ResNormal of
                          {write, Bin} -> Bin;
                          _ -> menelaus_util:encode_json(ResNormal)
                      end,
            HTTPRes:write_chunk(Encoded),
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    Res.

consume_watcher_notifies() ->
    receive
        notify_watcher ->
            consume_watcher_notifies()
    after 0 ->
            ok
    end.

handle_streaming(F, Req, HTTPRes, LastRes) ->
    Res =
        try streaming_inner(F, HTTPRes, LastRes)
        catch exit:normal ->
                HTTPRes:write_chunk(""),
                exit(normal)
        end,
    request_throttler:hibernate(?MODULE, handle_streaming_wakeup, [F, Req, HTTPRes, Res]).

handle_streaming_wakeup(F, Req, HTTPRes, Res) ->
    receive
        notify_watcher ->
            timer:sleep(50),
            consume_watcher_notifies(),
            ok;
        _ ->
            exit(normal)
    after 25000 ->
            ok
    end,
    handle_streaming(F, Req, HTTPRes, Res).

handle_join(Req) ->
    %% paths:
    %%  cluster secured, admin logged in:
    %%           after creds work and node join happens,
    %%           200 returned with Location header pointing
    %%           to new /pool/default
    %%  cluster not secured, after node join happens,
    %%           a 200 returned with Location header to new /pool/default,
    %%           401 if request had
    %%  cluster either secured or not:
    %%           a 400 with json error message when join fails for whatever reason
    %%
    %% parameter example: clusterMemberHostIp=192%2E168%2E0%2E1&
    %%                    clusterMemberPort=8091&
    %%                    user=admin&password=admin123
    %%
    case ns_config_auth:is_system_provisioned() of
        true ->
            Msg = <<"Node is already provisioned. To join use controller/addNode api of the cluster">>,
            reply_json(Req, [Msg], 400);
        false ->
            handle_join_clean_node(Req)
    end.

parse_validate_services_list(ServicesList) ->
    KnownServices = ns_cluster_membership:supported_services(),
    ServicePairs = [{erlang:atom_to_list(S), S} || S <- KnownServices],
    ServiceStrings = string:tokens(ServicesList, ","),
    FoundServices = [{SN, lists:keyfind(SN, 1, ServicePairs)} || SN <- ServiceStrings],
    UnknownServices = [SN || {SN, false} <- FoundServices],
    case UnknownServices of
        [_|_] ->
            Msg = io_lib:format("Unknown services: ~p", [UnknownServices]),
            {error, iolist_to_binary(Msg)};
        [] ->
            RV = lists:usort([S || {_, {_, S}} <- FoundServices]),
            case RV of
                [] ->
                    {error, <<"At least one service has to be selected">>};
                _ ->
                    {ok, RV}
            end
    end.

parse_validate_services_list_test() ->
    {error, _} = parse_validate_services_list(""),
    ?assertEqual({ok, [index, kv, n1ql]}, parse_validate_services_list("n1ql,kv,index")),
    {ok, [kv]} = parse_validate_services_list("kv"),
    {error, _} = parse_validate_services_list("n1ql,kv,s"),
    ?assertMatch({error, _}, parse_validate_services_list("neeql,kv")).

parse_join_cluster_params(Params, ThisIsJoin) ->
    Version = proplists:get_value("version", Params, "3.0"),

    OldVersion = (Version =:= "3.0"),

    Hostname = case proplists:get_value("hostname", Params) of
                   undefined ->
                       if
                           ThisIsJoin andalso OldVersion ->
                               %%  this is for backward compatibility
                               ClusterMemberPort = proplists:get_value("clusterMemberPort", Params),
                               ClusterMemberHostIp = proplists:get_value("clusterMemberHostIp", Params),
                               case lists:member(undefined,
                                                 [ClusterMemberPort, ClusterMemberHostIp]) of
                                   true ->
                                       "";
                                   _ ->
                                       lists:concat([ClusterMemberHostIp, ":", ClusterMemberPort])
                               end;
                           true ->
                               ""
                       end;
                   X ->
                       X
               end,

    OtherUser = proplists:get_value("user", Params),
    OtherPswd = proplists:get_value("password", Params),

    Version40 = cluster_compat_mode:compat_mode_string_40(),

    VersionErrors = case Version of
                        "3.0" ->
                            [];
                        %% bound above
                        Version40 ->
                            KnownParams = ["hostname", "version", "user", "password", "services"],
                            UnknownParams = [K || {K, _} <- Params,
                                                  not lists:member(K, KnownParams)],
                            case UnknownParams of
                                [_|_] ->
                                    Msg = io_lib:format("Got unknown parameters: ~p", [UnknownParams]),
                                    [iolist_to_binary(Msg)];
                                [] ->
                                    []
                            end;
                        _ ->
                            [<<"version is not recognized">>]
                    end,

    Services = case proplists:get_value("services", Params) of
                   undefined ->
                       {ok, ns_cluster_membership:default_services()};
                   SvcParams ->
                       case parse_validate_services_list(SvcParams) of
                           {ok, Svcs} ->
                               case (Svcs =:= ns_cluster_membership:default_services()
                                     orelse cluster_compat_mode:is_cluster_40()) of
                                   true ->
                                       {ok, Svcs};
                                   false ->
                                       {error, <<"services parameter is not supported in this cluster compatibility mode">>}
                               end;
                           SvcsError ->
                               SvcsError
                       end
               end,

    BasePList = [{user, OtherUser},
                 {password, OtherPswd}],

    MissingFieldErrors = [iolist_to_binary([atom_to_list(F), <<" is missing">>])
                          || {F, V} <- BasePList,
                             V =:= undefined],

    {HostnameError, ParsedHostnameRV} =
        case (catch parse_hostname(Hostname)) of
            {error, HMsgs} ->
                {HMsgs, undefined};
            {ParsedHost, ParsedPort} when is_list(ParsedHost) ->
                {[], {ParsedHost, ParsedPort}}
        end,

    Errors = MissingFieldErrors ++ VersionErrors ++ HostnameError ++
        case Services of
            {error, ServicesError} ->
                [ServicesError];
            _ ->
                []
        end,
    case Errors of
        [] ->
            {ok, ServicesList} = Services,
            {Host, Port} = ParsedHostnameRV,
            {ok, [{services, ServicesList},
                  {host, Host},
                  {port, Port}
                  | BasePList]};
        _ ->
            {errors, Errors}
    end.

handle_join_clean_node(Req) ->
    Params = Req:parse_post(),

    case parse_join_cluster_params(Params, true) of
        {errors, Errors} ->
            reply_json(Req, Errors, 400);
        {ok, Fields} ->
            OtherHost = proplists:get_value(host, Fields),
            OtherPort = proplists:get_value(port, Fields),
            OtherUser = proplists:get_value(user, Fields),
            OtherPswd = proplists:get_value(password, Fields),
            Services = proplists:get_value(services, Fields),
            handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd, Services)
    end.

handle_join_tail(Req, OtherHost, OtherPort, OtherUser, OtherPswd, Services) ->
    process_flag(trap_exit, true),
    RV = case ns_cluster:check_host_connectivity(OtherHost) of
             {ok, MyIP} ->
                 {struct, MyPList} = build_full_node_info(node(), MyIP),
                 Hostname = misc:expect_prop_value(hostname, MyPList),

                 BasePayload = [{<<"hostname">>, Hostname},
                                {<<"user">>, []},
                                {<<"password">>, []}],

                 {Payload, Endpoint} =
                     case Services =:= ns_cluster_membership:default_services() of
                         true ->
                             {BasePayload, "/controller/addNode"};
                         false ->
                             ServicesStr = string:join([erlang:atom_to_list(S) || S <- Services], ","),
                             SVCPayload = [{"version", cluster_compat_mode:compat_mode_string_40()},
                                           {"services", ServicesStr}
                                           | BasePayload],
                             {SVCPayload, "/controller/addNodeV2"}
                     end,


                 RestRV = menelaus_rest:json_request_hilevel(post,
                                                             {OtherHost, OtherPort,
                                                              Endpoint,
                                                              "application/x-www-form-urlencoded",
                                                              mochiweb_util:urlencode(Payload)},
                                                             {OtherUser, OtherPswd}),
                 case RestRV of
                     {error, What, _M, {bad_status, 404, Msg}} ->
                         {error, What, <<"Node attempting to join an older cluster. Some of the selected services are not available.">>, {bad_status, 404, Msg}};
                     Other ->
                         Other
                 end;
             X -> X
         end,

    case RV of
        {ok, _} ->
            reply(Req, 200);
        {client_error, JSON} ->
            reply_json(Req, JSON, 400);
        {error, _What, Message, _Nested} ->
            reply_json(Req, [Message], 400)
    end,
    exit(normal).

%% waits till only one node is left in cluster
do_eject_myself_rec(0, _) ->
    exit(self_eject_failed);
do_eject_myself_rec(IterationsLeft, Period) ->
    MySelf = node(),
    case ns_node_disco:nodes_actual_proper() of
        [MySelf] -> ok;
        _ ->
            timer:sleep(Period),
            do_eject_myself_rec(IterationsLeft-1, Period)
    end.

do_eject_myself() ->
    ns_cluster:leave(),
    do_eject_myself_rec(10, 250).

handle_eject_post(Req) ->
    PostArgs = Req:parse_post(),
    %
    % either Eject a running node, or eject a node which is down.
    %
    % request is a urlencoded form with otpNode
    %
    % responses are 200 when complete
    %               401 if creds were not supplied and are required
    %               403 if creds were supplied and are incorrect
    %               400 if the node to be ejected doesn't exist
    %
    OtpNodeStr = case proplists:get_value("otpNode", PostArgs) of
                     undefined -> undefined;
                     "Self" -> atom_to_list(node());
                     "zzzzForce" ->
                         handle_force_self_eject(Req),
                         exit(normal);
                     X -> X
                 end,
    case OtpNodeStr of
        undefined ->
            reply_text(Req, "Bad Request\n", 400);
        _ ->
            OtpNode = list_to_atom(OtpNodeStr),
            case ns_cluster_membership:get_cluster_membership(OtpNode) of
                active ->
                    reply_text(Req, "Cannot remove active server.\n", 400);
                _ ->
                    do_handle_eject_post(Req, OtpNode)
            end
    end.

handle_force_self_eject(Req) ->
    erlang:process_flag(trap_exit, true),
    ns_cluster:force_eject_self(),
    ns_audit:remove_node(Req, node()),
    reply_text(Req, "done", 200),
    ok.

do_handle_eject_post(Req, OtpNode) ->
    case OtpNode =:= node() of
        true ->
            do_eject_myself(),
            ns_audit:remove_node(Req, node()),
            reply(Req, 200);
        false ->
            case lists:member(OtpNode, ns_node_disco:nodes_wanted()) of
                true ->
                    ns_cluster:leave(OtpNode),
                    ?MENELAUS_WEB_LOG(?NODE_EJECTED, "Node ejected: ~p from node: ~p",
                                      [OtpNode, erlang:node()]),
                    ns_audit:remove_node(Req, OtpNode),
                    reply(Req, 200);
                false ->
                                                % Node doesn't exist.
                    ?MENELAUS_WEB_LOG(0018, "Request to eject nonexistant server failed.  Requested node: ~p",
                                      [OtpNode]),
                    reply_text(Req, "Server does not exist.\n", 400)
            end
    end.

handle_settings_max_parallel_indexers(Req) ->
    Config = ns_config:get(),

    GlobalValue =
        case ns_config:search(Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V} ->
                V
        end,
    ThisNodeValue =
        case ns_config:search_node(node(), Config, {couchdb, max_parallel_indexers}) of
            false ->
                null;
            {value, V2} ->
                V2
        end,

    reply_json(Req, {struct, [{globalValue, GlobalValue},
                              {nodes, {struct, [{node(), ThisNodeValue}]}}]}).

handle_settings_max_parallel_indexers_post(Req) ->
    Params = Req:parse_post(),
    V = proplists:get_value("globalValue", Params, ""),
    case parse_validate_number(V, 1, 1024) of
        {ok, Parsed} ->
            ns_config:set({couchdb, max_parallel_indexers}, Parsed),
            handle_settings_max_parallel_indexers(Req);
        Error ->
            reply_json(Req, {struct, [{'_', iolist_to_binary(io_lib:format("Invalid globalValue: ~p", [Error]))}]}, 400)
    end.

handle_settings_view_update_daemon(Req) ->
    {value, Config} = ns_config:search(set_view_update_daemon),

    UpdateInterval = proplists:get_value(update_interval, Config),
    UpdateMinChanges = proplists:get_value(update_min_changes, Config),
    ReplicaUpdateMinChanges = proplists:get_value(replica_update_min_changes, Config),

    true = (UpdateInterval =/= undefined),
    true = (UpdateMinChanges =/= undefined),
    true = (UpdateMinChanges =/= undefined),

    reply_json(Req, {struct, [{updateInterval, UpdateInterval},
                              {updateMinChanges, UpdateMinChanges},
                              {replicaUpdateMinChanges, ReplicaUpdateMinChanges}]}).

handle_settings_view_update_daemon_post(Req) ->
    Params = Req:parse_post(),

    {Props, Errors} =
        lists:foldl(
          fun ({Key, RestKey}, {AccProps, AccErrors} = Acc) ->
                  Raw = proplists:get_value(RestKey, Params),

                  case Raw of
                      undefined ->
                          Acc;
                      _ ->
                          case parse_validate_number(Raw, 0, undefined) of
                              {ok, Value} ->
                                  {[{Key, Value} | AccProps], AccErrors};
                              Error ->
                                  Msg = io_lib:format("Invalid ~s: ~p",
                                                      [RestKey, Error]),
                                  {AccProps, [{RestKey, iolist_to_binary(Msg)}]}
                          end
                  end
          end, {[], []},
          [{update_interval, "updateInterval"},
           {update_min_changes, "updateMinChanges"},
           {replica_update_min_changes, "replicaUpdateMinChanges"}]),

    case Errors of
        [] ->
            {value, CurrentProps} = ns_config:search(set_view_update_daemon),
            MergedProps = misc:update_proplist(CurrentProps, Props),
            ns_config:set(set_view_update_daemon, MergedProps),
            handle_settings_view_update_daemon(Req);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

get_cluster_name() ->
    get_cluster_name(ns_config:latest()).

get_cluster_name(Config) ->
    ns_config:search(Config, cluster_name, "").

validate_pool_settings_post(Config, CompatVersion, Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = validate_any_value(clusterName, R0),
    R2 = validate_memory_quota(Config, CompatVersion, R1),
    validate_unsupported_params(R2).

validate_memory_quota(Config, CompatVersion, R0) ->
    R1 = validate_integer(memoryQuota, R0),
    R2 = case cluster_compat_mode:is_version_40(CompatVersion) of
             true ->
                 validate_integer(indexMemoryQuota, R1);
             false ->
                 R1
         end,
    R3 = case cluster_compat_mode:is_version_45(CompatVersion) of
             true ->
                 validate_integer(ftsMemoryQuota, R2);
             false ->
                 R2
         end,
    R4 = case cluster_compat_mode:is_version_45(CompatVersion) of
             true ->
                 validate_integer(cbasMemoryQuota, R3);
             false ->
                 R3
         end,

    Values = menelaus_util:get_values(R4),

    Quotas = lists:filtermap(
               fun ({Key, Service}) ->
                       case lists:keyfind(Key, 1, Values) of
                           false ->
                               false;
                           {_, ServiceQuota} ->
                               {true, {Service, ServiceQuota}}
                       end
               end, [{memoryQuota, kv},
                     {indexMemoryQuota, index},
                     {ftsMemoryQuota, fts},
                     {cbasMemoryQuota, cbas}]),

    case Quotas of
        [] ->
            R4;
        _ ->
            do_validate_memory_quota(Config, Quotas, R4)
    end.

do_validate_memory_quota(Config, Quotas, R0) ->
    Nodes = ns_node_disco:nodes_wanted(Config),
    {ok, NodeStatuses} = ns_doctor:wait_statuses(Nodes, 3 * ?HEART_BEAT_PERIOD),
    NodeInfos =
        lists:map(
          fun (Node) ->
                  NodeStatus = dict:fetch(Node, NodeStatuses),
                  {_, MemoryData} = lists:keyfind(memory_data, 1, NodeStatus),
                  NodeServices = ns_cluster_membership:node_services(Config, Node),
                  {Node, NodeServices, MemoryData}
          end, Nodes),

    case ns_storage_conf:check_quotas(NodeInfos, Config, Quotas) of
        ok ->
            menelaus_util:return_value(quotas, Quotas, R0);
        {error, Error} ->
            {Key, Msg} = quota_error_msg(Error),
            menelaus_util:return_error(Key, Msg, R0)
    end.

quota_error_msg({total_quota_too_high, Node, TotalQuota, MaxAllowed}) ->
    Msg = io_lib:format("Total quota (~bMB) exceeds the maximum allowed quota (~bMB) on node ~p",
                        [TotalQuota, MaxAllowed, Node]),
    {'_', Msg};
quota_error_msg({service_quota_too_low, Service, Quota, MinAllowed}) ->
    {Key, Details} =
        case Service of
            kv ->
                D = " (current total buckets quota, or at least 256MB)",
                {memoryQuota, D};
            index ->
                {indexMemoryQuota, ""};
            fts ->
                {ftsMemoryQuota, ""};
            cbas ->
                {cbasMemoryQuota, ""}
        end,

    Msg = io_lib:format("The ~p service quota (~bMB) cannot be less than ~bMB~s.",
                        [Service, Quota, MinAllowed, Details]),
    {Key, Msg}.

handle_pool_settings_post(Req) ->
    do_handle_pool_settings_post_loop(Req, 10).

do_handle_pool_settings_post_loop(_, 0) ->
    erlang:error(exceeded_retries);
do_handle_pool_settings_post_loop(Req, RetriesLeft) ->
    try
        do_handle_pool_settings_post(Req)
    catch
        throw:retry_needed ->
            do_handle_pool_settings_post_loop(Req, RetriesLeft - 1)
    end.

do_handle_pool_settings_post(Req) ->
    Config = ns_config:get(),
    CompatVersion = cluster_compat_mode:get_compat_version(Config),

    execute_if_validated(
      fun (Values) ->
              do_handle_pool_settings_post_body(Req, Config, CompatVersion, Values)
      end, Req, validate_pool_settings_post(Config, CompatVersion, Req:parse_post())).

do_handle_pool_settings_post_body(Req, Config, CompatVersion, Values) ->
    case lists:keyfind(quotas, 1, Values) of
        {_, Quotas} ->
            case ns_storage_conf:set_quotas(Config, Quotas) of
                ok ->
                    ok;
                retry_needed ->
                    throw(retry_needed)
            end;
        false ->
            ok
    end,

    case lists:keyfind(clusterName, 1, Values) of
        {_, ClusterName} ->
            ok = ns_config:set(cluster_name, ClusterName);
        false ->
            ok
    end,

    case cluster_compat_mode:is_version_40(CompatVersion) of
        true ->
            do_audit_cluster_settings(Req);
        false ->
            ok
    end,

    reply(Req, 200).

do_audit_cluster_settings(Req) ->
    %% this is obviously raceful, but since it's just audit...
    {ok, KvQuota} = ns_storage_conf:get_memory_quota(kv),
    {ok, IndexQuota} = ns_storage_conf:get_memory_quota(index),
    {ok, FTSQuota} = ns_storage_conf:get_memory_quota(fts),
    {ok, CBASQuota} = ns_storage_conf:get_memory_quota(cbas),
    ClusterName = get_cluster_name(),

    ns_audit:cluster_settings(Req, KvQuota, IndexQuota, FTSQuota, CBASQuota, ClusterName).

handle_settings_web(Req) ->
    reply_json(Req, build_settings_web()).

build_settings_web() ->
    Port = proplists:get_value(port, webconfig()),
    User = case ns_config_auth:get_user(admin) of
               undefined ->
                   "";
               U ->
                   U
           end,
    {struct, [{port, Port},
              {username, list_to_binary(User)}]}.

%% @doc Settings to en-/disable stats sending to some remote server
handle_settings_stats(Req) ->
    reply_json(Req, {struct, build_settings_stats()}).

build_settings_stats() ->
    Defaults = default_settings_stats_config(),
    [{send_stats, SendStats}] = ns_config:search_prop(
                                  ns_config:get(), settings, stats, Defaults),
    [{sendStats, SendStats}].

default_settings_stats_config() ->
    [{send_stats, false}].

handle_settings_stats_post(Req) ->
    PostArgs = Req:parse_post(),
    SendStats = proplists:get_value("sendStats", PostArgs),
    case validate_settings_stats(SendStats) of
        error ->
            reply_text(Req, "The value of \"sendStats\" must be true or false.", 400);
        SendStats2 ->
            ns_config:set(settings, [{stats, [{send_stats, SendStats2}]}]),
            reply(Req, 200)
    end.

validate_settings_stats(SendStats) ->
    case SendStats of
        "true" -> true;
        "false" -> false;
        _ -> error
    end.

%% @doc Settings to en-/disable auto-failover
handle_settings_auto_failover(Req) ->
    Config = build_settings_auto_failover(),
    Enabled = proplists:get_value(enabled, Config),
    Timeout = proplists:get_value(timeout, Config),
    Count = proplists:get_value(count, Config),
    reply_json(Req, {struct, [{enabled, Enabled},
                              {timeout, Timeout},
                              {count, Count}]}).

build_settings_auto_failover() ->
    {value, Config} = ns_config:search(ns_config:get(), auto_failover_cfg),
    Config.

handle_settings_auto_failover_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    Enabled = proplists:get_value("enabled", PostArgs),
    Timeout = proplists:get_value("timeout", PostArgs),
    % MaxNodes is hard-coded to 1 for now.
    MaxNodes = "1",
    case {ValidateOnly,
          validate_settings_auto_failover(Enabled, Timeout, MaxNodes)} of
        {false, [true, Timeout2, MaxNodes2]} ->
            auto_failover:enable(Timeout2, MaxNodes2),
            ns_audit:enable_auto_failover(Req, Timeout2, MaxNodes2),
            reply(Req, 200);
        {false, false} ->
            auto_failover:disable(),
            ns_audit:disable_auto_failover(Req),
            reply(Req, 200);
        {false, {error, Errors}} ->
            Errors2 = [<<Msg/binary, "\n">> || {_, Msg} <- Errors],
            reply_text(Req, Errors2, 400);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        % Validation only and no errors
        {true, _}->
            reply_json(Req, {struct, [{errors, null}]}, 200)
    end.

validate_settings_auto_failover(Enabled, Timeout, MaxNodes) ->
    Enabled2 = case Enabled of
        "true" -> true;
        "false" -> false;
        _ -> {enabled, <<"The value of \"enabled\" must be true or false">>}
    end,
    case Enabled2 of
        true ->
            Errors = [is_valid_positive_integer_in_range(Timeout, ?AUTO_FAILLOVER_MIN_TIMEOUT, ?AUTO_FAILLOVER_MAX_TIMEOUT) orelse
                      {timeout, erlang:list_to_binary(io_lib:format("The value of \"timeout\" must be a positive integer in a range from ~p to ~p",
                                                                                [?AUTO_FAILLOVER_MIN_TIMEOUT, ?AUTO_FAILLOVER_MAX_TIMEOUT]))},
                      is_valid_positive_integer(MaxNodes) orelse
                      {maxNodes, <<"The value of \"maxNodes\" must be a positive integer">>}],
            case lists:filter(fun (E) -> E =/= true end, Errors) of
                [] ->
                    [Enabled2, list_to_integer(Timeout),
                     list_to_integer(MaxNodes)];
                Errors2 ->
                    {error, Errors2}
             end;
        false ->
            Enabled2;
        Error ->
            {error, [Error]}
    end.

%% @doc Resets the number of nodes that were automatically failovered to zero
handle_settings_auto_failover_reset_count(Req) ->
    auto_failover:reset_count(),
    ns_audit:reset_auto_failover_count(Req),
    reply(Req, 200).

maybe_cleanup_old_buckets() ->
    case ns_config_auth:is_system_provisioned() of
        true ->
            ok;
        false ->
            true = ns_node_disco:nodes_wanted() =:= [node()],
            ns_storage_conf:delete_unused_buckets_db_files()
    end.

is_valid_port_number_or_error("SAME") -> true;
is_valid_port_number_or_error(StringPort) ->
    case (catch menelaus_util:parse_validate_port_number(StringPort)) of
        {error, [Error]} ->
            Error;
        _ ->
            true
    end.

is_port_free("SAME") ->
    true;
is_port_free(Port) ->
    ns_bucket:is_port_free(list_to_integer(Port)).

validate_settings(Port, U, P) ->
    case lists:all(fun erlang:is_list/1, [Port, U, P]) of
        false -> [<<"All parameters must be given">>];
        _ -> Candidates = [is_valid_port_number_or_error(Port),
                           is_port_free(Port)
                           orelse <<"Port is already in use">>,
                           case {U, P} of
                               {[], _} -> <<"Username and password are required.">>;
                               {[_Head | _], P} ->
                                   case menelaus_web_rbac:validate_cred(U, username) of
                                       true ->
                                           menelaus_web_rbac:validate_cred(P, password);
                                       Msg ->
                                           Msg
                                   end
                           end],
             lists:filter(fun (E) -> E =/= true end,
                          Candidates)
    end.

%% These represent settings for a cluster.  Node settings should go
%% through the /node URIs
handle_settings_web_post(Req) ->
    PostArgs = Req:parse_post(),
    Port = proplists:get_value("port", PostArgs),
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    case validate_settings(Port, U, P) of
        [_Head | _] = Errors ->
            reply_json(Req, Errors, 400);
        [] ->
            PortInt = case Port of
                         "SAME" -> proplists:get_value(port, webconfig());
                         _      -> list_to_integer(Port)
                      end,
            case Port =/= PortInt orelse ns_config_auth:credentials_changed(admin, U, P) of
                false -> ok; % No change.
                true ->
                    maybe_cleanup_old_buckets(),
                    ns_config:set(rest, [{port, PortInt}]),
                    ns_config_auth:set_credentials(admin, U, P),
                    case ns_config:search(uuid) of
                        false ->
                            Uuid = couch_uuids:random(),
                            ns_config:set(uuid, Uuid);
                        _ ->
                            ok
                    end,
                    ns_audit:password_change(Req, {U, admin}),

                    menelaus_ui_auth:reset()

                    %% No need to restart right here, as our ns_config
                    %% event watcher will do it later if necessary.
            end,
            Host = Req:get_header_value("host"),
            PureHostName = case string:tokens(Host, ":") of
                               [Host] -> Host;
                               [HostName, _] -> HostName
                           end,
            NewHost = PureHostName ++ ":" ++ integer_to_list(PortInt),
            %% TODO: detect and support https when time will come
            reply_json(Req, {struct, [{newBaseUri, list_to_binary("http://" ++ NewHost ++ "/")}]})
    end.

handle_settings_alerts(Req) ->
    {value, Config} = ns_config:search(email_alerts),
    reply_json(Req, {struct, menelaus_alert:build_alerts_json(Config)}).

handle_settings_alerts_post(Req) ->
    PostArgs = Req:parse_post(),
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    case {ValidateOnly, menelaus_alert:parse_settings_alerts_post(PostArgs)} of
        {false, {ok, Config}} ->
            ns_config:set(email_alerts, Config),
            ns_audit:alerts(Req, Config),
            reply(Req, 200);
        {false, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {true, {ok, _}} ->
            reply_json(Req, {struct, [{errors, null}]}, 200);
        {true, {error, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200)
    end.

%% @doc Sends a test email with the current settings
handle_settings_alerts_send_test_email(Req) ->
    PostArgs = Req:parse_post(),
    Subject = proplists:get_value("subject", PostArgs),
    Body = proplists:get_value("body", PostArgs),
    PostArgs1 = [{K, V} || {K, V} <- PostArgs,
                           not lists:member(K, ["subject", "body"])],
    {ok, Config} = menelaus_alert:parse_settings_alerts_post(PostArgs1),

    case ns_mail:send(Subject, Body, Config) of
        ok ->
            reply(Req, 200);
        {error, Reason} ->
            Msg =
                case Reason of
                    {_, _, {error, R}} ->
                        R;
                    {_, _, R} ->
                        R;
                    R ->
                        R
                end,

            reply_json(Req, {struct, [{error, couch_util:to_binary(Msg)}]}, 400)
    end.

-ifdef(EUNIT).

test() ->
    eunit:test({module, ?MODULE},
               [verbose]).

-endif.

%% log categorizing, every logging line should be unique, and most
%% should be categorized

ns_log_cat(0013) ->
    crit;
ns_log_cat(0019) ->
    warn;
ns_log_cat(?START_FAIL) ->
    crit;
ns_log_cat(?NODE_EJECTED) ->
    info;
ns_log_cat(?UI_SIDE_ERROR_REPORT) ->
    warn.

ns_log_code_string(0013) ->
    "node join failure";
ns_log_code_string(0019) ->
    "server error during request processing";
ns_log_code_string(?START_FAIL) ->
    "failed to start service";
ns_log_code_string(?NODE_EJECTED) ->
    "node was ejected";
ns_log_code_string(?UI_SIDE_ERROR_REPORT) ->
    "client-side error report".

alert_key(?BUCKET_CREATED)  -> bucket_created;
alert_key(?BUCKET_DELETED)  -> bucket_deleted;
alert_key(_) -> all.

handle_dot(Bucket, Req) ->
    reply_ok(Req, "text/plain; charset=utf-8", ns_janitor_vis:graphviz(Bucket)).

handle_dotsvg(Bucket, Req) ->
    Dot = ns_janitor_vis:graphviz(Bucket),
    DoRefresh = case proplists:get_value("refresh", Req:parse_qs(), "") of
                    "ok" -> true;
                    "yes" -> true;
                    "1" -> true;
                    _ -> false
                end,
    MaybeRefresh = if DoRefresh ->
                           [{"refresh", 1}];
                      true -> []
                   end,
    reply_ok(Req, "image/svg+xml",
             menelaus_util:insecure_pipe_through_command("dot -Tsvg", Dot),
             MaybeRefresh).

handle_node("self", Req)            -> handle_node("default", node(), Req);
handle_node(S, Req) when is_list(S) -> handle_node("default", list_to_atom(S), Req).

handle_node(_PoolId, Node, Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    case lists:member(Node, ns_node_disco:nodes_wanted()) of
        true ->
            Result = build_full_node_info(Node, LocalAddr),
            reply_json(Req, Result);
        false ->
            reply_json(Req, <<"Node is unknown to this cluster.">>, 404)
    end.

build_full_node_info(Node, LocalAddr) ->
    {struct, KV} = (build_nodes_info_fun(true, normal, unstable, LocalAddr))(Node, undefined),
    NodeStatus = ns_doctor:get_node(Node),
    StorageConf = ns_storage_conf:storage_conf_from_node_status(NodeStatus),
    R = {struct, storage_conf_to_json(StorageConf)},
    DiskData = proplists:get_value(disk_data, NodeStatus, []),

    Fields = [{availableStorage, {struct, [{hdd, [{struct, [{path, list_to_binary(Path)},
                                                            {sizeKBytes, SizeKBytes},
                                                            {usagePercent, UsagePercent}]}
                                                  || {Path, SizeKBytes, UsagePercent} <- DiskData]}]}},
              {storageTotals, {struct, [{Type, {struct, PropList}}
                                        || {Type, PropList} <- ns_storage_conf:nodes_storage_info([Node])]}},
              {storage, R}] ++ KV ++ build_memory_quota_info(),
    {struct, lists:filter(fun (X) -> X =/= undefined end,
                                   Fields)}.

build_memory_quota_info() ->
    build_memory_quota_info(ns_config:latest()).

build_memory_quota_info(Config) ->
    {ok, KvQuota} = ns_storage_conf:get_memory_quota(Config, kv),
    Props = [{memoryQuota, KvQuota}],
    Props1 = case cluster_compat_mode:is_cluster_40() of
        true ->
            {ok, IndexQuota} = ns_storage_conf:get_memory_quota(Config, index),
            [{indexMemoryQuota, IndexQuota} | Props];
        false ->
            Props
    end,
    Props2 = case cluster_compat_mode:is_cluster_45() of
        true ->
            {ok, FTSQuota} = ns_storage_conf:get_memory_quota(Config, fts),
            [{ftsMemoryQuota, FTSQuota} | Props1];
        false ->
            Props1
    end,
    Props3 = case cluster_compat_mode:is_cluster_45() of
        true ->
            {ok, CBASQuota} = ns_storage_conf:get_memory_quota(Config, cbas),
            [{cbasMemoryQuota, CBASQuota} | Props2];
        false ->
            Props2
    end,
    Props3.


% S = [{ssd, []},
%      {hdd, [[{path, /some/nice/disk/path}, {quotaMb, 1234}, {state, ok}],
%            [{path, /another/good/disk/path}, {quotaMb, 5678}, {state, ok}]]}].
%
storage_conf_to_json(S) ->
    lists:map(fun ({StorageType, Locations}) -> % StorageType is ssd or hdd.
                  {StorageType, lists:map(fun (LocationPropList) ->
                                              {struct, lists:map(fun location_prop_to_json/1, LocationPropList)}
                                          end,
                                          Locations)}
              end,
              S).

location_prop_to_json({path, L}) -> {path, list_to_binary(L)};
location_prop_to_json({index_path, L}) -> {index_path, list_to_binary(L)};
location_prop_to_json({quotaMb, none}) -> {quotaMb, none};
location_prop_to_json({state, ok}) -> {state, ok};
location_prop_to_json(KV) -> KV.

handle_node_self_xdcr_ssl_ports(Req) ->
    case is_xdcr_over_ssl_allowed() of
        false ->
            reply_json(Req, [], 403);
        true ->
            {value, ProxyPort} = ns_config:search_node(ssl_proxy_downstream_port),
            {value, RESTSSL} = ns_config:search_node(ssl_rest_port),
            {value, CapiSSL} = ns_config:search_node(ssl_capi_port),
            reply_json(Req, {struct, [{sslProxy, ProxyPort},
                                      {httpsMgmt, RESTSSL},
                                      {httpsCAPI, CapiSSL}]})
    end.

-spec handle_node_settings_post(string() | atom(), any()) -> no_return().
handle_node_settings_post("self", Req)            -> handle_node_settings_post(node(), Req);
handle_node_settings_post(S, Req) when is_list(S) -> handle_node_settings_post(list_to_atom(S), Req);

handle_node_settings_post(Node, Req) ->
    Params = Req:parse_post(),

    {ok, DefaultDbPath} = ns_storage_conf:this_node_dbdir(),
    DbPath = proplists:get_value("path", Params, DefaultDbPath),
    IxPath = proplists:get_value("index_path", Params, DbPath),

    case Node =/= node() of
        true -> exit('Setting the disk storage path for other servers is not yet supported.');
        _ -> ok
    end,

    case ns_config_auth:is_system_provisioned() andalso DbPath =/= DefaultDbPath of
        true ->
            %% MB-7344: we had 1.8.1 instructions allowing that. And
            %% 2.0 works very differently making that original
            %% instructions lose data. Thus we decided it's much safer
            %% to un-support this path.
            reply_json(Req, {struct, [{error, <<"Changing data of nodes that are part of provisioned cluster is not supported">>}]}, 400),
            exit(normal);
        _ ->
            ok
    end,

    ValidatePath =
        fun ({Param, Path}) ->
                case Path of
                    [] ->
                        iolist_to_binary(io_lib:format("~p cannot be empty", [Param]));
                    Path ->
                        case misc:is_absolute_path(Path) of
                           false ->
                                iolist_to_binary(
                                  io_lib:format("An absolute path is required for ~p",
                                                [Param]));
                           _ -> ok
                        end
                end
        end,

    Results0 = lists:usort(lists:map(ValidatePath, [{path, DbPath},
                                                    {index_path, IxPath}])),
    Results1 =
        case Results0 of
            [ok] ->
                case ns_storage_conf:setup_disk_storage_conf(DbPath, IxPath) of
                    ok ->
                        ns_audit:disk_storage_conf(Req, Node, DbPath, IxPath),
                        %% NOTE: due to required restart we need to protect
                        %% ourselves from 'death signal' of parent
                        erlang:process_flag(trap_exit, true),

                        %% performing required restart from
                        %% successfull path change
                        {ok, _} = ns_server_cluster_sup:restart_ns_server(),
                        reply(Req, 200),
                        erlang:exit(normal);
                    {errors, Msgs} -> Msgs
                end;
            _ -> Results0
        end,


    case lists:filter(fun(ok) -> false;
                         (_) -> true
                      end, Results1) of
        [] -> exit(cannot_happen);
        Errs -> reply_json(Req, Errs, 400)
    end.

validate_setup_services_post(Req) ->
    Params = Req:parse_post(),
    case ns_config_auth:is_system_provisioned() of
        true ->
            {error, <<"cannot change node services after cluster is provisioned">>};
        _ ->
            ServicesString = proplists:get_value("services", Params, ""),
            case parse_validate_services_list(ServicesString) of
                {ok, Svcs} ->
                    case lists:member(kv, Svcs) of
                        true ->
                            case ns_cluster:enforce_topology_limitation(Svcs) of
                                ok ->
                                    setup_services_check_quota(Svcs);
                                Error ->
                                    Error
                            end;
                        false ->
                            {error, <<"cannot setup first cluster node without kv service">>}
                    end;
                {error, Msg} ->
                    {error, Msg}
            end
    end.

setup_services_check_quota(Services) ->
    {ok, KvQuota} = ns_storage_conf:get_memory_quota(kv),
    {ok, IndexQuota} = ns_storage_conf:get_memory_quota(index),
    {ok, FTSQuota} = ns_storage_conf:get_memory_quota(fts),
    {ok, CBASQuota} = ns_storage_conf:get_memory_quota(cbas),

    Quotas = [{kv, KvQuota},
              {index, IndexQuota},
              {fts, FTSQuota},
              {cbas, CBASQuota}],

    case ns_storage_conf:check_this_node_quotas(Services, Quotas) of
        ok ->
            {ok, Services};
        {error, {total_quota_too_high, _, TotalQuota, MaxAllowed}} ->
            Msg = io_lib:format("insufficient memory to satisfy memory quota "
                                "for the services "
                                "(requested quota is ~bMB, "
                                "maximum allowed quota for the node is ~bMB)",
                                [TotalQuota, MaxAllowed]),
            {error, iolist_to_binary(Msg)}
    end.

handle_setup_services_post(Req) ->
    case validate_setup_services_post(Req) of
        {error, Error} ->
            reply_json(Req, [Error], 400);
        {ok, Services} ->
            ns_config:set({node, node(), services}, Services),
            ns_audit:setup_node_services(Req, node(), Services),
            reply(Req, 200)
    end.

validate_add_node_params(User, Password) ->
    Candidates = case lists:member(undefined, [User, Password]) of
                     true -> [<<"Missing required parameter.">>];
                     _ -> [case {User, Password} of
                               {[], []} -> true;
                               {[_Head | _], [_PasswordHead | _]} -> true;
                               {[], [_PasswordHead | _]} -> <<"If a username is not specified, a password must not be supplied.">>;
                               _ -> <<"A password must be supplied.">>
                           end]
                 end,
    lists:filter(fun (E) -> E =/= true end, Candidates).

%% erlang R15B03 has http_uri:parse/2 that does the job
%% reimplement after support of R14B04 will be dropped
parse_hostname(Hostname) ->
    do_parse_hostname(misc:trim(Hostname)).

do_parse_hostname([]) ->
    throw({error, [<<"Hostname is required.">>]});
do_parse_hostname(Hostname) ->
    WithoutScheme = case string:str(Hostname, "://") of
                        0 ->
                            Hostname;
                        X ->
                            Scheme = string:sub_string(Hostname, 1, X - 1),
                            case string:to_lower(Scheme) =:= "http" of
                                false ->
                                    throw({error, [list_to_binary("Unsupported protocol " ++ Scheme)]});
                                true ->
                                    string:sub_string(Hostname, X + 3)
                            end
                    end,

    {Host, StringPort} = case string:tokens(WithoutScheme, ":") of
                             [H | [P | []]] ->
                                 {H, P};
                             [H | []] ->
                                 {H, "8091"};
                             _ ->
                                 throw({error, [<<"The hostname is malformed.">>]})
                         end,

    {Host, menelaus_util:parse_validate_port_number(StringPort)}.

handle_add_node(Req) ->
    do_handle_add_node(Req, undefined).

handle_add_node_to_group(GroupUUIDString, Req) ->
    do_handle_add_node(Req, list_to_binary(GroupUUIDString)).

do_handle_add_node(Req, GroupUUID) ->
    %% parameter example: hostname=epsilon.local, user=Administrator, password=asd!23
    Params = Req:parse_post(),

    Parsed = case parse_join_cluster_params(Params, false) of
                 {ok, ParsedKV} ->
                     case validate_add_node_params(proplists:get_value(user, ParsedKV),
                                                   proplists:get_value(password, ParsedKV)) of
                         [] ->
                             {ok, ParsedKV};
                         CredErrors ->
                             {errors, CredErrors}
                     end;
                 {errors, ParseErrors} ->
                     {errors, ParseErrors}
             end,

    case Parsed of
        {ok, KV} ->
            User = proplists:get_value(user, KV),
            Password = proplists:get_value(password, KV),
            Hostname = proplists:get_value(host, KV),
            Port = proplists:get_value(port, KV),
            Services = proplists:get_value(services, KV),
            case ns_cluster:add_node_to_group(
                   Hostname, Port,
                   {User, Password},
                   GroupUUID,
                   Services) of
                {ok, OtpNode} ->
                    ns_audit:add_node(Req, Hostname, Port, User, GroupUUID, Services, OtpNode),
                    reply_json(Req, {struct, [{otpNode, OtpNode}]}, 200);
                {error, unknown_group, Message, _} ->
                    reply_json(Req, [Message], 404);
                {error, _What, Message, _Nested} ->
                    reply_json(Req, [Message], 400)
            end;
        {errors, ErrorList} ->
            reply_json(Req, ErrorList, 400)
    end.

parse_failover_args(Req) ->
    Params = Req:parse_post(),
    NodeArg = proplists:get_value("otpNode", Params, "undefined"),
    Node = (catch list_to_existing_atom(NodeArg)),
    case Node of
        undefined ->
            {error, "No server specified."};
        _ when not is_atom(Node) ->
            {error, "Unknown server given."};
        _ ->
            {ok, Node}
    end.


handle_failover(Req) ->
    case parse_failover_args(Req) of
        {ok, Node} ->
            case ns_cluster_membership:failover(Node) of
                ok ->
                    ns_audit:failover_node(Req, Node, hard),
                    reply(Req, 200);
                rebalance_running ->
                    reply_text(Req, "Rebalance running.", 503);
                in_recovery ->
                    reply_text(Req, "Cluster is in recovery mode.", 503);
                last_node ->
                    reply_text(Req, "Last active node cannot be failed over.", 400);
                unknown_node ->
                    reply_text(Req, "Unknown server given.", 400);
                Other ->
                    reply_text(Req,
                               io_lib:format("Unexpected server error: ~p", [Other]),
                               500)
            end;
        {error, ErrorMsg} ->
            reply_text(Req, ErrorMsg, 400)
    end.

handle_start_graceful_failover(Req) ->
    case parse_failover_args(Req) of
        {ok, Node} ->
            Msg = case ns_orchestrator:start_graceful_failover(Node) of
                      ok ->
                          [];
                      in_progress ->
                          {503, "Rebalance running."};
                      in_recovery ->
                          {503, "Cluster is in recovery mode."};
                      not_graceful ->
                          {400, "Failover cannot be done gracefully (would lose vbuckets)."};
                      non_kv_node ->
                          {400, "Failover cannot be done gracefully for a node without data. Use hard failover."};
                      unknown_node ->
                          {400, "Unknown server given."};
                      last_node ->
                          {400, "Last active node cannot be failed over."};
                      {config_sync_failed, _} ->
                          {500, "Failed to synchronize config to other nodes"};
                      Other ->
                          {500,
                           io_lib:format("Unexpected server error: ~p", [Other])}
                  end,
            case Msg of
                [] ->
                    ns_audit:failover_node(Req, Node, graceful),
                    reply(Req, 200);
                {Code, Text} ->
                    reply_text(Req, Text, Code)
            end;
        {error, ErrorMsg} ->
            reply_text(Req, ErrorMsg, 400)
    end.

handle_rebalance(Req) ->
    Params = Req:parse_post(),
    case string:tokens(proplists:get_value("knownNodes", Params, ""),",") of
        [] ->
            reply_json(Req, {struct, [{empty_known_nodes, 1}]}, 400);
        KnownNodesS ->
            EjectedNodesS = string:tokens(proplists:get_value("ejectedNodes",
                                                              Params, ""), ","),
            UnknownNodes = [S || S <- EjectedNodesS ++ KnownNodesS,
                                try list_to_existing_atom(S), false
                                catch error:badarg -> true end],
            case UnknownNodes of
                [] ->
                    DeltaRecoveryBuckets = case proplists:get_value("deltaRecoveryBuckets", Params) of
                                               undefined -> all;
                                               RawRecoveryBuckets ->
                                                   [BucketName || BucketName <- string:tokens(RawRecoveryBuckets, ",")]
                                           end,
                    do_handle_rebalance(Req, KnownNodesS, EjectedNodesS, DeltaRecoveryBuckets);
                _ ->
                    reply_json(Req, {struct, [{mismatch, 1}]}, 400)
            end
    end.

-spec do_handle_rebalance(any(), [string()], [string()], all | [bucket_name()]) -> any().
do_handle_rebalance(Req, KnownNodesS, EjectedNodesS, DeltaRecoveryBuckets) ->
    EjectedNodes = [list_to_existing_atom(N) || N <- EjectedNodesS],
    KnownNodes = [list_to_existing_atom(N) || N <- KnownNodesS],
    case ns_cluster_membership:start_rebalance(KnownNodes,
                                               EjectedNodes, DeltaRecoveryBuckets) of
        already_balanced ->
            reply(Req, 200);
        in_progress ->
            reply(Req, 200);
        nodes_mismatch ->
            reply_json(Req, {struct, [{mismatch, 1}]}, 400);
        delta_recovery_not_possible ->
            reply_json(Req, {struct, [{deltaRecoveryNotPossible, 1}]}, 400);
        no_active_nodes_left ->
            reply_text(Req, "No active nodes left", 400);
        in_recovery ->
            reply_text(Req, "Cluster is in recovery mode.", 503);
        no_kv_nodes_left ->
            reply_json(Req, {struct, [{noKVNodesLeft, 1}]}, 400);
        ok ->
            ns_audit:rebalance_initiated(Req, KnownNodes, EjectedNodes, DeltaRecoveryBuckets),
            reply(Req, 200)
    end.

handle_rebalance_progress(_PoolId, Req) ->
    Status = case ns_cluster_membership:get_rebalance_status() of
                 {running, PerNode} ->
                     [{status, <<"running">>}
                      | [{atom_to_binary(Node, latin1),
                          {struct, [{progress, Progress}]}} || {Node, Progress} <- PerNode]];
                 _ ->
                     case ns_config:search(rebalance_status) of
                         {value, {none, ErrorMessage}} ->
                             [{status, <<"none">>},
                              {errorMessage, iolist_to_binary(ErrorMessage)}];
                         _ -> [{status, <<"none">>}]
                     end
             end,
    reply_json(Req, {struct, Status}, 200).

handle_stop_rebalance(Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("onlyIfSafe", Params) =:= "1" of
        true ->
            case ns_cluster_membership:stop_rebalance_if_safe() of
                unsafe ->
                    reply(Req, 400);
                _ -> %% ok | not_rebalancing
                    reply(Req, 200)
            end;
        _ ->
            ns_cluster_membership:stop_rebalance(),
            reply(Req, 200)
    end.

handle_re_add_node(Req) ->
    Params = Req:parse_post(),
    do_handle_set_recovery_type(Req, full, Params).

handle_re_failover(Req) ->
    Params = Req:parse_post(),
    NodeString = proplists:get_value("otpNode", Params, "undefined"),
    case ns_cluster_membership:re_failover(NodeString) of
        ok ->
            ns_audit:failover_node(Req, list_to_existing_atom(NodeString), cancel_recovery),
            reply(Req, 200);
        not_possible ->
            reply(Req, 400)
    end.

handle_tasks(PoolId, Req) ->
    RebTimeoutS = proplists:get_value("rebalanceStatusTimeout", Req:parse_qs(), "2000"),
    case menelaus_util:parse_validate_number(RebTimeoutS, 1000, 120000) of
        {ok, RebTimeout} ->
            do_handle_tasks(PoolId, Req, RebTimeout);
        _ ->
            reply_json(Req, {struct, [{rebalanceStatusTimeout, <<"invalid">>}]}, 400)
    end.

do_handle_tasks(PoolId, Req, RebTimeout) ->
    JSON = ns_doctor:build_tasks_list(PoolId, RebTimeout),
    reply_json(Req, JSON, 200).

handle_reset_alerts(Req) ->
    Params = Req:parse_qs(),
    Token = list_to_binary(proplists:get_value("token", Params, "")),
    reply_json(Req, menelaus_web_alerts_srv:consume_alerts(Token)).

nodes_to_hostnames(Config, Req) ->
    Nodes = ns_cluster_membership:active_nodes(Config),
    LocalAddr = menelaus_util:local_addr(Req),
    [{N, list_to_binary(build_node_hostname(Config, N, LocalAddr))}
     || N <- Nodes].

%% Node list
%% GET /pools/{PoolID}/buckets/{Id}/nodes
%%
%% Provides a list of nodes for a specific bucket (generally all nodes) with
%% links to stats for that bucket
handle_bucket_node_list(_PoolId, BucketName, Req) ->
    %% NOTE: since 4.0 release we're listing all active nodes as
    %% part of our approach for dealing with query stats
    NHs = nodes_to_hostnames(ns_config:get(), Req),
    Servers =
        [{struct,
          [{hostname, Hostname},
           {uri, bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname])},
           {stats, {struct, [{uri,
                              bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname, "stats"])}]}}]}
         || {_, Hostname} <- NHs],
    reply_json(Req, {struct, [{servers, Servers}]}).

find_node_hostname(HostnameList, Req) ->
    Hostname = list_to_binary(HostnameList),
    NHs = nodes_to_hostnames(ns_config:get(), Req),
    case [N || {N, CandidateHostname} <- NHs,
               CandidateHostname =:= Hostname] of
        [] ->
            false;
        [Node] ->
            {ok, Node}
    end.

%% Per-Node Stats URL information
%% GET /pools/{PoolID}/buckets/{Id}/nodes/{NodeId}
%%
%% Provides node hostname and links to the default bucket and node-specific
%% stats for the default bucket
%%
%% TODO: consider what else might be of value here
handle_bucket_node_info(_PoolId, BucketName, Hostname, Req) ->
    case find_node_hostname(Hostname, Req) of
        false ->
            reply_not_found(Req);
        _ ->
            BucketURI = bin_concat_path(["pools", "default", "buckets", BucketName]),
            NodeStatsURI = bin_concat_path(["pools", "default", "buckets", BucketName, "nodes", Hostname, "stats"]),
            reply_json(Req,
                       {struct, [{hostname, list_to_binary(Hostname)},
                                 {bucket, {struct, [{uri, BucketURI}]}},
                                 {stats, {struct, [{uri, NodeStatsURI}]}}]})
    end.

%% this serves fresh nodes replication and health status
handle_node_statuses(Req) ->
    LocalAddr = menelaus_util:local_addr(Req),
    OldStatuses = ns_doctor:get_nodes(),
    Config = ns_config:get(),
    BucketsAll = ns_bucket:get_buckets(Config),
    FreshStatuses = ns_heart:grab_fresh_failover_safeness_infos(BucketsAll),
    NodeStatuses =
        lists:map(
          fun (N) ->
                  InfoNode = ns_doctor:get_node(N, OldStatuses),
                  Hostname = proplists:get_value(hostname,
                                                 build_node_info(Config, N, InfoNode, LocalAddr)),
                  NewInfoNode = ns_doctor:get_node(N, FreshStatuses),
                  Dataless = not lists:member(kv, ns_cluster_membership:node_services(Config, N)),
                  V = case proplists:get_bool(down, NewInfoNode) of
                          true ->
                              {struct, [{status, unhealthy},
                                        {otpNode, N},
                                        {dataless, Dataless},
                                        {replication, average_failover_safenesses(N, OldStatuses, BucketsAll)}]};
                          false ->
                              {struct, [{status, healthy},
                                        {gracefulFailoverPossible,
                                         ns_rebalancer:check_graceful_failover_possible(N, BucketsAll)},
                                        {otpNode, N},
                                        {dataless, Dataless},
                                        {replication, average_failover_safenesses(N, FreshStatuses, BucketsAll)}]}
                      end,
                  {Hostname, V}
          end, ns_node_disco:nodes_wanted()),
    reply_json(Req, {struct, NodeStatuses}, 200).

average_failover_safenesses(Node, NodeInfos, BucketsAll) ->
    average_failover_safenesses_rec(Node, NodeInfos, BucketsAll, 0, 0).

average_failover_safenesses_rec(_Node, _NodeInfos, [], Sum, Count) ->
    try Sum / Count
    catch error:badarith -> 1.0
    end;
average_failover_safenesses_rec(Node, NodeInfos, [{BucketName, BucketConfig} | RestBuckets], Sum, Count) ->
    Level = failover_safeness_level:extract_replication_uptodateness(BucketName, BucketConfig, Node, NodeInfos),
    average_failover_safenesses_rec(Node, NodeInfos, RestBuckets, Sum + Level, Count + 1).

handle_set_autocompaction(Req) ->
    Params = Req:parse_post(),
    Is40 = cluster_compat_mode:is_cluster_40(),
    SettingsRV = parse_validate_auto_compaction_settings(Params, Is40),
    ValidateOnly = (proplists:get_value("just_validate", Req:parse_qs()) =:= "1"),
    case {ValidateOnly, SettingsRV} of
        {_, {errors, Errors}} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400);
        {true, {ok, _ACSettings, _, _}} ->
            reply_json(Req, {struct, [{errors, {struct, []}}]}, 200);
        {false, {ok, ACSettings, MaybePurgeInterval, MaybeIndex}} ->
            ns_config:set(autocompaction, ACSettings),
            case MaybePurgeInterval of
                [{purge_interval, PurgeInterval}] ->
                    case compaction_api:get_purge_interval(global) =:= PurgeInterval of
                        true ->
                            ok;
                        false ->
                            compaction_api:set_global_purge_interval(PurgeInterval)
                    end;
                [] ->
                    ok
            end,

            case Is40 of
                true ->
                    case cluster_compat_mode:is_cluster_45() of
                        true ->
                            new_index_compaction_settings(MaybeIndex);
                        false ->
                            old_index_compaction_settings(ACSettings, MaybeIndex)
                    end;
                false ->
                    ok
            end,

            ns_audit:modify_compaction_settings(Req, ACSettings ++ MaybePurgeInterval ++ MaybeIndex),
            reply_json(Req, [], 200)
    end.

old_index_compaction_settings(ACSettings, MaybeIndex) ->
    AllowedPeriod = proplists:get_value(allowed_time_period, ACSettings, []),
    Fragmentation =
        case MaybeIndex of
            [] ->
                [];
            _ ->
                [{fragmentation, misc:expect_prop_value(index_fragmentation_percentage, MaybeIndex)}]
        end,

    {ok, _} = index_settings_manager:update(compaction,
                                            [{interval, AllowedPeriod}] ++ Fragmentation).

new_index_compaction_settings(Settings) ->
    case proplists:get_value(index_fragmentation_percentage, Settings) of
        undefined ->
            ok;
        Val ->
            index_settings_manager:update(compaction, [{fragmentation, Val}])
    end,
    SetList = [{index_circular_compaction_days, daysOfWeek},
               {index_circular_compaction_abort, abort_outside},
               {index_circular_compaction_interval, interval}],
    Set = lists:filtermap(
            fun ({K, NewK}) ->
                    case proplists:get_value(K, Settings) of
                        undefined ->
                            false;
                        V ->
                            {true, {NewK, V}}
                    end
            end, SetList),
    case Set of
        [] ->
            ok;
        _ ->
            index_settings_manager:update(circularCompaction, Set)
    end,
    case proplists:get_value(index_compaction_mode, Settings) of
        undefined ->
            ok;
        Mode ->
            index_settings_manager:update(compactionMode, Mode)
    end.

mk_number_field_validator_error_maker(JSONName, Msg, Args) ->
    [{error, JSONName, iolist_to_binary(io_lib:format(Msg, Args))}].

mk_number_field_validator(Min, Max, Params) ->
    mk_number_field_validator(Min, Max, Params, list_to_integer).

mk_number_field_validator(Min, Max, Params, ParseFn) ->
    fun ({JSONName, CfgName, HumanName}) ->
            case proplists:get_value(JSONName, Params) of
                undefined -> [];
                V ->
                    case menelaus_util:parse_validate_number(V, Min, Max, ParseFn) of
                        {ok, IntV} -> [{ok, CfgName, IntV}];
                        invalid ->
                            Msg = case ParseFn of
                                      list_to_integer -> "~s must be an integer";
                                      _ -> "~s must be a number"
                                  end,
                            mk_number_field_validator_error_maker(JSONName, Msg, [HumanName]);
                        too_small ->
                            mk_number_field_validator_error_maker(JSONName, "~s is too small. Allowed range is ~p - ~p", [HumanName, Min, Max]);
                        too_large ->
                            mk_number_field_validator_error_maker(JSONName, "~s is too large. Allowed range is ~p - ~p", [HumanName, Min, Max])
                    end
            end
    end.

parse_validate_boolean_field(JSONName, CfgName, Params) ->
    case proplists:get_value(JSONName, Params) of
        undefined -> [];
        "true" -> [{ok, CfgName, true}];
        "false" -> [{ok, CfgName, false}];
        _ -> [{error, JSONName, iolist_to_binary(io_lib:format("~s is invalid", [JSONName]))}]
    end.

mk_string_field_validator(AV, Params) ->
    fun ({JSONName, CfgName, HumanName}) ->
            case proplists:get_value(JSONName, Params) of
                undefined ->
                    [];
                Val ->
                    %% Is Val one of the acceptable ones?
                    %% Some settings are list of strings
                    %% E.g. daysOfWeek can be "Sunday, Thursday"
                    %% Need to validate each token.
                    Tokens = string:tokens(Val, ","),
                    case lists:any(fun (V) -> not lists:member(V, AV) end, Tokens) of
                        true ->
                            [{error, JSONName,
                              iolist_to_binary(io_lib:format("~s must be one of ~p",
                                                             [HumanName, AV]))}];
                        false ->
                            [{ok, CfgName, list_to_binary(Val)}]
                    end
            end
    end.

parse_and_validat_time_interval(JSONName, Params) ->
    FromH = JSONName ++ "[fromHour]",
    FromM = JSONName ++ "[fromMinute]",
    ToH = JSONName ++ "[toHour]",
    ToM = JSONName ++ "[toMinute]",
    Abort = JSONName ++ "[abortOutside]",

    Hours = [{FromH, from_hour, "from hour"}, {ToH, to_hour, "to hour"}],
    Mins = [{FromM, from_minute, "from minute"}, {ToM, to_minute, "to minute"}],

    Res0 = lists:flatmap(mk_number_field_validator(0, 23, Params), Hours)
        ++ lists:flatmap(mk_number_field_validator(0, 59, Params), Mins)
        ++ parse_validate_boolean_field(Abort, abort_outside, Params),

    Err = lists:filter(fun ({error, _, _}) -> true; (_) -> false end, Res0),
    %% If validation failed for any field then return error.
    case Err of
        [] ->
            Res0;
        _ ->
            Err
    end.

parse_and_validate_extra_index_settings(Params) ->
    CModeValidator = mk_string_field_validator(["circular", "full"], Params),
    RV0 = CModeValidator({"indexCompactionMode", index_compaction_mode,
                          "index compaction mode"}),

    DaysList = misc:get_days_list(),
    DaysValidator = mk_string_field_validator(DaysList, Params),
    RV1 = DaysValidator({"indexCircularCompaction[daysOfWeek]",
                         index_circular_compaction_days,
                         "index circular compaction days"}) ++ RV0,

    Time0 = parse_and_validat_time_interval("indexCircularCompaction[interval]",
                                            Params),
    TimeResults = case Time0 of
                      [] ->
                          Time0;
                      [{error, _, _}|_] ->
                          Time0;
                      _ ->
                          {_, {_, _, Abort}, Time1} = lists:keytake(abort_outside, 2, Time0),
                          [{ok, index_circular_compaction_abort, Abort},
                           {ok, index_circular_compaction_interval,
                            [{F, V} || {ok, F, V} <- Time1]}]
                  end,
    TimeResults ++ RV1.

parse_validate_auto_compaction_settings(Params, ExpectIndex) ->
    PercResults = lists:flatmap(mk_number_field_validator(2, 100, Params),
                                [{"databaseFragmentationThreshold[percentage]",
                                  db_fragmentation_percentage,
                                  "database fragmentation"},
                                 {"viewFragmentationThreshold[percentage]",
                                  view_fragmentation_percentage,
                                  "view fragmentation"}]),
    SizeResults = lists:flatmap(mk_number_field_validator(1, infinity, Params),
                                [{"databaseFragmentationThreshold[size]",
                                  db_fragmentation_size,
                                  "database fragmentation size"},
                                 {"viewFragmentationThreshold[size]",
                                  view_fragmentation_size,
                                  "view fragmentation size"}]),

    IndexResults =
        case ExpectIndex of
            true ->
                PercValidator = mk_number_field_validator(2, 100, Params),
                RV0 = PercValidator({"indexFragmentationThreshold[percentage]",
                                     index_fragmentation_percentage,
                                     "index fragmentation"}),
                case cluster_compat_mode:is_cluster_45() of
                    true ->
                        parse_and_validate_extra_index_settings(Params) ++ RV0;
                    false ->
                        RV0
                end;
            false ->
                []
        end,

    ParallelResult = case parse_validate_boolean_field("parallelDBAndViewCompaction", parallel_db_and_view_compaction, Params) of
                         [] -> [{error, "parallelDBAndViewCompaction", <<"parallelDBAndViewCompaction is missing">>}];
                         X -> X
                     end,
    PeriodTimeResults = parse_and_validat_time_interval("allowedTimePeriod",
                                                        Params),
    PurgeIntervalResults = (mk_number_field_validator(0.04, 60, Params, list_to_float))({"purgeInterval", purge_interval, "metadata purge interval"}),

    Errors0 = [{iolist_to_binary(Field), Msg} ||
                  {error, Field, Msg} <- lists:append([PercResults, ParallelResult, PeriodTimeResults,
                                                       SizeResults, PurgeIntervalResults, IndexResults])],
    BadFields = lists:sort(["databaseFragmentationThreshold",
                            "viewFragmentationThreshold"]),
    Errors = case ordsets:intersection(lists:sort(proplists:get_keys(Params)),
                                       BadFields) of
                 [] ->
                     Errors0;
                 ActualBadFields ->
                     Errors0 ++ [{<<"_">>, iolist_to_binary([<<"Got unsupported fields: ">>, string:join(ActualBadFields, " and ")])}]
             end,
    case Errors of
        [] ->
            SizePList = [{F, V} || {ok, F, V} <- SizeResults],
            PercPList = [{F, V} || {ok, F, V} <- PercResults],
            MainFields =
                [{F, V} || {ok, F, V} <- ParallelResult]
                ++
                [{database_fragmentation_threshold, {
                    proplists:get_value(db_fragmentation_percentage, PercPList),
                    proplists:get_value(db_fragmentation_size, SizePList)}},
                 {view_fragmentation_threshold, {
                    proplists:get_value(view_fragmentation_percentage, PercPList),
                    proplists:get_value(view_fragmentation_size, SizePList)}}],

            AllFields =
                case PeriodTimeResults of
                    [] ->
                        MainFields;
                    _ -> [{allowed_time_period, [{F, V} || {ok, F, V} <- PeriodTimeResults]}
                          | MainFields]
                end,
            MaybePurgeResults = [{F, V} || {ok, F, V} <- PurgeIntervalResults],
            MaybeIndexResults = [{F, V} || {ok, F, V} <- IndexResults],
            {ok, AllFields, MaybePurgeResults, MaybeIndexResults};
        _ ->
            {errors, Errors}
    end.

handle_settings_auto_compaction(Req) ->
    JSON = [{autoCompactionSettings, build_global_auto_compaction_settings()},
            {purgeInterval, compaction_api:get_purge_interval(global)}],
    reply_json(Req, {struct, JSON}, 200).

internal_settings_conf() ->
    GetBool = fun (SV) ->
                      case SV of
                          "true" -> {ok, true};
                          "false" -> {ok, false};
                          _ -> invalid
                      end
              end,

    GetNumber = fun (Min, Max) ->
                        fun (SV) ->
                                parse_validate_number(SV, Min, Max)
                        end
                end,
    GetNumberOrEmpty = fun (Min, Max, Empty) ->
                               fun (SV) ->
                                       case SV of
                                           "" -> Empty;
                                           _ ->
                                               parse_validate_number(SV, Min, Max)
                                       end
                               end
                       end,
    GetString = fun (SV) ->
                        {ok, list_to_binary(string:strip(SV))}
                end,

    [{index_aware_rebalance_disabled, indexAwareRebalanceDisabled, false, GetBool},
     {rebalance_index_waiting_disabled, rebalanceIndexWaitingDisabled, false, GetBool},
     {index_pausing_disabled, rebalanceIndexPausingDisabled, false, GetBool},
     {rebalance_ignore_view_compactions, rebalanceIgnoreViewCompactions, false, GetBool},
     {rebalance_moves_per_node, rebalanceMovesPerNode, 1, GetNumber(1, 1024)},
     {rebalance_moves_before_compaction, rebalanceMovesBeforeCompaction, 64, GetNumber(1, 1024)},
     {{couchdb, max_parallel_indexers}, maxParallelIndexers, <<>>, GetNumber(1, 1024)},
     {{couchdb, max_parallel_replica_indexers}, maxParallelReplicaIndexers, <<>>, GetNumber(1, 1024)},
     {max_bucket_count, maxBucketCount, 10, GetNumber(1, 8192)},
     {{request_limit, rest}, restRequestLimit, undefined, GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {{request_limit, capi}, capiRequestLimit, undefined, GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {drop_request_memory_threshold_mib, dropRequestMemoryThresholdMiB, undefined,
      GetNumberOrEmpty(0, 99999, {ok, undefined})},
     {gotraceback, gotraceback, <<"crash">>, GetString},
     {{auto_failover_disabled, index}, indexAutoFailoverDisabled, true, GetBool},
     {{cert, use_sha1}, certUseSha1, false, GetBool}] ++
        case cluster_compat_mode:is_goxdcr_enabled() of
            false ->
                [{{xdcr, max_concurrent_reps}, xdcrMaxConcurrentReps, 32, GetNumber(1, 256)},
                 {{xdcr, checkpoint_interval}, xdcrCheckpointInterval, 1800, GetNumber(60, 14400)},
                 {{xdcr, worker_batch_size}, xdcrWorkerBatchSize, 500, GetNumber(500, 10000)},
                 {{xdcr, doc_batch_size_kb}, xdcrDocBatchSizeKb, 2048, GetNumber(10, 100000)},
                 {{xdcr, failure_restart_interval}, xdcrFailureRestartInterval, 30, GetNumber(1, 300)},
                 {{xdcr, optimistic_replication_threshold}, xdcrOptimisticReplicationThreshold, 256,
                  GetNumberOrEmpty(0, 20*1024*1024, undefined)},
                 {xdcr_anticipatory_delay, xdcrAnticipatoryDelay, 0, GetNumber(0, 99999)}];
            true ->
                []
        end.

build_internal_settings_kvs() ->
    Conf = internal_settings_conf(),
    [{JK, case ns_config:read_key_fast(CK, DV) of
              undefined ->
                  DV;
              V ->
                  V
          end}
     || {CK, JK, DV, _} <- Conf].

handle_internal_settings(Req) ->
    InternalSettings = lists:filter(
                         fun ({_, undefined}) ->
                                 false;
                             (_) ->
                                 true
                         end, build_internal_settings_kvs()),
    reply_json(Req, {InternalSettings}).

handle_internal_settings_post(Req) ->
    Conf = [{CK, atom_to_list(JK), JK, Parser} ||
               {CK, JK, _, Parser} <- internal_settings_conf()],
    Params = Req:parse_post(),
    CurrentValues = build_internal_settings_kvs(),
    {ToSet, Errors} =
        lists:foldl(
          fun ({SJK, SV}, {ListToSet, ListErrors}) ->
                  case lists:keyfind(SJK, 2, Conf) of
                      {CK, SJK, JK, Parser} ->
                          case Parser(SV) of
                              {ok, V} ->
                                  case proplists:get_value(JK, CurrentValues) of
                                      V ->
                                          {ListToSet, ListErrors};
                                      _ ->
                                          {[{CK, V} | ListToSet], ListErrors}
                                  end;
                              _ ->
                                  {ListToSet,
                                   [iolist_to_binary(io_lib:format("~s is invalid", [SJK])) | ListErrors]}
                          end;
                      false ->
                          {ListToSet,
                           [iolist_to_binary(io_lib:format("Unknown key ~s", [SJK])) | ListErrors]}
                  end
          end, {[], []}, Params),

    case Errors of
        [] ->
            case ToSet of
                [] ->
                    ok;
                _ ->
                    ns_config:set(ToSet),
                    ns_audit:internal_settings(Req, ToSet)
            end,
            reply_json(Req, []);
        _ ->
            reply_json(Req, {[{error, X} || X <- Errors]}, 400)
    end.

handle_node_rename(Req) ->
    Params = Req:parse_post(),
    Node = node(),

    Reply =
        case proplists:get_value("hostname", Params) of
            undefined ->
                {error, <<"The name cannot be empty">>, 400};
            Hostname ->
                case ns_cluster:change_address(Hostname) of
                    ok ->
                        ns_audit:rename_node(Req, Node, Hostname),
                        ok;
                    {cannot_resolve, Errno} ->
                        Msg = io_lib:format("Could not resolve the hostname: ~p", [Errno]),
                        {error, iolist_to_binary(Msg), 400};
                    {cannot_listen, Errno} ->
                        Msg = io_lib:format("Could not listen: ~p", [Errno]),
                        {error, iolist_to_binary(Msg), 400};
                    not_self_started ->
                        Msg = <<"Could not rename the node because name was fixed at server start-up.">>,
                        {error, Msg, 403};
                    {address_save_failed, E} ->
                        Msg = io_lib:format("Could not save address after rename: ~p", [E]),
                        {error, iolist_to_binary(Msg), 500};
                    {address_not_allowed, Message} ->
                        Msg = io_lib:format("Requested name hostname is not allowed: ~s", [Message]),
                        {error, iolist_to_binary(Msg), 400};
                    already_part_of_cluster ->
                        Msg = <<"Renaming is disallowed for nodes that are already part of a cluster">>,
                        {error, Msg, 400}
            end
        end,

    case Reply of
        ok ->
            reply(Req, 200);
        {error, Error, Status} ->
            reply_json(Req, [Error], Status)
    end.

build_terse_bucket_info(BucketName) ->
    case bucket_info_cache:terse_bucket_info(BucketName) of
        {ok, V} -> V;
        %% NOTE: {auth_bucket for this route handles 404 for us albeit
        %% harmlessly racefully
        {T, E, Stack} ->
            erlang:raise(T, E, Stack)
    end.

serve_short_bucket_info(_PoolId, BucketName, Req) ->
    V = build_terse_bucket_info(BucketName),
    reply_ok(Req, "application/json", V).

serve_streaming_short_bucket_info(_PoolId, BucketName, Req) ->
    handle_streaming(
      fun (_, _) ->
              V = build_terse_bucket_info(BucketName),
              {just_write, {write, V}}
      end, Req, undefined).

serve_node_services(Req) ->
    reply_ok(Req, "application/json", bucket_info_cache:build_node_services()).

serve_node_services_streaming(Req) ->
    handle_streaming(
      fun (_, _) ->
              V = bucket_info_cache:build_node_services(),
              {just_write, {write, V}}
      end, Req, undefined).

decode_recovery_type("delta") ->
    delta;
decode_recovery_type("full") ->
    full;
decode_recovery_type(_) ->
    undefined.

handle_set_recovery_type(Req) ->
    Params = Req:parse_post(),
    Type = decode_recovery_type(proplists:get_value("recoveryType", Params)),
    do_handle_set_recovery_type(Req, Type, Params).

do_handle_set_recovery_type(Req, Type, Params) ->
    NodeStr = proplists:get_value("otpNode", Params),

    Node = try
               list_to_existing_atom(NodeStr)
           catch
               error:badarg ->
                   undefined
           end,

    OtpNodeErrorMsg = <<"invalid node name or node can't be used for delta recovery">>,

    NodeSvcs = ns_cluster_membership:node_services(ns_config:latest(), Node),
    NotKVIndex = not lists:member(kv, NodeSvcs) andalso not lists:member(index, NodeSvcs),

    Errors = lists:flatten(
               [case Type of
                    undefined ->
                        [{recoveryType, <<"recovery type must be either 'delta' or 'full'">>}];
                    _ ->
                        []
                end,

                case Node of
                    undefined ->
                        [{otpNode, OtpNodeErrorMsg}];
                    _ ->
                        []
                end,

                case Type =:= delta andalso NotKVIndex of
                    true ->
                        [{otpNode, OtpNodeErrorMsg}];
                    false ->
                        []
                end]),

    case Errors of
        [] ->
            case ns_cluster_membership:update_recovery_type(Node, Type) of
                ok ->
                    ns_audit:enter_node_recovery(Req, Node, Type),
                    reply_json(Req, [], 200);
                bad_node ->
                    reply_json(Req, {struct, [{otpNode, OtpNodeErrorMsg}]}, 400)
            end;
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

-ifdef(EUNIT).

basic_parse_validate_auto_compaction_settings_test() ->
    %% TODO: Need to mock cluster_compat_mode:is_cluster_***
    {ok, Stuff0, [],
     []} =
        parse_validate_auto_compaction_settings([{"databaseFragmentationThreshold[percentage]", "10"},
                                                 {"viewFragmentationThreshold[percentage]", "20"},
                                                 {"indexFragmentationThreshold[size]", "42"},
                                                 {"indexFragmentationThreshold[percentage]", "43"},
                                                 {"parallelDBAndViewCompaction", "false"},
                                                 {"allowedTimePeriod[fromHour]", "0"},
                                                 {"allowedTimePeriod[fromMinute]", "1"},
                                                 {"allowedTimePeriod[toHour]", "2"},
                                                 {"allowedTimePeriod[toMinute]", "3"},
                                                 {"allowedTimePeriod[abortOutside]", "false"}], false),
    Stuff1 = lists:sort(Stuff0),
    ?assertEqual([{allowed_time_period, [{from_hour, 0},
                                         {to_hour, 2},
                                         {from_minute, 1},
                                         {to_minute, 3},
                                         {abort_outside, false}]},
                  {database_fragmentation_threshold, {10, undefined}},
                  {parallel_db_and_view_compaction, false},
                  {view_fragmentation_threshold, {20, undefined}}],
                 Stuff1),
    ok.

extra_field_parse_validate_auto_compaction_settings_test() ->
    {errors, Stuff0} = parse_validate_auto_compaction_settings([{"databaseFragmentationThreshold", "10"},
                                                                {"viewFragmentationThreshold", "20"},
                                                                {"parallelDBAndViewCompaction", "false"},
                                                                {"allowedTimePeriod[fromHour]", "0"},
                                                                {"allowedTimePeriod[fromMinute]", "1"},
                                                                {"allowedTimePeriod[toHour]", "2"},
                                                                {"allowedTimePeriod[toMinute]", "3"},
                                                                {"allowedTimePeriod[abortOutside]", "false"}],
                                                               false),
    ?assertEqual([{<<"_">>, <<"Got unsupported fields: databaseFragmentationThreshold and viewFragmentationThreshold">>}],
                 Stuff0),

    {errors, Stuff1} = parse_validate_auto_compaction_settings([{"databaseFragmentationThreshold", "10"},
                                                                {"parallelDBAndViewCompaction", "false"},
                                                                {"allowedTimePeriod[fromHour]", "0"},
                                                                {"allowedTimePeriod[fromMinute]", "1"},
                                                                {"allowedTimePeriod[toHour]", "2"},
                                                                {"allowedTimePeriod[toMinute]", "3"},
                                                                {"allowedTimePeriod[abortOutside]", "false"}],
                                                               false),
    ?assertEqual([{<<"_">>, <<"Got unsupported fields: databaseFragmentationThreshold">>}],
                 Stuff1),
    ok.

hostname_parsing_test() ->
    Urls = [" \t\r\nhttp://host:1025\n\r\t ",
            "http://host:100",
            "http://host:100000",
            "hTTp://host:8000",
            "ftp://host:600",
            "http://host",
            "127.0.0.1:6000",
            "host:port",
            "aaa:bb:cc",
            " \t\r\nhost\n",
            " "],

    ExpectedResults = [{"host",1025},
                       {error, [<<"The port number must be greater than 1023 and less than 65536.">>]},
                       {error, [<<"The port number must be greater than 1023 and less than 65536.">>]},
                       {"host", 8000},
                       {error, [<<"Unsupported protocol ftp">>]},
                       {"host", 8091},
                       {"127.0.0.1", 6000},
                       {error, [<<"Port must be a number.">>]},
                       {error, [<<"The hostname is malformed.">>]},
                       {"host", 8091},
                       {error, [<<"Hostname is required.">>]}],

    Results = [(catch parse_hostname(X)) || X <- Urls],

    ?assertEqual(ExpectedResults, Results),
    ok.

-endif.

handle_log_post(Req) ->
    Params = Req:parse_post(),
    Msg = proplists:get_value("message", Params),
    LogLevel = proplists:get_value("logLevel", Params),
    Component = proplists:get_value("component", Params),

    Errors =
        lists:flatten([case Msg of
                           undefined ->
                               {<<"message">>, <<"missing value">>};
                           _ ->
                               []
                       end,
                       case LogLevel of
                           "info" ->
                               [];
                           "warn" ->
                               [];
                           "error" ->
                               [];
                           _ ->
                               {<<"logLevel">>, <<"invalid or missing value">>}
                       end,
                       case Component of
                           undefined ->
                               {<<"component">>, <<"missing value">>};
                           _ ->
                               []
                       end]),

    case Errors of
        [] ->
            Fun = list_to_existing_atom([$x | LogLevel]),
            ale:Fun(?USER_LOGGER,
                    {list_to_atom(Component), unknown, -1}, undefined, Msg, []),
            reply_json(Req, []);
        _ ->
            reply_json(Req, {struct, Errors}, 400)
    end.

handle_settings_audit(Req) ->
    assert_is_enterprise(),
    assert_is_40(),

    Props = ns_audit_cfg:get_global(),
    Json = lists:map(fun ({K, V}) when is_list(V) ->
                             {K, list_to_binary(V)};
                         (Other) ->
                             Other
                     end, Props),
    reply_json(Req, {Json}).

validate_settings_audit(Args) ->
    R = validate_has_params({Args, [], []}),
    R0 = validate_boolean(auditdEnabled, R),
    R1 = validate_dir(logPath, R0),
    R2 = validate_integer(rotateInterval, R1),
    R3 = validate_range(
           rotateInterval, 15*60, 60*60*24*7,
           fun (Name, _Min, _Max) ->
                   io_lib:format("The value of ~p must be in range from 15 minutes to 7 days",
                                 [Name])
           end, R2),
    R4 = validate_by_fun(fun (Value) ->
                                 case Value rem 60 of
                                     0 ->
                                         ok;
                                     _ ->
                                         {error, "Value must not be a fraction of minute"}
                                 end
                         end, rotateInterval, R3),
    R5 = validate_integer(rotateSize, R4),
    R6 = validate_range(rotateSize, 0, 500*1024*1024, R5),
    validate_unsupported_params(R6).

handle_settings_audit_post(Req) ->
    assert_is_enterprise(),
    assert_is_40(),

    Args = Req:parse_post(),
    execute_if_validated(fun (Values) ->
                                 ns_audit_cfg:set_global(Values),
                                 reply(Req, 200)
                         end, Req, validate_settings_audit(Args)).

nth_path_tail(Path, N) when N > 0 ->
    nth_path_tail(path_tail(Path), N-1);
nth_path_tail(Path, 0) ->
    Path.

path_tail([$/|[$/|_] = Path]) ->
    path_tail(Path);
path_tail([$/|Path]) ->
    Path;
path_tail([_|Rest]) ->
    path_tail(Rest);
path_tail([]) ->
    [].

drop_rest_prefix("/" ++ Path) ->
    [$/ | nth_path_tail(Path, 2)].

drop_prefix("/" ++ Path) ->
    [$/ | nth_path_tail(Path, 1)].
