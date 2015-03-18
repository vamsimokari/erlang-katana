%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ktn_code: functions useful for dealing with erlang code
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-module(ktn_code).

-export([
         beam_to_string/1,
         beam_to_erl/2,
         parse_tree/1,
         parse_tree/2,
         eval/1,
         consult/1
        ]).

%% Getters
-export([
         type/1,
         attr/2,
         node_attr/2,
         content/1
        ]).

-type tree_node_type() ::
        function | clause | match | tuple
      | atom | integer | float | string | char
      | binary | binary_element | var
      | call | remote
      | 'case' | case_expr | case_clauses
      | 'fun' | named_fun
      | 'query'
      | 'try' | try_catch | try_case | try_after
      | 'if' | 'catch'
      | 'receive' | receive_after | receive_case
      | nil | cons
      | map | map_field_assoc | map_field_exact
      | lc | lc_expr | generate
      | bc | bc_expr | b_generate
      | op
      | record | record_field | record_index
      | block
        %% Attributes
      | module
      | type | callback
      | export | export_type
      | remote_type | type | ann_type | paren_type
      | any.

-type tree_node() ::
    #{type => tree_node_type(),
      attrs => map(),
      content => [tree_node()]}.

-exported_type(tree_node/1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Exported API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc If the beam was not compiled with debug_info
%%      the code generated by this function will look really ugly
%% @end
-spec beam_to_string(beam_lib:beam()) ->
  {ok, string()} | {error, beam_lib, term()}.
beam_to_string(BeamPath) ->
  case beam_lib:chunks(BeamPath, [abstract_code]) of
    {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
      Src = erl_prettypr:format(erl_syntax:form_list(tl(Forms))),
      {ok, Src};
    Error ->
      Error
  end.

%% @doc If the beam was not compiled with debug_info
%%      the code generated by this function will look really ugly
%% @end
-spec beam_to_erl(beam_lib:beam(), string()) -> ok.
beam_to_erl(BeamPath, ErlPath) ->
    case beam_to_string(BeamPath) of
      {ok, Src} ->
        {ok, Fd} = file:open(ErlPath, [write]),
        io:fwrite(Fd, "~s~n", [Src]),
        file:close(Fd);
      Error ->
        Error
    end.

%% @equiv parse_tree([], Source).
-spec parse_tree(string()) ->
    [{ok | error, erl_parse:abstract_form()}].
parse_tree(Source) ->
    parse_tree([], Source).

%% @doc Parses code in a string or binary format and returns the parse tree.
-spec parse_tree([string()], string()) ->
    [{ok | error, erl_parse:abstract_form()}].
parse_tree(IncludeDirs, Source) ->
    SourceStr = to_str(Source),
    ScanOpts = [text, return_comments],
    {ok, Tokens, _} = erl_scan:string(SourceStr, {1, 1}, ScanOpts),
    Options = [{include, IncludeDirs}],
    {ok, NewTokens} = aleppo:process_tokens(Tokens, Options),

    IsComment = fun
                    ({comment, _, _}) -> true;
                    (_) -> false
                end,

    {Comments, CodeTokens} = lists:partition(IsComment, NewTokens),
    Forms = ktn_lists:split_when(fun is_dot/1, CodeTokens),
    ParsedForms = lists:map(fun erl_parse:parse_form/1, Forms),
    Children = [to_map(Parsed) || {ok, Parsed} <- ParsedForms],

    #{type => root,
      attrs => #{},
      content => to_map(Comments) ++ Children}.

%% @doc Evaluates the erlang expression in the string provided.
-spec eval(string() | binary()) -> term().
eval(Source) ->
    eval(Source, []).

-spec eval(string() | binary(), orddict:orddict()) -> term().
eval(Source, Bindings) ->
    SourceStr = to_str(Source),
    {ok, Tokens, _} = erl_scan:string(SourceStr),
    {ok, Parsed} = erl_parse:parse_exprs(Tokens),
    {value, Result, _} = erl_eval:exprs(Parsed, Bindings),
    Result.

%% @doc Like file:consult/1 but for strings and binaries.
-spec consult(string() | binary()) -> [term()].
consult(Source) ->
    SourceStr = to_str(Source),
    {ok, Tokens, _} = erl_scan:string(SourceStr),
    Forms = ktn_lists:split_when(fun is_dot/1, Tokens),
    ParseFun = fun (Form) ->
                       {ok, Expr} = erl_parse:parse_exprs(Form),
                       Expr
               end,
    Parsed = lists:map(ParseFun, Forms),
    ExprsFun = fun(P) ->
                       {value, Value, _} = erl_eval:exprs(P, []),
                       Value
               end,
    lists:map(ExprsFun, Parsed).

%% Getters

-spec type(tree_node()) -> atom().
type(#{type := Type}) ->
    Type;
type(undefined) ->
    undefined.

-spec attr(term(), tree_node()) -> term() | undefined.
attr(Key, #{attrs := Attrs}) ->
    case maps:is_key(Key, Attrs) of
        true -> maps:get(Key, Attrs);
        false -> undefined
    end;
attr(_Key, Node) when is_map(Node) ->
    undefined;
attr(_Key, undefined) ->
    undefined.

-spec node_attr(term(), tree_node()) -> term() | undefined.
node_attr(Key, #{node_attrs := Attrs}) ->
  case maps:is_key(Key, Attrs) of
    true -> maps:get(Key, Attrs);
    false -> undefined
  end;
node_attr(_Key, Node) when is_map(Node) ->
  undefined;
node_attr(_Key, undefined) ->
    undefined.

-spec content(tree_node()) -> [tree_node()].
content(#{content := Content}) ->
    Content;
content(_Node) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec to_str(binary() | list() | atom()) -> string().
to_str(Arg) when is_binary(Arg) ->
    unicode:characters_to_list(Arg);
to_str(Arg) when is_atom(Arg) ->
    atom_to_list(Arg);
to_str(Arg) when is_integer(Arg) ->
    integer_to_list(Arg);
to_str(Arg) when is_list(Arg) ->
    Arg.

-spec is_dot(tuple()) -> boolean().
is_dot({dot, _}) -> true;
is_dot(_) -> false.

%% @private
get_location(Attrs) when is_integer(Attrs) ->
    Line = Attrs,
    {Line, 1};
get_location(Attrs) when is_list(Attrs) ->
    Line = proplists:get_value(line, Attrs),
    Column = proplists:get_value(column, Attrs),
    {Line, Column};
get_location(_Attrs) ->
    {-1, -1}.

%% @private
get_text(Attrs) when is_integer(Attrs) ->
    undefined;
get_text(Attrs) when is_list(Attrs) ->
    proplists:get_value(text, Attrs, "");
get_text(_Attrs) ->
    "".

%% @doc Converts a parse tree form the abstract format to a map based repr.
%% TODO: Attributes are not being handled correctly.
-spec to_map(term()) -> tree_node().
to_map(ListParsed) when is_list(ListParsed) ->
    lists:map(fun to_map/1, ListParsed);

to_map({function, Attrs, Name, Arity, Clauses}) ->
    #{type => function,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name,
                 arity => Arity},
      content => to_map(Clauses)};
to_map({function, Name, Arity}) ->
    #{type => function,
      attrs => #{name => Name,
                 arity => Arity}};
to_map({function, Module, Name, Arity}) ->
    #{type => function,
      attrs => #{module => Module,
                 name => Name,
                 arity => Arity}};

