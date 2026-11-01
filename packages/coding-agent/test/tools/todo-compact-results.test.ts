import { describe, expect, test } from "bun:test";
import type { TodoPhase } from "@oh-my-pi/pi-tui/tools/todo";
import { Settings } from "../../src/config/settings";
import type { ToolSession } from "../../src/tools";
import { TodoTool } from "../../src/tools/todo";

function createTool(compact: boolean): { tool: TodoTool; phases: () => TodoPhase[] } {
	let phases: TodoPhase[] = [];
	const session: ToolSession = {
		cwd: process.cwd(),
		hasUI: false,
		settings: Settings.isolated({ "todo.compactResults": compact }),
		getSessionFile: () => null,
		getSessionSpawns: () => null,
		getTodoPhases: () => phases,
		setTodoPhases: next => {
			phases = next;
		},
	};
	return { tool: new TodoTool(session), phases: () => phases };
}

function text(result: { content: Array<{ type: string; text?: string }> }): string {
	return result.content.map(part => part.text ?? "").join("\n");
}

const INIT = {
	op: "init" as const,
	list: [
		{ phase: "Plan", items: ["read the spec", "sketch the schema"] },
		{ phase: "Build", items: ["write the model", "write the tests", "wire the router"] },
	],
};

describe("todo.compactResults", () => {
	test("off by default: mutations return the full summary tree", async () => {
		const { tool } = createTool(false);
		await tool.execute("t1", INIT);
		const done = await tool.execute("t2", { op: "done", task: "read the spec" });
		const out = text(done);
		expect(out).toContain("Remaining items (4):");
		expect(out).toContain("Active phase 1/2");
		expect(out).toContain("    - [X] read the spec");
	});

	test("init echoes counts and the next task instead of the whole list", async () => {
		const { tool } = createTool(true);
		const out = text(await tool.execute("t1", INIT));
		expect(out).toBe("Initialized 5 tasks in 2 phases.\nOpen: 5 of 5. Next: read the spec [in_progress] (Plan).");
	});

	test("done reports only the changed items, the open count, and the next task", async () => {
		const { tool } = createTool(true);
		await tool.execute("t1", INIT);
		const out = text(await tool.execute("t2", { op: "done", task: "read the spec" }));
		expect(out).toBe(
			[
				"Changed (2):",
				"  read the spec: in_progress → completed",
				"  sketch the schema: pending → in_progress",
				"Open: 4 of 5. Next: sketch the schema [in_progress] (Plan).",
			].join("\n"),
		);
		// The compact form never replays the per-phase tree.
		expect(out).not.toContain("Remaining items");
		expect(out).not.toContain("Active phase");
	});

	test("block, append, and rm name the touched items", async () => {
		const { tool } = createTool(true);
		await tool.execute("t1", INIT);
		const blocked = text(
			await tool.execute("t2", { op: "block", task: "read the spec", reason: "waiting on\nuser" }),
		);
		expect(blocked).toContain("  read the spec: in_progress → blocked (blocked: waiting on user)");
		expect(blocked).toContain("Open: 4 of 5, 1 blocked. Next: sketch the schema [in_progress] (Plan).");

		const appended = text(await tool.execute("t3", { op: "append", phase: "Build", items: ["ship it"] }));
		expect(appended).toContain("  + ship it [pending] (Build)");
		expect(appended).toContain("Open: 5 of 6, 1 blocked.");

		const removed = text(await tool.execute("t4", { op: "rm", task: "ship it" }));
		expect(removed).toContain("  - ship it removed (Build)");
	});

	test("errors keep the Errors line and report no changes", async () => {
		const { tool, phases } = createTool(true);
		await tool.execute("t1", INIT);
		const before = JSON.stringify(phases());
		const result = await tool.execute("t2", { op: "done", task: "task-3" });
		expect(result.isError).toBe(true);
		const out = text(result);
		expect(out.startsWith('Errors: Task "task-3" not found.')).toBe(true);
		expect(out).toContain("Changed: none.");
		expect(JSON.stringify(phases())).toBe(before);
	});

	test("closing every task says so", async () => {
		const { tool } = createTool(true);
		await tool.execute("t1", { op: "init", items: ["only task"] });
		const out = text(await tool.execute("t2", { op: "done" }));
		expect(out).toBe("Changed (1):\n  only task: in_progress → completed\nOpen: 0 of 1. All tasks closed.");
	});

	test("view still returns the whole list", async () => {
		const { tool } = createTool(true);
		await tool.execute("t1", INIT);
		const out = text(await tool.execute("t2", { op: "view" }));
		expect(out).toContain("Remaining items (5):");
		expect(out).toContain("  Build:");
		expect(out).toContain("    - [ ] wire the router");
	});
});
