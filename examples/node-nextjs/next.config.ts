// next.config.ts - standalone output: .next/standalone/server.js plus only the node_modules it imports,
// so the daemon starts `node server.js` without `next start` or the full dependency tree.
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  compress: false, // Nginx compresses; doing it twice wastes CPU on a small droplet
};

export default nextConfig;