to_map({clause, Attrs, Patterns, Guards, Body}) ->
    #{type => clause,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{pattern => to_map(Patterns),
                guards => to_map(Guards)},
      content => to_map(Body)};

to_map({match, Attrs, Left, Right}) ->
    #{type => match,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map([Left, Right])};

to_map({tuple, Attrs, Elements}) ->
    #{type => tuple,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Elements)};

%% Literals

to_map({Type, Attrs, Value}) when
      Type == atom;
      Type == integer;
      Type == float;
      Type == string;
      Type == char ->
    #{type => Type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 value => Value}};

to_map({bin, Attrs, Elements}) ->
    #{type => binary,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Elements)};

to_map({bin_element, Attrs, Value, Size, TSL}) ->
    #{type => binary_element,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 type_spec_list => TSL},
      node_attrs => #{value => to_map(Value),
                      size => case Size of
                                default -> #{type => default};
                                _ -> to_map(Size)
                              end }};

%% Variables

to_map({var, Attrs, Name}) ->
    #{type => var,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name}};

%% Function call

to_map({call, Attrs, Function, Arguments}) ->
    #{type => call,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{function => to_map(Function)},
      content => to_map(Arguments)};

to_map({remote, Attrs, Module, Function}) ->
    #{type => remote,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{module => to_map(Module),
                      function => to_map(Function)}};

%% case

to_map({'case', Attrs, Expr, Clauses}) ->
    CaseExpr = to_map({case_expr, Attrs, Expr}),
    CaseClauses = to_map({case_clauses, Attrs, Clauses}),
    #{type => 'case',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{expression => to_map(Expr)},
      content => [CaseExpr, CaseClauses]};
to_map({case_expr, Attrs, Expr}) ->
    #{type => case_expr,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [to_map(Expr)]};
