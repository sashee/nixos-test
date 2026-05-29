{ lib }:

let
  defaultPrune = {
    ignoreErrors = false;
    opts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  withPrune = args: args // { prune = defaultPrune // (args.prune or { }); };
in
{
  rest = args:
    let
      normalized = builtins.removeAttrs (withPrune args) [ "url" "repository" "username" ];
    in
    normalized // {
      repository = "rest:${args.url}/${args.repository}";
      backend = {
        type = "rest";
        username = args.username;
        credentials = [ "backend-password" ];
      };
    };

  s3 = args:
    let
      normalized = builtins.removeAttrs (withPrune args) [ "endpoint" "bucket" ];
    in
    normalized // {
      repository = "s3:${args.endpoint}/${args.bucket}";
      backend = {
        type = "s3";
        credentials = [
          "aws-access-key-id"
          "aws-secret-access-key"
        ];
      };
    };
}
