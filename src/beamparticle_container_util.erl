%%%-------------------------------------------------------------------
%%% @author neerajsharma
%%% @copyright (C) 2017, Neeraj Sharma <neeraj.sharma@alumni.iitg.ernet.in>
%%% @doc
%%%
%%% Containerization of generic processes.
%%%
%%% @end
%%% %CopyrightBegin%
%%%
%%% Copyright Neeraj Sharma <neeraj.sharma@alumni.iitg.ernet.in> 2017.
%%% All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% %CopyrightEnd%
%%%-------------------------------------------------------------------
-module(beamparticle_container_util).

-include("beamparticle_constants.hrl").

-ifdef('CONTAINER_ALCOVE').
-include_lib("alcove/include/alcove.hrl").
-endif.

-export([create_driver/2,
         execute_command/5]).

-export_type([ref/0]).

-ifdef('CONTAINER_ALCOVE').

-export([create_child/7]).

-export_type([create_option/0]).
-type create_option() :: ctldir
    | rlimit_fsize
    | rlimit_nofile
    | rlimit_nproc
    | chroot_path
    %% following are specifically used for namespaces
    | cgroup_name
    | cpuset_cpus
    | cpuset_mems
    | memory_memsw_limit_in_bytes
    | memory_limit_in_bytes.
-type ref() :: alcove_drv:ref().

-else.

%% erlexec has Pid, OsPid
-type ref() :: {pid(), non_neg_integer()}.

-endif.


%% API

%%%===================================================================
%%% API
%%%===================================================================

-ifdef('CONTAINER_ALCOVE').

execute_command(Drv, Path, Command, Args, TimeoutMsec) ->
    {ok, ChildPID} = alcove:fork(Drv, []),
    alcove:chdir(Drv, [ChildPID], Path),
    EnvironmentVars = [],
    ok = alcove:execve(Drv, [ChildPID], Command, [Command | Args],
                       EnvironmentVars),
    lager:debug("git-backend running command ~s ~s", [Command, Args]),
    receive
        {alcove_event, Drv, [ChildPID], {exit_status, ExitCode}} = Event ->
            lager:debug("git-backend received event ~p", [Event]),
            Stdout = iolist_to_binary(alcove:stdout(Drv, [ChildPID])),
            Stderr = iolist_to_binary(alcove:stderr(Drv, [ChildPID])),
            {ExitCode, Stdout, Stderr}
    after
        TimeoutMsec ->
            alcove:kill(Drv, [], ChildPID, 9),
            {error, timeout}
    end.

-else.

execute_command({Pid, _OsPid}, Path, Command, Args, TimeoutMsec) ->
    exec:send(Pid, <<"cd ", Path/binary, "; echo {{{{DONE}}}}\n">>),
    loop_receive_response([], [], <<"{{{{DONE}}}}\n">>, TimeoutMsec),
    AllArgs = lists:join(<<" ">>, Args),
    CommandBin = iolist_to_binary([Command | AllArgs]),
    exec:send(Pid, CommandBin),
    exec:send(Pid, <<";echo $?; echo {{{{DONE}}}}\n">>),
    case loop_receive_response([], [], <<"{{{{DONE}}}}\n">>, TimeoutMsec) of
        {Stdout, Stderr} ->
            [H | RestStdout] = Stdout,
            ExitCode = binary_to_integer(
                         string:trim(
                           iolist_to_binary(H))),
            {ExitCode, lists:reverse(RestStdout), lists:reverse(Stderr)};
        _ ->
            {1, [], []}
    end.

loop_receive_response(StdoutAccIn, StderrAccIn, TerminatingResponse, TimeoutMsec) ->
    T1 = erlang:system_time(millisecond),
    receive
        {stdout, _SameOsPid, Response} ->
            T2 = erlang:system_time(millisecond),
            ResponseBin = iolist_to_binary(Response),
            ResponseBytes = byte_size(ResponseBin),
            RemainingLen = ResponseBytes - byte_size(TerminatingResponse),
            case RemainingLen >= 0 of
                true ->
                    case ResponseBin of
                        <<RemainingResponse:RemainingLen/binary, TerminatingResponse/binary>> ->
                            case RemainingResponse of
                                <<>> ->
                                    {StdoutAccIn, StderrAccIn};
                                _ ->
                                    {[RemainingResponse | StdoutAccIn],
                                     StderrAccIn}
                            end;
                        _ ->
                            loop_receive_response([Response | StdoutAccIn],
                                                  StderrAccIn,
                                                  TerminatingResponse,
                                                  TimeoutMsec - (T2 - T1))
                    end;
                false ->
                        loop_receive_response([Response | StdoutAccIn],
                                              StderrAccIn,
                                              TerminatingResponse,
                                              TimeoutMsec - (T2 - T1))
            end;
        {stderr, _SameOsPid, Response} ->
            T2 = erlang:system_time(millisecond),
            loop_receive_response(StdoutAccIn,
                                  [Response | StderrAccIn],
                                  TerminatingResponse,
                                  TimeoutMsec - (T2 - T1))
    after
        TimeoutMsec ->
            {StdoutAccIn, StderrAccIn}
    end.

