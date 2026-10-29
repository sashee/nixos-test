# The password manager's iroh tunnel (common.pwMgrTunnel); see modules/e2ee-store-tunnel.nix.
import ./e2ee-store-tunnel.nix {
  app = "pw-mgr";
  option = "pwMgrTunnel";
  title = "the password manager";
  description = "Password manager reachability over iroh";
}
