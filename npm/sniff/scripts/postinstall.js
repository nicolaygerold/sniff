#!/usr/bin/env node

import { existsSync, mkdirSync, copyFileSync, chmodSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const binDir = join(__dirname, "..", "bin");
const binPath = join(binDir, "sniff");

// Platform to package mapping
const PLATFORMS = {
  "darwin-arm64": "@nicgerold/sniff-darwin-arm64",
  "darwin-x64": "@nicgerold/sniff-darwin-x64",
  "linux-arm64": "@nicgerold/sniff-linux-arm64",
  "linux-x64": "@nicgerold/sniff-linux-x64",
};

function getPlatformPackage() {
  const platform = process.platform;
  const arch = process.arch;

  // Map Node.js platform/arch to our package names
  let key;
  if (platform === "darwin" && arch === "arm64") {
    key = "darwin-arm64";
  } else if (platform === "darwin" && arch === "x64") {
    key = "darwin-x64";
  } else if (platform === "linux" && arch === "arm64") {
    key = "linux-arm64";
  } else if (platform === "linux" && arch === "x64") {
    key = "linux-x64";
  } else {
    return null;
  }

  return PLATFORMS[key];
}

function main() {
  const packageName = getPlatformPackage();

  if (!packageName) {
    console.warn(
      `sniff: No prebuilt binary available for ${process.platform}-${process.arch}`
    );
    console.warn("You can build from source: https://github.com/nicolaygerold/sniff");
    process.exit(0);
  }

  try {
    // Try to find the platform-specific package
    const platformBinPath = join(
      dirname(require.resolve(`${packageName}/package.json`)),
      "bin",
      "sniff"
    );

    if (!existsSync(platformBinPath)) {
      console.warn(`sniff: Binary not found in ${packageName}`);
      process.exit(0);
    }

    // Ensure bin directory exists
    if (!existsSync(binDir)) {
      mkdirSync(binDir, { recursive: true });
    }

    // Copy binary
    copyFileSync(platformBinPath, binPath);
    chmodSync(binPath, 0o755);

    console.log(`sniff: Installed binary for ${process.platform}-${process.arch}`);
  } catch (err) {
    // Optional dependency not installed, that's okay
    if (err.code === "MODULE_NOT_FOUND") {
      console.warn(`sniff: Platform package ${packageName} not installed`);
      console.warn("You can build from source: https://github.com/nicolaygerold/sniff");
    } else {
      console.error(`sniff: Error during postinstall: ${err.message}`);
    }
    process.exit(0);
  }
}

main();
