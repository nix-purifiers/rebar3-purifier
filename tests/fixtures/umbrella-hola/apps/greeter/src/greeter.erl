-module(greeter).

-export([greet/1]).

%% A greeting that names the versions of the git dependencies, so a check
%% sees that the release holds them.
greet(Name) ->
    {ok, Recon} = application:get_key(recon, vsn),
    {ok, Otel} = application:get_key(opentelemetry_api, vsn),
    io_lib:format("Hola, ~s (recon ~s, opentelemetry_api ~s)", [Name, Recon, Otel]).