-endif.

-ifdef('CONTAINER_ALCOVE').

-spec create_driver(simple | sandbox | namespace, Opts :: [{create_option(), term()}]) ->
    {ok, Drv :: alcove_drv:ref()}.
create_driver(simple, [{ctldir, CtlDir}]) ->
    alcove_drv:start_link([{ctldir, CtlDir}]);
create_driver(sandbox, [{ctldir, CtlDir}]) ->
    %% sudo is required for using chroot later
    %% ensure that alcove binary has capabilities set via sudoers
    %% -----
    %% sudo visudo -f /etc/sudoers.d/99_alcove
    %% <user> ALL = NOPASSWD: /path/to/alcove/priv/alcove
    %% Defaults!/path/to/alcove/priv/alcove !requiretty
    %% -----
    %% chown root:root priv/alcove
    %% chmod u+s priv/alcove
    %% -----
    alcove_drv:start([{exec, "sudo -n"}, {ctldir, CtlDir}]);
create_driver(namespace, Opts) ->
    %% ensure settings same as that for sandbox above
    CtlDir = proplists:get_value(ctldir, Opts),
    {ok, Drv} = alcove_drv:start_link([{exec, "sudo -n"}, {ctldir, CtlDir}]),
    GroupName = proplists:get_value(cgroup_name, Opts),
    ok = alcove_cgroup:create(Drv, [], GroupName),
    %% http://man7.org/linux/man-pages/man7/cpuset.7.html
    case proplists:get_value(cpuset_cpus, Opts) of
        undefined ->
            ok;
        CpusetCpus ->
            {ok, _} = alcove_cgroup:set(Drv, [], <<"cpuset">>, <<"alcove">>,
                                        <<"cpuset.cpus">>, CpusetCpus)
    end,
    case proplists:get_value(cpuset_mems, Opts) of
        undefined ->
            ok;
        CpusetMems ->
            {ok, _} = alcove_cgroup:set(Drv, [], <<"cpuset">>, <<"alcove">>,
                                        <<"cpuset.mems">>, CpusetMems)
    end,
    case proplists:get_value(memory_memsw_limit_in_bytes, Opts) of
        undefined ->
            ok;
        MemswLimitOctets ->
            {ok, _} = alcove_cgroup:set(Drv, [], <<"memory">>, <<"alcove">>,
                                        <<"memory.memsw.limit_in_bytes">>,
                                        MemswLimitOctets)
    end,

    case proplists:get_value(memory_limit_in_bytes, Opts) of
        undefined ->
            ok;
        MemoryLimitOctets ->
            {ok, _} = alcove_cgroup:set(Drv, [], <<"memory">>, <<"alcove">>,
                                        <<"memory.limit_in_bytes">>,
                                        MemoryLimitOctets)
    end,
    {ok, Drv}.

-else.

-spec create_driver(simple, Opts :: [{term(), term()}]) ->
    {ok, Drv :: ref()}.
create_driver(simple, _Opts) ->
    CommandShell = application:get_env(?APPLICATION_NAME, command_shell, "/bin/bash"),
    {ok, Pid, OsPid} = exec:run_link(CommandShell, [stdin, {stdout, self()}, {stderr, self()}]),
    {ok, {Pid, OsPid}}.

-endif.


-ifdef('CONTAINER_ALCOVE').

