import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The repository also contains a root lockfile for non-admin tooling. Pin
  // tracing to this deployable app so Next does not infer the wrong root and
  // bundle unrelated workspace files into the server artifact.
  outputFileTracingRoot: dirname(fileURLToPath(import.meta.url)),
};

export default nextConfig;
