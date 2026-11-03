import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import type { ToolSession } from "@oh-my-pi/pi-coding-agent/tools";
import { removeWithRetries } from "@oh-my-pi/pi-utils";
import { ReadTool } from "../../src/tools/read";
import { resetReadDedupe } from "../../src/tools/read-dedupe";

// `read.dedupeUnchanged`: a re-read of the same file and selector, unchanged and still in context,
// answers with a stub. A changed file, a compaction (reset), an evicted earlier result, a `;` read,
// or the key off all return the content. Off is upstream behavior.

const STUB = "unchanged since your read";

/** A session whose "live context" is the set of call ids the test says are still there. */
function session(cwd: string, settings: Settings, inContext: Set<string>): ToolSession {
	return {
		cwd,
		hasUI: false,
		getSessionFile: () => null,
		getSessionSpawns: () => "*",
		settings,
		isToolResultInContext: id => inContext.has(id),
	};
}

function text(result: { content: Array<{ type: string; text?: string }> }): string {
	return result.content
		.filter(entry => entry.type === "text")
		.map(entry => entry.text ?? "")
		.join("\n");
}

describe("read.dedupeUnchanged", () => {
	let dir: string;
	let file: string;
	let live: Set<string>;
	let tool: ReadTool;
	let toolSession: ToolSession;

	/** One read call; its result enters the live context as the agent loop would append it. */
	async function read(id: string, readPath = "alpha.py"): Promise<string> {
		const out = text(await tool.execute(id, { path: readPath }));
		live.add(id);
		return out;
	}

	beforeEach(async () => {
		dir = await fs.mkdtemp(path.join(os.tmpdir(), "pi-read-dedupe-"));
		file = path.join(dir, "alpha.py");
		await Bun.write(file, "ALPHA = 1\nBETA = 2\nGAMMA = 3\n");
		await Bun.write(path.join(dir, "beta.py"), "BETA = 2\n");
		live = new Set();
		toolSession = session(dir, Settings.isolated({ "read.dedupeUnchanged": true }), live);
		tool = new ReadTool(toolSession);
	});

	afterEach(async () => {
		await removeWithRetries(dir);
	});

	it("stubs an unchanged second read of the same path and selector", async () => {
		expect(await read("c1")).toContain("ALPHA = 1");
		const second = await read("c2");
		expect(second).toContain(STUB);
		expect(second).toContain("alpha.py");
		expect(second).toContain("1 call ago");
		expect(second).not.toContain("ALPHA = 1");
		// Counted from the full read, not from the stub.
		await read("c3", "beta.py");
		expect(await read("c4")).toContain("3 calls ago");
	});

	it("reads a different selector in full", async () => {
		await read("c1");
		expect(await read("c2", "alpha.py:2-3")).toContain("BETA = 2");
	});

	it("returns the content again when the file changed", async () => {
		await read("c1");
		await Bun.write(file, "ALPHA = 10\nBETA = 2\nGAMMA = 3\n");
		expect(await read("c2")).toContain("ALPHA = 10");
	});

	it("returns the content again after an edit/write bumped the mutation counter", async () => {
		let version = 0;
		toolSession.getFileMutationVersion = () => version;
		await read("c1");
		version++;
		expect(await read("c2")).toContain("ALPHA = 1");
	});

	it("returns the content again after a compaction reset", async () => {
		await read("c1");
		resetReadDedupe(toolSession);
		expect(await read("c2")).toContain("ALPHA = 1");
	});

	it("returns the content again when the earlier result left the context", async () => {
		await read("c1");
		live.delete("c1");
		expect(await read("c2")).toContain("ALPHA = 1");
	});

	it("never stubs `;` multi-path reads", async () => {
		await read("c1", "alpha.py;beta.py");
		expect(await read("c2", "alpha.py;beta.py")).toContain("ALPHA = 1");
		expect(await read("c3")).toContain("ALPHA = 1");
	});

	it("returns full content with the key off", async () => {
		tool = new ReadTool(session(dir, Settings.isolated(), live));
		await read("c1");
		expect(await read("c2")).toContain("ALPHA = 1");
	});
});