%% Note that Arg0 is absolute filename (that is with absolute path)
%% Note that EnvironmentVars must be like the following
%% ```
%%     EnvironmentVars = ["HOME=/", "PATH="/bin:/sbin:"] 
%% '''
-spec create_child(simple | sandbox | namespace,
                   Drv :: alcove_drv:ref(), GroupName :: binary(),
                   Arg0 :: string(), Args :: [string()],
                   EnvironmentVars :: [string()],
                   Opts :: [{atom(), term()}]) ->
    {ok, ChildPID :: alcove:pid_t()}.
create_child(simple, Drv, _GroupName, Arg0, Args, EnvironmentVars, _Opts) ->
    {ok, ChildPID} = alcove:fork(Drv, []),
    %% ensure child get sighup when parent dies
    {ok, _, _, _, _, _} = alcove:prctl(Drv, [ChildPID], pr_set_pdeathsig, 9, 0, 0, 0),
    %% execute app
    ok = alcove:execve(Drv, [ChildPID], Arg0, [Arg0 | Args], EnvironmentVars),
    {ok, ChildPID};
create_child(sandbox, Drv, _GroupName, Arg0, Args, EnvironmentVars, Opts) ->
    Arg0Path = filename:dirname(Arg0),
    BasePath = filename:dirname(Arg0Path),
    {ok, ChildPID} = alcove:fork(Drv, []),
    %% ensure child get sighup when parent dies
    {ok, _, _, _, _, _} = alcove:prctl(Drv, [ChildPID], pr_set_pdeathsig, 9, 0, 0, 0),
    case proplists:get_value(rlimit_fsize, Opts) of
        undefined ->
            ok;
        {CurFsize, MaxFsize} ->
            ok = alcove:setrlimit(Drv, [ChildPID], rlimit_fsize,
                #alcove_rlimit{cur = CurFsize, max = MaxFsize})
    end,
    case proplists:get_value(rlimit_nproc, Opts) of
        undefined ->
            ok;
        {CurNproc, MaxNproc} ->
            ok = alcove:setrlimit(Drv, [ChildPID], rlimit_nproc,
                #alcove_rlimit{cur = CurNproc, max = MaxNproc})
    end,
    case proplists:get_value(rlimit_nproc, Opts) of
        undefined ->
            ok;
        {CurNoFile, MaxNoFile} ->
            ok = alcove:setrlimit(Drv, [ChildPID], rlimit_nofile,
                #alcove_rlimit{cur = CurNoFile, max = MaxNoFile})
    end,
    %% chroot
    ok = alcove:chroot(Drv, [ChildPID], BasePath),
    ok = alcove:chdir(Drv, [ChildPID], "/"),
    %% drop priviledge to random id
    RandomUserId = 16#f0000000 + rand:uniform(16#ffff) - 1,
    ok = alcove:setgid(Drv, [ChildPID], RandomUserId),
    ok = alcove:setuid(Drv, [ChildPID], RandomUserId),
    %% execute app
    ok = alcove:execve(Drv, [ChildPID], Arg0, [Arg0 | Args], EnvironmentVars),
    {ok, ChildPID};
create_child(namespace, Drv, GroupName, Arg0, Args, EnvironmentVars, _Opts) ->
    Arg0Path = filename:dirname(Arg0),
    BasePath = filename:dirname(Arg0Path),
    {ok, ChildPID} = alcove:clone(Drv, [], [
			clone_newipc, % IPC
            clone_newnet, % network
            clone_newns,  % mounts
            clone_newpid, % PID, ChildPID is PID 1 in the namespace
            clone_newuts  % hostname
            ]),
    %% ensure child get sighup when parent dies
    {ok, _, _, _, _, _} = alcove:prctl(Drv, [ChildPID], pr_set_pdeathsig, 9, 0, 0, 0),
    %% optionally set custom hostname
    %%ok = alcove:sethostname(Drv, [ChildPID], ["alcove", integer_to_list(Id)]),
    %% optionally mout /proc
    %% proc on /proc type proc (rw,noexec,nosuid,nodev)
    MountFlags= [
        ms_noexec,
        ms_nosuid,
        ms_nodev
    ],
    ok = alcove:mount(Drv, [ChildPID], "proc", "/proc", "proc", MountFlags, <<>>, <<>>),

    %% add child to the cgroup
    {ok,_} = alcove_cgroup:set(Drv, [], <<>>, GroupName,
                               <<"tasks">>, integer_to_list(ChildPID)),
    %% chroot
    ok = alcove:chroot(Drv, [ChildPID], BasePath),
    ok = alcove:chdir(Drv, [ChildPID], "/"),
    %% drop priviledge to random id
    RandomUserId = 16#f0000000 + rand:uniform(16#ffff) - 1,
    ok = alcove:setgid(Drv, [ChildPID], RandomUserId),
    ok = alcove:setuid(Drv, [ChildPID], RandomUserId),
    %% execute app
    ok = alcove:execve(Drv, [ChildPID], Arg0, [Arg0 | Args], EnvironmentVars),

    {ok, ChildPID}.

-endif.

%%%===================================================================
%%% Internal functions
%%%===================================================================


