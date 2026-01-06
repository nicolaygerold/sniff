#!/usr/bin/env node

import { existsSync, copyFileSync, chmodSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const binDir = join(__dirname, "..", "bin");

// Map platform/arch to binary name
function getBinaryName() {
  const platform = process.platform;
  const arch = process.arch;

  if (platform === "darwin" && arch === "arm64") return "sniff-darwin-arm64";
  if (platform === "darwin" && arch === "x64") return "sniff-darwin-x64";
  if (platform === "linux" && arch === "arm64") return "sniff-linux-arm64";
  if (platform === "linux" && arch === "x64") return "sniff-linux-x64";
  
  return null;
}

function main() {
  const binaryName = getBinaryName();
  
  if (!binaryName) {
    console.warn(`sniff: No prebuilt binary for ${process.platform}-${process.arch}`);
    console.warn("Build from source: https://github.com/nicolaygerold/sniff");
    process.exit(0);
  }

  const sourcePath = join(binDir, binaryName);
  const targetPath = join(binDir, "sniff");

  if (!existsSync(sourcePath)) {
    console.warn(`sniff: Binary ${binaryName} not found`);
    process.exit(0);
  }

  // Copy platform binary to "sniff"
  copyFileSync(sourcePath, targetPath);
  chmodSync(targetPath, 0o755);
}

main();
