# The media library's iroh tunnel (common.mediaStoreTunnel); see modules/e2ee-store-tunnel.nix.
import ./e2ee-store-tunnel.nix {
  app = "media-store";
  option = "mediaStoreTunnel";
  title = "the media library";
  description = "Media library reachability over iroh";
}
