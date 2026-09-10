## Auto upgrade

* runs daily
* when the upgrade starts, it will:
    * run the nix-gc first
    * update the flake inputs
    * evaluate, making the drvs
    * build each package one-by-one
    * when all of them are build then do the normal upgrade
* switch only on boot, not live
