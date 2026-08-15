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
  # The repository location is a credential, not configuration, so these only name the backend
  # and the credential files it needs. The repository string itself lives in the `repository`
  # blob in the backup's credentialDirectory.
  rest = args:
    withPrune args // {
      backend = {
        type = "rest";
        credentials = [
          "backend-username"
          "backend-password"
        ];
      };
    };

  s3 = args:
    withPrune args // {
      backend = {
        type = "s3";
        credentials = [
          "aws-access-key-id"
          "aws-secret-access-key"
        ];
      };
    };
}
