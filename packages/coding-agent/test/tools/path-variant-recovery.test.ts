import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { removeSyncWithRetries } from "@oh-my-pi/pi-utils";
import { Settings } from "../../src/config/settings";
import { EditTool } from "../../src/edit";
import type { ToolSession } from "../../src/tools";
import { GlobTool } from "../../src/tools/glob";
import { findPathVariant } from "../../src/tools/path-utils";
import { ReadTool } from "../../src/tools/read";

let root: string;
let cwd: string;

beforeEach(() => {
	root = fs.mkdtempSync(path.join(os.tmpdir(), "path-variant-"));
	// A workspace that lives under a dot directory, like `sandbox/.omp/`.
	cwd = path.join(root, "sandbox");
	fs.mkdirSync(path.join(cwd, ".omp", "hooks"), { recursive: true });
	fs.writeFileSync(path.join(cwd, ".omp", "config.yml"), "read:\n  defaultLimit: 600\n");
	fs.writeFileSync(path.join(cwd, ".omp", "hooks", "pre.ts"), "export const hook = 1;\n");
	fs.mkdirSync(path.join(cwd, "src"), { recursive: true });
	fs.writeFileSync(path.join(cwd, "src", "main.py"), "print('hi')\n");
});

afterEach(() => {
	removeSyncWithRetries(root);
});

function session(recover: boolean): ToolSession {
	return {
		cwd,
		hasUI: false,
		settings: Settings.isolated({ "tools.recoverPathVariants": recover, "edit.enforceSeenLines": false }),
		getSessionFile: () => null,
		getSessionSpawns: () => null,
	};
}

function text(result: { content: Array<{ type: string; text?: string }> }): string {
	return result.content.map(part => part.text ?? "").join("\n");
}

describe("findPathVariant", () => {
	test("restores the dropped dot of a dot directory", async () => {
		const match = await findPathVariant("omp/config.yml", cwd);
		expect(match).toEqual({
			absolutePath: path.join(cwd, ".omp", "config.yml"),
			displayPath: ".omp/config.yml",
			via: "dot-directory spelling",
		});
	});

	test("strips a repeated cwd basename", async () => {
		const match = await findPathVariant("sandbox/src/main.py", cwd);
		expect(match?.displayPath).toBe("src/main.py");
		expect(match?.via).toBe("repeated cwd prefix");
	});

	test("combines both rewrites, and handles absolute paths under the cwd", async () => {
		expect((await findPathVariant("sandbox/omp/hooks/pre.ts", cwd))?.displayPath).toBe(".omp/hooks/pre.ts");
		expect((await findPathVariant(path.join(cwd, "omp", "config.yml"), cwd))?.displayPath).toBe(".omp/config.yml");
	});

	test("never invents a file: no variant, ambiguity, globs, URLs, and parent escapes return null", async () => {
		expect(await findPathVariant("omp/missing.yml", cwd)).toBeNull();
		// Both `src/main.py` and `.src/main.py` exist → ambiguous → null.
		fs.mkdirSync(path.join(cwd, ".src"));
		fs.writeFileSync(path.join(cwd, ".src", "main.py"), "");
		expect(await findPathVariant("sandbox/src/main.py", cwd)).toBeNull();
		expect(await findPathVariant("omp/*.yml", cwd)).toBeNull();
		expect(await findPathVariant("skill://omp/config.yml", cwd)).toBeNull();
		expect(await findPathVariant("../sandbox/omp/config.yml", cwd)).toBeNull();
		expect(await findPathVariant(path.join(root, "omp", "config.yml"), cwd)).toBeNull();
	});
});

describe("tools.recoverPathVariants", () => {
	test("read: off by default, the missing path stays an error", async () => {
		const tool = new ReadTool(session(false));
		await expect(tool.execute("r0", { path: "omp/config.yml" })).rejects.toThrow("Path 'omp/config.yml' not found");
	});

	test("read: resolves the variant and announces it on the first line", async () => {
		const tool = new ReadTool(session(true));
		const result = await tool.execute("r1", { path: "omp/config.yml" });
		const out = text(result);
		expect(out.split("\n")[0]).toBe(
			"[Path 'omp/config.yml' not found; resolved to '.omp/config.yml' via dot-directory spelling]",
		);
		expect(out).toContain("defaultLimit: 600");
		expect(result.details?.suffixResolution).toEqual({
			from: "omp/config.yml",
			to: ".omp/config.yml",
			via: "dot-directory spelling",
		});
	});

	test("read: a path with no existing variant is still not found", async () => {
		const tool = new ReadTool(session(true));
		await expect(tool.execute("r2", { path: "omp/nope.yml" })).rejects.toThrow("Path 'omp/nope.yml' not found");
	});

	test("glob: lists the variant directory with the notice first", async () => {
		const tool = new GlobTool(session(true));
		const result = await tool.execute("g1", { path: "sandbox/omp" });
		const out = text(result);
		expect(out.split("\n")[0]).toBe(
			"[Path 'sandbox/omp' not found; resolved to '.omp' via repeated cwd prefix + dot-directory spelling]",
		);
		expect(result.details?.files).toEqual(expect.arrayContaining([".omp/config.yml", ".omp/hooks/pre.ts"]));
	});

	test("glob: off by default, the missing path stays an error", async () => {
		const tool = new GlobTool(session(false));
		await expect(tool.execute("g0", { path: "sandbox/omp" })).rejects.toThrow("Path not found");
	});

	test("edit: rewrites the path, applies the edit, and announces it", async () => {
		const tool = new EditTool(session(true), "replace");
		const result = await tool.execute("e1", {
			path: "sandbox/src/main.py",
			old_string: "print('hi')",
			new_string: "print('hello')",
		});
		expect(result.isError).not.toBe(true);
		expect(text(result).split("\n")[0]).toBe(
			"[Path 'sandbox/src/main.py' not found; resolved to 'src/main.py' via repeated cwd prefix]",
		);
		expect(fs.readFileSync(path.join(cwd, "src", "main.py"), "utf8")).toBe("print('hello')\n");
	});

	test("edit: off by default, the native session reports the missing file", async () => {
		const tool = new EditTool(session(false), "replace");
		const result = await tool.execute("e0", {
			path: "sandbox/src/main.py",
			old_string: "print('hi')",
			new_string: "print('hello')",
		});
		expect(result.isError).toBe(true);
		expect(fs.readFileSync(path.join(cwd, "src", "main.py"), "utf8")).toBe("print('hi')\n");
	});
});
