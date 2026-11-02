import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import type { ToolSession } from "@oh-my-pi/pi-coding-agent/tools";
import { removeWithRetries } from "@oh-my-pi/pi-utils";
import { ReadTool } from "../../src/tools/read";

// `read.advertiseMultiPath`: the read description names the `;` form, and that form reads every part
// in one call. Off is the upstream description.

function session(cwd: string, settings: Settings): ToolSession {
	return { cwd, hasUI: false, getSessionFile: () => null, getSessionSpawns: () => "*", settings };
}

function text(result: { content: Array<{ type: string; text?: string }> }): string {
	return result.content
		.filter(entry => entry.type === "text")
		.map(entry => entry.text ?? "")
		.join("\n");
}

describe("read.advertiseMultiPath", () => {
	let dir: string;

	beforeEach(async () => {
		dir = await fs.mkdtemp(path.join(os.tmpdir(), "pi-read-multi-path-"));
		await Bun.write(path.join(dir, "alpha.py"), "ALPHA = 1\n");
		await Bun.write(path.join(dir, "beta.py"), "BETA = 2\n");
	});

	afterEach(async () => {
		await removeWithRetries(dir);
	});

	it("is absent from the description by default", () => {
		const tool = new ReadTool(session(dir, Settings.isolated()));
		expect(tool.description).not.toContain("Several files in one call");
	});

	it("names the `;` form when on", () => {
		const tool = new ReadTool(session(dir, Settings.isolated({ "read.advertiseMultiPath": true })));
		expect(tool.description).toContain("Several files in one call");
		expect(tool.description).toContain('"a.py;b.py:10-40;docs/c.md"');
	});

	it("reads every `;` part in one call, as the description says", async () => {
		const tool = new ReadTool(session(dir, Settings.isolated({ "read.advertiseMultiPath": true })));
		const out = text(await tool.execute("multi", { path: "alpha.py;beta.py" }));
		expect(out).toContain("ALPHA = 1");
		expect(out).toContain("BETA = 2");
	});
});
