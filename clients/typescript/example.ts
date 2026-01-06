import Sniff, { search } from "./sniff";

async function main() {
  // Example 1: One-off search
  console.log("=== One-off search ===");
  const results = await search(".", "main", {
    binPath: "../../zig-out/bin/sniff",
  });
  console.log("Results:", results);

  // Example 2: Persistent instance for multiple queries
  console.log("\n=== Persistent instance ===");
  const sniff = new Sniff({
    binPath: "../../zig-out/bin/sniff",
    maxResults: 10,
  });

  await sniff.init("../..");
  console.log(`Indexed ${sniff.files} files in ${sniff.indexTime}ms`);

  // Multiple searches reuse the same index
  const queries = ["main", "sniff", "scorer", "json"];

  for (const query of queries) {
    const start = Date.now();
    const results = await sniff.search(query);
    console.log(
      `\n"${query}" (${Date.now() - start}ms): ${results.length} results`
    );
    results.slice(0, 3).forEach((r) => {
      console.log(`  ${r.path} (score: ${r.score})`);
    });
  }

  sniff.close();
}

main().catch(console.error);