to_map({case_clauses, Attrs, Clauses}) ->
    #{type => case_clauses,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Clauses)};

%% fun

to_map({'fun', Attrs, {function, Name, Arity}}) ->
  #{type => 'fun',
    attrs => #{location => get_location(Attrs),
               text => get_text(Attrs),
               name => Name,
               arity => Arity}};

to_map({'fun', Attrs, {function, Module, Name, Arity}}) ->
    #{type => 'fun',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 module => Module,
                 name => Name,
                 arity => Arity}};

to_map({'fun', Attrs, {clauses, Clauses}}) ->
    #{type => 'fun',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Clauses)};

to_map({named_fun, Attrs, Name, Clauses}) ->
    #{type => named_fun,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      content => to_map(Clauses)};

%% query - deprecated, implemented for completion.

to_map({'query', Attrs, ListCompr}) ->
    #{type => 'query',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(ListCompr)};

%% try..catch..after

to_map({'try', Attrs, Body, [], CatchClauses, AfterBody}) ->
    TryBody = to_map(Body),
    TryCatch = to_map({try_catch, Attrs, CatchClauses}),
    TryAfter = to_map({try_after, Attrs, AfterBody}),

    #{type => 'try',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{catch_clauses => to_map(CatchClauses),
                      after_body => to_map(AfterBody)},
      content => TryBody ++ [TryCatch, TryAfter]};

%% try..of..catch..after

to_map({'try', Attrs, Expr, CaseClauses, CatchClauses, AfterBody}) ->
    TryCase = to_map({try_case, Attrs, Expr, CaseClauses}),
    TryCatch = to_map({try_catch, Attrs, CatchClauses}),
    TryAfter = to_map({try_after, Attrs, AfterBody}),

    #{type => 'try',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [TryCase, TryCatch, TryAfter]};

to_map({try_case, Attrs, Expr, Clauses}) ->
    #{type => try_case,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{expression => to_map(Expr)},
      content => to_map(Clauses)};

to_map({try_catch, Attrs, Clauses}) ->
    #{type => try_catch,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Clauses)};

to_map({try_after, Attrs, AfterBody}) ->
    #{type => try_after,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(AfterBody)};

%% if

to_map({'if', Attrs, IfClauses}) ->
    #{type => 'if',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(IfClauses)};

%% catch

to_map({'catch', Attrs, Expr}) ->
    #{type => 'catch',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [to_map(Expr)]};

%% receive

to_map({'receive', Attrs, Clauses}) ->
    RecClauses = to_map({receive_case, Attrs, Clauses}),
    #{type => 'receive',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [RecClauses]};

to_map({'receive', Attrs, Clauses, AfterExpr, AfterBody}) ->
    RecClauses = to_map({receive_case, Attrs, Clauses}),
    RecAfter = to_map({receive_after, Attrs, AfterExpr, AfterBody}),
    #{type => 'receive',
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [RecClauses, RecAfter]};

to_map({receive_case, Attrs, Clauses}) ->
    #{type => receive_case,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Clauses)};

to_map({receive_after, Attrs, Expr, Body}) ->
    #{type => receive_after,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{expression => to_map(Expr)},
      content => to_map(Body)};

%% List

to_map({nil, Attrs}) ->
    #{type => nil,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)}};

to_map({cons, Attrs, Head, Tail}) ->
    #{type => cons,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [to_map(Head), to_map(Tail)]};

%% Map

to_map({map, Attrs, Pairs}) ->
    #{type => map,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Pairs)};
to_map({map, Attrs, Var, Pairs}) ->
    #{type => map,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{var => to_map(Var)},
      content => to_map(Pairs)};

to_map({Type, Attrs, Key, Value}) when
      map_field_exact == Type;
      map_field_assoc == Type ->
    #{type => Type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{key => to_map(Key),
                      value => to_map(Value)}};

%% List Comprehension

to_map({lc, Attrs, Expr, GeneratorsFilters}) ->
    LcExpr = to_map({lc_expr, Attrs, Expr}),
    LcGenerators = to_map(GeneratorsFilters),
    #{type => lc,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [LcExpr | LcGenerators]};

to_map({generate, Attrs, Pattern, Expr}) ->
    #{type => generate,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{pattern => to_map(Pattern),
                      expression => to_map(Expr)}};
to_map({lc_expr, Attrs, Expr}) ->
    #{type => lc_expr,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [to_map(Expr)]};

%% Binary Comprehension

to_map({bc, Attrs, Expr, GeneratorsFilters}) ->
    BcExpr = to_map({bc_expr, Attrs, Expr}),
    BcGenerators = to_map(GeneratorsFilters),
    #{type => bc,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [BcExpr | BcGenerators]};
