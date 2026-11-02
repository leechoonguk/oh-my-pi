import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { buildSystemPrompt } from "@oh-my-pi/pi-coding-agent/system-prompt";
import { cleanupTempHome } from "./helpers/temp-home-cleanup";

const EMPTY_TREE = { rootPath: "", rendered: "", truncated: false, totalLines: 0, agentsMdFiles: [] };
const RULES = [
	{ name: "backend-api", description: "Router shape", path: "/r/backend-api.md", globs: ["backend/app/routers/**"] },
];

describe("rules.omitListGlobs", () => {
	let tempDir = "";
	let tempHomeDir = "";
	let originalHome: string | undefined;

	beforeEach(() => {
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-rule-globs-"));
		tempHomeDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-rule-globs-home-"));
		originalHome = process.env.HOME;
		process.env.HOME = tempHomeDir;
	});

	afterEach(cleanupTempHome(() => ({ tempDir, tempHomeDir, originalHome })));

	async function render(omitRuleGlobs?: boolean): Promise<string> {
		const { systemPrompt } = await buildSystemPrompt({
			cwd: tempDir,
			contextFiles: [],
			skills: [],
			rules: RULES,
			omitRuleGlobs,
			toolNames: [],
			workspaceTree: { ...EMPTY_TREE, rootPath: tempDir },
		});
		return systemPrompt.join("\n\n");
	}

	it("unset lists each rule with its globs (upstream)", async () => {
		expect(await render()).toContain("- backend-api (backend/app/routers/**): Router shape");
	});

	it("set lists each rule by name and description only", async () => {
		const rendered = await render(true);
		expect(rendered).toContain("- backend-api: Router shape");
		expect(rendered).not.toContain("backend/app/routers/**");
	});
});
