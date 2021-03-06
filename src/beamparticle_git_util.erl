%%%-------------------------------------------------------------------
%%% @author neerajsharma
%%% @copyright (C) 2017, Neeraj Sharma <neeraj.sharma@alumni.iitg.ernet.in>
%%% @doc
%%%
%%% The inspiration for implementation of these utility functions is
%%% as follows:
%%%
%%%
%%% * https://git-scm.com/docs/git-status#_short_format
%%% * https://github.com/theia-ide/dugite-extra/blob/master/src/command/
%%%
%%% @end
%%% 
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
-module(beamparticle_git_util).

-export([parse_git_status/1,
         parse_git_log_details/1]).
-export([git_status_command/0,
         git_show_command/3,
         git_log_command/2,
         git_log_details_command/1,
         git_log_details_command/3,
         git_branch_command/2,
         git_branch_command/1]).
-export([parse_git_list_branches/1]).


%% @doc Git command used for retrieving the repo status
%%
%% Git command which generated the content is as follows:
%% git status --untracked-files=all --branch --porcelain -z
git_status_command() ->
    [<<"status">>, <<"--untracked-files=all">>, <<"--branch">>, <<"--porcelain">>, <<"-z">>].

%% @doc Parse git status output into meaningful information
%%
%%
%% @see git_status_command/0
%%
%%
%% ```
%% A = <<"## master\0M  nlpfn_top_page.erl.fun\0 M test.erl\0A  test3.erl.fun\0M  test_get.erl.fun\0A  test_java2.java.fun\0A  test_python_simple_http.py.fun\0?? res\0?? test.py\0?? test_conditions.erl.fun\0R  test_stage_moved.erl.fun\0test_stage.erl.fun\0">>,
%% parse_git_status(A)
%% '''
%%
parse_git_status(GitStatusContent) ->
    Lines = string:split(GitStatusContent, <<"\0">>, all),
    [BranchLine | Rest] = Lines,
    <<"## ", BranchName/binary>> = BranchLine,
    {_, ChangedFiles} = lists:foldl(fun(<<>>, {A, AccIn}) ->
                                       {A, AccIn};
                                  (E, {A, AccIn}) ->
                                       R2 = case binary:split(E, <<" ">>, [global]) of
                                                [<<>>, S, F] ->
                                                    {#{<<"staged">> => false, <<"status">> => S}, F};
                                                [S, <<>>, F] ->
                                                    {#{<<"staged">> => true, <<"status">> => S}, F};
                                                [S, F] ->
                                                    {#{<<"staged">> => false, <<"status">> => S}, F};
                                                [F] ->
                                                    %% This is the file which was moved as indicated
                                                    %% in earlier change record
                                                    {F}
                                            end,
                                       case R2 of
                                           {Status, Filename} ->
                                               FileStatus = maps:get(Filename, AccIn, []),
                                               {Filename, AccIn#{Filename => [Status | FileStatus]}};
                                           {Filename} ->
                                               [H|HRest] = maps:get(A, AccIn, [#{}]),
                                               {A, AccIn#{A => [H#{<<"old">> => Filename} | HRest]}}
                                       end
                               end, {undefined, #{}}, Rest),
    #{<<"branch">> => BranchName,
      <<"changes">> => ChangedFiles}.


%% @doc Get git file contents at a given reference, commit or tree
%%
%% git show COMMITSHA1:PATH
git_show_command(hash, Hash, RelativeFilePath) ->
    [<<"show">>, <<Hash/binary, ":", RelativeFilePath/binary>>].

%% @doc Get git log hash for a given file.
%%
%% For short hash:
%%   git log --follow --pretty="%h" -z <filename>
%% For long hash:
%%   git log --follow --pretty="%H" -z <filename>
%%
git_log_command(short, RelativeFilePath) ->
    [<<"log">>, <<"--follow">>, <<"--pretty=\"%h\"">>, <<"-z">>, RelativeFilePath];
git_log_command(full, RelativeFilePath) ->
    [<<"log">>, <<"--follow">>, <<"--pretty=\"%H\"">>, <<"-z">>, RelativeFilePath].

%% @doc Get git log details for a given file.
%%
%%   git log --follow --pretty="%h%x00%at%x00%ae%x00%an%x00%ar%x00%s%x00%b%x00" --name-status -z <filename>
%%
-spec git_log_details_command(binary()) -> [binary()].
git_log_details_command(RelativeFilePath) ->
    [<<"log">>, <<"--follow">>,
     <<"--name-status">>, <<"-z">>,
     <<"--pretty=%h%x00%at%x00%ae%x00%an%x00%ar%x00%s%x00%b%x1f">>,
     RelativeFilePath].

%% @doc Get git log details for a given file and start, end sha1.
%%
%%   git log --follow --pretty="%h%x00%at%x00%ae%x00%an%x00%ar%x00%s%x00%b%x1f" --name-status -z <startsha1>..<endsha1> <filename>
%%
%% Note that <filename> can be '.' when it is for a folder
-spec git_log_details_command(binary(), binary(), binary()) -> [binary()].
git_log_details_command(StartSha1, EndSha1, RelativeFilePath) ->
    [<<"log">>, <<"--follow">>,
     <<"--name-status">>, <<"-z">>,
     <<"--pretty=%h%x00%at%x00%ae%x00%an%x00%ar%x00%s%x00%b%x1f">>,
     <<StartSha1/binary, "..", EndSha1/binary>>,
     RelativeFilePath].

%% A = os:cmd("cd /opt/beamparticle-data/git-data/git-src && git log --follow --pretty=\"%h%x00%at%x00%ae%x00%an%x00%ar%x00%s%x00%b%x1f\" --name-status -z nlpfn_top_page.erl.fun").
%% beamparticle_git_util:parse_git_log_details(list_to_binary(A))
%%
%% beamparticle_gitbackend_server:git_log_details("/opt/beamparticle-data/git-data/git-src", <<"nlpfn_top_page.erl.fun">>, 5000).
%%
%% Return result with latest change at the top.
%%
-spec parse_git_log_details(binary()) -> [map()].
parse_git_log_details(GitLogDetailsContent) ->
    Lines = string:split(GitLogDetailsContent, <<16#1f, 0>>, all),
    Result = lists:foldl(fun(E, AccIn) ->
                        Parts = string:split(E, <<"\0">>, all),
                        case Parts of
                            [ShortSha1, UnixTimeSec, Email, Name, RelativeDate,
                             Subject, Body] ->
                                Entry = #{
                                  <<"sha">> => ShortSha1,
                                  <<"timestamp">> => UnixTimeSec,
                                  <<"email">> => Email,
                                  <<"name">> => Name,
                                  <<"authorDateRelative">> => RelativeDate,
                                  <<"summary">> => Subject,
                                  <<"body">> => Body},
                                [Entry | AccIn];
                            [<<"\n", Status/binary>>, Filename,
                             ShortSha1, UnixTimeSec, Email, Name, RelativeDate,
                             Subject, Body] ->
                                [H | Rest] = AccIn,
                                Entry = #{
                                  <<"sha">> => ShortSha1,
                                  <<"timestamp">> => UnixTimeSec,
                                  <<"email">> => Email,
                                  <<"name">> => Name,
                                  <<"authorDateRelative">> => RelativeDate,
                                  <<"summary">> => Subject,
                                  <<"body">> => Body},
                                FileChanges = #{
                                  <<"status">> => Status,
                                  <<"filename">> => Filename},
                                [Entry,
                                 H#{<<"changes">> => FileChanges} | Rest];
                            [<<"\n", Status/binary>>, Filename, _Empty] ->
                                [H | Rest] = AccIn,
                                FileChanges = #{
                                  <<"status">> => Status,
                                  <<"filename">> => Filename},
                                [H#{<<"changes">> => FileChanges} | Rest]
                        end
                end, [], Lines),
    lists:reverse(Result).

git_branch_command(list, current) ->
    [<<"rev-parse">>, <<"--abbrev-ref">>, <<"HEAD">>].

git_branch_command(list_branches) ->
    %% TODO do not use double quotes within format
    [<<"for-each-ref">>, <<"--format=%(refname)%00%(refname:short)%00%(upstream:short)%00%(objectname)%00%(author)%00%(parent)%00%(subject)%00%(body)%1f">>].

-spec parse_git_list_branches(Content :: binary()) -> map().
parse_git_list_branches(Content) ->
    Lines = binary:split(Content, <<16#1f>>, [global, trim]),
    TransformFun = fun(Line, AccIn) ->
                        Parts = binary:split(Line, <<"\0">>, [global]),
                        case Parts of
                            [A1, A2, A3, A4, A5, A6, A7, A8] ->
                                R = #{<<"refname">> => A1,
                                  <<"refname_short">> => A2,
                                  <<"upstream_short">> => A3,
                                  <<"objectname">> => A4,
                                  <<"author">> => A5,
                                  <<"parent">> => A6,
                                  <<"subject">> => A7,
                                  <<"body">> => A8
                                 },
                                [R | AccIn];
                            _ ->
                                AccIn
                        end
                   end,
    lists:foldr(TransformFun, [], Lines).

%% git log --format="%H"
%% git log -n 1 --format="%H"

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% git_file_status_type(<<"??">>) ->
