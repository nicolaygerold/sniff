import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import { EventEmitter } from "events";
import * as readline from "readline";

export interface SearchResult {
  path: string;
  score: number;
  positions: number[];
}

export interface ReadyMessage {
  type: "ready";
  files: number;
  indexTime: number;
}

export interface ResultsMessage {
  type: "results";
  query: string;
  searchTime: number;
  results: SearchResult[];
}

export interface ErrorMessage {
  type: "error";
  message: string;
}

type Message = ReadyMessage | ResultsMessage | ErrorMessage;

export interface SniffOptions {
  /** Path to sniff binary (default: "sniff") */
  binPath?: string;
  /** Maximum results to return (default: 100) */
  maxResults?: number;
  /** Timeout for searches in ms (default: 5000) */
  timeout?: number;
}

export class Sniff extends EventEmitter {
  private process: ChildProcessWithoutNullStreams | null = null;
  private rl: readline.Interface | null = null;
  private ready: boolean = false;
  private pendingSearch: {
    resolve: (results: SearchResult[]) => void;
    reject: (error: Error) => void;
    timeout: NodeJS.Timeout;
  } | null = null;

  public files: number = 0;
  public indexTime: number = 0;

  constructor(private options: SniffOptions = {}) {
    super();
  }

  /**
   * Initialize the fuzzy finder with a directory to index
   */
  async init(directory: string): Promise<void> {
    const binPath = this.options.binPath ?? "sniff";
    const args = ["--json"];

    if (this.options.maxResults) {
      args.push("--limit", this.options.maxResults.toString());
    }

    args.push(directory);

    return new Promise((resolve, reject) => {
      this.process = spawn(binPath, args, {
        stdio: ["pipe", "pipe", "pipe"],
      });

      this.process.on("error", (err) => {
        reject(new Error(`Failed to start sniff: ${err.message}`));
      });

      this.process.on("exit", (code) => {
        this.ready = false;
        this.emit("exit", code);
      });

      this.process.stderr.on("data", (data) => {
        this.emit("error", new Error(data.toString()));
      });

      // Parse newline-delimited JSON from stdout
      this.rl = readline.createInterface({
        input: this.process.stdout,
        crlfDelay: Infinity,
      });

      this.rl.on("line", (line) => {
        try {
          const msg: Message = JSON.parse(line);
          this.handleMessage(msg, resolve);
        } catch (e) {
          this.emit("error", new Error(`Failed to parse: ${line}`));
        }
      });
    });
  }

  private handleMessage(
    msg: Message,
    initResolve?: (value: void) => void
  ): void {
    switch (msg.type) {
      case "ready":
        this.ready = true;
        this.files = msg.files;
        this.indexTime = msg.indexTime;
        this.emit("ready", msg);
        if (initResolve) initResolve();
        break;

      case "results":
        if (this.pendingSearch) {
          clearTimeout(this.pendingSearch.timeout);
          this.pendingSearch.resolve(msg.results);
          this.pendingSearch = null;
        }
        this.emit("results", msg);
        break;

      case "error":
        const error = new Error(msg.message);
        if (this.pendingSearch) {
          clearTimeout(this.pendingSearch.timeout);
          this.pendingSearch.reject(error);
          this.pendingSearch = null;
        }
        this.emit("error", error);
        break;
    }
  }

  /**
   * Search for files matching the query
   */
  async search(query: string): Promise<SearchResult[]> {
    if (!this.ready || !this.process) {
      throw new Error("Sniff not initialized. Call init() first.");
    }

    if (this.pendingSearch) {
      throw new Error("Search already in progress");
    }

    const timeout = this.options.timeout ?? 5000;

    return new Promise((resolve, reject) => {
      this.pendingSearch = {
        resolve,
        reject,
        timeout: setTimeout(() => {
          this.pendingSearch = null;
          reject(new Error("Search timed out"));
        }, timeout),
      };

      this.process!.stdin.write(query + "\n");
    });
  }

  /**
   * Close the sniff process
   */
  close(): void {
    if (this.rl) {
      this.rl.close();
      this.rl = null;
    }
    if (this.process) {
      this.process.stdin.end();
      this.process.kill();
      this.process = null;
    }
    this.ready = false;
  }

  /**
   * Check if sniff is ready for queries
   */
  isReady(): boolean {
    return this.ready;
  }
}

// Convenience function for one-off searches
export async function search(
  directory: string,
  query: string,
  options?: SniffOptions
): Promise<SearchResult[]> {
  const sniff = new Sniff(options);
  try {
    await sniff.init(directory);
    return await sniff.search(query);
  } finally {
    sniff.close();
  }
}

export default Sniff;