to_map({b_generate, Attrs, Pattern, Expr}) ->
    #{type => b_generate,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{pattern => to_map(Pattern),
                      expression => to_map(Expr)}};
to_map({bc_expr, Attrs, Expr}) ->
    #{type => bc_expr,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => [to_map(Expr)]};

%% Operation

to_map({op, Attrs, Operation, Left, Right}) ->
    #{type => op,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 operation => Operation},
      content => to_map([Left, Right])};

to_map({op, Attrs, Operation, Single}) ->
    #{type => op,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 operation => Operation},
      content => to_map([Single])};

%% Record

to_map({record, Attrs, Name, Fields}) ->
    #{type => record,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      content => to_map(Fields)};
to_map({record, Attrs, Var, Name, Fields}) ->
    #{type => record,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      node_attrs => #{variable => to_map(Var)},
      content => to_map(Fields)};

to_map({record_index, Attrs, Name, Field}) ->
    #{type => record_index,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      content => [to_map(Field)]};

to_map({record_field, Attrs, Name}) ->
    #{type => record_field,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{name => to_map(Name)}};
to_map({record_field, Attrs, Name, Default}) ->
    #{type => record_field,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{default => to_map(Default),
                      name => to_map(Name)}};
to_map({record_field, Attrs, Var, Name, Field}) ->
    #{type => record_field,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      node_attrs => #{variable => to_map(Var)},
      content => [to_map(Field)]};

%% Block

to_map({block, Attrs, Body}) ->
    #{type => block,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      content => to_map(Body)};

%% Record Attribute

to_map({attribute, Attrs, record, {Name, Fields}}) ->
    #{type => record_attr,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      content => to_map(Fields)};
to_map({typed_record_field, Field, Type}) ->
    FieldMap = to_map(Field),
    #{type => typed_record_field,
      attrs => #{location => attr(location, FieldMap),
                 text => attr(text, FieldMap),
                 field => FieldMap},
      node_attrs => #{type => to_map(Type)}};

%% Type

to_map({type, Attrs, 'fun', Types}) ->
    #{type => type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => 'fun'},
      content => to_map(Types)};
to_map({type, Attrs, constraint, [Sub, SubType]}) ->
    #{type => type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => constraint,
                 subtype => Sub},
      content => to_map(SubType)};
to_map({type, Attrs, bounded_fun, [FunType, Defs]}) ->
    #{type => type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => bounded_fun},
      node_attrs => #{'fun' => to_map(FunType)},
      content => to_map(Defs)};
to_map({type, Attrs, Name, any}) ->
    to_map({type, Attrs, Name, [any]});
to_map({type, Attrs, Name, Types}) ->
    #{type => type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      content => to_map(Types)};

to_map({type, Attrs, map_field_assoc, Name, Type}) ->
    {Location, Text} =
        case Attrs of
            Line when is_integer(Attrs) ->
                {{Line, Line}, undefined};
            Attrs ->
                {get_location(Attrs),
                 get_text(Attrs)}
        end,
    #{type => type_map_field,
      attrs => #{location => Location,
                 text => Text},
      node_attrs => #{key => to_map(Name),
                      type => to_map(Type)}};
to_map({remote_type, Attrs, [Module, Function, Args]}) ->
    #{type => remote_type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{module => to_map(Module),
                      function => to_map(Function),
                      args => to_map(Args)}};
to_map({ann_type, Attrs, [Var, Type]}) ->
    #{type => record_field,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{var => to_map(Var),
                      type => to_map(Type)}};
to_map({paren_type, Attrs, [Type]}) ->
    #{type => record_field,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)},
      node_attrs => #{type => to_map(Type)}};
to_map(any) -> %% any()
    #{type => any};

%% Other Attributes

to_map({attribute, Attrs, type, {Name, Type, Args}}) ->
    #{type => type_attr,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name},
      node_attrs => #{args => to_map(Args),
                      type => to_map(Type)}};
to_map({attribute, Attrs, spec, {{Name, Arity}, Types}}) ->
    #{type => spec,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 name => Name,
                 arity => Arity},
     content => to_map(Types)};
to_map({attribute, Attrs, Type, Value}) ->
    #{type => Type,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs),
                 value => Value}};

%% Comments

to_map({comment, Attrs, _Text}) ->
    #{type => comment,
      attrs => #{location => get_location(Attrs),
                 text => get_text(Attrs)}};

%% Unhandled forms

to_map(Parsed) when is_tuple(Parsed) ->
    throw({unhandled_abstract_form, Parsed});
to_map(Parsed) ->
    throw({unexpected_abstract_form, Parsed}).
