-module(http2_spec_8_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_head_request,
     sends_headers_containing_trailer_part,
     sends_second_headers_with_no_end_stream,
     sends_uppercase_headers,
     sends_pseudo_after_regular,
     sends_invalid_pseudo,
     sends_response_pseudo_with_request,
     sends_connection_header,
     sends_bad_TE_header,
     sends_double_pseudo,
     sends_invalid_content_length_single_frame,
     sends_invalid_content_length_multi_frame,
     sends_non_integer_content_length
    ].

init_per_suite(Config) ->
    chatterbox_test_buddy:start(Config).

end_per_suite(Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

sends_head_request(_Config) ->
    {ok, Client} = http2c:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"HEAD">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM
        },
      h2_frame_headers:new(HeadersBin)
     },
    http2c:send_unaltered_frames(Client, [HF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{Header, _Payload}] = Resp,
    ?assertEqual(?HEADERS, (Header#frame_header.type)),
    ok.

sends_headers_containing_trailer_part(_Config) ->
    {ok, Client} = http2c:start_link(),

    CL = integer_to_binary(8 * 2047 * 4),
    RequestHeaders =
        [
         {<<":method">>, <<"POST">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"content-type">>, <<"text/plain">>},
         {<<"content-length">>, CL},
         {<<"trailer">>, <<"x-test">>}
        ],
    {ok, {HeadersBin, EC}} = hpack:encode(RequestHeaders, hpack:new_context()),

    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      h2_frame_headers:new(HeadersBin)
     },

    %% Send data len 16376 = 8 * 2047
    Value = <<"12345678">>,
    Data = {
      #frame_header{
         stream_id=1,
         length=8*2047
        },
      h2_frame_data:new(binary:copy(Value, 2047))
     },

    RequestTrailers =
        [
         {<<"x-test">>, <<"ok">>}
        ],
    {ok, {TrailersBin, _EC2}} = hpack:encode(RequestTrailers, EC),
    TF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM
        },
      h2_frame_headers:new(TrailersBin)
     },

    %% Receive a window update frame and rst_stream frame, send 4 data frame and with total data len 65504
    http2c:send_unaltered_frames(Client, [HF, Data, Data, Data, Data, TF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 3),
    ct:pal("Resp: ~p", [Resp]),

    ?assertEqual(3, (length(Resp))),

    [{WUH, WUD}, {HeaderH, _}, {DataH, _}] = Resp,

    %% After send 3 data frame with length 8 * 2047, receive a window update frame for refill to initial window size
    ExpectedWU = {#frame_header{
                     type=?WINDOW_UPDATE,
                     length=4,
                     stream_id=1},
                   h2_frame_window_update:new(8 * 2047 * 3)},
    ?assertEqual({WUH, WUD}, ExpectedWU),
    ?assertEqual(?WINDOW_UPDATE, (WUH#frame_header.type)),
    ?assertEqual(?HEADERS, (HeaderH#frame_header.type)),
    ?assertEqual(?DATA, (DataH#frame_header.type)),
    ok.

sends_second_headers_with_no_end_stream(_Config) ->
    {ok, Client} = http2c:start_link(),

    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"trailer">>, <<"x-test">>}
        ],

    {ok, {HeadersBin, EC}} = hpack:encode(RequestHeaders, hpack:new_context()),

    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      h2_frame_headers:new(HeadersBin)
     },

    Data = {
      #frame_header{
         stream_id=1,
         length=2
        },
      h2_frame_data:new(<<"hi">>)
     },

    RequestTrailers =
        [
         {<<"x-test">>, <<"ok">>}
        ],
    {ok, {TrailersBin, _EC2}} = hpack:encode(RequestTrailers, EC),
    TF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      h2_frame_headers:new(TrailersBin)
     },

    http2c:send_unaltered_frames(Client, [HF, Data, TF]),

    %% Only receive a rst_stream frame
    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{Header, Payload}] = Resp,
    ?assertEqual(?RST_STREAM, (Header#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_rst_stream:error_code(Payload))),
    ok.

sends_uppercase_headers(_Config) ->
    test_rst_stream(
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"X-TEST">>, <<"test">>}
        ]).

sends_pseudo_after_regular(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<":method">>, <<"GET">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

sends_invalid_pseudo(_Config) ->
    test_rst_stream(
        [
         {<<":anything">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

sends_response_pseudo_with_request(_Config) ->
    test_rst_stream(
        [
         {<<":status">>, <<"200">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]).

test_rst_stream(RequestHeaders) ->
    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      h2_frame_headers:new(HeadersBin)
     },
    http2c:send_unaltered_frames(Client, [HF]),

    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{Header, Payload}] = Resp,
    ?assertEqual(?RST_STREAM, (Header#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_rst_stream:error_code(Payload))),
    ok.

sends_connection_header(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"connection">>, <<"keep-alive">>}
        ]).

sends_bad_TE_header(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"te">>, <<"trailers, deflate">>}
        ]).

sends_double_pseudo(_Config) ->
    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),

    test_rst_stream(
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ]),
    ok.

sends_invalid_content_length_single_frame(_Config) ->
    test_content_length(
      [{#frame_header{
           type=?DATA,
           flags=?FLAG_END_STREAM,
           length=8,
           stream_id=1
          }, h2_frame_data:new(<<1,2,3,4,5,6,7,8>>)}]).

sends_invalid_content_length_multi_frame(_Config) ->
    test_content_length(
      [{#frame_header{
           type=?DATA,
           length=8,
           stream_id=1
          }, h2_frame_data:new(<<1,2,3,4,5,6,7,8>>)},
       {#frame_header{
           type=?DATA,
           length=8,
           flags=?FLAG_END_STREAM,
           stream_id=1
          }, h2_frame_data:new(<<11,12,13,14,15,16,17,18>>)}
      ]).


test_content_length(DataFrames) ->
    RequestHeaders =
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"content-length">>, <<"0">>}
        ],

    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS
        },
      h2_frame_headers:new(HeadersBin)
     },
    http2c:send_unaltered_frames(Client, [HF|DataFrames]),

    ExpectedFrameCount = 1,

    Resp = http2c:wait_for_n_frames(Client, 1, ExpectedFrameCount),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(ExpectedFrameCount, (length(Resp))),

    [ErrorFrame] = Resp,
    {Header, Payload} = ErrorFrame,
    ?assertEqual(?RST_STREAM, (Header#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_rst_stream:error_code(Payload))),

    ok.

sends_non_integer_content_length(_Context) ->
    RequestHeaders =
        [
         {<<":path">>, <<"/">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<":method">>, <<"GET">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>},
         {<<"content-length">>, <<"q">>}
        ],

    {ok, Client} = http2c:start_link(),
    {ok, {HeadersBin, _EC}} = hpack:encode(RequestHeaders, hpack:new_context()),
    HF = {
      #frame_header{
         stream_id=1,
         flags=?FLAG_END_HEADERS bor ?FLAG_END_STREAM
        },
      h2_frame_headers:new(HeadersBin)
     },
    http2c:send_unaltered_frames(Client, [HF]),
    Resp = http2c:wait_for_n_frames(Client, 1, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, (length(Resp))),
    [{Header, Payload}] = Resp,
    ?assertEqual(?RST_STREAM, (Header#frame_header.type)),
    ?assertEqual(?PROTOCOL_ERROR, (h2_frame_rst_stream:error_code(Payload))),

    ok.
