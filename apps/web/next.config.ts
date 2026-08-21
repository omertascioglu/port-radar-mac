import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Keeps the dev overlay out of /press screenshot captures
  devIndicators: false,
};

export default nextConfig;
