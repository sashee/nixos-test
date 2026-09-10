## Auto upgrade

* runs daily
* when the upgrade starts, it will:
    * run the nix-gc first
    * update the flake inputs
    * evaluate, making the drvs
    * build all outputs of each derivation one-by-one
    * when all of them are built then do the normal upgrade
* only one core and job is running concurrently
* switch only on boot, not live
